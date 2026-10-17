#lang racket/base

;; Fulcrum Plugin Protocol v1 (FPP1) + v2 (FPP2).
;;
;; A plugin is a directory under the plugins directory containing
;; manifest.json and an executable entry. The manifest declares metadata,
;; commands, and an argv-style entry:
;;
;;   {
;;     "id": "epoch",
;;     "protocol": 2,
;;     "mode": "daemon",
;;     "name": "Epoch",
;;     "version": "0.1.0",
;;     "description": "Unix timestamp ↔ date",
;;     "icon": "plugin",
;;     "entry": {"exec": ["/usr/bin/python3", "epoch.py"]},
;;     "commands": [
;;       {"id": "convert", "name": "Convert timestamp", "keyword": "ts"}
;;     ],
;;     "preferences": [
;;       {"name": "token", "type": "secret", "label": "API token"}
;;     ],
;;     "permissions": []
;;   }
;;
;; Wire protocol: one JSON object per line on stdin/stdout.
;;   → {"op":"query","command":"<cid>","query":"...","request_id":1}
;;   ← {"request_id":1,"results":[{"title":"…","subtitle":"…","arg":"…",
;;        "icon":"…","actions":[{"id":"x","title":"X"}],"detail-request":true}]}
;;   → {"op":"run"/"run-action","command":"<cid>","arg":"…","action":"…",…}
;;   ← {"request_id":2,"status":"ok","message":"optional"}
;;   → {"op":"detail","command":"<cid>","arg":"…",…}
;;   ← {"request_id":3,"text":"…","metadata":[["k","v"],…]}
;;
;; FPP1 semantics (no "protocol" field): every query/run spawns a fresh
;; process and kills it afterwards, bounded by the timeout. FPP2 opts in
;; per plugin: "mode":"daemon" keeps one warm process per backend session
;; with request interleaving, crash backoff, and rate-limited push
;; events; results may carry ⌘K actions and a detail flag; preferences
;; declared in the manifest are injected by the backend (env + payload).
;; The process boundary stays, and every op stays timeout-bounded: a
;; broken plugin costs its own timeout, never the launcher.
;;
;; Manifest permissions remain advisory metadata; enforcing them is the
;; staged roadmap in docs/fpp2.md, and the docs all say so.

(require json
         racket/async-channel
         racket/contract
         racket/file
         racket/list
         racket/path
         racket/port
         racket/string
         "proc.rkt")

(provide (struct-out plugin)
         (struct-out plugin-command)
         (struct-out plugin-pref)
         (struct-out plugin-manager)
         make-plugin-manager
         plugin-manager-reload!
         plugin-manager-plugins
         plugin-manager-errors
         plugin-manager-disabled-plugins
         plugin-manager-query
         plugin-manager-run!
         plugin-manager-run-action!
         plugin-manager-detail!
         plugin-manager-row-actions
         plugin-manager-command-exists?
         plugin-manager-prefs-changed!
         plugin-manager-daemon-state
         valid-plugin-action-id?
         valid-plugin-command-id?
         validate-plugin-pref-value)

