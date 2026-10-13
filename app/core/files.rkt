#lang racket/base

;; File search — per-platform, always available on desktop:
;;   macOS: Spotlight (`mdfind -name`) — millisecond responses, deep index
;;   Linux: `locate -i` (the mlocate/plocate index) or `find` as fallback
;;   Windows: PowerShell `Get-ChildItem -Recurse` (bounded depth)
;; Claims `find <query>` queries so it never clutters unrelated searches.
;; Opening a result uses the platform opener, the same side-effect path
;; application launches use.

(require racket/bool
         racket/contract
         racket/list
         racket/path
         racket/string
         "proc.rkt")

(provide file-search-available?
         parse-paths
         file-search
         file-open!)

;; ---- availability ---------------------------------------------------------

(define (file-search-available?)
  (case (system-type 'os)
    [(macosx) (not (false? (resolve-program "mdfind")))]
    [(unix) (or (not (false? (resolve-program "locate")))
                (not (false? (resolve-program "find"))))]
    [(windows) (not (false? (resolve-program "powershell.exe")))]
    [else #f]))

;; ---- search ---------------------------------------------------------------

;; Returns three values: program (or #f), args, and a parser function
;; that turns raw output into (name path) pairs.
(define (search-command query)
  (case (system-type 'os)
    [(macosx)
     (values "mdfind" (list "-name" query) parse-paths)]
    [(unix)
     (if (not (false? (resolve-program "locate")))
         (values "locate" (list "-i" "-l" "8" query) parse-paths)
         (values "find"
                 (list (path->string (find-system-path 'home-dir))
                       "-maxdepth" "4"
                       "-iname" (string-append "*" query "*")
                       "-type" "f")
                 parse-paths))]
    [(windows)
     (values "powershell.exe"
             (list "-NoProfile" "-Command"
                   (format "Get-ChildItem -Path ~a -Recurse -Depth 3 -Filter '*~a*' -File | Select-Object -First 8 -ExpandProperty FullName"
                           "$env:USERPROFILE" query))
             parse-paths)]
    [else (values #f '() parse-paths)]))

;; Universal path-list parser: newline-separated absolute paths →
;; (name path) pairs, bounded and deduplicated. Works for mdfind, locate,
;; find, and PowerShell output alike.
(define (parse-paths output [limit 8])
  (if (not (string? output))
      '()
      (take-min
       (remove-duplicates
        (for/list ([line (in-list
                          (filter (lambda (s)
                                    (string-contains? s "/"))
                                  (string-split output "\n")))])
          (cons (path->string (file-name-from-path (string->path line)))
                line)))
       limit)))

(define (take-min xs n)
  (if (> (length xs) n) (take xs n) xs))

;; (name path) pairs, or '() when the platform has no search tool.
;; Bounded by the command timeout: a wedged index or deep filesystem scan
;; costs 3 s at most.
(define (file-search query [limit 8])
  (if (not (file-search-available?))
      '()
      (let-values ([(program args parser)
                    (case (system-type 'os)
                      [(macosx)
                       (values "mdfind" (list "-name" query) parse-paths)]
                      [(unix)
                       (if (not (false? (resolve-program "locate")))
                           (values "locate" (list "-i" "-l" "8" query) parse-paths)
                           (values "find"
                                   (list (path->string (find-system-path 'home-dir))
                                         "-maxdepth" "4"
                                         "-iname" (string-append "*" query "*")
                                         "-type" "f")
                                   parse-paths))]
                      [(windows)
                       (values "powershell.exe"
                               (list "-NoProfile" "-Command"
                                     (format "Get-ChildItem -Path $env:USERPROFILE -Recurse -Depth 3 -Filter '*~a*' -File | Select-Object -First 8 -ExpandProperty FullName"
                                             query))
                               parse-paths)])])
        (let ([output (run-command program args #:timeout-ms 3000)])
          (parser output limit)))))

(define (opener-for-platform)
  (case (system-type 'os)
    [(macosx) "open"]
    [(windows) "explorer.exe"]
    [else "xdg-open"]))

;; Fire-and-forget, like application launches. #f means the opener could
;; not run at all.
(define (file-open! path)
  (spawn-command (opener-for-platform) (list (path->string (simple-form-path path)))))
