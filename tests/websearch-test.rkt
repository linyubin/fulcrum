#lang racket/base

;; Web search provider tests.
;;
;; Pure surface: the bang table, RFC 3986 URL building (the row hands the
;; URL to the host's browser, so a metacharacter that slips through is a
;; query injection), and the bang/fallback routing contract.

(require rackunit
         racket/list
         racket/string
         "../app/core/websearch.rkt")

(test-case "bang table shape"
  (define engines (bang-engines))
  (check-true (pair? engines) "at least one engine")
  (for ([b (in-list engines)])
    (check-true (web-bang? b))
    (check-true (string-prefix? (web-bang-prefix b) "!")
                "every engine routes through a ! bang")
    (check-true (string-contains? (web-bang-url-template b) "~a")
                "template has the text slot"))
  (check-equal? (length (remove-duplicates (map web-bang-prefix engines)))
                (length engines)
                "prefixes are unique — first match would otherwise win silently"))

(test-case "URL building percent-encodes from UTF-8 bytes (RFC 3986)"
  (check-equal? (web-bang->url (car (bang-engines)) "hello world")
                "https://www.google.com/search?q=hello%20world")
  (check-equal? (web-bang->url (car (bang-engines)) "héllo")
                "https://www.google.com/search?q=h%c3%a9llo")
  (check-equal? (web-bang->url (car (bang-engines)) "-_.~aZ09")
                "https://www.google.com/search?q=-_.~aZ09"
                "unreserved characters survive")
  (check-equal? (web-bang->url (car (bang-engines)) "a&b=c d")
                "https://www.google.com/search?q=a%26b%3dc%20d"
                "query metacharacters must not escape into the URL"))

(test-case "bang routing takes the whole tail as the engine's query"
  (check-equal? (web-search-row-target "!gh fulcrum repo")
                (cons "!gh" "https://github.com/search?q=fulcrum%20repo"))
  (check-equal? (web-search-row-target "!w Grace Hopper")
                (cons "!w"
                      "https://en.wikipedia.org/wiki/Special:Search?search=Grace%20Hopper")))

(test-case "non-bang queries fall back to the default engine"
  (check-equal? (web-search-row-target "racket contracts")
                (cons "web" "https://www.google.com/search?q=racket%20contracts"))
  (check-equal? (web-search-row-target "racket contracts"
                                       #:default-engine "!d")
                (cons "web" "https://duckduckgo.com/?q=racket%20contracts")))

(test-case "empty queries yield no row target"
  (check-false (web-search-row-target ""))
  (check-false (web-search-row-target "   ")))
