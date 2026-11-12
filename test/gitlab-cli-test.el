;;; gitlab-cli-test.el --- Tests of the glab transport -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Daniel Nagy

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;;; Commentary:

;; Offline tests of gitlab-cli.el against the mock-glab program.

;;; Code:

(require 'ert)
(require 'seq)
(require 'gitlab-test-helper)
(require 'gitlab-cli)
(require 'gitlab-data)
(require 'gitlab-error)

(ert-deftest gitlab-cli-request-json ()
  "A synchronous JSON request returns a list of alists."
  (gitlab-test-with-environment
   (let ((data (gitlab-cli-request '("mr" "list" "--output" "json"))))
     (should (= 2 (length data)))
     (should (equal 12 (gitlab-data-field "iid" (car data)))))))

(ert-deftest gitlab-cli-request-text ()
  "A nil PARSE returns the raw text."
  (gitlab-test-with-environment
   (let ((text (gitlab-cli-request '("ci" "trace" "1") 'text)))
     (should (stringp text))
     (should (string-match-p "step 2" text)))))

(ert-deftest gitlab-cli-request-error ()
  "A non-zero exit signals `gitlab-cli-error'."
  (gitlab-test-with-environment
   (let ((process-environment
          (cons "GITLAB_TEST_FAIL=1" process-environment)))
     (should-error (gitlab-cli-request '("mr" "list" "--output" "json"))
                   :type 'gitlab-cli-error))))

(ert-deftest gitlab-cli-request-async-success ()
  "An asynchronous request calls the success callback."
  (gitlab-test-with-environment
   (let (done data failure)
     (gitlab-cli-request-async
      '("mr" "list" "--output" "json")
      (lambda (value) (setq done t data value))
      (lambda (error) (setq done t failure error)))
     (should (gitlab-test-wait (lambda () done)))
     (should-not failure)
     (should (= 2 (length data))))))

(ert-deftest gitlab-cli-request-async-error ()
  "An asynchronous request calls the error callback with a condition."
  (gitlab-test-with-environment
   (let ((process-environment
          (cons "GITLAB_TEST_FAIL=1" process-environment))
         done failure)
     (gitlab-cli-request-async
      '("mr" "list" "--output" "json")
      (lambda (_value) (setq done t))
      (lambda (error) (setq done t failure error)))
     (should (gitlab-test-wait (lambda () done)))
     (should (eq (car failure) 'gitlab-cli-error)))))

(ert-deftest gitlab-cli-repository-arguments ()
  "A set repository is appended once."
  (let ((gitlab-repository "group/project"))
    (should (equal '("mr" "list" "--repo" "group/project")
                   (gitlab-cli--repository-arguments '("mr" "list"))))
    (should (equal '("mr" "list" "--repo" "mine")
                   (gitlab-cli--repository-arguments
                    '("mr" "list" "--repo" "mine"))))
    (should (equal '("mr" "list" "--repo=other/x")
                   (gitlab-cli--repository-arguments
                    '("mr" "list" "--repo=other/x"))))
    (should (equal '("mr" "list" "-Rother/x")
                   (gitlab-cli--repository-arguments
                    '("mr" "list" "-Rother/x"))))))

(ert-deftest gitlab-cli-group-suppresses-repository ()
  "A group selection wins over the repository, because glab ignores one."
  (let ((gitlab-repository "group/project"))
    (should (equal '("mr" "list" "--group" "my-group")
                   (gitlab-cli--repository-arguments
                    '("mr" "list" "--group" "my-group"))))
    (should (equal '("mr" "list" "--group=my-group")
                   (gitlab-cli--repository-arguments
                    '("mr" "list" "--group=my-group"))))
    (should (equal '("mr" "list" "-gmy-group")
                   (gitlab-cli--repository-arguments
                    '("mr" "list" "-gmy-group"))))))

(ert-deftest gitlab-cli-host-environment ()
  "The request environment names the instance of a group request."
  (let ((gitlab-cli--host "gitlab.example.com"))
    (should (member "GITLAB_HOST=gitlab.example.com"
                    (gitlab-cli--environment))))
  (let ((gitlab-cli--host nil))
    (should-not (seq-find (lambda (entry)
                            (string-prefix-p "GITLAB_HOST=" entry))
                          (gitlab-cli--environment))))
  (let ((gitlab-cli--host ""))
    (should-not (seq-find (lambda (entry)
                            (string-prefix-p "GITLAB_HOST=" entry))
                          (gitlab-cli--environment)))))

(ert-deftest gitlab-cli-directory ()
  "The program runs in `gitlab-cli-directory' when it is set."
  (gitlab-test-with-environment
   (let ((gitlab-cli-directory temporary-file-directory))
     (let* ((data (gitlab-cli-request '("probe" "pwd")))
            (pwd (gitlab-data-field "pwd" data)))
       (should (equal (file-truename (file-name-as-directory
                                      temporary-file-directory))
                      (file-truename (file-name-as-directory pwd))))))))

(ert-deftest gitlab-cli-project-directory ()
  "The display directory is the project root or the directory itself."
  (cl-letf (((symbol-function 'project-current)
             (lambda (&rest _arguments) 'stub-project))
            ((symbol-function 'project-root)
             (lambda (_project) "/the/project/")))
    (should (equal "/the/project/"
                   (gitlab-cli--project-directory
                    (file-name-as-directory "/the/project/sub")))))
  (cl-letf (((symbol-function 'project-current)
             (lambda (&rest _arguments) nil)))
    (should (equal (file-name-as-directory "/no/project")
                   (gitlab-cli--project-directory "/no/project")))))

(ert-deftest gitlab-cli-stream-no-timeout ()
  "A stream has no timeout by default."
  (gitlab-test-with-environment
   (let ((buffer (generate-new-buffer " *gitlab-stream test*")))
     (unwind-protect
         (let ((process (gitlab-cli-stream '("ci" "trace" "1")
                                           buffer #'ignore #'ignore)))
           (should-not (process-get process 'gitlab-cli-timer))
           (when (process-live-p process)
             (delete-process process)))
       (kill-buffer buffer)))))

(ert-deftest gitlab-cli-insert-chunk-keeps-point ()
  "A streamed chunk never moves point."
  (with-temp-buffer
    (gitlab-cli--insert-chunk "first\n")
    (should (= 1 (point)))
    (should (equal "first\n" (buffer-string))))
  (with-temp-buffer
    (gitlab-cli--insert-chunk "first\n")
    (goto-char (point-max))
    (gitlab-cli--insert-chunk "second\n")
    (should (= 7 (point)))
    (should (equal "first\nsecond\n" (buffer-string))))
  (with-temp-buffer
    (gitlab-cli--insert-chunk "first\n")
    (goto-char 3)
    (gitlab-cli--insert-chunk "second\n")
    (should (= 3 (point)))))

(ert-deftest gitlab-cli-project-endpoint ()
  "The API endpoint encodes a namespace path, or keeps :id."
  (let ((gitlab-repository "group/sub/project"))
    (should (string-match-p "projects/group%2Fsub%2Fproject/merge_requests/1"
                            (gitlab-cli-project-endpoint
                             "merge_requests/1"))))
  (let ((gitlab-repository nil))
    (should (equal "projects/:id/merge_requests/1"
                   (gitlab-cli-project-endpoint "merge_requests/1")))))

(provide 'gitlab-cli-tests)

;;; gitlab-cli-test.el ends here