(struct plugin (id name version description icon commands entry permissions
                protocol mode preferences)
  #:transparent)

(struct plugin-command (id name keyword description icon actions) #:transparent)

;; A declared user preference. `type` is one of "text", "secret",
;; "boolean", "select" (select carries `choices`). Values are stored and
;; injected by the backend; plugins never manage config files.
(struct plugin-pref (name type label default required choices description)
  #:transparent)

;; The manager is a closure holder: dirs, timeout, loaded plugins, and load
;; errors, guarded by one lock. Plugins themselves are immutable snapshots.
;; `disabled-thunk` names the plugins the user turned off; it is consulted
;; on every reload so a toggle takes effect without rebuilding anything.
;; `daemons` holds the warm FPP2 processes (plugin id → daemon), killed on
;; reload. `nudge-thunk` fires (rate-limited) when a daemon pushes
;; results-changed; `prefs-thunk` supplies the preference values injected
;; into every request.
(struct plugin-manager (path timeout-ms state lock disabled-thunk
                        daemons nudge-thunk prefs-thunk backoff-ms)
  #:mutable)

(define max-manifest-bytes 65536)
(define max-commands-per-plugin 32)
(define max-results-per-query 10)
(define max-preferences-per-plugin 16)
(define max-actions-per-result 4)
;; Rate limit for one daemon's results-changed pushes, per command.
(define nudge-min-interval-ms 1000)
;; Crash policy: a daemon that crashes this many times inside the window
;; is marked failed for the session (cold-spawn fallback still serves it).
(define daemon-fail-threshold 3)
(define daemon-fail-window-ms 300000)

(define (safe-read-json-file path)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (when (> (file-size path) max-manifest-bytes)
      (error 'load-plugin "manifest too large"))
    (define text (file->string path))
    (string->jsexpr text)))

;; Ids travel inside row action ids ("plugin-action:<pid>:<cid>:<aid>"),
;; so colons would make the routing ambiguous. Enforced at load; the
;; registry CI enforces the same shape for submissions.
(define id-regexp #rx"^[A-Za-z0-9][A-Za-z0-9_-]*$")

(define (valid-plugin-command-id? v)
  (and (string? v) (regexp-match? id-regexp v)))

(define (valid-plugin-action-id? v)
  (and (string? v) (regexp-match? id-regexp v)))

(define (parse-actions raw)
  (if (not (list? raw))
      '()
      (for/list ([a (in-list raw)]
                 #:when (and (hash? a)
                             (valid-plugin-action-id? (hash-ref a 'id #f))
                             (string? (hash-ref a 'title #f))))
        (cons (hash-ref a 'id) (hash-ref a 'title)))))

(define pref-types '("text" "secret" "boolean" "select"))

(define (valid-pref-decl? p)
  (define name (hash-ref p 'name #f))
  (define type (hash-ref p 'type #f))
  (define choices (hash-ref p 'choices #f))
  (and (string? name)
       (regexp-match? id-regexp name)
       (member type pref-types)
       (or (not (equal? type "select"))
           (and (list? choices) (pair? choices) (andmap string? choices)))))

(define (parse-preferences raw errors-box)
  (if (not (list? raw))
      '()
      (for/list ([p (in-list (take-min raw max-preferences-per-plugin))]
                 #:when (hash? p))
        (define name (hash-ref p 'name #f))
        (define type (hash-ref p 'type #f))
        (cond
          [(valid-pref-decl? p)
           (plugin-pref name
                        type
                        (or (and (string? (hash-ref p 'label #f))
                                 (hash-ref p 'label))
                            name)
                        (or (and (string? (hash-ref p 'default #f))
                                 (hash-ref p 'default))
                            "")
                        (eq? (hash-ref p 'required #f) #t)
                        (if (equal? type "select")
                            (hash-ref p 'choices '())
                            '())
                        (or (and (string? (hash-ref p 'description #f))
                                 (hash-ref p 'description))
                            ""))]
          [else
           (set-box! errors-box
                     (cons (format "invalid preference declaration ignored (~a)"
                                   (if (string? name) name "?"))
                           (unbox errors-box)))
           #f]))))

;; A stored value must respect the declared spec: select values come from
;; choices, booleans are true/false, everything else is non-empty when
;; required. Exported so the backend `plugin set` route and the registry
;; validator share one definition of valid.
(define (validate-plugin-pref-value pref value)
  (and (plugin-pref? pref)
       (string? value)
       (case (plugin-pref-type pref)
         [("boolean") (pair? (member value '("true" "false")))]
         [("select") (pair? (member value (plugin-pref-choices pref)))]
         [else (or (not (plugin-pref-required pref))
                   (non-empty-string? (string-trim value)))])))

(define (manifest->plugin dir manifest)
  (define (str key [default #f])
    (define v (hash-ref manifest key default))
    (and (string? v) (non-empty-string? v) v))
  (define id (str 'id))
  (define name (str 'name))
  (define entry (hash-ref manifest 'entry #f))
  (define exec
    (and (hash? entry)
         (let ([argv (hash-ref entry 'exec #f)])
           (and (list? argv)
                (pair? argv)
                (andmap string? argv)
                ;; Arguments resolve against the plugin directory; the
                ;; program itself stays as written (absolute path or PATH
                ;; lookup) unless it clearly names a relative file.
                (cons (if (and (not (complete-path? (car argv)))
                               (string-contains? (car argv) "/"))
                          (path->string (build-path dir (car argv)))
                          (car argv))
                      (for/list ([a (in-list (cdr argv))])
                        (if (complete-path? a)
                            a
                            (path->string (build-path dir a)))))))))
  (define pref-errors (box '()))
  (define commands-raw (hash-ref manifest 'commands '()))
  (define commands-ok?
    (and (list? commands-raw)
         (<= (length commands-raw) max-commands-per-plugin)))
  ;; Commands with malformed ids are dropped by the filter; say so rather
  ;; than silently shrinking the plugin.
  (for ([c (in-list (if (list? commands-raw) commands-raw '()))]
        #:when (and (hash? c)
                    (string? (hash-ref c 'id #f))
                    (not (valid-plugin-command-id? (hash-ref c 'id)))))
    (set-box! pref-errors
              (cons (format "command id rejected: ~a (colons and leading punctuation are not allowed)"
                            (hash-ref c 'id))
                    (unbox pref-errors))))
  (define commands
    (if commands-ok?
        (for/list ([c (in-list commands-raw)]
                   #:when (and (hash? c) (string? (hash-ref c 'id #f))
                               (string? (hash-ref c 'name #f))
                               (valid-plugin-command-id? (hash-ref c 'id))))
          (plugin-command (hash-ref c 'id)
                          (hash-ref c 'name)
                          (or (and (string? (hash-ref c 'keyword #f))
                                   (hash-ref c 'keyword))
                              "")
                          (or (and (string? (hash-ref c 'description #f))
                                   (hash-ref c 'description))
                              "")
                          (or (and (string? (hash-ref c 'icon #f))
                                   (hash-ref c 'icon))
                              "plugin")
                          (parse-actions (hash-ref c 'actions '()))))
        '()))
  (define permissions
    (let ([raw (hash-ref manifest 'permissions '())])
      (if (list? raw) (filter string? raw) '())))
  (define protocol
    (let ([v (hash-ref manifest 'protocol 1)])
      (if (and (exact-integer? v) (or (= v 1) (= v 2))) v 1)))
  (define mode
    (let ([v (hash-ref manifest 'mode "on-demand")])
      (if (member v '("on-demand" "daemon")) v "on-demand")))
  (define preferences
    (filter plugin-pref? (parse-preferences (hash-ref manifest 'preferences '())
                                            pref-errors)))
  (define plugin-result
    (and id name exec
         (plugin id
                 name
                 (or (str 'version) "0.0.0")
                 (or (str 'description) "")
                 (or (str 'icon) "plugin")
                 commands
                 exec
                 permissions
                 protocol
                 mode
                 preferences)))
  (values plugin-result (reverse (unbox pref-errors))))

(define (load-plugins! mgr)
  (define dir (plugin-manager-path mgr))
  (define disabled
    (let ([thunk (plugin-manager-disabled-thunk mgr)])
      (if thunk (thunk) '())))
  (make-directory* dir)
  (define plugins '())
  (define disabled-plugins '())
  (define errors '())
  (for ([sub (in-list (sort (directory-list dir) string<? #:key path->string))])
    (define sub-dir (build-path dir sub))
    (when (directory-exists? sub-dir)
      ;; Disabled plugins stay on disk and keep their manifest parsed so
      ;; the plugin center can offer to re-enable them — they just never
      ;; answer queries. The loader used to skip them entirely, which left
      ;; a disabled plugin invisible and impossible to re-enable.
      (define off? (member (path->string sub) disabled))
      (define manifest-path (build-path sub-dir "manifest.json"))
      (with-handlers ([exn:fail?
                       (lambda (e)
                         (set! errors
                               (cons (format "~a: ~a"
                                             (path->string sub-dir)
                                             (exn-message e))
                                     errors)))])
        (if (file-exists? manifest-path)
            (let ([manifest (safe-read-json-file manifest-path)])
              (cond
                [(not (hash? manifest))
                 (set! errors
                       (cons (format "~a: manifest is not a JSON object"
                                     (path->string sub-dir))
                             errors))]
                [else
                 (define-values (loaded plugin-errors)
                   (manifest->plugin sub-dir manifest))
                 (if loaded
                     (begin
                       (if off?
                           (set! disabled-plugins (cons loaded disabled-plugins))
                           (set! plugins (cons loaded plugins)))
                       (set! errors (append (reverse plugin-errors) errors)))
                     (set! errors
                           (cons (format "~a: manifest missing id, name, or entry.exec"
                                         (path->string sub-dir))
                                 errors)))]))
            (set! errors
                  (cons (format "~a: missing manifest.json" (path->string sub-dir))
                        errors))))))
  (set-plugin-manager-state! mgr (list (reverse plugins)
                                       (reverse errors)
                                       (reverse disabled-plugins))))

;; ---- FPP1 cold spawn -----------------------------------------------------

(define (call-plugin! exec timeout-ms request)
  ;; Returns a jsexpr response or an error string. The process is always
  ;; killed; a hung plugin costs at most its timeout. Interpreter names
  ;; resolve on PATH like the shell would ("python3", not only
  ;; "/usr/bin/python3").
  (with-handlers ([exn:fail? (lambda (e) (format "plugin spawn failed: ~a" (exn-message e)))])
  (define-values (proc stdout stdin stderr)
    (apply subprocess #f #f #f (resolve-program (car exec)) (cdr exec)))
  (dynamic-wind
    (lambda () (void))
    (lambda ()
      (with-handlers ([exn:fail? (lambda (e) (format "plugin write failed: ~a" (exn-message e)))])
        (display (jsexpr->string request) stdin)
        (newline stdin)
        (flush-output stdin))
      (define result-ch (make-async-channel))
      (define reader
        (thread
         (lambda ()
           (with-handlers ([exn:fail?
                            (lambda (_)
                              (async-channel-put result-ch 'reader-failed))])
             (define line (read-line stdout 'any))
             (async-channel-put result-ch line)))))
      (define result (sync/timeout (/ timeout-ms 1000) result-ch))
      (cond
        [(not result) "plugin timed out"]
        [(eq? result 'reader-failed) "plugin crashed"]
        [(eof-object? result) "plugin exited without a response"]
        [(not (string? result)) "plugin sent an invalid response"]
        [else
         (with-handlers ([exn:fail? (lambda (_) "plugin sent invalid JSON")])
           (define response (string->jsexpr result))
           (if (hash? response) response "plugin sent a non-object response"))]))
    (lambda ()
      (subprocess-kill proc #t)
      (close-output-port stdin)
      (close-input-port stdout)
      (close-input-port stderr)))))

;; ---- FPP2 daemon lifecycle ----------------------------------------------

;; One warm process. `state-box`: 'running | 'backoff | 'failed.
;; The reader thread demuxes stdout lines: responses resolve their
;; pending channel by request_id, event lines go to the nudge path, and
;; EOF/crash fails every pending op and schedules the backoff.
(struct daemon (id plugin proc stdin stdout
                lock pending nudge-box state-box
                crash-times-box spawn-count-box)
  #:mutable)

(define (daemon-state d) (unbox (daemon-state-box d)))

(define (next-request-id!)
  (random 1 1000000000))

;; Full environment for a daemon spawn: the backend's environment plus
;; the plugin's declared preferences (FULCRUM_PLUGIN_PREF_<NAME>, with
;; NAME uppercased; dashes become underscores). subprocess inherits the
;; current-environment-variables parameter, so the injection rides a
;; copied environment object — never the process's own.
(define (daemon-environment prefs)
  (define env (make-environment-variables))
  (for ([name (in-list (environment-variables-names
                        (current-environment-variables)))])
    (environment-variables-set! env name
                                (environment-variables-ref
                                 (current-environment-variables) name)))
  (for ([k (in-hash-keys prefs)])
    (environment-variables-set!
     env
     (string->bytes/utf-8
      (string-append "FULCRUM_PLUGIN_PREF_"
                     (string-upcase (string-replace (symbol->string k)
                                                    "-" "_"))))
     (string->bytes/utf-8 (format "~a" (hash-ref prefs k)))))
  env)

(define (spawn-daemon! mgr p)
  (define prefs
    (let ([thunk (plugin-manager-prefs-thunk mgr)])
      (if thunk (or (thunk (plugin-id p)) (hash)) (hash))))
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (define-values (proc stdout stdin stderr)
      (parameterize ([current-directory (plugin-manager-path mgr)]
                     [current-environment-variables
                      (daemon-environment prefs)])
        (apply subprocess #f #f #f
               (resolve-program (car (plugin-entry p)))
               (cdr (plugin-entry p)))))
    (define d
      (daemon (plugin-id p) p proc stdin stdout
              (make-semaphore 1)
              (make-hash)              ; request_id -> async-channel
              (make-hash)              ; command-id -> last-nudge ms
              (box 'running)
              (box '())
              (box 1)))
    (start-reader! mgr d)
    (hash-set! (unbox (plugin-manager-daemons mgr)) (plugin-id p) d)
    d))

;; The reader never touches the plugin manager state beyond the daemons
;; hash and the nudge thunk; everything else stays inside the daemon.
(define (start-reader! mgr d)
  (thread
   (lambda ()
     (let loop ()
       (define line
         (with-handlers ([exn:fail? (lambda (_) eof)])
           (read-line (daemon-stdout d) 'any)))
       (cond
         [(eof-object? line)
          (on-daemon-exit! mgr d "exited")
          (loop)]
         [else
          (define parsed
            (with-handlers ([exn:fail? (lambda (_) #f)])
              (string->jsexpr line)))
          (cond
            [(hash? parsed)
             (define rid (hash-ref parsed 'request_id #f))
             (cond
               [rid (resolve-pending! d rid parsed)]
               [(string? (hash-ref parsed 'event #f))
                (handle-daemon-event! mgr d (hash-ref parsed 'event))])])
          (loop)])))))

(define (resolve-pending! d rid response)
  (call-with-semaphore
   (daemon-lock d)
   (lambda ()
     (define ch (hash-ref (daemon-pending d) rid #f))
     (when ch (async-channel-put ch response))
     (hash-remove! (daemon-pending d) rid))))

(define (handle-daemon-event! mgr d event)
  ;; `event` is a string from the wire — case clauses are symbols, so this
  ;; is a cond (the 2026-10-02 lesson, re-learned).
  (cond
    [(string=? event "results-changed")
     (define now (current-inexact-milliseconds))
     (define last (hash-ref (daemon-nudge-box d) 'last 0))
     (when (> (- now last) nudge-min-interval-ms)
       (hash-set! (daemon-nudge-box d) 'last now)
       (define thunk (plugin-manager-nudge-thunk mgr))
       (when thunk (with-handlers ([exn:fail? void]) (thunk))))]))

(define (fail-pending! d reason)
  (call-with-semaphore
   (daemon-lock d)
   (lambda ()
     (for ([entry (in-hash-pairs (daemon-pending d))])
       (async-channel-put (cdr entry) reason))
     (hash-clear! (daemon-pending d)))))

(define (on-daemon-exit! mgr d reason)
  (fail-pending! d "plugin crashed")
  (close-output-port (daemon-stdin d))
  (hash-remove! (unbox (plugin-manager-daemons mgr)) (daemon-id d))
  (define now (current-inexact-milliseconds))
  (set-box! (daemon-crash-times-box d)
            (cons now (unbox (daemon-crash-times-box d))))
  (define recent
    (filter (lambda (ts) (< (- now ts) daemon-fail-window-ms))
            (unbox (daemon-crash-times-box d))))
  (set-box! (daemon-crash-times-box d) recent)
  (cond
    [(>= (length recent) daemon-fail-threshold)
     (set-box! (daemon-state-box d) 'failed)]
    [else
     (set-box! (daemon-state-box d) 'backoff)
     (define delay
       (list-ref (plugin-manager-backoff-ms mgr)
                 (min (sub1 (length recent))
                      (sub1 (length (plugin-manager-backoff-ms mgr))))))
     (thread
      (lambda ()
        (sleep (/ delay 1000))
        (when (eq? (daemon-state d) 'backoff)
          (set-box! (daemon-state-box d) 'stopped))))]))

;; Returns a live daemon or #f (not running / failed). Restartable states
;; spawn here; 'failed never respawns this session.
(define (ensure-daemon! mgr p)
  (define existing
    (hash-ref (unbox (plugin-manager-daemons mgr)) (plugin-id p) #f))
  (cond
    [(and existing (eq? (daemon-state existing) 'running)) existing]
    [(or (not existing) (not (eq? (daemon-state existing) 'backoff)))
     (when existing
       (hash-remove! (unbox (plugin-manager-daemons mgr)) (plugin-id p)))
     (spawn-daemon! mgr p)]
    [else #f]))

(define (kill-daemon! d)
  (set-box! (daemon-state-box d) 'stopped)
  (with-handlers ([exn:fail? void])
    (subprocess-kill (daemon-proc d) #t))
  (fail-pending! d "plugin stopped"))

;; One op against a warm daemon. Registers the pending channel and writes
;; the request under one lock acquisition so responses cannot race the
;; registration; a timeout recycles the daemon (a daemon that stops
;; answering has lost its warm-process privilege and goes through the
;; crash/backoff path like any other failure).
(define (daemon-call! mgr d request timeout-ms)
  (define rid (next-request-id!))
  (define req (hash-set request 'request_id rid))
  (define ch (make-async-channel 1))
  (define wrote?
    (call-with-semaphore
     (daemon-lock d)
     (lambda ()
       (hash-set! (daemon-pending d) rid ch)
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (display (jsexpr->string req) (daemon-stdin d))
         (newline (daemon-stdin d))
         (flush-output (daemon-stdin d))
         #t))))
  (cond
    [(not wrote?)
     (call-with-semaphore
      (daemon-lock d)
      (lambda () (hash-remove! (daemon-pending d) rid)))
     "plugin crashed"]
    [else
     (define result (sync/timeout (/ timeout-ms 1000) ch))
     (call-with-semaphore
      (daemon-lock d)
      (lambda () (hash-remove! (daemon-pending d) rid)))
     (cond
       [(not result)
        (kill-daemon! d)
        "plugin timed out"]
       [(string? result) result]
       [(hash? result) result]
       [else "plugin sent an invalid response"])]))

;; Daemon-or-cold dispatch for FPP2 plugins: warm when possible, honest
;; cold spawn while the daemon is in backoff or failed. `send` takes the
;; daemon (or #f) and produces the response.
(define (with-plugin-process! mgr p op request timeout-ms)
  (if (equal? (plugin-mode p) "daemon")
      (let ([d (ensure-daemon! mgr p)])
        (if d
            (daemon-call! mgr d request timeout-ms)
            (call-plugin! (plugin-entry p) timeout-ms request)))
      (call-plugin! (plugin-entry p) timeout-ms request)))

;; Preference values for one request: the payload carries the coerced
;; jsexpr values; env injection happens at spawn time.
(define (prefs-for mgr p)
  (define specs (plugin-preferences p))
  (if (null? specs)
      (hash)
      (let ([thunk (plugin-manager-prefs-thunk mgr)])
        (if thunk
            (or (thunk (plugin-id p)) (hash))
            (hash)))))

(define (request-with-prefs mgr p base)
  (define prefs (prefs-for mgr p))
  (if (hash-empty? prefs) base (hash-set base 'prefs prefs)))

;; ---- public API ----------------------------------------------------------

(define/contract (make-plugin-manager path
                                      #:timeout-ms [timeout-ms 2000]
                                      #:disabled-thunk [disabled-thunk #f]
                                      #:nudge-thunk [nudge-thunk #f]
                                      #:prefs-thunk [prefs-thunk #f]
                                      #:daemon-backoff-ms [backoff-ms '(1000 5000 30000)])
  (->* (path?)
       (#:timeout-ms (and/c exact-integer? (>=/c 100) (<=/c 10000))
        #:disabled-thunk (or/c (-> (listof string?)) #f)
        #:nudge-thunk (or/c (-> any/c) #f)
        #:prefs-thunk (or/c (-> string? (hash/c symbol? jsexpr?)) #f)
        #:daemon-backoff-ms (listof exact-positive-integer?))
       plugin-manager?)
  (define mgr
    (plugin-manager path timeout-ms #f (make-semaphore 1) disabled-thunk
                    (box (make-hash)) nudge-thunk prefs-thunk backoff-ms))
  (plugin-manager-reload! mgr)
  mgr)

(define/contract (plugin-manager-reload! mgr)
  (-> plugin-manager? void?)
  (call-with-semaphore
   (plugin-manager-lock mgr)
   (lambda ()
     ;; Source of truth changed: every warm daemon dies and respawns
     ;; lazily against the new directory contents.
     (for ([d (in-hash-values (unbox (plugin-manager-daemons mgr)))])
       (kill-daemon! d))
     (hash-clear! (unbox (plugin-manager-daemons mgr)))
     (with-handlers ([exn:fail?
                      (lambda (e)
                        (set-plugin-manager-state! mgr (list '() (list (exn-message e)) '())))])
       (load-plugins! mgr)))))

;; State is (list enabled-plugins errors disabled-plugins); the accessors
;; below are the only readers.
(define/contract (plugin-manager-plugins mgr)
  (-> plugin-manager? (listof plugin?))
  (define state (plugin-manager-state mgr))
  (if state (car state) '()))

(define/contract (plugin-manager-errors mgr)
  (-> plugin-manager? (listof string?))
  (define state (plugin-manager-state mgr))
  (if state (cadr state) '()))

;; Installed but turned off: parsed from disk like the live ones, listed by
;; the plugin center so the user can turn them back on, never queried.
(define/contract (plugin-manager-disabled-plugins mgr)
  (-> plugin-manager? (listof plugin?))
  (define state (plugin-manager-state mgr))
  (if state (caddr state) '()))

(define (command-matches? command query)
  ;; A command with a keyword claims queries of the form "<keyword> ..." or
  ;; exactly "<keyword>"; a command without a keyword participates in every
  ;; query.
  (define keyword (plugin-command-keyword command))
  (cond
    [(string=? keyword "") #t]
    [(string-ci=? query keyword) #t]
    [(string-prefix? query (string-append keyword " ")) #t]
    [else #f]))

(define (query-text-for command query)
  (define keyword (plugin-command-keyword command))
  (if (and (not (string=? keyword "")) (> (string-length query) (string-length keyword)))
      (string-trim (substring query (string-length keyword)))
      ""))

;; Last query results per command, remembered so the ⌘K panel can offer a
;; result's declared actions without re-spawning the plugin: rows are
;; (title subtitle arg icon "<pid>:<cid>" detail-request?), and the cache
;; maps "<pid>:<cid>" → hash(arg → (actions detail-request?)).
(define results-cache (box (make-hash)))

(define/contract (plugin-manager-query mgr query)
  (-> plugin-manager? string?
      (listof (list/c string? string? string? string? string? boolean?)))
  ;; Returns rows of (title subtitle arg icon "<plugin-id>:<command-id>"
  ;; detail-request?).
  (define trimmed (string-trim query))
  (if (zero? (string-length trimmed))
      '()
      (let ([command-rows
             (for*/list ([p (in-list (plugin-manager-plugins mgr))]
                         [c (in-list (plugin-commands p))]
                         #:when (command-matches? c trimmed))
               (define command-key
                 (string-append (plugin-id p) ":" (plugin-command-id c)))
               (define response
                 (with-plugin-process!
                  mgr p "query"
                  (request-with-prefs
                   mgr p
                   (hasheq 'op "query"
                           'command (plugin-command-id c)
                           'query (query-text-for c trimmed)))
                  (plugin-manager-timeout-ms mgr)))
               (define results
                 (if (hash? response)
                     (let ([raw (hash-ref response 'results '())])
                       (if (list? raw) (take-min raw max-results-per-query) '()))
                     '()))
               (define rows
                 (for/list ([r (in-list results)]
                            #:when (and (hash? r) (string? (hash-ref r 'title #f))))
                   (define actions
                     (let ([raw-actions (hash-ref r 'actions '())])
                       (if (list? raw-actions) (parse-actions raw-actions) '())))
                   (define detail-request? (eq? (hash-ref r 'detail-request #f) #t))
                   (list (hash-ref r 'title)
                         (or (hash-ref r 'subtitle #f) "")
                         (or (hash-ref r 'arg #f) "")
                         (or (hash-ref r 'icon #f) (plugin-icon p))
                         command-key
                         detail-request?)))
               ;; Merge each result's actions with the command's declared
               ;; defaults; per-result wins. The empty arg never caches —
               ;; several results may legitimately share it (FPP1 epoch).
               (define cache (make-hash))
               (for ([r (in-list rows)]
                     [raw (in-list results)])
                 (define arg (list-ref r 2))
                 (unless (string=? arg "")
                   (define result-actions
                     (let ([ra (hash-ref raw 'actions '())])
                       (if (list? ra) (parse-actions ra) '())))
                   (hash-set! cache arg
                              (cons (if (null? result-actions)
                                        (plugin-command-actions c)
                                        result-actions)
                                    (list-ref r 5)))))
               (hash-set! (unbox results-cache) command-key cache)
               rows)])
        ;; command-rows is one list of rows per plugin command; flatten it.
        (apply append command-rows))))

(define (take-min xs n)
  (if (> (length xs) n) (take xs n) xs))

;; Split "<plugin-id>:<command-id>" at the first colon. Plugin ids never
;; contain colons, so everything after the first one is the command id.
(define (split-command-id command-id)
  (define cut (index-of-char command-id #\:))
  (if cut
      (list (substring command-id 0 cut)
            (substring command-id (add1 cut)))
      (list command-id)))

(define (index-of-char s ch)
  (for/first ([i (in-range (string-length s))]
              #:when (char=? (string-ref s i) ch))
    i))

(define (find-plugin-command mgr command-id)
  ;; Always two values: the plugin (or #f) and its command (or #f).
  (define parts (split-command-id command-id))
  (if (= (length parts) 2)
      (let ([p (findf (lambda (pl) (string=? (plugin-id pl) (car parts)))
                      (plugin-manager-plugins mgr))])
        (if p
            (values p
                    (findf (lambda (c)
                             (string=? (plugin-command-id c) (cadr parts)))
                           (plugin-commands p)))
            (values #f #f)))
      (values #f #f)))

(define/contract (plugin-manager-command-exists? mgr command-id)
  (-> plugin-manager? string? boolean?)
  (let-values ([(p c) (find-plugin-command mgr command-id)])
    (and p c #t)))

(define/contract (plugin-manager-run! mgr command-id arg)
  (-> plugin-manager? string? string? string?)
  ;; command-id is "<plugin-id>:<command-id>".
  (let-values ([(p c) (find-plugin-command mgr command-id)])
    (cond
      [(not (and p c)) (format "unknown plugin command: ~a" command-id)]
      [else
       (define response
         (with-plugin-process!
          mgr p "run"
          (request-with-prefs
           mgr p (hasheq 'op "run" 'command (plugin-command-id c) 'arg arg))
          (plugin-manager-timeout-ms mgr)))
       (if (hash? response)
           (let ([status (hash-ref response 'status "error")])
             (if (string? status) status "error"))
           response)])))

(define/contract (plugin-manager-run-action! mgr command-id arg action-id)
  (-> plugin-manager? string? string? string? string?)
  (let-values ([(p c) (find-plugin-command mgr command-id)])
    (cond
      [(not (and p c)) (format "unknown plugin command: ~a" command-id)]
      [else
       (define response
         (with-plugin-process!
          mgr p "run-action"
          (request-with-prefs
           mgr p (hasheq 'op "run-action"
                         'command (plugin-command-id c)
                         'arg arg
                         'action action-id))
          (plugin-manager-timeout-ms mgr)))
       (if (hash? response)
           (let ([status (hash-ref response 'status "error")])
             (if (string? status) status "error"))
           response)])))

(define/contract (plugin-manager-detail! mgr command-id arg)
  (-> plugin-manager? string? string? (or/c hash? string?))
  ;; Returns the detail jsexpr ({text, metadata}) or an error string.
  (let-values ([(p c) (find-plugin-command mgr command-id)])
    (cond
      [(not (and p c)) (format "unknown plugin command: ~a" command-id)]
      [else
       (define response
         (with-plugin-process!
          mgr p "detail"
          (request-with-prefs
           mgr p (hasheq 'op "detail" 'command (plugin-command-id c) 'arg arg))
          (plugin-manager-timeout-ms mgr)))
       (cond
         [(hash? response) response]
         [else response])])))

;; ⌘K actions for one cached result: per-result actions win over the
;; command's declared defaults; unknown results (cache cold) offer the
;; command defaults. Returns (listof (cons action-id title)).
(define/contract (plugin-manager-row-actions mgr command-id arg)
  (-> plugin-manager? string? string? (listof (cons/c string? string?)))
  (let-values ([(p c) (find-plugin-command mgr command-id)])
    (cond
      [(not (and p c)) '()]
      [else
       (define table
         (hash-ref (unbox results-cache) command-id #f))
       (define cached
         (and table (hash-ref table arg #f)))
       (define actions
         (cond
           [cached (car cached)]
           [else (plugin-command-actions c)]))
       (append
        (if (and cached (cdr cached))
            (list (cons "__detail" "Details"))
            '())
        actions)])))

(define/contract (plugin-manager-prefs-changed! mgr plugin-id)
  (-> plugin-manager? string? void?)
  ;; Notify a live daemon that preference values changed; on-demand
  ;; plugins simply read the new values on their next spawn.
  (define d (hash-ref (unbox (plugin-manager-daemons mgr)) plugin-id #f))
  (when (and d (eq? (daemon-state d) 'running))
    (with-handlers ([exn:fail? void])
      (call-with-semaphore
       (daemon-lock d)
       (lambda ()
         (display (jsexpr->string (hasheq 'event "prefs-changed"))
                  (daemon-stdin d))
         (newline (daemon-stdin d))
         (flush-output (daemon-stdin d)))))))

;; Test/observability accessor: 'running | 'backoff | 'failed | #f.
(define/contract (plugin-manager-daemon-state mgr plugin-id)
  (-> plugin-manager? string? (or/c symbol? #f))
  (define d (hash-ref (unbox (plugin-manager-daemons mgr)) plugin-id #f))
  (and d (daemon-state d)))
