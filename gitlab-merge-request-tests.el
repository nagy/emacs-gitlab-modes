;;; gitlab-merge-request-tests.el --- Tests of the merge request views -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Daniel Nagy

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;;; Commentary:

;; Offline tests of the merge request list and detail buffers.

;;; Code:

(require 'ert)
(require 'gitlab-test-helpers)
(require 'gitlab-merge-request)

(defun gitlab-merge-request-tests--wait-for (buffer text)
  "Wait until BUFFER contains TEXT."
  (gitlab-test-wait
   (lambda ()
     (and (buffer-live-p buffer)
          (with-current-buffer buffer
            (string-match-p (regexp-quote text) (buffer-string)))))))

(ert-deftest gitlab-merge-request-detail-list-buffers-directory ()
  "A detail buffer names its object in `list-buffers-directory'."
  (gitlab-test-with-environment
   (let* ((gitlab-repository "group/project")
          (buffer (gitlab--prepare-detail
                   (lambda (_id _context) "*GitLab list-buffers test*")
                   #'gitlab-merge-request-mode "12")))
     (unwind-protect
         (with-current-buffer buffer
           (should (equal "group/project!12" list-buffers-directory)))
       (with-current-buffer buffer
         (set-buffer-modified-p nil))
       (kill-buffer buffer)))))

(ert-deftest gitlab-merge-request-list-entries ()
  "The list renders both merge requests."
  (gitlab-test-with-environment
   (let ((buffer (generate-new-buffer "*GitLab MR list test*")))
     (unwind-protect
         (with-current-buffer buffer
           (gitlab-merge-request-list-mode)
           (gitlab-list--refresh)
           (should (gitlab-test-wait
                    (lambda () (= 2 (length tabulated-list-entries)))))
           (should (= 2 (length gitlab-list--rows)))
           (should (string-match-p "!12" (buffer-string)))
           (should (string-match-p "Add the export dialog" (buffer-string)))
           (should (string-match-p "closed" (buffer-string))))
       (kill-buffer buffer)))))

(ert-deftest gitlab-merge-request-list-thing-at-point-url ()
  "The url thing at point is the web URL of the row."
  (gitlab-test-with-environment
   (let ((buffer (generate-new-buffer "*GitLab MR list url test*")))
     (unwind-protect
         (with-current-buffer buffer
           (gitlab-merge-request-list-mode)
           (gitlab-list--refresh)
           (should (gitlab-test-wait
                    (lambda () (= 2 (length tabulated-list-entries)))))
           (goto-char (point-min))
           (forward-line 1)
           (forward-char 3)
           (should (equal "https://gitlab.example/group/project/-/merge_requests/13"
                          (thing-at-point 'url)))
           (should (equal (gitlab-data-field
                           "web_url" (gitlab-list--row-at-point))
                          (thing-at-point 'url))))
       (with-current-buffer buffer
         (set-buffer-modified-p nil))
       (kill-buffer buffer)))))

(ert-deftest gitlab-merge-request-detail-render ()
  "The detail buffer shows fields and nested objects."
  (gitlab-test-with-environment
   (let ((buffer (generate-new-buffer "*GitLab MR detail test*")))
     (unwind-protect
         (progn
           (with-current-buffer buffer
             (gitlab-merge-request-mode)
             (setq-local gitlab--id "12")
             (gitlab--refresh))
           (should (gitlab-merge-request-tests--wait-for
                    buffer "Add the export dialog"))
           (with-current-buffer buffer
             (should (string-match-p "Alice (@alice)"
                                     (buffer-string)))
             (should (string-match-p "Milestone One (!16)" (buffer-string)))
             (should (string-match-p "#1001 success" (buffer-string)))
             (should (string-match-p "Fix for #1" (buffer-string)))))
       (kill-buffer buffer)))))

(ert-deftest gitlab-merge-request-notes-command ()
  "The notes command adds the notes below the fields."
  (gitlab-test-with-environment
   (let ((buffer (generate-new-buffer "*GitLab MR notes test*")))
     (unwind-protect
         (progn
           (with-current-buffer buffer
             (gitlab-merge-request-mode)
             (setq-local gitlab--id "12")
             (gitlab--refresh))
           (should (gitlab-merge-request-tests--wait-for
                    buffer "Add the export dialog"))
           (with-current-buffer buffer
             (gitlab-merge-request-show-notes))
           (should (gitlab-merge-request-tests--wait-for
                    buffer "Looks good to me."))
           (with-current-buffer buffer
             (should (string-match-p "Changed the target branch."
                                     (buffer-string)))
             (should (string-match-p "(system)" (buffer-string)))))
       (kill-buffer buffer)))))

(ert-deftest gitlab-merge-request-entries-fields ()
  "A list row carries the IID, state and branch columns."
  (let* ((data '(((iid . 7)
                  (title . "Seven")
                  (state . "opened")
                  (author (name . "Alice") (username . "alice"))
                  (source_branch . "feature")
                  (target_branch . "main")
                  (labels . ("UX"))
                  (updated_at . "2026-10-31T20:57:30.763Z"))))
         (entries (gitlab-merge-request--entries data))
         (row (cadr (car entries))))
    (should (equal "7" (car (car entries))))
    (should (equal "!7" (aref row 0)))
    (should (equal "Seven" (aref row 1)))
    (should (equal "Alice (@alice)" (aref row 3)))
    (should (equal "feature -> main" (aref row 4)))
    (should (equal "UX" (aref row 5)))
    (should (equal "2026-10-31 20:57:30" (aref row 6)))
    (should (eq 'gitlab-date (get-text-property 0 'face (aref row 6))))))

(ert-deftest gitlab-merge-request-detail-parent ()
  "A merge request detail buffer opens the merge request list.
The list belongs to the project of the merge request, so a merge
request of another project opens the list of that project."
  (gitlab-test-with-environment
   (let ((buffer (generate-new-buffer "*GitLab MR parent test*")))
     (unwind-protect
         (let ((gitlab-repository "group/project"))
           (with-current-buffer buffer
             (gitlab-merge-request-mode)
             (setq-local gitlab--id "12")
             (gitlab-go-to-parent)
             (should (derived-mode-p 'gitlab-merge-request-list-mode))
             (should (equal "group/project"
                            (buffer-local-value
                             'gitlab--context (current-buffer))))))
       (kill-buffer buffer)
       (when-let* ((list (get-buffer
                          (gitlab--contextual-name
                           gitlab-merge-request-list-buffer-name
                           "group/project"))))
         (kill-buffer list))))))

(defun gitlab-merge-request-tests--detail-buffer (iid)
  "Return a merge request detail buffer for IID without a fetch."
  (let ((buffer (generate-new-buffer "*GitLab MR sibling test*")))
    (with-current-buffer buffer
      (gitlab-merge-request-mode)
      (gitlab--use-project-directory)
      (setq-local gitlab--id iid)
      (setq-local gitlab--identity
                  (list #'gitlab-merge-request-mode iid gitlab--context)))
    buffer))

(defun gitlab-merge-request-tests--list-buffer ()
  "Return a rendered merge request list buffer."
  (let ((buffer (generate-new-buffer "*GitLab MR list sibling test*")))
    (with-current-buffer buffer
      (gitlab-merge-request-list-mode)
      (gitlab--use-project-directory)
      (setq-local gitlab--identity
                  (list #'gitlab-merge-request-list-mode nil gitlab--context))
      (gitlab-list--refresh))
    (gitlab-test-wait
     (lambda () (with-current-buffer buffer
                  (not (null tabulated-list-entries)))))
    buffer))

(ert-deftest gitlab-merge-request-detail-next-sibling ()
  "The next sibling of a merge request is the next row of its list."
  (gitlab-test-with-environment
   (let ((list (gitlab-merge-request-tests--list-buffer))
         (detail (gitlab-merge-request-tests--detail-buffer "12"))
         opened)
     (unwind-protect
         (with-current-buffer detail
           (cl-letf (((symbol-function 'gitlab-display-merge-request)
                      (lambda (iid) (setq opened iid))))
             (call-interactively #'gitlab-next-sibling))
           (should (equal "13" opened)))
       (kill-buffer detail)
       (kill-buffer list)))))

(ert-deftest gitlab-merge-request-detail-previous-sibling ()
  "The previous sibling of a merge request is the earlier row."
  (gitlab-test-with-environment
   (let ((list (gitlab-merge-request-tests--list-buffer))
         (detail (gitlab-merge-request-tests--detail-buffer "13"))
         opened)
     (unwind-protect
         (with-current-buffer detail
           (cl-letf (((symbol-function 'gitlab-display-merge-request)
                      (lambda (iid) (setq opened iid))))
             (call-interactively #'gitlab-previous-sibling))
           (should (equal "12" opened)))
       (kill-buffer detail)
       (kill-buffer list)))))

(ert-deftest gitlab-merge-request-detail-sibling-needs-list ()
  "A merge request detail without its list signals a `user-error'."
  (gitlab-test-with-environment
   (let ((detail (gitlab-merge-request-tests--detail-buffer "12")))
     (unwind-protect
         (with-current-buffer detail
           (should-error (gitlab-next-sibling) :type 'user-error))
       (kill-buffer detail)))))

(provide 'gitlab-merge-request-tests)

;;; gitlab-merge-request-tests.el ends here
