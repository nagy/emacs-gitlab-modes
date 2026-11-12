;;; gitlab-context-test.el --- Tests of the project context -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Daniel Nagy

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;;; Commentary:

;; Offline tests of the project context: the PATH or PATH@HOST
;; spelling of `gitlab-cli-repository-normalize', the Git remote read,
;; the buffer names of a list and of a detail buffer, and the buffer
;; lookup that ignores the name that the user gave a buffer.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'gitlab-test-helper)
(require 'gitlab-cli)
(require 'gitlab-data)
(require 'gitlab-git)
(require 'gitlab-read)
(require 'gitlab-merge-request)
(require 'gitlab-pipeline)

(defvar gitlab-context-tests--environment
  '("GIT_CONFIG_NOSYSTEM=1"
    "GIT_CONFIG_GLOBAL=/dev/null"
    "GIT_AUTHOR_NAME=Test"
    "GIT_AUTHOR_EMAIL=test@example.com"
    "GIT_COMMITTER_NAME=Test"
    "GIT_COMMITTER_EMAIL=test@example.com")
  "Environment that keeps git away from the user configuration.")

(defun gitlab-context-tests--git (directory &rest arguments)
  "Run git with ARGUMENTS in DIRECTORY and return its output."
  (let ((default-directory directory)
        (process-environment (append gitlab-context-tests--environment
                                     process-environment)))
    (with-temp-buffer
      (unless (eq 0 (apply #'process-file "git" nil t nil arguments))
        (error "git %S failed: %s" arguments (buffer-string)))
      (string-trim (buffer-string)))))

(defun gitlab-context-tests--repo (&optional url)
  "Return a scratch repository that holds one commit.
URL becomes the origin remote, so the display layer derives a
project context from it.  The repository also carries a fetched
refs/remotes/origin/merge-requests/7/head ref.  Return a cons of the
directory and the base commit."
  (let ((directory (make-temp-file "gitlab-context-test-" t)))
    (gitlab-context-tests--git directory "init" "-q" "-b" "main")
    (with-temp-file (expand-file-name "file.txt" directory)
      (insert "one\n"))
    (gitlab-context-tests--git directory "add" "file.txt")
    (gitlab-context-tests--git directory "commit" "-q" "-m" "first")
    (let ((base (gitlab-context-tests--git directory "rev-parse" "HEAD")))
      (with-temp-file (expand-file-name "file.txt" directory)
        (insert "two\n"))
      (gitlab-context-tests--git directory "commit" "-q" "-am" "second")
      (let ((head (gitlab-context-tests--git directory "rev-parse" "HEAD")))
        (gitlab-context-tests--git directory "update-ref"
                                   "refs/remotes/origin/merge-requests/7/head"
                                   head)
        (when url
          (gitlab-context-tests--git directory "remote" "add" "origin" url))
        (cons directory base)))))

(defun gitlab-context-tests--data (base)
  "Return merge request data that names BASE as the diff base."
  `((iid . 7)
    (title . "Local commits")
    (source_branch . "feature")
    (target_branch . "main")
    (diff_refs . ((base_sha . ,base)
                  (start_sha . ,base)))))

