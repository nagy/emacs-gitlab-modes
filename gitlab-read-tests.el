;;; gitlab-read-tests.el --- Tests of the GitLab ID prompts -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Daniel Nagy

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;;; Commentary:

;; Offline tests of the completion helpers.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'gitlab-test-helpers)
(require 'gitlab-read)

(ert-deftest gitlab-read-strip ()
  "A leading ! or # goes away."
  (should (equal "12" (gitlab-read--strip "!12" '(?! ?#))))
  (should (equal "301" (gitlab-read--strip "#301" '(?! ?#))))
  (should (equal "plain" (gitlab-read--strip "plain" '(?! ?#)))))

(ert-deftest gitlab-read-answer ()
  "A matching label wins, otherwise the typed ID is returned."
  (should (equal "12" (gitlab-read--answer
                       '(("!12  Fix" . "12")) "!12  Fix")))
  (should (equal "99" (gitlab-read--answer nil "!99"))))

(ert-deftest gitlab-read-merge-request-iid ()
  "The prompt completes from the cached list, or accepts typed input."
  (gitlab-test-with-environment
   (cl-letf (((symbol-function 'completing-read)
              (lambda (&rest _arguments) "!12")))
     (should (equal "12" (gitlab-read-merge-request-iid))))))

(ert-deftest gitlab-read-pipeline-id ()
  "The pipeline prompt accepts a typed ID."
  (gitlab-test-with-environment
   (cl-letf (((symbol-function 'completing-read)
              (lambda (&rest _arguments) "1001")))
     (should (equal "1001" (gitlab-read-pipeline-id))))))

(ert-deftest gitlab-read-job-id ()
  "The job prompt reads a pipeline first, then a job."
  (gitlab-test-with-environment
   (let ((calls 0))
     (cl-letf (((symbol-function 'completing-read)
                (lambda (&rest _arguments)
                  (setq calls (1+ calls))
                  (if (= calls 1) "1001" "5001"))))
       (should (equal "5001" (gitlab-read-job-id)))
       (should (= 2 calls))))))

(provide 'gitlab-read-tests)

;;; gitlab-read-tests.el ends here
