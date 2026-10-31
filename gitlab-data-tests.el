;;; gitlab-data-tests.el --- Tests of the GitLab data layer -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Daniel Nagy

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;;; Commentary:

;; Offline tests of gitlab-data.el.  No test opens a network
;; connection; every request runs mock-glab.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'gitlab-test-helpers)
(require 'gitlab-data)
(require 'gitlab-error)

(ert-deftest gitlab-data-field-access ()
  "Field access compares symbols and keeps missing fields distinct."
  (let ((data '((iid . 12) (state . "opened") (title . "Fix"))))
    (should (equal 12 (gitlab-data-field "iid" data)))
    (should (equal 12 (gitlab-data-field 'iid data)))
    (should (equal "missing" (gitlab-data-field "nope" data "missing")))
    (should (equal "12" (gitlab-data-field-string "iid" data)))))

(ert-deftest gitlab-data-alist-p ()
  "Only a JSON object counts as an alist."
  (should (gitlab-data-alist-p '((id . 1))))
  (should-not (gitlab-data-alist-p '(((id . 1)))))
  (should-not (gitlab-data-alist-p nil)))

(ert-deftest gitlab-data-set-field ()
  "Set an existing field and append a missing one."
  (let ((data '((id . 1))))
    (gitlab-data-set-field "status" data "running")
    (should (equal "running" (gitlab-data-field "status" data)))
    (gitlab-data-set-field "status" data "success")
    (should (equal "success" (gitlab-data-field "status" data)))))

(ert-deftest gitlab-merge-request-list ()
  "Fetch the merge request list."
  (gitlab-test-with-environment
   (let ((data (gitlab-merge-request-list)))
     (should (= 2 (length data)))
     (should (equal 8285 (gitlab-data-field "iid" (car data)))))))

(ert-deftest gitlab-merge-request-show ()
  "Fetch one merge request."
  (gitlab-test-with-environment
   (let ((data (gitlab-merge-request-show 8285)))
     (should (equal "Make file extension match the export type"
                    (gitlab-data-field "title" data)))
     (should (equal "success"
                    (gitlab-data-field "status"
                                       (gitlab-data-field "pipeline" data)))))))

(ert-deftest gitlab-merge-request-notes ()
  "Fetch the notes of a merge request."
  (gitlab-test-with-environment
   (let ((notes (gitlab-merge-request-notes 8285)))
     (should (= 2 (length notes)))
     (should (equal "Looks good to me."
                    (gitlab-data-field "body" (car notes)))))))

(ert-deftest gitlab-pipeline-list-and-show ()
  "Fetch the pipeline list and one pipeline with its jobs."
  (gitlab-test-with-environment
   (let* ((pipelines (gitlab-pipeline-list))
          (pipeline (gitlab-pipeline-show 3010647305)))
     (should (= 2 (length pipelines)))
     (should (equal "success" (gitlab-data-field "status" pipeline)))
     (should (= 3 (length (gitlab-data-field "jobs" pipeline)))))))

(ert-deftest gitlab-pipeline-jobs-fallback ()
  "When ci get omits jobs, fetch the jobs endpoint once."
  (gitlab-test-with-environment
   (let ((process-environment
          (cons "GITLAB_TEST_NO_JOBS=1" process-environment)))
     (let ((pipeline (gitlab-pipeline-show 3010647305)))
       (should (= 2 (length (gitlab-data-field "jobs" pipeline))))
       (should (equal "media-check"
                      (gitlab-data-field
                       "name" (car (gitlab-data-field "jobs" pipeline)))))))))

(ert-deftest gitlab-job-trace ()
  "Fetch a job trace as text."
  (gitlab-test-with-environment
   (let ((text (gitlab-job-trace 17624043693)))
     (should (stringp text))
     (should (string-match-p "step 1" text)))))

(ert-deftest gitlab-list-cache ()
  "A cached list keeps its answer until the cache is cleared."
  (gitlab-test-with-environment
   (let ((first (gitlab-merge-request-list-cached))
         (second (gitlab-merge-request-list-cached)))
     (should (equal first second))
     (gitlab-cache-invalidate 'merge-request)
     (should (equal first (gitlab-merge-request-list-cached))))))

(ert-deftest gitlab-data-pagination-arguments ()
  "Notes and jobs requests ask for one full page.
`--paginate' concatenates JSON arrays, which one decode cannot
read, so the endpoints cap the request at 100 items instead."
  (let ((gitlab-repository "group/project"))
    (dolist (arguments (list (gitlab--cli-merge-request-notes-arguments 12)
                             (gitlab--cli-pipeline-jobs-arguments 301)))
      (should-not (member "--paginate" arguments))
      (should (cl-some (lambda (argument)
                         (string-match-p "per_page=100" argument))
                       arguments)))))

(ert-deftest gitlab-api-backend-reserved ()
  "The api backend signals a clear backend error."
  (let ((gitlab-backend 'api))
    (should-error (gitlab-merge-request-list)
                  :type 'gitlab-backend-error)))

(provide 'gitlab-data-tests)

;;; gitlab-data-tests.el ends here