(defmacro gitlab-context-tests--with-repo (url &rest body)
  "Run BODY with REPO bound to a scratch repository that has URL.
Kill every GitLab buffer that BODY opened."
  (declare (indent 1))
  `(progn
     (skip-unless (executable-find "git"))
     (let ((repo (gitlab-context-tests--repo ,url)))
       (unwind-protect
           (progn ,@body)
         (dolist (buffer (buffer-list))
           (with-current-buffer buffer
             (when (or gitlab--identity gitlab-list--kind)
               (kill-buffer buffer))))
         (delete-directory (car repo) t)))))

(defun gitlab-context-tests--display-list (repository)
  "Display the merge request list of REPOSITORY and return the buffer."
  (with-temp-buffer
    (let ((gitlab-repository repository))
      (gitlab-list-merge-requests))))

;;; Repository spelling

(ert-deftest gitlab-context-normalize ()
  "A URL, a Git URL and a bare path share one spelling."
  (should (equal "group/project"
                 (gitlab-cli-repository-normalize "group/project")))
  (should (equal "group/sub/project"
                 (gitlab-cli-repository-normalize "/group/sub/project/")))
  (should (equal "group/project"
                 (gitlab-cli-repository-normalize
                  "https://gitlab.com/group/project.git")))
  (should (equal "group/project@gitlab.example.com"
                 (gitlab-cli-repository-normalize
                  "git@gitlab.example.com:group/project.git")))
  (should (equal "group/project@gitlab.example.com"
                 (gitlab-cli-repository-normalize
                  "https://gitlab.example.com/group/project")))
  (should (equal "group/project@gitlab.example.com"
                 (gitlab-cli-repository-normalize
                  "group/project@GitLab.Example.com")))
  (should (equal "g/p@host.example"
                 (gitlab-cli-repository-normalize
                  "ssh://git@host.example:2222/g/p.git")))
  (should-not (gitlab-cli-repository-normalize nil))
  (should-not (gitlab-cli-repository-normalize "")))

(ert-deftest gitlab-context-split ()
  "The split keeps the default instance out of the answer."
  (should (equal '(nil . "group/project")
                 (gitlab-cli-repository-split
                  "https://gitlab.com/group/project")))
  (should (equal '(nil . "group/project")
                 (gitlab-cli-repository-split "group/project@gitlab.com")))
  (should (equal '("gitlab.example.com" . "group/project")
                 (gitlab-cli-repository-split
                  "group/project@gitlab.example.com")))
  (should (equal "group/project"
                 (gitlab-cli-repository-path
                  "group/project@gitlab.example.com")))
  (should (equal "gitlab.example.com"
                 (gitlab-cli-repository-host
                  "group/project@gitlab.example.com")))
  (should-not (gitlab-cli-repository-host "group/project")))

(ert-deftest gitlab-context-repository-arguments ()
  "A project of another instance selects that instance."
  (let ((gitlab-repository "group/project@gitlab.example.com"))
    (should (equal '("mr" "list" "--repo"
                     "https://gitlab.example.com/group/project")
                   (gitlab-cli--repository-arguments '("mr" "list")))))
  (let ((gitlab-repository "group/project"))
    (should (equal '("mr" "list" "--repo" "group/project")
                   (gitlab-cli--repository-arguments '("mr" "list"))))))

(ert-deftest gitlab-context-project-endpoint ()
  "The host of a project stays out of the API endpoint."
  (let ((gitlab-repository "group/project@gitlab.example.com"))
    (should (equal "projects/group%2Fproject/merge_requests/1"
                   (gitlab-cli-project-endpoint "merge_requests/1")))))

(ert-deftest gitlab-context-web-url ()
  "A project of another instance links to that instance."
  (let ((gitlab-repository "group/project"))
    (should (equal "https://gitlab.com/group/project/-/merge_requests/12"
                   (gitlab-web-url 'merge-request 12))))
  (let ((gitlab-repository "group/project@gitlab.example.com"))
    (should (equal
             "https://gitlab.example.com/group/project/-/pipelines/1001"
             (gitlab-web-url 'pipeline 1001)))
    (should (equal
             "https://gitlab.example.com/group/project/-/jobs/5001"
             (gitlab-web-url 'job 5001)))))

;;; Git remote

(ert-deftest gitlab-context-git-remote ()
  "The remote URL names the project and its instance."
  (gitlab-context-tests--with-repo "git@gitlab.example.com:group/project.git"
    (should (equal "group/project@gitlab.example.com"
                   (gitlab-git-remote-context (car repo))))
    (should (equal (list "origin") (gitlab-git-remotes (car repo))))
    (should (equal "group/project@gitlab.example.com"
                   (gitlab-git-context (car repo))))))

(ert-deftest gitlab-context-git-remote-local-path ()
  "A remote that names a local path gives no context."
  (gitlab-context-tests--with-repo "/tmp/other/checkout"
    (should-not (gitlab-git-remote-context (car repo)))))

(ert-deftest gitlab-context-git-without-remote ()
  "A repository without a remote gives no context."
  (gitlab-context-tests--with-repo nil
    (should-not (gitlab-git-remote-context (car repo)))))

(ert-deftest gitlab-context-explicit-repository-wins ()
  "A set `gitlab-repository' wins over the remote."
  (gitlab-context-tests--with-repo "git@gitlab.example.com:group/project.git"
    (let ((gitlab-repository "mine/fork"))
      (should (equal "mine/fork" (gitlab-git-context (car repo)))))))

