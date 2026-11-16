;;; gitlab-git.el --- Local Git support for GitLab modes -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Daniel Nagy

;; Author: Daniel Nagy
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
;; Keywords: tools, convenience
;; URL: https://github.com/nagy/emacs-gitlab-modes

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

;; Local Git reads for the merge request views.  The file fetches
;; nothing from the network.  It reads the merge request refs that the
;; user already fetched, so a project with this fetch refspec gets the
;; richer view:
;;
;;   fetch = +refs/merge-requests/*/head:refs/remotes/origin/merge-requests/*
;;
;; `gitlab-git-merge-request-commits' returns the commits between the
;; merge base and the local head ref.  `gitlab-git-show-commit' opens
;; one commit.  Both prefer Magit when it is available and fall back to
;; a plain `diff-mode' buffer.
;;
;; The layer never runs a command that writes to the repository.  A
;; missing ref, a missing object or a command failure returns nil, so a
;; display buffer shows no section instead of a signal.
;;
;; The file also reads the project context of a checkout, the project
;; path and its instance host, from the URL of
;; `gitlab-git-preferred-remote'.  The display layer names its buffers
;; by that context, so two projects and two instances never share one
;; buffer.  `gitlab-git-remote-context' reads only the remote, and
;; `gitlab-git-context' lets a set `gitlab-repository' win over it.

;;; Code:

(require 'seq)
(require 'subr-x)
(require 'gitlab-cli)
(require 'gitlab-data)

(declare-function magit-diff-range "magit-diff" (rev-or-range &optional args files))
(declare-function magit-get-all "magit-git" (&rest keys))
(declare-function magit-list-remotes "magit-git" ())
(declare-function magit-log-other "magit-log" (revs &optional args files))
(declare-function magit-rev-ancestor-p "magit-git" (rev1 rev2))
(declare-function magit-show-commit "magit-diff" (rev &optional args files module))

(defcustom gitlab-git-program "git"
  "Program name of the Git command line."
  :type 'string
  :group 'gitlab)

(defcustom gitlab-git-use-magit t
  "Non-nil if the GitLab views use Magit when it is available.
A nil value keeps every view in the plain `diff-mode' buffers of
this package.  The package never requires Magit at load time."
  :type 'boolean
  :group 'gitlab)

(defcustom gitlab-git-commit-limit 50
  "Maximum number of local commits that a merge request view lists.
A larger number keeps a very long merge request inside one buffer."
  :type 'integer
  :group 'gitlab)

(defcustom gitlab-git-preferred-remote "origin"
  "Remote whose URL names the project of a checkout.
The display layer reads this URL to name its buffers by project and
instance.  A repository without this remote uses its first remote
instead."
  :type 'string
  :group 'gitlab)

(defcustom gitlab-git-context-from-git t
  "Non-nil if a display buffer takes its project from the Git remote.
A project whose `gitlab-repository' is nil then reads the URL of
`gitlab-git-preferred-remote', so two projects and two instances
never share one buffer.  A nil value leaves the buffer name
without a project, and glab infers the project from the directory,
as an earlier version did."
  :type 'boolean
  :group 'gitlab)

;;; Running Git

(defun gitlab-git--run (arguments &optional directory)
  "Run git with ARGUMENTS and return its standard output.
The command runs in DIRECTORY, or in `gitlab-cli-directory-of'.
Return nil when git exits with a non-zero status, so a missing ref
never signals."
  (let ((default-directory (or directory (gitlab-cli-directory-of)))
        (coding-system-for-read 'utf-8-unix)
        (coding-system-for-write 'utf-8-unix)
        (process-environment (cons "GIT_OPTIONAL_LOCKS=0"
                                   process-environment)))
    (when (file-directory-p default-directory)
      (with-temp-buffer
        (when (eq 0 (apply #'process-file gitlab-git-program nil t nil
                           arguments))
          (buffer-string))))))

(defun gitlab-git--lines (arguments &optional directory)
  "Run git with ARGUMENTS and return its output as a list of lines.
The command runs in DIRECTORY, or in `gitlab-cli-directory-of'."
  (when-let* ((output (gitlab-git--run arguments directory)))
    (split-string output "\n" t)))

(defun gitlab-git--rev (revision)
  "Return the commit that REVISION names, or nil."
  (when-let* ((output (gitlab-git--run
                       (list "rev-parse" "--verify" "--quiet"
                             (concat revision "^{commit}")))))
    (string-trim output)))

(defun gitlab-git--iid (iid)
  "Return IID as a string of digits.
Signal a user error for anything else, because the number becomes
part of a ref name and of a git argument."
  (let ((text (gitlab-data-id-string iid)))
    (unless (string-match-p "\\`[0-9]+\\'" text)
      (user-error "Invalid merge request IID: %s" iid))
    text))

;;; Remotes and project context

(defun gitlab-git--magit-p ()
  "Return non-nil when Magit supplies the repository reads.
The function asks only a Magit that the user already loaded with
`gitlab-git-use-magit' left on, because a display command reads one
Git config value and must not load the whole Magit library for it.
A plain `git' call gives the same answer, so the fallback costs
nothing but one process."
  (declare (side-effect-free t))
  (and gitlab-git-use-magit
       (featurep 'magit)
       (fboundp 'magit-get-all)))

(defun gitlab-git-remotes (&optional directory)
  "Return the names of the Git remotes of DIRECTORY."
  (let ((directory (file-name-as-directory
                    (or directory (gitlab-cli-directory-of)))))
    (if (gitlab-git--magit-p)
        (let ((default-directory directory))
          (ignore-errors (magit-list-remotes)))
      (gitlab-git--lines (list "remote") directory))))

(defun gitlab-git-remote-url (remote &optional directory)
  "Return the first URL of REMOTE in DIRECTORY, or nil."
  (let ((directory (file-name-as-directory
                    (or directory (gitlab-cli-directory-of)))))
    (when (member remote (gitlab-git-remotes directory))
      (car
       (if (gitlab-git--magit-p)
           (let ((default-directory directory))
             (ignore-errors (magit-get-all "remote" remote "url")))
         (gitlab-git--lines
          (list "config" "--get-all" (format "remote.%s.url" remote))
          directory))))))

(defun gitlab-git--remote-url-p (url)
  "Return non-nil when URL names a remote server, not a local path."
  (declare (pure t) (side-effect-free t))
  (and (stringp url)
       (not (string-prefix-p "file://" url))
       (or (string-match-p "\\`[[:alpha:]][[:alnum:]+.-]*://" url)
           (string-match-p "\\`[^/]+:" url))))

(defun gitlab-git--remote (&optional directory)
  "Return the name of the remote that names the project of DIRECTORY.
`gitlab-git-preferred-remote' wins, and the first remote answers
when the preferred one is absent."
  (let ((names (gitlab-git-remotes directory)))
    (if (member gitlab-git-preferred-remote names)
        gitlab-git-preferred-remote
      (car names))))

(defun gitlab-git-remote-context (&optional directory)
  "Return the project context of the checkout of DIRECTORY.
The value comes from the URL of `gitlab-git-preferred-remote', or
from the first remote when the preferred one is absent.  It uses
the PATH or PATH@HOST spelling of
`gitlab-cli-repository-normalize'.  Return nil outside a Git
repository, without a remote, and for a remote that names a local
path."
  (let* ((directory (or directory (gitlab-cli-directory-of)))
         (remote (gitlab-git--remote directory))
         (url (and remote (gitlab-git-remote-url remote directory))))
    (when (gitlab-git--remote-url-p url)
      (gitlab-cli-repository-normalize url))))

(defun gitlab-git-context (&optional directory)
  "Return the project context of DIRECTORY, or nil.
A set `gitlab-repository' names the project and wins over the Git
remote, which the function reads only with
`gitlab-git-context-from-git'.  The value uses the PATH or PATH@HOST
spelling, so buffer names, bookmarks and Org links agree."
  (or (gitlab-cli-repository-normalize gitlab-repository)
      (and gitlab-git-context-from-git
           (gitlab-git-remote-context directory))))

;;; Merge request refs

(defun gitlab-git--fetch-refspecs (remote &optional directory)
  "Return the fetch refspecs of REMOTE in DIRECTORY."
  (let ((directory (file-name-as-directory
                    (or directory (gitlab-cli-directory-of)))))
    (when (member remote (gitlab-git-remotes directory))
      (if (gitlab-git--magit-p)
          (let ((default-directory directory))
            (ignore-errors (magit-get-all "remote" remote "fetch")))
        (gitlab-git--lines
         (list "config" "--get-all" (format "remote.%s.fetch" remote))
         directory)))))

(defun gitlab-git--merge-request-refspec (refspec)
  "Return the destination pattern of a merge request REFSPEC, or nil.
The value is a cons of the text before the `*' of the destination
and the text after it, so a caller names one merge request ref
from an IID.  A refspec that fetches something else answers nil."
  (when (string-match "\\`\\+?\\([^:]+\\):\\(.+\\)\\'" refspec)
    (let* ((source (match-string 1 refspec))
           (destination (match-string 2 refspec))
           (index (string-search "*" destination)))
      (when (and index (string-prefix-p "refs/merge-requests/" source))
        (cons (substring destination 0 index)
              (substring destination (1+ index)))))))

(defun gitlab-git--merge-request-ref-matchers (pairs)
  "Return the regexps that name a merge request ref.
PAIRS holds the destination patterns of
`gitlab-git--merge-request-refspec'.  The last regexp accepts the
standard spellings of the GitLab documentation, so a repository
without the fetch refspec still finds a ref that the user fetched
by hand."
  (append (mapcar (lambda (pair)
                    (concat "\\`" (regexp-quote (car pair))
                            "\\([0-9]+\\)"
                            (regexp-quote (cdr pair)) "\\'"))
                  pairs)
          '("/merge-requests/\\([0-9]+\\)/head\\'")))

(defun gitlab-git--merge-request-ref-iid (ref matchers)
  "Return the merge request IID that REF names, or nil.
MATCHERS holds the regexps of
`gitlab-git--merge-request-ref-matchers'."
  (seq-some (lambda (matcher)
              (when (string-match matcher ref)
                (match-string 1 ref)))
            matchers))

(defun gitlab-git-merge-request-refs (&optional directory)
  "Return an alist of merge request IID to a cons of ref name and commit.
The function reads the destination of every merge request refspec
of the remote of DIRECTORY, so a repository that fetches the refs
under any prefix answers, and it also reads the standard
refs/remotes/REMOTE/merge-requests/IID/head and
refs/merge-requests/IID/head spellings.  Return nil outside a Git
repository.  When two refs name the same IID, the first ref in name
order answers."
  (let* ((remote (gitlab-git--remote directory))
         (pairs (delq nil (mapcar #'gitlab-git--merge-request-refspec
                                  (and remote
                                       (gitlab-git--fetch-refspecs
                                        remote directory)))))
         (matchers (gitlab-git--merge-request-ref-matchers pairs))
         (patterns (append (mapcar (lambda (pair)
                                     (concat (car pair) "*" (cdr pair)))
                                   pairs)
                           '("refs/remotes" "refs/merge-requests")))
         (result nil))
    (dolist (line (gitlab-git--lines
                   (append (list "for-each-ref"
                                 "--format=%(refname)%00%(objectname)")
                           patterns)
                   directory))
      (pcase-let ((`(,ref ,commit) (split-string line "\0")))
        (when-let* ((iid (gitlab-git--merge-request-ref-iid ref matchers))
                    ((not (assoc iid result))))
          (push (cons iid (cons ref commit)) result))))
    (nreverse result)))

(defun gitlab-git-merge-request-head-ref (iid)
  "Return the local head ref of merge request IID, or nil.
Accept a remote-tracking ref such as
refs/remotes/origin/merge-requests/12/head, a direct ref such as
refs/merge-requests/12/head, and the destination of the fetch
refspec of the repository."
  (car (cdr (assoc-string (gitlab-git--iid iid)
                          (gitlab-git-merge-request-refs)))))

(defun gitlab-git--ancestor-p (ancestor descendant)
  "Return non-nil when commit ANCESTOR is an ancestor of DESCENDANT.
The function prefers Magit when the user already loaded it, because
`magit-rev-ancestor-p' runs the same command."
  (if (gitlab-git--magit-p)
      (let ((default-directory (file-name-as-directory
                                (gitlab-cli-directory-of))))
        (ignore-errors (magit-rev-ancestor-p ancestor descendant)))
    (and (gitlab-git--run (list "merge-base" "--is-ancestor"
                                ancestor descendant))
         t)))

(defun gitlab-git--holding-refs (commit &optional directory)
  "Return a hash of the ref names that hold COMMIT.
The function reads the repository of DIRECTORY.  Return nil when git
cannot answer, so a caller falls back to one ancestry check per
ref."
  (let ((output (gitlab-git--run
                 (list "for-each-ref" "--format=%(refname)"
                       (format "--contains=%s" commit))
                 directory)))
    (when output
      (let ((table (make-hash-table :test #'equal)))
        (dolist (ref (split-string output "\n" t))
          (puthash ref t table))
        table))))

(defun gitlab-git--target-tip (target remote)
  "Return the commit of branch TARGET on REMOTE, or nil.
The remote-tracking branch wins over a local branch of the same
name, because a local branch of the user answers no fetch."
  (or (and remote
           (not (string-empty-p target))
           (gitlab-git--rev (format "%s/%s" remote target)))
      (gitlab-git--rev target)))

(defun gitlab-git-merge-requests-behind (requests &optional directory)
  "Return a hash of the merge request IIDs that sit behind their target.
REQUESTS is a list of decoded merge request answers, and the
function reads the refs of DIRECTORY.  A request
counts when its local merge request ref holds the `sha' field of the
answer, so a stale ref never answers about another head.  A request
without that ref, without a `sha' field, and with a `target_branch'
that no local ref names gets no entry either.  The target branch
counts as its remote-tracking branch, then as the branch of the same
name."
  (let* ((refs (gitlab-git-merge-request-refs directory))
         (remote (gitlab-git--remote directory))
         (holdings (make-hash-table :test #'equal))
         (behind (make-hash-table :test #'equal)))
    (dolist (request requests)
      (let* ((iid (gitlab-data-id-string
                   (gitlab-data-field "iid" request)))
             (entry (cdr (assoc iid refs)))
             (head (cdr entry))
             (sha (gitlab-data-field-string "sha" request))
             (target (gitlab-data-field-string "target_branch" request)))
        (when (and entry
                   (not (string-empty-p sha))
                   (equal sha head)
                   (not (string-empty-p target)))
          (when-let* ((tip (gitlab-git--target-tip target remote)))
            (let ((holding (or (gethash tip holdings)
                               (puthash tip
                                        (gitlab-git--holding-refs
                                         tip directory)
                                        holdings))))
              (if holding
                  (unless (gethash (car entry) holding)
                    (puthash iid t behind))
                (unless (gitlab-git--ancestor-p tip head)
                  (puthash iid t behind))))))))
    behind))

(defun gitlab-git--diff-refs-sha (data key)
  "Return the commit that DATA gives for KEY, or nil.
KEY names a field of the nested diff_refs object."
  (let* ((refs (gitlab-data-field "diff_refs" data))
         (sha (and refs (gitlab-data-field key refs))))
    (and (stringp sha)
         (not (string-empty-p sha))
         (gitlab-git--rev sha))))

(defun gitlab-git--merge-base (head target)
  "Return the merge base of HEAD and TARGET, or nil."
  (when-let* ((output (gitlab-git--run (list "merge-base" head target))))
    (string-trim output)))

(defun gitlab-git--parent (commit)
  "Return the parent of COMMIT, or nil for a root commit."
  (when-let* ((output (gitlab-git--run
                       (list "rev-parse" "--verify" "--quiet"
                             (concat commit "^")))))
    (string-trim output)))

(defun gitlab-git--empty-tree ()
  "Return the empty tree of the repository object format."
  (when-let* ((output (gitlab-git--run
                       (list "hash-object" "-t" "tree" "/dev/null"))))
    (string-trim output)))

(defun gitlab-git-commit-selection-range (commits)
  "Return the commit range of the selected COMMITS.
COMMITS holds the commit hashes in display order, newest first.
The range runs from the parent of the oldest commit to the newest
commit, so it names exactly the selected span.  A root commit uses
the empty tree as its base.  Return nil without COMMITS or when a
selected commit is absent."
  (when commits
    (let ((head (gitlab-git--rev (car commits)))
          (oldest (gitlab-git--rev (car (last commits)))))
      (when (and head oldest)
        (cons head (or (gitlab-git--parent oldest)
                       (gitlab-git--empty-tree)))))))

(defun gitlab-git-merge-request-range (iid data)
  "Return the local commit range of merge request IID in DATA.
The value is a cons of the head commit and the base commit, or nil
when the local ref or the base object is absent."
  (when-let* ((ref (gitlab-git-merge-request-head-ref iid))
              (head (gitlab-git--rev ref)))
    (let ((base (or (gitlab-git--diff-refs-sha data "base_sha")
                    (gitlab-git--diff-refs-sha data "start_sha")
                    (when-let* ((target
                                 (gitlab-data-field-string
                                  "target_branch" data)))
                      (unless (string-empty-p target)
                        (gitlab-git--merge-base head target))))))
      (when base
        (cons head base)))))

;;; Commits

(defun gitlab-git--commit-entry (line)
  "Return the commit record that LINE describes, or nil.
LINE holds the five NUL separated fields that
`gitlab-git-merge-request-commits' asks git to print."
  (pcase-let ((`(,sha ,short ,author ,date ,subject)
               (split-string line "\0")))
    (when (and sha short)
      (list (cons 'sha sha)
            (cons 'short short)
            (cons 'author author)
            (cons 'date date)
            (cons 'subject subject)))))

(defun gitlab-git-merge-request-commits (iid data &optional limit)
  "Return the local commits of merge request IID in DATA.
LIMIT caps the number of commits and defaults to
`gitlab-git-commit-limit'.  The value is a plist with
:head, :base, :total and :commits.  Return nil when the local ref
or the base object is absent."
  (when-let* ((range (gitlab-git-merge-request-range iid data))
              (head (car range))
              (base (cdr range)))
    (let* ((limit (or limit gitlab-git-commit-limit))
           (revision (format "%s..%s" base head))
           (total (gitlab-git--run (list "rev-list" "--count" revision)))
           (format "%H%x00%h%x00%an%x00%aI%x00%s")
           (commits (gitlab-git--lines
                     (list "log"
                           (format "--max-count=%d" limit)
                           (format "--format=%s" format)
                           revision))))
      (list :head head
            :base base
            :total (if total (string-to-number (string-trim total)) 0)
            :commits (delq nil (mapcar #'gitlab-git--commit-entry
                                       commits))))))

;;; Patch buffers

(define-derived-mode gitlab-git-patch-mode diff-mode "GitLab Patch"
  "Display a read-only Git patch in `diff-mode'.
The buffer keeps the hunk commands of `diff-mode'.  It never loads a
file."
  :group 'gitlab
  :interactive nil
  (setq-local buffer-read-only t)
  (setq-local buffer-stale-function nil)
  (setq-local truncate-lines t))

(define-key gitlab-git-patch-mode-map (kbd "q") #'quit-window)

(define-derived-mode gitlab-git-commit-mode gitlab-git-patch-mode
  "GitLab Commit"
  "Display one Git commit in a read-only `diff-mode' buffer.
The buffer shows the commit message and the patch that the commit
introduced."
  :group 'gitlab
  :interactive nil)

(define-key gitlab-git-commit-mode-map (kbd "q") #'quit-window)

(defun gitlab-git--show-commit-buffer (sha)
  "Display SHA in a plain `diff-mode' buffer.
The command returns the buffer."
  (let* ((directory (gitlab-cli-directory-of))
         (buffer (get-buffer-create
                  (format "*GitLab Commit %s*" (substring sha 0 7))))
         (text (gitlab-git--run
                (list "show" "--no-color" "--stat" "--patch" sha))))
    (with-current-buffer buffer
      (setq-local default-directory directory)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (or text "")))
      (gitlab-git-commit-mode)
      (set-buffer-modified-p nil)
      (goto-char (point-min)))
    (pop-to-buffer buffer)))

(defun gitlab-git-show-commit (sha)
  "Display commit SHA in its own buffer.
Use Magit when `gitlab-git-use-magit' is non-nil and Magit is
available.  Signal a user error when SHA names no local commit."
  (interactive
   (list (or (get-text-property (point) 'gitlab-commit-sha)
             (read-string "Commit: "))))
  (let ((revision (gitlab-git--rev sha)))
    (unless revision
      (user-error "Unknown commit: %s" sha))
    (if (and gitlab-git-use-magit (require 'magit nil t))
        (gitlab-git--magit-call #'magit-show-commit revision)
      (gitlab-git--show-commit-buffer revision))))

;;; Changes and log

(defun gitlab-git--magit-call (function &rest arguments)
  "Call FUNCTION with ARGUMENTS in the directory of the current buffer."
  (let ((default-directory (gitlab-cli-directory-of)))
    (apply function arguments)))

(defun gitlab-git--patch-buffer (name text mode)
  "Display buffer NAME with TEXT and MODE, and return the buffer.
The buffer starts read-only and stays out of auto-revert."
  (let* ((directory (gitlab-cli-directory-of))
         (buffer (get-buffer-create name)))
    (with-current-buffer buffer
      (setq-local default-directory directory)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert text))
      (funcall mode)
      (set-buffer-modified-p nil)
      (goto-char (point-min)))
    (pop-to-buffer buffer)))

(defun gitlab-git--merge-request-revision (iid data &optional commits)
  "Return the local revision range of merge request IID in DATA.
COMMITS, when non-nil, limits the range to the selected commits.
Return nil when the local ref or the base object is absent."
  (when-let* ((range (or (gitlab-git-commit-selection-range commits)
                         (gitlab-git-merge-request-range iid data))))
    (format "%s..%s" (cdr range) (car range))))

(defun gitlab-git--show-patch-buffer (name arguments mode)
  "Return buffer NAME with the answer of git ARGUMENTS.
MODE is the major mode of the buffer."
  (gitlab-git--patch-buffer
   name
   (or (gitlab-git--run arguments) "No changes.\n")
   mode))

(defun gitlab-git-show-changes (iid data &optional commits)
  "Show the local changes of merge request IID in DATA.
The view covers the merge base to the fetched head.  COMMITS, when
non-nil, limits the view to the selected commits.  Use Magit and
its whole-tree diff when `gitlab-git-use-magit' is non-nil and
Magit is available, and a plain `diff-mode' buffer otherwise.
Signal a user error when no local ref or base exists."
  (let ((revision (or (gitlab-git--merge-request-revision iid data commits)
                      (user-error
                       "No local merge request ref for !%s" iid))))
    (if (and gitlab-git-use-magit (require 'magit nil t))
        (gitlab-git--magit-call #'magit-diff-range revision)
      (gitlab-git--show-patch-buffer
       (format "*GitLab MR %s Changes*" iid)
       (list "diff" "--no-color" "--stat" "--patch" revision)
       #'gitlab-git-patch-mode))))

(defun gitlab-git-show-log (iid data &optional commits)
  "Show the local commit log of merge request IID in DATA.
The log holds only the commits of the merge request.  COMMITS, when
non-nil, limits the log to the selected commits.  Use Magit's log
buffer when `gitlab-git-use-magit' is non-nil and Magit is
available, and a plain `diff-mode' buffer otherwise.  Signal a user
error when no local ref or base exists."
  (let ((revision (or (gitlab-git--merge-request-revision iid data commits)
                      (user-error
                       "No local merge request ref for !%s" iid))))
    (if (and gitlab-git-use-magit (require 'magit nil t))
        (gitlab-git--magit-call #'magit-log-other (list revision))
      (gitlab-git--show-patch-buffer
       (format "*GitLab MR %s Log*" iid)
       (list "log" "--no-color" "--decorate" "--stat" "--patch"
             revision)
       #'gitlab-git-patch-mode))))

(provide 'gitlab-git)

;;; gitlab-git.el ends here
