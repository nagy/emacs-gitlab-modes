;;; gitlab-git-test.el --- Tests of the local Git support -*- lexical-binding: t; -*-

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

(require 'cl-lib)
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
  "Run git in DIRECTORY with ARGUMENTS and return its output."
  (let ((default-directory directory)
        (process-environment (append gitlab-git-tests--environment
                                     process-environment)))
    (with-temp-buffer
      (unless (eq 0 (apply #'process-file "git" nil t nil arguments))
        (error "Git %S failed: %s" arguments (buffer-string)))
      (string-trim (buffer-string)))))

(defun gitlab-git-tests--write (directory name text)
  "Write into DIRECTORY the file NAME with the contents TEXT."
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

(defmacro gitlab-git-tests--with-repo-commits (spec extra &rest body)
  "Bind SPEC to a scratch repository with EXTRA commits and run BODY.
The macro deletes the repository afterwards."
  (declare (indent 2))
  `(let ((,spec (gitlab-git-tests--repo ,extra)))
     (unwind-protect
         (progn ,@body)
       (delete-directory (car ,spec) t))))

(defmacro gitlab-git-tests--with-repo (spec &rest body)
  "Bind SPEC to the result of `gitlab-git-tests--repo' and run BODY.
The macro deletes the repository afterwards."
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

(ert-deftest gitlab-git-merge-request-commits-without-head ()
  "A merge request whose head commit the checkout lacks yields no commits."
  (skip-unless (executable-find "git"))
  (gitlab-git-tests--with-repo repo
    (with-temp-buffer
      (setq-local gitlab-cli-directory (car repo))
      (let ((data (gitlab-git-tests--data (cdr repo))))
        (should-not (gitlab-git-merge-request-commits "8" data))))))

(ert-deftest gitlab-git-merge-request-head-sha ()
  "The head of the answer wins over a local ref and names the commit."
  (should (equal "aa" (gitlab-git--merge-request-head-sha
                       '((sha . "bb")
                         (diff_refs . ((head_sha . "aa")))))))
  (should (equal "bb" (gitlab-git--merge-request-head-sha
                       '((sha . "bb")))))
  (should-not (gitlab-git--merge-request-head-sha '((iid . 7)))))

(ert-deftest gitlab-git-merge-request-commits-from-answer-head ()
  "The head commit of the answer serves without a merge request ref."
  (skip-unless (executable-find "git"))
  (gitlab-git-tests--with-repo repo
    (with-temp-buffer
      (setq-local gitlab-cli-directory (car repo))
      (let* ((head (gitlab-git-tests--git (car repo) "rev-parse" "HEAD"))
             (data (append (list (cons 'sha head))
                           (gitlab-git-tests--data (cdr repo))))
             (info (gitlab-git-merge-request-commits "8" data)))
        (should (equal head (plist-get info :head)))
        (should (equal 1 (plist-get info :total)))))))

(ert-deftest gitlab-git-merge-request-head-ref-refspec ()
  "The fetch refspec of the repository names the merge request ref.
A user who fetches the refs under another prefix still gets the
local reads."
  (skip-unless (executable-find "git"))
  (gitlab-git-tests--with-repo repo
    (let ((directory (car repo)))
      (gitlab-git-tests--git directory "remote" "add" "origin"
                             "git@gitlab.example.com:group/project.git")
      (gitlab-git-tests--git directory "config" "--add"
                             "remote.origin.fetch"
                             "+refs/merge-requests/*/head:refs/mr/*")
      (gitlab-git-tests--git directory "update-ref" "refs/mr/9"
                             "refs/remotes/origin/merge-requests/7/head")
      (gitlab-git-tests--git directory "update-ref" "-d"
                             "refs/remotes/origin/merge-requests/7/head")
      (with-temp-buffer
        (setq-local gitlab-cli-directory directory)
        (should (equal "refs/mr/9" (gitlab-git-merge-request-head-ref "9")))
        (should (equal "9"
                       (car (assoc "9" (gitlab-git-merge-request-refs)))))
        (should-not (gitlab-git-merge-request-head-ref "7"))))))

(ert-deftest gitlab-git-merge-requests-behind-up-to-date ()
  "A merge request whose target holds its head is not behind."
  (skip-unless (executable-find "git"))
  (gitlab-git-tests--with-repo repo
    (with-temp-buffer
      (setq-local gitlab-cli-directory (car repo))
      (let* ((sha (gitlab-git-tests--git
                   (car repo) "rev-parse"
                   "refs/remotes/origin/merge-requests/7/head"))
             (data (append (gitlab-git-tests--data (cdr repo))
                           (list (cons 'sha sha))))
             (behind (gitlab-git-merge-requests-behind (list data))))
        (should (equal 0 (hash-table-count behind)))))))

(ert-deftest gitlab-git-merge-requests-behind-target-ahead ()
  "A merge request that lacks a commit of the target is behind."
  (skip-unless (executable-find "git"))
  (gitlab-git-tests--with-repo repo
    (let ((directory (car repo))
          (gitlab-cli-directory (car repo))
          (sha nil))
      (setq sha (gitlab-git-tests--git
                 directory "rev-parse"
                 "refs/remotes/origin/merge-requests/7/head"))
      (gitlab-git-tests--write directory "file.txt" "three\n")
      (gitlab-git-tests--git directory "commit" "-q" "-am" "third")
      (let* ((data (append (gitlab-git-tests--data (cdr repo))
                           (list (cons 'sha sha))))
             (behind (gitlab-git-merge-requests-behind (list data))))
        (should (gethash "7" behind))))))

(ert-deftest gitlab-git-merge-requests-behind-answer-head ()
  "The behind check follows the head that the answer names.
A local ref that holds another commit changes nothing, because the
answer carries the newer head."
  (skip-unless (executable-find "git"))
  (gitlab-git-tests--with-repo repo
    (with-temp-buffer
      (setq-local gitlab-cli-directory (car repo))
      (let* ((data (append (gitlab-git-tests--data (cdr repo))
                           (list (cons 'sha (cdr repo)))))
             (behind (gitlab-git-merge-requests-behind (list data))))
        (should (gethash "7" behind))))))

(ert-deftest gitlab-git-merge-requests-behind-without-ref ()
  "A head commit that the checkout holds answers behind without a ref."
  (skip-unless (executable-find "git"))
  (gitlab-git-tests--with-repo repo
    (let ((directory (car repo))
          (gitlab-cli-directory (car repo))
          (sha nil))
      (setq sha (gitlab-git-tests--git
                 directory "rev-parse"
                 "refs/remotes/origin/merge-requests/7/head"))
      (gitlab-git-tests--git directory "update-ref" "-d"
                             "refs/remotes/origin/merge-requests/7/head")
      (gitlab-git-tests--write directory "file.txt" "three\n")
      (gitlab-git-tests--git directory "commit" "-q" "-am" "third")
      (let* ((data (append (list (cons 'iid 8) (cons 'sha sha))
                           (gitlab-git-tests--data (cdr repo))))
             (behind (gitlab-git-merge-requests-behind (list data))))
        (should (gethash "8" behind))))))

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

(ert-deftest gitlab-git-show-commit-uses-magit ()
  "The commit view goes through the commit function of Magit."
  (skip-unless (executable-find "git"))
  (gitlab-git-tests--with-repo repo
    (let ((captured 'none))
      (cl-letf (((symbol-function 'gitlab-git--ensure-magit) #'ignore)
                ((symbol-function 'magit-show-commit)
                 (lambda (rev &optional _args _files _module)
                   (setq captured rev))))
        (with-temp-buffer
          (setq-local gitlab-cli-directory (car repo))
          (gitlab-git-show-commit (cdr repo))))
      (should (equal (cdr repo) captured)))))

(ert-deftest gitlab-git-show-changes-uses-magit-arguments ()
  "The changes view passes the diff arguments of Magit."
  (skip-unless (executable-find "git"))
  (gitlab-git-tests--with-repo repo
    (let ((captured 'none)
          (head (gitlab-git-tests--git
                 (car repo) "rev-parse"
                 "refs/remotes/origin/merge-requests/7/head")))
      (cl-letf (((symbol-function 'gitlab-git--ensure-magit) #'ignore)
                ((symbol-function 'magit-diff-arguments)
                 (lambda (&optional _mode) '(("--stat") "file.txt")))
                ((symbol-function 'magit-diff-range)
                 (lambda (range &optional args files)
                   (setq captured (list range args files)))))
        (with-temp-buffer
          (setq-local gitlab-cli-directory (car repo))
          (gitlab-git-show-changes "7" (gitlab-git-tests--data (cdr repo)))))
      (should (equal (format "%s..%s" (cdr repo) head)
                     (nth 0 captured)))
      (should (equal '("--stat") (nth 1 captured)))
      (should (equal "file.txt" (nth 2 captured))))))

(ert-deftest gitlab-git-show-changes-single-commit ()
  "One selected commit opens its commit view instead of a diff."
  (skip-unless (executable-find "git"))
  (gitlab-git-tests--with-repo-commits repo 2
    (let ((captured 'none))
      (cl-letf (((symbol-function 'gitlab-git--ensure-magit) #'ignore)
                ((symbol-function 'magit-diff-range)
                 (lambda (&rest _) (setq captured 'diff)))
                ((symbol-function 'magit-show-commit)
                 (lambda (rev &optional _args _files _module)
                   (setq captured rev))))
        (with-temp-buffer
          (setq-local gitlab-cli-directory (car repo))
          (let* ((data (gitlab-git-tests--data (cdr repo)))
                 (commits (plist-get
                           (gitlab-git-merge-request-commits "7" data)
                           :commits))
                 (middle (alist-get 'sha (nth 1 commits))))
            (gitlab-git-show-changes "7" data (list middle))
            (should (equal middle captured))))))))

(ert-deftest gitlab-git-show-log-uses-magit-arguments ()
  "The log view passes the log arguments of Magit."
  (skip-unless (executable-find "git"))
  (gitlab-git-tests--with-repo repo
    (let ((captured 'none))
      (cl-letf (((symbol-function 'gitlab-git--ensure-magit) #'ignore)
                ((symbol-function 'magit-log-arguments)
                 (lambda (&optional _mode) '(("--graph") "file.txt")))
                ((symbol-function 'magit-log-other)
                 (lambda (revs &optional args files)
                   (setq captured (list revs args files)))))
        (with-temp-buffer
          (setq-local gitlab-cli-directory (car repo))
          (gitlab-git-show-log "7" (gitlab-git-tests--data (cdr repo)))))
      (should (equal (list (format "%s..%s"
                                   (cdr repo)
                                   (gitlab-git-tests--git
                                    (car repo) "rev-parse"
                                    "refs/remotes/origin/merge-requests/7/head")))
                     (nth 0 captured)))
      (should (equal '("--graph") (nth 1 captured)))
      (should (equal "file.txt" (nth 2 captured))))))

(ert-deftest gitlab-git-views-need-magit ()
  "A Git view without Magit signals a user error."
  (skip-unless (executable-find "git"))
  (gitlab-git-tests--with-repo repo
    (let ((gitlab-git-use-magit nil))
      (with-temp-buffer
        (setq-local gitlab-cli-directory (car repo))
        (should-error (gitlab-git-show-changes
                       "7" (gitlab-git-tests--data (cdr repo)))
                      :type 'user-error)
        (should-error (gitlab-git-show-log
                       "7" (gitlab-git-tests--data (cdr repo)))
                      :type 'user-error)
        (should-error (gitlab-git-show-commit (cdr repo))
                      :type 'user-error)))))

(ert-deftest gitlab-git-views-need-installed-magit ()
  "A Git view signals a user error when Magit is absent."
  (cl-letf (((symbol-function 'require) (lambda (&rest _) nil)))
    (should-error (gitlab-git--ensure-magit) :type 'user-error)))

(ert-deftest gitlab-git-show-changes-without-ref ()
  "A missing local ref signals a user error."
  (skip-unless (executable-find "git"))
  (gitlab-git-tests--with-repo repo
    (with-temp-buffer
      (setq-local gitlab-cli-directory (car repo))
      (should-error
       (gitlab-git-show-changes "8" (gitlab-git-tests--data (cdr repo)))
       :type 'user-error))))

(defun gitlab-git-tests--position (sha)
  "Return the line start of the commit SHA in the current buffer."
  (save-excursion
    (when (gitlab--goto-property 'gitlab-commit-sha sha)
      (point))))

(defun gitlab-git-tests--select-commits (first last)
  "Select the commit lines from FIRST through LAST.
FIRST and LAST are commit hashes in the current merge request
buffer."
  (let ((start (gitlab-git-tests--position first))
        (end (gitlab-git-tests--position last)))
    (goto-char end)
    (forward-line 1)
    (set-mark (point))
    (goto-char start)
    (activate-mark)))

(ert-deftest gitlab-git-commit-selection-range ()
  "The selected commits give the parent of the oldest as their base."
  (skip-unless (executable-find "git"))
  (gitlab-git-tests--with-repo-commits repo 2
    (with-temp-buffer
      (setq-local gitlab-cli-directory (car repo))
      (let* ((data (gitlab-git-tests--data (cdr repo)))
             (info (gitlab-git-merge-request-commits "7" data))
             (commits (plist-get info :commits))
             (newest (alist-get 'sha (nth 0 commits)))
             (middle (alist-get 'sha (nth 1 commits)))
             (oldest (alist-get 'sha (nth 2 commits)))
             (range (gitlab-git-commit-selection-range
                     (list middle oldest))))
        (should (equal middle (car range)))
        (should (equal (cdr repo) (cdr range)))
        (should-not (equal newest (car range)))))))

(ert-deftest gitlab-git-commit-selection-range-root ()
  "A selected root commit uses the empty tree as its base."
  (skip-unless (executable-find "git"))
  (gitlab-git-tests--with-repo repo
    (with-temp-buffer
      (setq-local gitlab-cli-directory (car repo))
      (let* ((root (gitlab-git-tests--git (car repo) "rev-list"
                                          "--max-parents=0" "HEAD"))
             (range (gitlab-git-commit-selection-range (list root))))
        (should (equal root (car range)))
        (should (equal (gitlab-git--empty-tree) (cdr range)))
        (should (equal "1"
                       (gitlab-git-tests--git
                        (car repo) "rev-list" "--count"
                        (format "%s..%s" (cdr range) (car range)))))))))

(ert-deftest gitlab-merge-request-region-commits ()
  "The region helper returns the selected commit lines in order."
  (skip-unless (executable-find "git"))
  (gitlab-git-tests--with-repo-commits repo 2
    (let ((buffer (generate-new-buffer "*GitLab MR region test*")))
      (unwind-protect
          (with-current-buffer buffer
            (gitlab-merge-request-mode)
            (setq-local gitlab--id "7")
            (setq-local gitlab-cli-directory (car repo))
            (setq-local gitlab--last-data (gitlab-git-tests--data (cdr repo)))
            (gitlab-merge-request--render "7" gitlab--last-data)
            (let* ((info (gitlab-git-merge-request-commits
                          "7" gitlab--last-data))
                   (commits (plist-get info :commits))
                   (middle (alist-get 'sha (nth 1 commits)))
                   (oldest (alist-get 'sha (nth 2 commits))))
              (gitlab-git-tests--select-commits middle oldest)
              (should (equal (list middle oldest)
                             (gitlab-merge-request--region-commits)))))
        (kill-buffer buffer)))))

(ert-deftest gitlab-merge-request-show-changes-region ()
  "The changes command passes the selected commits to the Git layer."
  (skip-unless (executable-find "git"))
  (gitlab-git-tests--with-repo-commits repo 2
    (let ((buffer (generate-new-buffer "*GitLab MR changes region test*")))
      (unwind-protect
          (with-current-buffer buffer
            (gitlab-merge-request-mode)
            (setq-local gitlab--id "7")
            (setq-local gitlab-cli-directory (car repo))
            (setq-local gitlab--last-data (gitlab-git-tests--data (cdr repo)))
            (gitlab-merge-request--render "7" gitlab--last-data)
            (let* ((info (gitlab-git-merge-request-commits
                          "7" gitlab--last-data))
                   (commits (plist-get info :commits))
                   (middle (alist-get 'sha (nth 1 commits)))
                   (oldest (alist-get 'sha (nth 2 commits)))
                   (captured 'none))
              (gitlab-git-tests--select-commits middle oldest)
              (cl-letf (((symbol-function 'gitlab-git-show-changes)
                         (lambda (_iid _data &optional commits)
                           (setq captured commits))))
                (gitlab-merge-request-show-changes))
              (should (equal (list middle oldest) captured))))
        (kill-buffer buffer)))))

(ert-deftest gitlab-merge-request-show-log-region ()
  "The log command passes the selected commits to the Git layer."
  (skip-unless (executable-find "git"))
  (gitlab-git-tests--with-repo-commits repo 2
    (let ((buffer (generate-new-buffer "*GitLab MR log region test*")))
      (unwind-protect
          (with-current-buffer buffer
            (gitlab-merge-request-mode)
            (setq-local gitlab--id "7")
            (setq-local gitlab-cli-directory (car repo))
            (setq-local gitlab--last-data (gitlab-git-tests--data (cdr repo)))
            (gitlab-merge-request--render "7" gitlab--last-data)
            (let* ((info (gitlab-git-merge-request-commits
                          "7" gitlab--last-data))
                   (commits (plist-get info :commits))
                   (middle (alist-get 'sha (nth 1 commits)))
                   (oldest (alist-get 'sha (nth 2 commits)))
                   (captured 'none))
              (gitlab-git-tests--select-commits middle oldest)
              (cl-letf (((symbol-function 'gitlab-git-show-log)
                         (lambda (_iid _data &optional commits)
                           (setq captured commits))))
                (gitlab-merge-request-show-log))
              (should (equal (list middle oldest) captured))))
        (kill-buffer buffer)))))

(ert-deftest gitlab-git-show-log-selected-commits ()
  "A selected commit range leaves the other commits out of the log."
  (skip-unless (executable-find "git"))
  (gitlab-git-tests--with-repo-commits repo 2
    (with-temp-buffer
      (setq-local gitlab-cli-directory (car repo))
      (let* ((data (gitlab-git-tests--data (cdr repo)))
             (commits (plist-get (gitlab-git-merge-request-commits
                                  "7" data)
                                 :commits))
             (middle (alist-get 'sha (nth 1 commits)))
             (oldest (alist-get 'sha (nth 2 commits)))
             (range (gitlab-git-commit-selection-range (list middle oldest)))
             (captured 'none))
        (cl-letf (((symbol-function 'gitlab-git--ensure-magit) #'ignore)
                  ((symbol-function 'magit-log-arguments)
                   (lambda (&optional _mode) nil))
                  ((symbol-function 'magit-log-other)
                   (lambda (revs &optional _args _files)
                     (setq captured revs))))
          (gitlab-git-show-log "7" data (list middle oldest)))
        (should (equal (list (format "%s..%s" (cdr range) (car range)))
                       captured))))))

(defun gitlab-git-tests--list-row-data (repo data)
  "Prepare the buffer as the merge request list of REPO and return DATA.
REPO names a checkout that holds the local refs, and DATA holds the
decoded merge request answers."
  (gitlab-merge-request-list-mode)
  (setq-local gitlab-cli-directory (car repo))
  (setq-local gitlab-repository "group/project")
  (setq-local gitlab-list--rows (gitlab-merge-request--rows data))
  data)

(ert-deftest gitlab-merge-request-child-entries-commits ()
  "A merge request row expands into its commits, newest first."
  (skip-unless (executable-find "git"))
  (gitlab-git-tests--with-repo repo
    (with-temp-buffer
      (let* ((directory (car repo))
             (sha (gitlab-git-tests--git
                   directory "rev-parse"
                   "refs/remotes/origin/merge-requests/7/head"))
             (short (gitlab-git-tests--git directory "rev-parse" "--short"
                                          sha))
             (data (gitlab-git-tests--list-row-data
                    repo
                    (list (append (gitlab-git-tests--data (cdr repo))
                                  (list (cons 'sha sha))))))
             (rows (gitlab-merge-request--child-entries "7")))
        (ignore data)
        (should (equal 1 (length rows)))
        (should (equal (cons "7" sha) (car (car rows))))
        (let ((cells (cadr (car rows))))
          (should (equal 7 (length cells)))
          (should (equal (concat "   " short)
                         (substring-no-properties (aref cells 0))))
          (should (eq 'gitlab-hash (get-text-property 3 'face (aref cells 0))))
          (should (equal "second" (aref cells 1)))
          (should (equal "" (aref cells 2)))
          (should (equal "Test" (substring-no-properties (aref cells 3))))
          (should (equal "" (aref cells 4)))
          (should (equal "" (aref cells 5)))
          (should (eq 'gitlab-date (get-text-property 0 'face (aref cells 6)))))))))

(ert-deftest gitlab-merge-request-child-entries-note-rows ()
  "A row without a local ref, and a row of another project, answer a note."
  (skip-unless (executable-find "git"))
  (gitlab-git-tests--with-repo repo
    (with-temp-buffer
      (gitlab-git-tests--list-row-data
       repo (list (gitlab-git-tests--data (cdr repo))))
      (let ((cells (cadr (car (gitlab-merge-request--child-entries "8")))))
        (should (equal "   No local commit."
                       (substring-no-properties (aref cells 0)))))
      (setq-local gitlab--context "other/project")
      (setq-local gitlab--context-local nil)
      (let ((cells (cadr (car (gitlab-merge-request--child-entries "7")))))
        (should (equal "   No local commit."
                       (substring-no-properties (aref cells 0))))))))

(ert-deftest gitlab-merge-request-child-entries-answer-head ()
  "A head commit that the checkout holds lists commits without a ref."
  (skip-unless (executable-find "git"))
  (gitlab-git-tests--with-repo repo
    (with-temp-buffer
      (let* ((directory (car repo))
             (sha (gitlab-git-tests--git
                   directory "rev-parse"
                   "refs/remotes/origin/merge-requests/7/head")))
        (gitlab-git-tests--list-row-data
         repo
         (list (append (list (cons 'iid 8) (cons 'sha sha))
                       (gitlab-git-tests--data (cdr repo)))))
        (let ((rows (gitlab-merge-request--child-entries "8")))
          (should (equal 1 (length rows)))
          (should (equal (cons "8" sha) (car (car rows)))))))))

(ert-deftest gitlab-merge-request-child-entries-missing-head ()
  "A head commit that the checkout lacks answers a note that names it."
  (skip-unless (executable-find "git"))
  (gitlab-git-tests--with-repo repo
    (with-temp-buffer
      (let ((sha "6666666666666666666666666666666666666666"))
        (gitlab-git-tests--list-row-data
         repo
         (list (append (list (cons 'iid 8) (cons 'sha sha))
                       (gitlab-git-tests--data (cdr repo)))))
        (let ((cells (cadr (car (gitlab-merge-request--child-entries "8")))))
          (should (equal "   Commit 6666666 not found locally."
                         (substring-no-properties (aref cells 0)))))))))

(ert-deftest gitlab-merge-request-child-entries-group ()
  "A group list indents the IID cell and keeps the Project column empty."
  (skip-unless (executable-find "git"))
  (gitlab-git-tests--with-repo repo
    (with-temp-buffer
      (gitlab-git-tests--list-row-data
       repo (list (gitlab-git-tests--data (cdr repo))))
      (setq-local gitlab--scope 'group)
      (setq-local gitlab--context "group")
      (let ((cells (cadr (car (gitlab-merge-request--child-entries "8")))))
        (should (equal 8 (length cells)))
        (should (equal "" (aref cells 0)))
        (should (equal "   No local commit."
                       (substring-no-properties (aref cells 1))))))))

(ert-deftest gitlab-merge-request-commit-row-data ()
  "A commit row answers its web URL to `thing-at-point'."
  (skip-unless (executable-find "git"))
  (gitlab-git-tests--with-repo repo
    (with-temp-buffer
      (let* ((directory (car repo))
             (sha (gitlab-git-tests--git
                   directory "rev-parse"
                   "refs/remotes/origin/merge-requests/7/head")))
        (gitlab-git-tests--list-row-data
         repo
         (list (append (gitlab-git-tests--data (cdr repo))
                       (list (cons 'sha sha)))))
        (gitlab-merge-request--child-entries "7")
        (should (equal (format "https://gitlab.com/group/project/-/commit/%s"
                               sha)
                       (gitlab-data-field
                        "web_url"
                        (gitlab-merge-request--row-data (cons "7" sha)))))
        (should (equal sha (gitlab-merge-request--row-id-string
                            (cons "7" sha))))
        (should-not (gitlab-merge-request--row-data "7"))))))

(ert-deftest gitlab-merge-request-open-row ()
  "RET opens the commit of a commit row and the request of a request row."
  (let ((opened nil))
    (cl-letf (((symbol-function 'gitlab-git-show-commit)
               (lambda (sha) (setq opened (cons 'commit sha))))
              ((symbol-function 'gitlab-display-merge-request)
               (lambda (id) (setq opened (cons 'request id)))))
      (gitlab-merge-request--open-row (cons "7" "abc"))
      (should (equal '(commit . "abc") opened))
      (gitlab-merge-request--open-row "7")
      (should (equal '(request . "7") opened))
      (gitlab-merge-request--open-row (cons 'note "7"))
      (should (equal '(request . "7") opened)))))

(ert-deftest gitlab-merge-request-list-expands-commits ()
  "The list prints the commit rows of an expanded merge request."
  (skip-unless (executable-find "git"))
  (gitlab-git-tests--with-repo repo
    (with-temp-buffer
      (let* ((directory (car repo))
             (sha (gitlab-git-tests--git
                   directory "rev-parse"
                   "refs/remotes/origin/merge-requests/7/head"))
             (data (list (append (gitlab-git-tests--data (cdr repo))
                                 (list (cons 'sha sha))))))
        (gitlab-merge-request-list-mode)
        (setq-local gitlab-cli-directory directory)
        (setq-local gitlab-repository "group/project")
        (gitlab-list--set-expanded "7" t)
        (gitlab-list--render nil data)
        (should (string-match-p "Local commits" (buffer-string)))
        (should (string-match-p "second" (buffer-string)))
        (goto-char (point-min))
        (forward-line 1)
        (should (equal (cons "7" sha) (tabulated-list-get-id)))
        ;; A region over the rendered commit row answers that commit.
        (set-mark (point-min))
        (goto-char (point-max))
        (activate-mark)
        (should (member (cons "7" sha)
                        (gitlab-merge-request--region-rows)))
        (deactivate-mark)))))

(provide 'gitlab-git-tests)

;;; gitlab-git-test.el ends here