(ert-deftest gitlab-context-option-off ()
  "Without the option the remote stays out of the context."
  (gitlab-context-tests--with-repo "git@gitlab.example.com:group/project.git"
    (let ((gitlab-git-context-from-git nil))
      (should-not (gitlab-git-context (car repo))))))

;;; Buffer names

(ert-deftest gitlab-context-detail-buffer-name ()
  "A detail buffer name carries the project and the instance."
  (should (equal "*GitLab MR group/project!12*"
                 (gitlab-merge-request--buffer-name
                  "12" "group/project")))
  (should (equal "*GitLab MR group/project@gitlab.example.com!12*"
                 (gitlab-merge-request--buffer-name
                  "12" "group/project@gitlab.example.com")))
  (should (equal "*GitLab MR !12*"
                 (gitlab-merge-request--buffer-name "12")))
  (should (equal "*GitLab Pipeline group/project#1001*"
                 (gitlab-pipeline--buffer-name
                  "1001" "group/project")))
  (should (equal "*GitLab Pipeline #1001*"
                 (gitlab-pipeline--buffer-name "1001")))
  (should (equal "*GitLab Job group/project@host.example&5001*"
                 (gitlab-pipeline--job-log-buffer-name
                  "5001" "group/project@host.example"))))

(ert-deftest gitlab-context-list-buffer-name ()
  "A list buffer name carries the project and the instance."
  (should (equal "*GitLab Merge Requests group/project*"
                 (gitlab--contextual-name
                  "*GitLab Merge Requests*" "group/project")))
  (should (equal "*GitLab Merge Requests group/project@host.example*"
                 (gitlab--contextual-name
                  "*GitLab Merge Requests*" "group/project@host.example")))
  (should (equal "*GitLab Merge Requests*"
                 (gitlab--contextual-name "*GitLab Merge Requests*" nil))))

;;; Buffer identity

(ert-deftest gitlab-context-two-projects-two-buffers ()
  "Two projects get one list buffer each."
  (gitlab-test-with-environment
   (let ((first (gitlab-context-tests--display-list "group/alpha"))
         (second (gitlab-context-tests--display-list "group/beta")))
     (unwind-protect
         (progn
           (should-not (eq first second))
           (should (equal "*GitLab Merge Requests group/alpha*"
                          (buffer-name first)))
           (should (equal "*GitLab Merge Requests group/beta*"
                          (buffer-name second))))
       (kill-buffer first)
       (kill-buffer second)))))

(ert-deftest gitlab-context-list-buffer-survives-rename ()
  "A renamed list buffer stays the buffer of its project."
  (gitlab-test-with-environment
   (let ((first (gitlab-context-tests--display-list "group/alpha")))
     (unwind-protect
         (progn
           (with-current-buffer first
             (rename-buffer "*my merge requests*" t))
           (should (eq first
                       (gitlab-context-tests--display-list "group/alpha")))
           (should (equal "*my merge requests*" (buffer-name first))))
       (kill-buffer first)))))

(ert-deftest gitlab-context-detail-buffer-survives-rename ()
  "A renamed detail buffer stays the buffer of its merge request."
  (gitlab-test-with-environment
   (let ((first (with-temp-buffer
                  (let ((gitlab-repository "group/alpha"))
                    (gitlab-display-merge-request "12")))))
     (unwind-protect
         (progn
           (with-current-buffer first
             (rename-buffer "*my merge request*" t))
           (let ((second (with-temp-buffer
                           (let ((gitlab-repository "group/alpha"))
                             (gitlab-display-merge-request "12")))))
             (should (eq first second)))
           (should (equal "*my merge request*" (buffer-name first))))
       (kill-buffer first)))))

