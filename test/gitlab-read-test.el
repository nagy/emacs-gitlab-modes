;;; gitlab-read-test.el --- Tests of the GitLab ID prompts -*- lexical-binding: t; -*-

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
(require 'gitlab-test-helper)
(require 'gitlab-read)

(ert-deftest gitlab-read-strip ()
  "A leading !, #, & or % goes away."
  (should (equal "12" (gitlab-read--strip "!12" '(?! ?#))))
  (should (equal "301" (gitlab-read--strip "#301" '(?! ?#))))
  (should (equal "21" (gitlab-read--strip "%21" '(?! ?# ?& ?%))))
  (should (equal "plain" (gitlab-read--strip "plain" '(?! ?#)))))

(ert-deftest gitlab-read-selected ()
  "A candidate wins, otherwise the typed ID is returned."
  (should (equal "12" (gitlab-read--selected "!12" '(("!12" . "12"))
                                              #'identity)))
  (should (equal "99" (gitlab-read--selected "!99" nil #'identity)))
  (should (equal "7" (gitlab-read--selected "&7" nil #'identity))))

(ert-deftest gitlab-read-number ()
  "The sort number of a candidate ignores its sigil."
  (should (= 12 (gitlab-read--number "!12")))
  (should (= 1001 (gitlab-read--number "#1001")))
  (should (= 0 (gitlab-read--number "plain"))))

(ert-deftest gitlab-read-sort-by-number ()
  "Candidates sort by the number that each one names."
  (should (equal '("#9" "#10" "!100")
                 (gitlab-read--sort-by-number '("#10" "#9" "!100")))))

(ert-deftest gitlab-read-annotation ()
  "The annotation of a candidate names the object behind it."
  (let* ((candidates '(("!12" . ((title . "Fix") (state . "opened")))))
         (annotate
          (gitlab-read--annotator
           candidates
           (lambda (object)
             (format "%s  [%s]" (alist-get 'title object)
                     (alist-get 'state object))))))
    (should (equal "  Fix  [opened]" (funcall annotate "!12")))
    (should-not (funcall annotate "!99"))))

(ert-deftest gitlab-read-merge-request-metadata ()
  "The merge request prompt declares its category and annotation."
  (gitlab-test-with-environment
   (let (collection category annotation)
     (cl-letf (((symbol-function 'gitlab-merge-request-list-cached)
                (lambda ()
                  '(((iid . 7) (title . "Seven") (state . "opened"))
                    ((iid . 10) (title . "Ten") (state . "closed")))))
               ((symbol-function 'completing-read)
                (lambda (_prompt completions &rest _arguments)
                  (setq collection (append completions nil)
                        category (plist-get completion-extra-properties
                                            :category)
                        annotation
                        (funcall (plist-get completion-extra-properties
                                            :annotation-function)
                                 "!7"))
                  "!7")))
       (should (equal "7" (gitlab-read-merge-request-iid))))
     (should (equal '("!7" "!10") collection))
     (should (eq 'gitlab-merge-request category))
     (should (equal "  Seven  [opened]" annotation)))))

(ert-deftest gitlab-read-repository-current-mark ()
  "The prompt of a project marks the project of the directory."
  (gitlab-test-with-environment
   (let (candidates annotation)
     (cl-letf (((symbol-function 'gitlab-git-context)
                (lambda () "group/project"))
               ((symbol-function 'completing-read)
                (lambda (_prompt completions &rest _arguments)
                  (setq candidates (append completions nil)
                        annotation
                        (funcall (plist-get completion-extra-properties
                                            :annotation-function)
                                 "group/project"))
                  "group/project")))
       (should (equal "group/project" (gitlab-read-repository))))
     (should (equal '("group/project") candidates))
     (should (equal "  (current)" annotation)))))

(ert-deftest gitlab-read-merge-request-iid ()
  "The prompt completes from the cached list, or accepts typed input."
  (gitlab-test-with-environment
   (cl-letf (((symbol-function 'completing-read)
              (lambda (&rest _arguments) "!12")))
     (should (equal "12" (gitlab-read-merge-request-iid))))))

(ert-deftest gitlab-read-work-item-iid ()
  "The work item prompt accepts a typed ID."
  (gitlab-test-with-environment
   (cl-letf (((symbol-function 'completing-read)
              (lambda (&rest _arguments) "%21")))
     (should (equal "21" (gitlab-read-work-item-iid))))))

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

(ert-deftest gitlab-read-group-text ()
  "The group prompt accepts a path, a context and a group URL."
  (should (equal "my-group" (gitlab-read--group-text "my-group")))
  (should (equal "my-group@gitlab.example.com"
                 (gitlab-read--group-text "my-group@gitlab.example.com")))
  (should (equal "my-group"
                 (gitlab-read--group-text
                  "https://gitlab.com/groups/my-group")))
  (should (equal "group/sub@gitlab.example.com"
                 (gitlab-read--group-text
                  "https://gitlab.example.com/groups/group/sub")))
  (should (equal "my-group@gitlab.example.com"
                 (gitlab-read--group-text
                  (concat "https://gitlab.example.com/groups/my-group"
                          "/-/merge_requests?state=opened")))))

(ert-deftest gitlab-read-namespace ()
  "The group candidate drops the last path segment and keeps the host."
  (should (equal "group" (gitlab-read--namespace "group/project")))
  (should (equal "group/sub" (gitlab-read--namespace "group/sub/project")))
  (should (equal "group@host" (gitlab-read--namespace "group/project@host")))
  (should-not (gitlab-read--namespace "project"))
  (should-not (gitlab-read--namespace nil)))

(ert-deftest gitlab-read-group-default ()
  "A group buffer offers its own group, and a project buffer its namespace."
  (gitlab-test-with-environment
   (cl-letf (((symbol-function 'gitlab-git-context)
              (lambda (&optional _directory) "group/project"))
             ((symbol-function 'completing-read)
              (lambda (_prompt collection _predicate _require _initial history
                       default)
                (should (member default collection))
                (should (memq history '(gitlab-read-group-history)))
                default)))
     (should (equal "group" (gitlab-read-group)))
     (should (equal "my-group" (gitlab-read-group nil "my-group"))))))

(provide 'gitlab-read-tests)

;;; gitlab-read-test.el ends here
