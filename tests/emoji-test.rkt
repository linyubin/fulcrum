#lang racket/base

;; Emoji search: dataset integrity, match behavior, and the paste
;; action contract.

(require racket/list racket/string
         rackunit
         "../app/core/engine.rkt"
         "../app/core/emoji.rkt")

(define (row-id-helper row) (list-ref row 0))

(test-case "the dataset is clean"
  (check-true (> (emoji-count) 100) "enough entries to be useful")
  ;; Every entry: non-empty char, non-empty name, deduplicated.
  (define chars (map car emoji-entries))
  (check-true (andmap (lambda (e) (non-empty-string? (list-ref e 0))) emoji-entries))
  (check-true (andmap (lambda (e) (non-empty-string? (list-ref e 1))) emoji-entries))
  (check-equal? (length chars) (length (remove-duplicates chars))
                "no duplicate characters"))

(test-case "search matches names and keywords"
  (check-true (pair? (emoji-search "grin")))
  (check-true (pair? (emoji-search "fire")))
  ;; Single characters return nothing — one letter would match half the set.
  (check-equal? (emoji-search "a") '())
  (check-equal? (emoji-search "") '())
  ;; Bounded at 4 results.
  (check-true (<= (length (emoji-search "heart")) 4)))


(test-case "the engine offers emoji rows that paste into the frontmost app"
  (define eng (make-engine #:clipboard-store #f #:snippet-store #f #:plugin-manager #f))
  (define rows (engine-search eng "grin"))
  (define emoji-rows (filter (lambda (r) (string=? (list-ref r 0) "emoji.paste")) rows))
  (check-true (pair? emoji-rows) "emoji rows appear inline")
  (check-equal? (list-ref (car emoji-rows) 3) "Emoji")
  (check-equal? (row-id-helper (car emoji-rows)) "emoji.paste")
  ;; Enter runs the paste event — the same one a clipboard paste uses.
  (define outcome
    (engine-run eng "emoji.paste" (list-ref (car emoji-rows) 4)))
  (check-equal? (car outcome) "copied")
  (check-equal? (cdr outcome)
                (list (cons 'paste-to-frontmost (list-ref (car emoji-rows) 4))))
  ;; ⌘K offers Copy as the alternative.
  (define actions (engine-row-actions eng "emoji.paste"
                                      (list-ref (car emoji-rows) 4)))
  (check-true (pair? actions))
  (check-equal? (list-ref (car actions) 0) "copy"))

