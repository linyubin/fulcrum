#lang racket/base

;; FPP2 end-to-end tests: daemon lifecycle, request interleaving, the
;; run-action/detail ops, result actions, preferences injection, push
;; nudges, and crash backoff. The fixture plugin is a Racket script
;; speaking one-JSON-object-per-line over stdio — the exact contract real
;; plugins implement in any language, runnable on every CI OS.

(require racket/file
         racket/list
         racket/port
         racket/string
         rackunit
         "../app/core/engine.rkt"
         "../app/core/paths.rkt"
         "../app/core/plugins.rkt")

;; The fixture needs the racket executable; without one on PATH the whole
;; end-to-end suite skips (the parse/validation paths still run).
(define racket-path
  (or (find-executable-path "racket")
      (find-executable-path "racket.exe")))

(define (with-racket body-thunk)
  (if racket-path
      (body-thunk)
      (displayln "skipping FPP2 end-to-end: no racket on PATH")))

;; The daemon fixture: counts invocations in a state file (so tests can
;; tell warm from cold), echoes the preference token from env and payload,
;; offers a result action, marks the first result detail-request, and can
;; crash on demand or spam results-changed events.
(define fixture-script
  #<<RACKET
#lang racket/base
(require json racket/file racket/string)
(define state-dir (or (getenv "FULCRUM_FIXTURE_STATE") "."))
(define (write-file p v)
  (call-with-output-file p (lambda (out) (display v out)) #:exists 'truncate))
(define count-path (build-path state-dir "count"))
(define clean-n
  (add1
   (let ([n (with-handlers ([exn:fail? (lambda (_) 0)])
              (string->number
               (string-trim (file->string count-path))))])
     (if (exact-integer? n) n 0))))
(write-file count-path (number->string clean-n))
(let loop ()
  (define line (read-line))
  (unless (eof-object? line)
    (define req (with-handlers ([exn:fail? (lambda (_) (hasheq))])
                  (string->jsexpr line)))
    (define rid (hash-ref req 'request_id 0))
    (define prefs (hash-ref req 'prefs (hasheq)))
    (case (hash-ref req 'op "")
      [("query")
       (define query (hash-ref req 'query ""))
       (cond
         [(string=? query "crash") (exit 1)]
         [(string=? query "churn")
          (for ([_ (in-range 5)])
            (displayln (jsexpr->string (hasheq 'event "results-changed"))))
          (printf "~a\n" (jsexpr->string
                          (hasheq 'request_id rid
                                  'results (list (hasheq 'title "churn" 'arg "c")))))]
         [else
          (printf "~a\n"
                  (jsexpr->string
                   (hasheq 'request_id rid
                           'results (list
                                     (hasheq 'title (format "~a" clean-n)
                                             'subtitle (format "env=~a payload=~a"
                                                               (getenv "FULCRUM_PLUGIN_PREF_TOKEN")
                                                               (hash-ref prefs 'token ""))
                                             'arg "a"
                                             'actions (list (hasheq 'id "ping" 'title "Ping"))
                                             'detail-request #t)))))])]
      [("run") (printf "~a\n" (jsexpr->string (hasheq 'request_id rid 'status "ok")))]
      [("run-action") (printf "~a\n" (jsexpr->string (hasheq 'request_id rid 'status "ok")))]
      [("detail") (printf "~a\n" (jsexpr->string
                                  (hasheq 'request_id rid
                                          'text "deep detail"
                                          'metadata (list (list "k" "v")))))]
      [else (printf "~a\n" (jsexpr->string (hasheq 'request_id rid 'status "error")))])
    ;; Daemon-mode plugins are long-lived: stdout is block-buffered, so
    ;; every response must be flushed explicitly.
    (flush-output)
    (loop)))
RACKET
  )

(define fixture-manifest
  #<<JSON
{
  "id": "fpp2d",
  "protocol": 2,
  "mode": "daemon",
  "name": "FPP2 Daemon",
  "version": "1.0.0",
  "description": "conformance fixture",
  "icon": "plugin",
  "entry": {"exec": ["RACKET", "fixture.rkt"]},
  "commands": [
    {"id": "search", "name": "Search", "keyword": "fx",
     "actions": [{"id": "ping", "title": "Ping"}]}
  ],
  "preferences": [
    {"name": "token", "type": "secret", "label": "Token", "default": "seed"},
    {"name": "level", "type": "select", "label": "Level",
     "choices": ["low", "high"], "default": "low"}
  ],
  "permissions": []
}
JSON
  )

(define bad-pref-manifest
  #<<JSON
{
  "id": "badpref",
  "protocol": 2,
  "name": "Bad Pref",
  "version": "1.0.0",
  "entry": {"exec": ["RACKET", "fixture.rkt"]},
  "commands": [{"id": "search", "name": "Search", "keyword": "bp"}],
  "preferences": [
    {"name": "level", "type": "select", "label": "No choices"}
  ]
}
JSON
  )

(define (write-file! path contents)
  (call-with-output-file path
    (lambda (out) (display contents out))
    #:exists 'truncate))

(define (call-with-fixture thunk)
  (define dir (make-temporary-file "fulcrum-fpp2-~a" 'directory))
  (define state-dir (build-path dir "state"))
  (make-directory* state-dir)
  (define plug (build-path dir "fpp2d"))
  (make-directory* plug)
  ;; A Windows racket path carries backslashes, which are JSON escape
  ;; characters — double them before substituting into the manifest.
  (define racket-json
    (string-replace (path->string racket-path) "\\" "\\\\"))
  (write-file! (build-path plug "manifest.json")
               (string-replace fixture-manifest "RACKET" racket-json))
  (write-file! (build-path plug "fixture.rkt") fixture-script)
  (define bad (build-path dir "badpref"))
  (make-directory* bad)
  (write-file! (build-path bad "manifest.json")
               (string-replace bad-pref-manifest "RACKET" racket-json))
  (write-file! (build-path bad "fixture.rkt") fixture-script)
  (dynamic-wind
    (lambda () (thunk dir state-dir))
    (lambda () (delete-directory/files dir))
    (lambda () void)))

;; ---- manifest v2 parsing (no spawn) ---------------------------------------

(test-case "manifest v2 fields parse; invalid preferences are dropped loudly"
  (call-with-fixture
   (lambda (dir state-dir)
     (define nudges (box 0))
     (define mgr (make-plugin-manager dir #:nudge-thunk (lambda () (set-box! nudges 0))))
     (define plugins (plugin-manager-plugins mgr))
     (define p (findf (lambda (p) (string=? (plugin-id p) "fpp2d")) plugins))
     (check-true (and p #t))
     (check-equal? (plugin-protocol p) 2)
     (check-equal? (plugin-mode p) "daemon")
     (check-equal? (length (plugin-preferences p)) 2)
     (define token (findf (lambda (s) (string=? (plugin-pref-name s) "token"))
                          (plugin-preferences p)))
     (check-equal? (plugin-pref-type token) "secret")
     (check-equal? (plugin-pref-default token) "seed")
     (define c (car (plugin-commands p)))
     (check-equal? (length (plugin-command-actions c)) 1)
     ;; The select preference without choices is rejected with an error
     ;; line; the plugin itself still loads.
     (define bad (findf (lambda (p) (string=? (plugin-id p) "badpref")) plugins))
     (check-true (and bad #t))
     (check-equal? (length (plugin-preferences bad)) 0)
     (check-true (pair? (plugin-manager-errors mgr)))
     (check-true (ormap (lambda (e) (string-contains? e "invalid preference"))
                        (plugin-manager-errors mgr))))))

;; ---- daemon + prefs + ops --------------------------------------------------

(with-racket
 (lambda ()
   (test-case "daemon serves warm queries with preferences injected"
     (call-with-fixture
      (lambda (dir state-dir)
        (define nudges (box 0))
        (define mgr
          (make-plugin-manager dir
                               #:timeout-ms 5000
                               #:nudge-thunk (lambda () (set-box! nudges (add1 (unbox nudges))))
                               #:prefs-thunk (lambda (id)
                                               (if (string=? id "fpp2d")
                                                   (hasheq 'token "injected")
                                                   (hash)))))
        (define first-rows (plugin-manager-query mgr "fx one"))
        (check-equal? (length first-rows) 1)
        (check-equal? (list-ref (car first-rows) 0) "1")
        ;; The env injection and the payload injection both made it through.
        (check-true (string-contains? (list-ref (car first-rows) 1)
                                      "env=injected"))
        (check-true (string-contains? (list-ref (car first-rows) 1)
                                      "payload=injected"))
        ;; Second query on the warm daemon: the fixture's counter file
        ;; increments, and the row still works — request interleaving is
        ;; exercised implicitly by the backend's own query flow.
        (define second-rows (plugin-manager-query mgr "fx two"))
        (check-equal? (length second-rows) 1)
        (check-equal? (plugin-manager-daemon-state mgr "fpp2d") 'running)
        ;; detail-request flag rode on the row.
        (check-true (list-ref (car second-rows) 5))))

   (test-case "run-action and detail ops work over the daemon"
     (call-with-fixture
      (lambda (dir state-dir)
        (define mgr (make-plugin-manager dir #:timeout-ms 5000))
        (plugin-manager-query mgr "fx warm")
        (check-equal? (plugin-manager-run! mgr "fpp2d:search" "a") "ok")
        (check-equal? (plugin-manager-run-action! mgr "fpp2d:search" "a" "ping") "ok")
        (define detail (plugin-manager-detail! mgr "fpp2d:search" "a"))
        (check-true (hash? detail))
        (check-equal? (hash-ref detail 'text) "deep detail")
        (check-equal? (hash-ref detail 'metadata) (list (list "k" "v"))))))

   (test-case "result actions reach the ⌘K panel through the cache"
     (call-with-fixture
      (lambda (dir state-dir)
        (define mgr (make-plugin-manager dir #:timeout-ms 5000))
        (plugin-manager-query mgr "fx x")
        (define actions (plugin-manager-row-actions mgr "fpp2d:search" "a"))
        (check-true (pair? actions))
        ;; The detail affordance comes first (the row declared
        ;; detail-request), then the result's own action.
        (check-equal? (car (car actions)) "__detail")
        (check-true (ormap (lambda (a) (string=? (car a) "ping")) actions))
        (check-equal? (cdr (findf (lambda (a) (string=? (car a) "ping")) actions))
                      "Ping"))))

   (test-case "results-changed pushes are rate-limited through the nudge"
     (call-with-fixture
      (lambda (dir state-dir)
        (define nudges (box 0))
        (define mgr
          (make-plugin-manager dir
                               #:timeout-ms 5000
                               #:nudge-thunk (lambda () (set-box! nudges (add1 (unbox nudges))))))
        (plugin-manager-query mgr "fx churn")
        ;; The fixture pushed five events for one query; the nudge thunk
        ;; must have fired at least once but far fewer than five times.
        (define count (unbox nudges))
        (check-true (>= count 1) "at least one nudge")
        (check-true (<= count 2) "rate-limited well below the event count"))))

   (test-case "crashes back off, then fall back to cold spawns honestly"
     (call-with-fixture
      (lambda (dir state-dir)
        (define mgr
          (make-plugin-manager dir
                               #:timeout-ms 5000
                               #:daemon-backoff-ms '(10 10 10)))
        ;; Warm the daemon, then crash it.
        (plugin-manager-query mgr "fx warm")
        (check-equal? (plugin-manager-daemon-state mgr "fpp2d") 'running)
        (define crashed (plugin-manager-query mgr "fx crash"))
        (check-equal? crashed '() "the crashing op yields no rows")
        ;; During backoff the cold-spawn fallback still serves queries.
        (define fallback (plugin-manager-query mgr "fx fallback"))
        (check-true (pair? fallback) "cold fallback serves during backoff")
        ;; Drive three daemon crashes quickly (tiny backoffs): after the
        ;; third the daemon is failed for the session, and cold spawn
        ;; keeps serving.
        (let loop ([i 0])
          (when (< i 6)
            (plugin-manager-query mgr "fx crash")
            (sleep 0.03)
            (loop (add1 i))))
        (check-false (eq? (plugin-manager-daemon-state mgr "fpp2d") 'running))
        (define still-works (plugin-manager-query mgr "fx after-fail"))
        (check-true (pair? still-works) "failed daemon never strands the user"))))

   (test-case "engine routes detail rows and plugin actions"
     (call-with-fixture
      (lambda (dir state-dir)
        (define mgr (make-plugin-manager dir #:timeout-ms 5000))
        (define engine (make-engine #:clipboard-store #f
                                    #:snippet-store #f
                                    #:plugin-manager mgr))
        (define rows (engine-search engine "fx q"))
        (check-true (pair? rows))
        (define row (car rows))
        ;; The result declared detail-request, so the row id routes to the
        ;; detail surface.
        (check-true (string-prefix? (list-ref row 0) "plugin-detail:"))
        (check-equal? (car (engine-run engine (list-ref row 0) (list-ref row 4)))
                      "detail")
        ;; ⌘K on the row offers the fixture's action; running it succeeds.
        (define actions (engine-row-actions engine (list-ref row 0) (list-ref row 4)))
        (check-true (pair? actions))
        (define ping-row (findf (lambda (a) (string-contains? (list-ref a 0) ":ping"))
                                actions))
        (check-true (and ping-row #t))
        (check-equal? (car (engine-run engine (list-ref ping-row 0) (list-ref row 4)))
                      "ok")))))))

;; ---- preference value validation (pure) ------------------------------------

(test-case "preference value validation follows the declared spec"
  (define select-spec (plugin-pref "level" "select" "Level" "low" #f (list "low" "high") ""))
  (define bool-spec (plugin-pref "flag" "boolean" "Flag" "false" #f '() ""))
  (define text-spec (plugin-pref "name" "text" "Name" "" #t '() ""))
  (check-true (validate-plugin-pref-value select-spec "high"))
  (check-false (validate-plugin-pref-value select-spec "medium"))
  (check-true (validate-plugin-pref-value bool-spec "true"))
  (check-false (validate-plugin-pref-value bool-spec "maybe"))
  (check-false (validate-plugin-pref-value text-spec "  ") "required text")
  (check-true (validate-plugin-pref-value text-spec "ok")))
