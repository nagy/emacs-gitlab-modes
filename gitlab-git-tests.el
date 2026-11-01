;;; gitlab-git-tests.el --- Tests of the local Git support -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Daniel Nagy

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;;; Commentary:

;; Offline tests of the local Git reads.  Each test builds a scratch
;; repository, so no network and no existing checkout are needed.

;;; Code:

(require 'ert)
(require 'gitlab-git)
(require 'gitlab-merge-request)

(defvar gitlab-git-tests--environment
  '("GIT_CONFIG_NOSYSTEM=1"
    "GIT_CONFIG_GLOBAL=/dev/null"
    "GIT_AUTHOR_NAME=Test"
    "GIT_AUTHOR_EMAIL=test@example.com"
    "GIT_COMMITTER_NAME=Test"
    "GIT_COMMITTER_EMAIL=test@example.com")
  "Environment that keeps git away from the user configuration.")

(defun gitlab-git-tests--git (directory &rest arguments)
  "Run git with ARGUMENTS in DIRECTORY and return its output."
  (let ((default-directory directory)
        (process-environment (append gitlab-git-tests--environment
                                     process-environment)))
    (with-temp-buffer
      (unless (eq 0 (apply #'process-file "git" nil t nil arguments))
        (error "git %S failed: %s" arguments (buffer-string)))
      (string-trim (buffer-string)))))

(defun gitlab-git-tests--write (directory name text)
  "Write TEXT to file NAME in DIRECTORY."
  (with-temp-file (expand-file-name name directory)
    (insert text)))

(defun gitlab-git-tests--repo (&optional extra-commits)
  "Return a cons of a scratch repository directory and its base commit.
Add EXTRA-COMMITS commits after the second commit.  The repository
carries a fetched refs/remotes/origin/merge-requests/7/head ref."
  (let ((directory (make-temp-file "gitlab-git-test-" t)))
    (gitlab-git-tests--git directory "init" "-q" "-b" "main")
    (gitlab-git-tests--write directory "file.txt" "one\n")
    (gitlab-git-tests--git directory "add" "file.txt")
    (gitlab-git-tests--git directory "commit" "-q" "-m" "first")
    (let ((base (gitlab-git-tests--git directory "rev-parse" "HEAD")))
      (gitlab-git-tests--write directory "file.txt" "two\n")
      (gitlab-git-tests--git directory "commit" "-q" "-am" "second")
      (dotimes (index (or extra-commits 0))
        (gitlab-git-tests--write directory "file.txt"
                                 (format "extra %d\n" index))
        (gitlab-git-tests--git directory "commit" "-q" "-am"
                               (format "extra %d" index)))
      (let ((head (gitlab-git-tests--git directory "rev-parse" "HEAD")))
        (gitlab-git-tests--git directory "update-ref"
                               "refs/remotes/origin/merge-requests/7/head"
                               head)
        (cons directory base)))))

(defun gitlab-git-tests--data (base)
  "Return merge request data that names BASE as the diff base."
  `((iid . 7)
    (title . "Local commits")
    (source_branch . "feature")
    (target_branch . "main")
    (diff_refs . ((base_sha . ,base)
                  (start_sha . ,base)))))

(defmacro gitlab-git-tests--with-repo (spec &rest body)
  "Run BODY with SPEC bound to a scratch repository.
SPEC receives the cons that `gitlab-git-tests--repo' returns.  The
macro deletes the repository afterwards."
  (declare (indent 1))
  `(let ((,spec (gitlab-git-tests--repo)))
     (unwind-protect
         (progn ,@body)
       (delete-directory (car ,spec) t))))

(ert-deftest gitlab-git-merge-request-head-ref ()
  "The local merge request ref resolves from the remote namespace."
  (skip-unless (executable-find "git"))
  (gitlab-git-tests--with-repo repo
    (with-temp-buffer
      (setq-local gitlab-cli-directory (car repo))
      (should (equal "refs/remotes/origin/merge-requests/7/head"
                     (gitlab-git-merge-request-head-ref "7")))
      (should-not (gitlab-git-merge-request-head-ref "8")))))

(ert-deftest gitlab-git-merge-request-commits ()
  "The commit list holds the commits between the base and the head."
  (skip-unless (executable-find "git"))
  (gitlab-git-tests--with-repo repo
    (with-temp-buffer
      (setq-local gitlab-cli-directory (car repo))
      (let* ((data (gitlab-git-tests--data (cdr repo)))
             (info (gitlab-git-merge-request-commits "7" data))
             (commit (car (plist-get info :commits))))
        (should (equal 1 (plist-get info :total)))
        (should (equal 1 (length (plist-get info :commits))))
        (should (equal "second" (alist-get 'subject commit)))
        (should (equal "Test" (alist-get 'author commit)))
        (should (equal (plist-get info :base) (cdr repo)))
        (should (equal 40 (length (plist-get info :head))))))))

(ert-deftest gitlab-git-merge-request-commits-limit ()
  "The commit list stops at the limit and reports the total."
  (skip-unless (executable-find "git"))
  (let* ((repo (gitlab-git-tests--repo 2))
         (directory (car repo)))
    (unwind-protect
        (with-temp-buffer
          (setq-local gitlab-cli-directory directory)
          (let* ((data (gitlab-git-tests--data (cdr repo)))
                 (info (gitlab-git-merge-request-commits "7" data 2)))
            (should (equal 3 (plist-get info :total)))
            (should (equal 2 (length (plist-get info :commits))))))
      (delete-directory directory t))))

(ert-deftest gitlab-git-merge-request-commits-without-ref ()
  "A merge request without a local ref yields no commit list."
  (skip-unless (executable-find "git"))
  (gitlab-git-tests--with-repo repo
    (with-temp-buffer
      (setq-local gitlab-cli-directory (car repo))
      (let ((data (gitlab-git-tests--data (cdr repo))))
        (should-not (gitlab-git-merge-request-commits "8" data))))))

(ert-deftest gitlab-merge-request-render-commits ()
  "The merge request buffer lists the local commits with a property."
  (skip-unless (executable-find "git"))
  (gitlab-git-tests--with-repo repo
    (with-temp-buffer
      (setq-local gitlab--id "7")
      (setq-local gitlab-cli-directory (car repo))
      (setq-local gitlab-merge-request-show-commits t)
      (gitlab-merge-request--render "7" (gitlab-git-tests--data (cdr repo)))
      (should (string-match-p "Commits (1)" (buffer-string)))
      (should (string-match-p "second" (buffer-string)))
      (goto-char (point-min))
      (should (gitlab--goto-property 'gitlab-commit-sha
                                     (gitlab-git-tests--git
                                      (car repo) "rev-parse" "HEAD")))
      (should (equal "Open the commit"
                     (get-text-property (point) 'help-echo))))))

(ert-deftest gitlab-merge-request-render-commits-off ()
  "The option removes the commit section."
  (skip-unless (executable-find "git"))
  (gitlab-git-tests--with-repo repo
    (with-temp-buffer
      (setq-local gitlab--id "7")
      (setq-local gitlab-cli-directory (car repo))
      (setq-local gitlab-merge-request-show-commits nil)
      (gitlab-merge-request--render "7" (gitlab-git-tests--data (cdr repo)))
      (should-not (string-match-p "Commits (" (buffer-string))))))

(ert-deftest gitlab-git-show-commit-buffer ()
  "The plain commit buffer shows the message and the patch."
  (skip-unless (executable-find "git"))
  (gitlab-git-tests--with-repo repo
    (let ((gitlab-git-use-magit nil)
          (buffer nil))
      (unwind-protect
          (with-temp-buffer
            (setq-local gitlab-cli-directory (car repo))
            (gitlab-git-show-commit
             (gitlab-git-tests--git (car repo) "rev-parse" "HEAD"))
            (setq buffer (current-buffer))
            (should (derived-mode-p 'gitlab-git-commit-mode))
            (should (string-match-p "second" (buffer-string)))
            (should (string-match-p "\\+two" (buffer-string)))
            (should buffer-read-only))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(provide 'gitlab-git-tests)

;;; gitlab-git-tests.el ends here