(ert-deftest gitlab-context-remembers-project ()
  "A display buffer remembers its project for a later prompt."
  (gitlab-test-with-environment
   (let ((buffer (gitlab-context-tests--display-list "group/alpha")))
     (unwind-protect
         (progn
           (should (equal '("group/alpha") gitlab-repositories))
           (gitlab-context-tests--display-list "group/alpha")
           (should (equal '("group/alpha") gitlab-repositories)))
       (kill-buffer buffer)))))

(ert-deftest gitlab-context-list-buffers-directory ()
  "`list-buffers' shows the project and the instance."
  (gitlab-test-with-environment
   (let ((buffer (gitlab-context-tests--display-list "group/project@host.example")))
     (unwind-protect
         (with-current-buffer buffer
           (should (equal "group/project@host.example"
                          list-buffers-directory)))
       (kill-buffer buffer)))))

(ert-deftest gitlab-context-list-buffers-directory-rename ()
  "A rename keeps the identifier in `list-buffers-directory'."
  (gitlab-test-with-environment
   (let ((buffer (with-temp-buffer
                   (let ((gitlab-repository "group/alpha"))
                     (gitlab-display-merge-request "12")))))
     (unwind-protect
         (with-current-buffer buffer
           (should (equal "group/alpha!12" list-buffers-directory))
           (rename-buffer "*my merge request*" t)
           (should (equal "group/alpha!12" list-buffers-directory)))
       (kill-buffer buffer)))))

;;; Repository prompt

(ert-deftest gitlab-context-read-repository ()
  "The prompt offers the session projects and the current one."
  (let ((gitlab-repositories '("group/alpha" "group/beta@host.example"))
        (gitlab-git-context-from-git nil)
        (gitlab-repository "group/gamma")
        seen
        answer)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt collection &rest _arguments)
                 (setq seen collection)
                 "https://gitlab.example.com/group/delta")))
      (setq answer (gitlab-read-repository)))
    (should (member "group/alpha" seen))
    (should (member "group/beta@host.example" seen))
    (should (member "group/gamma" seen))
    (should (equal "group/delta@gitlab.example.com" answer))))

(ert-deftest gitlab-context-list-prompts-without-context ()
  "A list command prompts for the project when none is known."
  (gitlab-test-with-environment
   (let (asked buffer)
     (cl-letf (((symbol-function 'gitlab-read-repository)
                (lambda (&optional _prompt)
                  (setq asked t)
                  "group/alpha")))
       (setq buffer (with-temp-buffer (gitlab-list-merge-requests))))
     (unwind-protect
         (progn
           (should asked)
           (should (equal "*GitLab Merge Requests group/alpha*"
                          (buffer-name buffer))))
       (kill-buffer buffer)))))

(ert-deftest gitlab-context-list-does-not-prompt-with-context ()
  "A list command of a known project asks nothing."
  (gitlab-test-with-environment
   (let ((gitlab-repository "group/alpha")
         asked
         buffer)
     (cl-letf (((symbol-function 'gitlab-read-repository)
                (lambda (&optional _prompt)
                  (setq asked t)
                  "group/beta")))
       (setq buffer (with-temp-buffer (gitlab-list-merge-requests))))
     (unwind-protect
         (progn
           (should-not asked)
           (should (equal "*GitLab Merge Requests group/alpha*"
                          (buffer-name buffer))))
       (kill-buffer buffer)))))

;;; Foreign project

(ert-deftest gitlab-context-foreign-project-hides-commits ()
  "A buffer of another project shows no local commits."
  (gitlab-context-tests--with-repo "git@gitlab.example.com:group/project.git"
    (let ((data (gitlab-context-tests--data (cdr repo)))
          (local (generate-new-buffer "*GitLab MR local context*"))
          (foreign (generate-new-buffer "*GitLab MR foreign context*")))
      (unwind-protect
          (progn
            (with-current-buffer local
              (gitlab-merge-request-mode)
              (setq-local gitlab--id "7")
              (gitlab--use-project-directory (car repo))
              (should gitlab--context-local)
              (gitlab-merge-request--render "7" data)
              (should (string-match-p "\nCommits (1)" (buffer-string))))
            (with-current-buffer foreign
              (gitlab-merge-request-mode)
              (setq-local gitlab--id "7")
              (gitlab--use-project-directory (car repo) "other/project")
              (should-not gitlab--context-local)
              (should (equal "other/project" gitlab--context))
              (gitlab-merge-request--render "7" data)
              (should-not (string-match-p "\nCommits (" (buffer-string)))
              (should-error (gitlab-merge-request-show-changes)
                            :type 'user-error)
              (should-error (gitlab-merge-request-show-log)
                            :type 'user-error)))
        (kill-buffer local)
        (kill-buffer foreign)))))

(provide 'gitlab-context-tests)

;;; gitlab-context-test.el ends here
