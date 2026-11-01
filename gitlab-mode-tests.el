;;; gitlab-mode-tests.el --- Tests of the GitLab display layer -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Daniel Nagy

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;;; Commentary:

;; Unit tests of the renderers, the stale check and the two base modes.
;; The tests never start glab and never open a network connection.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'gitlab-test-helpers)
(require 'gitlab-mode)

(ert-deftest gitlab-mode-format-value ()
  "Values render as readable text."
  (should (equal "-" (gitlab--format-value nil)))
  (should (equal "no" (gitlab--format-value :false)))
  (should (equal "yes" (gitlab--format-value t)))
  (should (equal "UX, CLI" (gitlab--format-value '("UX" "CLI"))))
  (should (equal "Tavmjong Bah (@tavmjong)"
                 (gitlab--format-value
                  '((username . "tavmjong") (name . "Tavmjong Bah"))))))

(ert-deftest gitlab-mode-format-object-pipeline ()
  "A nested pipeline becomes text with a navigation property."
  (let* ((value (gitlab--format-value
                 '((id . 100) (status . "success") (ref . "main"))))
         (id (get-text-property 0 'gitlab-pipeline-id value)))
    (should (equal "#100 success" value))
    (should (equal "100" id))))

(ert-deftest gitlab-mode-format-date-and-duration ()
  "Timestamps and durations have compact forms."
  (should (equal "2026-10-31 20:57:30"
                 (gitlab--format-date "2026-10-31T20:57:30.763Z")))
  (should (equal "8m 42s" (gitlab--format-duration 522)))
  (should (equal "1m 40s" (gitlab--format-duration 100.234765)))
  (should (equal "1h 0m 5s" (gitlab--format-duration 3605))))

(ert-deftest gitlab-mode-render-fields ()
  "A field table has labels, values and a field property."
  (gitlab-test-with-environment
   (with-temp-buffer
     (gitlab--render-fields
      "Merge request !12"
      '((iid . 12)
        (title . "Fix")
        (author (username . "alice") (name . "Alice"))))
     (should (string-match-p "Merge request !12" (buffer-string)))
     (should (string-match-p "Alice (@alice)" (buffer-string)))
     (gitlab--goto-field 'title)
     (should (eq 'title (gitlab--field-at-point)))
     (should (string-match-p "Title:" (buffer-substring
                                        (line-beginning-position)
                                        (line-end-position)))))))

(ert-deftest gitlab-mode-stale-check ()
  "The stale check honours the refresh interval and pending state."
  (let ((gitlab-refresh-visible-only nil)
        (gitlab-refresh-interval 30)
        (gitlab-refresh-fast-interval 5))
    (with-temp-buffer
      (setq-local gitlab--last-fetch-time nil)
      (should (gitlab--buffer-stale-p))
      (setq-local gitlab--last-fetch-time (float-time))
      (should-not (gitlab--buffer-stale-p))
      (setq-local gitlab--last-fetch-time (- (float-time) 40))
      (should (gitlab--buffer-stale-p))
      (setq-local gitlab--pending t)
      (should-not (gitlab--buffer-stale-p)))))

(ert-deftest gitlab-mode-detail-refresh ()
  "A synchronous fetch renders the detail buffer."
  (gitlab-test-with-environment
   (with-temp-buffer
     (gitlab-detail-mode)
     (setq-local gitlab--id "12")
     (setq-local gitlab--fetch-function
                 (lambda (_id success _error)
                   (funcall success '((iid . 12) (title . "Fix")))))
     (gitlab--refresh)
     (should (string-match-p "Fix" (buffer-string)))
     (should-not gitlab--pending)
     (should-not (buffer-modified-p)))))

(ert-deftest gitlab-mode-detail-error-keeps-data ()
  "A failed refresh keeps the last good content."
  (gitlab-test-with-environment
   (with-temp-buffer
     (gitlab-detail-mode)
     (setq-local gitlab--id "12")
     (setq-local gitlab--fetch-function
                 (lambda (_id success _error)
                   (funcall success '((iid . 12) (title . "Good")))))
     (gitlab--refresh)
     (setq-local gitlab--fetch-function
                 (lambda (_id _success error)
                   (funcall error '(gitlab-cli-error "boom"))))
     (gitlab--refresh)
     (should (string-match-p "Good" (buffer-string)))
     (should (string-match-p "boom" (or header-line-format ""))))))

(ert-deftest gitlab-mode-list-refresh ()
  "A synchronous list fetch fills `tabulated-list-entries'."
  (gitlab-test-with-environment
   (with-temp-buffer
     (gitlab-list-mode)
     (setq-local tabulated-list-format [("ID" 8 t) ("Title" 20 t)])
     (setq-local gitlab-list--fetch-function
                 (lambda (success _error)
                   (funcall success '(((id . 1) (title . "One"))
                                      ((id . 2) (title . "Two"))))))
     (setq-local gitlab-list--entries-function
                 (lambda (data)
                   (mapcar (lambda (row)
                             (list (gitlab-data-id-string
                                    (gitlab-data-field "id" row))
                                   (vector (gitlab-data-id-string
                                            (gitlab-data-field "id" row))
                                           (gitlab-data-field "title" row))))
                           data)))
     (setq-local gitlab-list--rows-function
                 (lambda (data)
                   (mapcar (lambda (row)
                             (cons (gitlab-data-id-string
                                    (gitlab-data-field "id" row))
                                   row))
                           data)))
     (setq-local gitlab-list--open-function #'ignore)
     (gitlab-list--refresh)
     (should (= 2 (length tabulated-list-entries)))
     (should (= 2 (length gitlab-list--rows)))
     (should (string-match-p "One" (buffer-string))))))

(ert-deftest gitlab-mode-list-error ()
  "A list error goes to the mode line."
  (gitlab-test-with-environment
   (with-temp-buffer
     (gitlab-list-mode)
     (setq-local tabulated-list-format [("ID" 8 t)])
     (setq-local gitlab-list--fetch-function
                 (lambda (_success error)
                   (funcall error '(gitlab-cli-error "offline"))))
     (gitlab-list--refresh)
     (should (string-match-p "offline" (format "%s" mode-line-process))))))

(ert-deftest gitlab-mode-navigation-property ()
  "RET opens the object that the text property names."
  (with-temp-buffer
    (insert (gitlab--nav-string "#100 success" 'gitlab-pipeline-id "100"))
    (goto-char (point-min))
    (let (opened)
      (cl-letf (((symbol-function 'gitlab-display-pipeline)
                 (lambda (id) (setq opened id))))
        (gitlab-open-at-point))
      (should (equal "100" opened)))))

(ert-deftest gitlab-mode-list-revert ()
  "`revert-buffer' fetches the collection again."
  (gitlab-test-with-environment
   (with-temp-buffer
     (let ((calls 0))
       (gitlab-list-mode)
       (setq-local tabulated-list-format [("ID" 8 t)])
       (setq-local gitlab-list--fetch-function
                   (lambda (success _error)
                     (setq calls (1+ calls))
                     (funcall success nil)))
       (setq-local gitlab-list--entries-function #'ignore)
       (setq-local gitlab-list--rows-function #'ignore)
       (setq-local gitlab-list--open-function #'ignore)
       (gitlab-list--refresh)
       (should (= 1 calls))
       (revert-buffer nil t)
       (should (= 2 calls))))))

(ert-deftest gitlab-mode-detail-directory ()
  "A detail buffer keeps the project root for glab."
  (gitlab-test-with-environment
   (let ((default-directory (file-name-as-directory "/some/project/sub")))
     (with-temp-buffer
       (cl-letf (((symbol-function 'project-current)
                  (lambda (&rest _arguments) 'stub-project))
                 ((symbol-function 'project-root)
                  (lambda (_project) "/some/project/")))
         (let ((buffer (gitlab--prepare-detail
                        "*GitLab directory test*"
                        #'gitlab-detail-mode "1")))
           (unwind-protect
               (with-current-buffer buffer
                 (should (equal "/some/project/" default-directory))
                 (should (equal "/some/project/" gitlab-cli-directory))
                 (should-not (buffer-modified-p)))
             (kill-buffer buffer))))))))

(ert-deftest gitlab-mode-detail-directory-outside-project ()
  "A detail buffer keeps the directory when it belongs to no project."
  (gitlab-test-with-environment
   (let ((default-directory (file-name-as-directory "/no/project")))
     (with-temp-buffer
       (cl-letf (((symbol-function 'project-current)
                  (lambda (&rest _arguments) nil)))
         (let ((buffer (gitlab--prepare-detail
                        "*GitLab directory fallback test*"
                        #'gitlab-detail-mode "1")))
           (unwind-protect
               (with-current-buffer buffer
                 (should (equal (file-name-as-directory "/no/project")
                                default-directory))
                 (should (equal (file-name-as-directory "/no/project")
                                gitlab-cli-directory)))
             (kill-buffer buffer))))))))

(ert-deftest gitlab-mode-list-number-sort ()
  "A numeric column sorts entries and ignores the IID sigil."
  (gitlab-test-with-environment
   (with-temp-buffer
     (gitlab-list-mode)
     (setq-local tabulated-list-format
                 [("IID" 7 gitlab-list--number-sort)
                  ("Title" 20 t)])
     (setq-local tabulated-list-entries
                 '(("8286" ["!8286" "b"])
                   ("8285" ["!8285" "a"])))
     (setq-local tabulated-list-sort-key '("IID" . nil))
     (tabulated-list-print t)
     (should (equal '("8285" "8286")
                    (mapcar #'car tabulated-list-entries))))))

(ert-deftest gitlab-mode-list-change-hook-kind ()
  "A list refresh passes its collection kind to the change hook."
  (gitlab-test-with-environment
   (with-temp-buffer
     (gitlab-list-mode)
     (setq-local tabulated-list-format [("ID" 8 t)])
     (setq-local gitlab-list--kind 'merge-request)
     (setq-local gitlab-list--fetch-function
                 (lambda (success _error) (funcall success nil)))
     (setq-local gitlab-list--entries-function #'ignore)
     (setq-local gitlab-list--rows-function #'ignore)
     (let* (seen
            (gitlab-change-functions
             (list (lambda (kind id _data) (setq seen (list kind id))))))
       (gitlab-list--refresh)
       (should (equal '(merge-request nil) seen))))))

(ert-deftest gitlab-mode-format-object-job ()
  "A nested job gets no pipeline property."
  (let* ((value (gitlab--format-value
                 '((id . 5) (status . "failed") (stage . "test")
                   (name . "lint"))))
         (pipeline (get-text-property 0 'gitlab-pipeline-id value)))
    (should (equal "#5 failed" value))
    (should-not pipeline)))

(provide 'gitlab-mode-tests)

;;; gitlab-mode-tests.el ends here
