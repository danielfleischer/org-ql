;;; org-ql-completing-read.el --- Completing read of Org entries using org-ql  -*- lexical-binding: t; -*-

;; Copyright (C) 2022  Adam Porter

;; Author: Adam Porter <adam@alphapapa.net>

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This library provides completing-read of Org entries using `org-ql'
;; search.

;;; Code:

(require 'org-ql)

;;;; Customization

(defgroup org-ql-completing-read nil
  "Completing-read of Org entries using `org-ql' search."
  :group 'org-ql)

(defcustom org-ql-completing-read-reverse-paths t
  "Whether to reverse Org outline paths in `org-ql-completing-read' results."
  :type 'boolean)

(defcustom org-ql-completing-read-snippet-function #'org-ql-completing-read--snippet-simple
  ;; TODO: I'd like to make the -regexp one the default, but with
  ;; default Emacs completion affixation, it can sometimes be a bit
  ;; slow, and I don't want that to be a user's first impression.  It
  ;; may be possible to further optimize the -regexp one so that it
  ;; can be used by default.  In the meantime, the -simple one seems
  ;; fast enough for general use.
  "Function used to annotate results in `org-ql-completing-read'.
Function is called at entry beginning.  (When set to
`org-ql-completing-read--snippet-regexp', it is called with a
regexp matching plain query tokens.)"
  :type '(choice (function-item :tag "Show context around search terms" org-ql-completing-read--snippet-regexp)
                 (function-item :tag "Show first N characters" org-ql-completing-read--snippet-simple)
                 (function :tag "Custom function")))

(defcustom org-ql-completing-read-snippet-length 51
  "Size of snippets of entry content to include in completion annotations.
Only used when `org-ql-completing-read-snippet-function' is set
to `org-ql-completing-read--snippet-regexp'."
  :type 'integer)

(defcustom org-ql-completing-read-snippet-minimum-token-length 3
  "Query tokens shorter than this many characters are ignored.
That is, they are not included when gathering entry snippets.
This avoids too-small tokens causing performance problems."
  :type 'integer)

(defcustom org-ql-completing-read-snippet-prefix nil
  "String prepended to snippets.
For an experience like `org-rifle', use a newline."
  :type '(choice (const :tag "None (shown on same line)" nil)
                 (const :tag "New line (shown under heading)" "\n")
                 string))

(defface org-ql-completing-read-snippet '((t (:inherit font-lock-comment-face)))
  "Snippets.")

;;;; Functions

;;;;; Completing read

;;;###autoload
(cl-defun org-ql-completing-read (buffers-files &key query-prefix query-filter
                                                (prompt "Find entry: "))
  "Return marker at Org entry in BUFFERS-FILES selected with `org-ql'.
PROMPT is shown to the user.

QUERY-PREFIX may be a string to prepend to the query entered by
the user (e.g. use \"heading:\" to only search headings, easily
creating a custom command that saves the user from having to type
it).

QUERY-FILTER may be a function through which the query the user
types is filtered before execution (e.g. it could replace spaces
with commas to turn multiple tokens, which would normally be
treated as multiple predicates, into multiple arguments to a
single predicate)."
  (declare (indent defun))
  ;; Emacs's completion API is not always easy to understand, especially when using "programmed
  ;; completion."  This code was made possible by the example Clemens Radermacher shared at
  ;; <https://github.com/radian-software/selectrum/issues/114#issuecomment-744041532>.

  ;; NOTE: I don't usually leave commented-out debugging code, but due to the incredibly tedious
  ;; complexity of the "Programmed Completion" API and the time spent trying to get this reasonably
  ;; close to "correct," I'm leaving it in, because I will undoubtedly have to go through this
  ;; process again.
  
  ;;  (message "ORG-QL-COMPLETING-READ: Starts.")
  (let ((table (make-hash-table :test #'equal))
        (disambiguations (make-hash-table :test #'equal))
        (window-width (window-width))
        last-input org-outline-path-cache query-tokens snippet-regexp)
    (cl-labels (;; (debug-message
                ;;  (f &rest args) (apply #'message (concat "ORG-QL-COMPLETING-READ: " f) args))
                (action
                 () (font-lock-ensure (point-at-bol) (point-at-eol))
                 ;; FIXME: We want the fontified heading, and `org-heading-components' returns it
                 ;; without properties, so we have to use `org-get-heading', which added additional
                 ;; optional arguments in a certain Org version, so in those versions, it will
                 ;; return priority cookies and comment strings.
                 (let ((heading (org-link-display-format (org-entry-get (point) "ITEM"))))
                   (when (gethash heading table)
                     ;; Disambiguate heading (even adding the path isn't enough, because that could
                     ;; also be duplicated).
                     (if-let ((suffix (gethash heading disambiguations)))
                         (setf heading (format "%s <%s>" heading (cl-incf suffix)))
                       (setf heading (format "%s <%s>" heading (puthash heading 2 disambiguations)))))
                   (puthash heading (point-marker) table)))
                (path (marker)
                      (org-with-point-at marker
                        (let* ((path (thread-first (org-get-outline-path nil t)
                                                   (org-format-outline-path window-width nil "")
                                                   (org-split-string "")))
                               (formatted-path (if org-ql-completing-read-reverse-paths
                                                   (concat "\\" (string-join (reverse path) "\\"))
                                                 (concat "/" (string-join path "/")))))
                          formatted-path)))
                (todo
                 (marker) (if-let (it (org-entry-get marker "TODO"))
                              (concat (propertize it 'face (org-get-todo-face it)) " ")
                            ""))
                (affix (completions)
                       ;; (debug-message "AFFIX:%S" completions)
                       (cl-loop for completion in completions
                                for marker = (gethash completion table)
                                for prefix = (todo marker)
                                for suffix = (concat (path marker) " " (snippet marker))
                                collect (list completion prefix suffix)))
                (annotate (candidate)
                          ;; (debug-message "ANNOTATE:%S" candidate)
                          (or (snippet (gethash candidate table)) ""))
                (snippet
                 (marker) (when-let
                              ((snippet
                                (org-with-point-at marker
                                  (or (funcall org-ql-completing-read-snippet-function snippet-regexp)
                                      (org-ql-completing-read--snippet-simple)))))
                            (propertize (concat " " snippet)
                                        'face 'org-ql-completing-read-snippet)))
                (group (candidate transform)
                       (pcase transform
                         (`nil (buffer-name (marker-buffer (gethash candidate table))))
                         (_ candidate)))
                (try (string _collection _pred point &optional _metadata)
                     ;; (debug-message "TRY: STRING:%S" string)
                     (cons string point))
                (all (string table pred _point)
                     ;; (debug-message "all: STRING:%S" string)
                     ;; (debug-message "all-completions RETURNS: %S" (all-completions string table pred))
                     (all-completions string table pred))
                (collection (input _pred flag)
                            (when query-prefix
                              (setf input (concat query-prefix input)))
                            (pcase flag
                              ('metadata (list 'metadata
                                               (cons 'group-function #'group)
                                               (cons 'affixation-function #'affix)
                                               (cons 'annotation-function #'annotate)))
                              (`t
                               ;; (debug-message "COLLECTION:t INPUT:%S KEYS:%S"
                               ;;                input (hash-table-keys table))
                               ;; It's not ideal to call `run-query' unconditionally here, but due to
                               ;; the complexity of the "Programmed Completion" API, it's basically
                               ;; necessary, and org-ql's caching should make it nearly free.
                               (run-query input)
                               (hash-table-keys table))
                              ('lambda
                                ;; (debug-message "COLLECTION:lambda INPUT:%S KEYS:%S"
                                ;;                input (hash-table-keys table))
                                (if (not (hash-table-empty-p table))
                                    (when (gethash input table)
                                      t)
                                  (run-query input)
                                  (when (gethash input table)
                                    ;; (debug-message "COLLECTION:lambda INPUT:%S FOUND" input)
                                    t)))
                              (`nil
                               ;; (debug-message "COLLECTION:nil INPUT:%S" input)
                               (if (not (hash-table-empty-p table))
                                   (when (gethash input table)
                                     t)
                                 (run-query input)
                                 ;; (debug-message "COLLECTION:nil INPUT:%S KEYS:%S"
                                 ;;                input (hash-table-keys table))
                                 (cond ((hash-table-empty-p table)
                                        nil)
                                       ((gethash input table)
                                        t)
                                       (t
                                        ;; FIXME: "it should return the longest common prefix
                                        ;; substring of all matches otherwise"...but there's no
                                        ;; function to compute that?  At least returning an empty
                                        ;; string doesn't seem to break anything.
                                        input))))
                              (`(boundaries . ,suffix)
                               ;; (debug-message "COLLECTION:boundaries INPUT:%S SUFFIX:%S KEYS:%S"
                               ;;                input suffix (hash-table-keys table))
                               ;; FIXME: This is unlikely to be correct, but I'm not even sure if it
                               ;; can be correct in this case since the input (e.g. "todo: foo")
                               ;; usually won't match a completion candidate directly.
                               `(boundaries 0 . ,(length suffix)))))
                (run-query (input)
                           ;; (debug-message "RUN-QUERY:%S" input)
                           (unless (or (string-empty-p input)
                                       (equal last-input input))
                             ;; (debug-message "RUN-QUERY:%S  RUNNING" input)
                             (setf last-input input)
                             ;; Clear hash table each time the user changes the input.
                             (clrhash table)
                             (clrhash disambiguations)
                             (when query-filter
                               (setf input (funcall query-filter input)))
                             (pcase org-ql-completing-read-snippet-function
                               ('org-ql-completing-read--snippet-regexp
                                (setf query-tokens
                                      ;; Remove any tokens that specify predicates or are too short.
                                      (--select (not (or (string-match-p (rx bos (1+ (not (any ":"))) ":") it)
                                                         (< (length it) org-ql-completing-read-snippet-minimum-token-length)))
                                                (split-string input nil t (rx space)))
                                      snippet-regexp
                                      (when query-tokens
                                        ;; Limiting each context word to 15 characters prevents
                                        ;; excessively long, non-word strings from ending up in
                                        ;; snippets, which can adversely affect performance.
                                        (rx-to-string `(seq (or ,@query-tokens)))))))
                             (org-ql-select buffers-files (org-ql--query-string-to-sexp input)
                               :action #'action))))
      ;; NOTE: It seems that the `completing-read' machinery can call, abort, and re-call the
      ;; collection function while the user is typing, which can interrupt the machinery Org uses to
      ;; prepare an Org buffer when an Org file is loaded.  This results in, e.g. the buffer being
      ;; left in fundamental-mode, unprepared to be used as an Org buffer, which breaks many things
      ;; and is very confusing for the user.  Ideally, of course, we would solve this in
      ;; `org-ql-select', and we already attempt to, but that function is called by the
      ;; `completing-read' machinery, which interrupts it, so we must work around this problem by
      ;; ensuring all of the BUFFERS-FILES are loaded and initialized before calling
      ;; `completing-read'.
      (unless (listp buffers-files)
        ;; Since we map across this argument, we ensure it's a list.
        (setf buffers-files (list buffers-files)))
      (mapc #'org-ql--ensure-buffer buffers-files)
      (let* ((completion-styles '(org-ql-completing-read))
             (completion-styles-alist (list (list 'org-ql-completing-read #'try #'all "Org QL Find")))
             (selected (completing-read prompt #'collection nil nil)))
        ;; (debug-message "SELECTED:%S  KEYS:%S" selected (hash-table-keys table))
        (or (gethash selected table)
            ;; If there are completions in the table, but none of them exactly match the user input
            ;; (e.g. a heading "foo" that matches a query "todo:"), `completing-read' will not
            ;; select it automatically, so we return it ourselves.  But note that this is not
            ;; necessarily correct.  For example, if the user types "todo:" and gets a list of
            ;; completions ("foo" "bar"), and then changes the input to "ba" and presses RET
            ;; immediately (without getting a new list of completions), the table will include "foo"
            ;; and "bar", and we will return "foo"'s value rather than the first match for the query
            ;; "ba", because `completing-read' will not cause the COLLECTION function to run a new
            ;; query for the new input.
            (car (hash-table-values table))
            (user-error "No results for input"))))))

(defun org-ql-completing-read--snippet-simple (&optional _regexp)
  "Return a snippet of the current entry.
Returns up to `org-ql-completing-read-snippet-length' characters."
  (save-excursion
    (org-end-of-meta-data t)
    (unless (org-at-heading-p)
      (let ((end (min (+ (point) org-ql-completing-read-snippet-length)
                      (org-entry-end-position))))
        (concat org-ql-completing-read-snippet-prefix
                (truncate-string-to-width
                 (replace-regexp-in-string (rx (1+ "\n")) "\n"
                                           (buffer-substring (point) end) t t)
                 100 nil nil t))))))

(defun org-ql-completing-read--snippet-regexp (regexp)
  "Return a snippet of the current entry's matches for REGEXP."
  ;; REGEXP may be nil if there are no qualifying tokens in the query.
  (when regexp
    (save-excursion
      (org-end-of-meta-data t)
      (unless (org-at-heading-p)
        (let* ((end (org-entry-end-position))
               (snippets (progn
                           (re-search-forward regexp end)
                           (match-string 0)))
               (snippets (replace-regexp-in-string (rx (1+ "\n")) "\n" snippets)))
          (unless (string-empty-p snippets)
            (concat org-ql-completing-read-snippet-prefix snippets)))))))

;;;; Footer

(provide 'org-ql-completing-read)

;;; org-ql-completing-read.el ends here
