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
           (should (string-match-p "!8285" (buffer-string)))
           (should (string-match-p "Make file extension" (buffer-string)))
           (should (string-match-p "closed" (buffer-string))))
       (kill-buffer buffer)))))

(ert-deftest gitlab-merge-request-detail-render ()
  "The detail buffer shows fields and nested objects."
  (gitlab-test-with-environment
   (let ((buffer (generate-new-buffer "*GitLab MR detail test*")))
     (unwind-protect
         (progn
           (with-current-buffer buffer
             (gitlab-merge-request-mode)
             (setq-local gitlab--id "8285")
             (gitlab--refresh))
           (should (gitlab-merge-request-tests--wait-for
                    buffer "Make file extension match the export type"))
           (with-current-buffer buffer
             (should (string-match-p "Tavmjong Bah (@tavmjong)"
                                     (buffer-string)))
             (should (string-match-p "Inkscape 1.5 (!16)" (buffer-string)))
             (should (string-match-p "#3010647305 success" (buffer-string)))
             (should (string-match-p "Fix for #4238" (buffer-string)))))
       (kill-buffer buffer)))))

(ert-deftest gitlab-merge-request-notes-command ()
  "The notes command adds the notes below the fields."
  (gitlab-test-with-environment
   (let ((buffer (generate-new-buffer "*GitLab MR notes test*")))
     (unwind-protect
         (progn
           (with-current-buffer buffer
             (gitlab-merge-request-mode)
             (setq-local gitlab--id "8285")
             (gitlab--refresh))
           (should (gitlab-merge-request-tests--wait-for
                    buffer "Make file extension match the export type"))
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
    (should (equal "UX" (aref row 5)))))

(provide 'gitlab-merge-request-tests)

;;; gitlab-merge-request-tests.el ends here
