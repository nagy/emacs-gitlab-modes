;;; gitlab-export-tests.el --- Tests of the JSON export -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Daniel Nagy

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Affero General Public License for more details.

;; You should have received a copy of the GNU Affero General Public
;; License along with this program.  If not, see
;; <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Offline tests of `gitlab-export-json'.  The suite compares the
;; export with the fixture that the mock glab prints, so a raw answer
;; must survive the fetch byte for byte.

;;; Code:

(require 'ert)
(require 'gitlab-test-helpers)
(require 'gitlab-export)
(require 'gitlab-merge-request)
(require 'gitlab-pipeline)

(defun gitlab-export-tests--fixture (name)
  "Return the text of the fixture NAME without trailing whitespace."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name name
                       (expand-file-name "fixtures"
                                         gitlab-test--directory)))
    (string-trim-right (buffer-string))))

(defun gitlab-export-tests--wait-for-render (buffer)
  "Wait until BUFFER holds a rendered answer."
  (gitlab-test-wait
   (lambda ()
     (and (buffer-live-p buffer)
          (with-current-buffer buffer gitlab--rendered)))))

(ert-deftest gitlab-export-json-remaps-the-json-mode ()
  "A request for the JSON major mode reaches the export command."
  (with-temp-buffer
    (gitlab-detail-mode)
    (should (eq (command-remapping 'js-json-mode) #'gitlab-export-json)))
  (with-temp-buffer
    (gitlab-list-mode)
    (should (eq (command-remapping 'js-json-mode) #'gitlab-export-json))))

(ert-deftest gitlab-export-json-keeps-the-detail-answer ()
  "A merge request export matches the glab text byte for byte."
  (gitlab-test-with-environment
   (let ((buffer (generate-new-buffer "*gitlab-export-detail*")))
     (unwind-protect
         (progn
           (with-current-buffer buffer
             (gitlab-merge-request-mode)
             (setq-local gitlab--id "12")
             (gitlab--refresh))
           (should (gitlab-export-tests--wait-for-render buffer))
           (with-current-buffer buffer
             (let ((export (gitlab-export-json)))
               (unwind-protect
                   (with-current-buffer export
                     (should (equal
                              (string-trim-right (buffer-string))
                              (gitlab-export-tests--fixture
                               "mr-view.json"))))
                 (kill-buffer export)))))
       (kill-buffer buffer)))))

(ert-deftest gitlab-export-json-copies-the-buffer-identifier ()
  "The export buffer shows the identifier of its source buffer."
  (gitlab-test-with-environment
   (let ((buffer (let ((gitlab-repository "group/project"))
                   (gitlab-display-merge-request "12"))))
     (unwind-protect
         (progn
           (should (gitlab-export-tests--wait-for-render buffer))
           (with-current-buffer buffer
             (should (equal "group/project!12" list-buffers-directory))
             (let ((export (gitlab-export-json)))
               (unwind-protect
                   (with-current-buffer export
                     (should (equal "group/project!12"
                                    list-buffers-directory)))
                 (kill-buffer export)))))
       (kill-buffer buffer)))))

(ert-deftest gitlab-export-json-keeps-the-list-answer ()
  "A pipeline list export matches the glab array."
  (gitlab-test-with-environment
   (let ((buffer (generate-new-buffer "*gitlab-export-list*")))
     (unwind-protect
         (progn
           (with-current-buffer buffer
             (gitlab-pipeline-list-mode)
             (gitlab-list--refresh))
           (should (gitlab-export-tests--wait-for-render buffer))
           (with-current-buffer buffer
             (let ((export (gitlab-export-json)))
               (unwind-protect
                   (with-current-buffer export
                     (should (equal
                              (string-trim-right (buffer-string))
                              (gitlab-export-tests--fixture
                               "ci-list.json"))))
                 (kill-buffer export)))))
       (kill-buffer buffer)))))

(ert-deftest gitlab-export-json-keeps-the-jobs-array ()
  "A pipeline export matches the answer that holds the jobs."
  (gitlab-test-with-environment
   (let ((buffer (generate-new-buffer "*gitlab-export-pipeline*")))
     (unwind-protect
         (progn
           (with-current-buffer buffer
             (gitlab-pipeline-mode)
             (setq-local gitlab--id "1001")
             (gitlab--refresh))
           (should (gitlab-export-tests--wait-for-render buffer))
           (with-current-buffer buffer
             (let ((export (gitlab-export-json)))
               (unwind-protect
                   (with-current-buffer export
                     (should (equal
                              (string-trim-right (buffer-string))
                              (gitlab-export-tests--fixture
                               "ci-get.json"))))
                 (kill-buffer export)))))
       (kill-buffer buffer)))))

(ert-deftest gitlab-export-json-reuses-one-buffer ()
  "A second export replaces the text of the same buffer."
  (let ((source (generate-new-buffer "*gitlab-export-source*"))
        first
        second)
    (unwind-protect
        (progn
          (with-current-buffer source
            (gitlab-detail-mode)
            (setq-local gitlab--last-data '((iid . 1) (draft . :false)))
            (setq-local gitlab--rendered t)
            (setq first (gitlab-export-json)))
          (with-current-buffer first
            (should (string-match-p "\"iid\": 1" (buffer-string)))
            (should (string-match-p "\"draft\": false" (buffer-string)))
            (should (eq major-mode 'js-json-mode))
            (should buffer-read-only)
            (should-not (buffer-modified-p)))
          (with-current-buffer source
            (setq-local gitlab--last-data '((iid . 2)))
            (setq second (gitlab-export-json)))
          (should (eq first second))
          (with-current-buffer first
            (should (string-match-p "\"iid\": 2" (buffer-string)))
            (should-not (string-match-p "\"iid\": 1" (buffer-string)))))
      (when (buffer-live-p first) (kill-buffer first))
      (kill-buffer source))))

(ert-deftest gitlab-export-json-reverts-from-the-source ()
  "`revert-buffer' reads the source buffer again."
  (let ((source (generate-new-buffer "*gitlab-export-revert*"))
        (export nil))
    (unwind-protect
        (progn
          (with-current-buffer source
            (gitlab-detail-mode)
            (setq-local gitlab--last-data '((iid . 1)))
            (setq-local gitlab--rendered t)
            (setq export (gitlab-export-json)))
          (with-current-buffer source
            (setq-local gitlab--last-data '((iid . 3))))
          (with-current-buffer export
            (should (string-match-p "\"iid\": 1" (buffer-string)))
            (revert-buffer nil nil)
            (should (string-match-p "\"iid\": 3" (buffer-string)))
            (should-not (buffer-modified-p)))
          (kill-buffer source)
          (with-current-buffer export
            (should-error (revert-buffer nil nil) :type 'user-error)))
      (when (buffer-live-p export) (kill-buffer export)))))

(ert-deftest gitlab-export-json-encodes-a-merged-fetch ()
  "A pipeline fetch that merges two answers drops the raw text."
  (gitlab-test-with-environment
   (let ((process-environment
          (cons "GITLAB_TEST_NO_JOBS=1" process-environment))
         (buffer (generate-new-buffer "*gitlab-export-merge-fetch*")))
     (unwind-protect
         (progn
           (with-current-buffer buffer
             (gitlab-pipeline-mode)
             (setq-local gitlab--id "1001")
             (gitlab--refresh))
           (should (gitlab-export-tests--wait-for-render buffer))
           (with-current-buffer buffer
             (should-not gitlab--raw-text)
             (let ((export (gitlab-export-json)))
               (unwind-protect
                   (with-current-buffer export
                     (should (string-match-p "\"jobs\":"
                                             (buffer-string)))
                     (should (string-match-p "unit-tests"
                                             (buffer-string))))
                 (kill-buffer export)))))
       (kill-buffer buffer)))))

(ert-deftest gitlab-export-json-encodes-a-merged-answer ()
  "An answer without a raw text encodes false and null again."
  (let ((source (generate-new-buffer "*gitlab-export-merged*"))
        (export nil))
    (unwind-protect
        (progn
          (with-current-buffer source
            (gitlab-detail-mode)
            (setq-local gitlab--last-data
                        '((draft . :false) (closed_at . nil)))
            (setq-local gitlab--rendered t)
            (setq export (gitlab-export-json)))
          (with-current-buffer export
            (should (string-match-p "\"draft\": false" (buffer-string)))
            (should (string-match-p "\"closed_at\": null" (buffer-string)))))
      (when (buffer-live-p export) (kill-buffer export))
      (kill-buffer source))))

(ert-deftest gitlab-export-json-refuses-a-buffer-without-data ()
  "A job log and a fresh detail buffer have no JSON answer."
  (with-temp-buffer
    (gitlab-job-log-mode)
    (should-error (gitlab-export-json) :type 'user-error))
  (with-temp-buffer
    (gitlab-detail-mode)
    (should-error (gitlab-export-json) :type 'user-error)))

(ert-deftest gitlab-export-json-command-modes ()
  "The export command names both display base modes."
  (should (equal '(gitlab-detail-mode gitlab-list-mode)
                 (command-modes #'gitlab-export-json))))

(provide 'gitlab-export-tests)

;;; gitlab-export-tests.el ends here
