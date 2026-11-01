;;; gitlab-merge-request.el --- Merge request views -*- lexical-binding: t; -*-

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

;; Merge request views.  `gitlab-merge-request-mode' displays one merge
;; request per buffer.  `gitlab-merge-request-list-mode' displays the
;; collection.  Both refresh themselves through the base modes of
;; gitlab-mode.el.
;;
;; The detail buffer renders every field of `glab mr view --output
;; json' as a field table.  Nested objects become one readable line:
;; a user yields Name (@username), a milestone yields its title and a
;; pipeline yields #ID status with a link to the pipeline buffer.
;;
;; Notes are separate.  The first render shows only the merge request
;; fields, so an automatic refresh stays cheap.  The command
;; `gitlab-merge-request-show-notes' fetches the notes endpoint once and
;; renders the notes below the fields.  A later refresh keeps them.
;;
;; The list columns are IID, Title, State, Author, Branches, Labels and
;; Updated.  The row identity is the IID, so an update keeps point on
;; the same merge request.

;;; Code:

(require 'subr-x)
(require 'gitlab-data)
(require 'gitlab-git)
(require 'gitlab-mode)

(declare-function gitlab-read-merge-request-iid "gitlab-read" (&optional prompt))

(defcustom gitlab-merge-request-list-buffer-name "*GitLab Merge Requests*"
  "Buffer name of the merge request list."
  :type 'string
  :group 'gitlab)

(defcustom gitlab-merge-request-show-commits t
  "Whether a merge request buffer lists the local commits.
The list needs a fetched merge request ref, for example through
this fetch refspec:

  +refs/merge-requests/*/head:refs/remotes/origin/merge-requests/*

A project without the ref shows no commit section."
  :type 'boolean
  :group 'gitlab)

(defcustom gitlab-merge-request-list-arguments nil
  "Extra glab arguments for the merge request list.
The value is a list of strings, for example (\"--all\").  A
prefix argument on `gitlab-list-merge-requests' adds --all for
that invocation only."
  :type '(repeat string)
  :group 'gitlab)

(defvar-local gitlab-merge-request--notes nil
  "Decoded notes of the merge request in the current buffer.")

(defvar-local gitlab-merge-request--notes-loaded nil
  "Non-nil when the notes of the current buffer were fetched.")

;;; List

(defvar gitlab-merge-request-list-format
  [("IID" 7 gitlab-list--number-sort)
   ("Title" 42 t)
   ("State" 10 t)
   ("Author" 20 t)
   ("Branches" 32 t)
   ("Labels" 18 t)
   ("Updated" 20 t)]
  "Table format of the merge request list.")

(defun gitlab-merge-request--rows (data)
  "Return an alist of merge request ID to row for DATA."
  (mapcar (lambda (merge-request)
            (cons (gitlab-data-id-string
                   (gitlab-data-field "iid" merge-request))
                  merge-request))
          data))

(defun gitlab-merge-request--entries (data)
  "Return `tabulated-list-entries' for merge request DATA."
  (mapcar
   (lambda (merge-request)
     (let* ((iid (gitlab-data-field "iid" merge-request))
            (id (gitlab-data-id-string iid))
            (title (gitlab-data-field-string "title" merge-request))
            (state (gitlab-data-field-string "state" merge-request))
            (author (gitlab--format-value
                     (gitlab-data-field "author" merge-request)))
            (source (gitlab-data-field-string "source_branch" merge-request))
            (target (gitlab-data-field-string "target_branch" merge-request))
            (labels (gitlab--format-value
                     (gitlab-data-field "labels" merge-request)))
            (updated (gitlab-list--date-cell
                      (gitlab-data-field "updated_at" merge-request))))
       (list id
             (vector
              (gitlab-list--id-cell (format "!%s" id)
                                    'gitlab-merge-request-iid)
              title
              (propertize state 'face (or (gitlab--status-face state)
                                          'default))
              author
              (format "%s -> %s" source target)
              labels
              updated))))
   data))

(defun gitlab-merge-request--fetch-list (success error)
  "Fetch the merge request list for the current list buffer.
Call SUCCESS with the decoded array or ERROR with a condition."
  (gitlab-merge-request-list-async success error gitlab-list--arguments))

(define-derived-mode gitlab-merge-request-list-mode gitlab-list-mode
  "GitLab Merge Requests"
  "Display the merge requests of the current project.
The table columns are IID, Title, State, Author, Branches, Labels
and Updated.  RET opens the merge request at point; c copies its
IID and w opens its web page."
  :group 'gitlab
  (setq-local tabulated-list-format gitlab-merge-request-list-format)
  (setq-local tabulated-list-sort-key '("Updated" . t))
  (setq-local gitlab-list--kind 'merge-request)
  (setq-local gitlab-list--fetch-function #'gitlab-merge-request--fetch-list)
  (setq-local gitlab-list--entries-function #'gitlab-merge-request--entries)
  (setq-local gitlab-list--rows-function #'gitlab-merge-request--rows)
  (setq-local gitlab-list--open-function #'gitlab-display-merge-request))

;;;###autoload
(defun gitlab-list-merge-requests (&optional all)
  "Display the merge requests of the current project.
With prefix argument ALL, include closed and merged requests by
adding --all to the glab arguments."
  (interactive "P")
  (let ((arguments (if all
                       (cons "--all" gitlab-merge-request-list-arguments)
                     gitlab-merge-request-list-arguments)))
    (gitlab-list--show
     gitlab-merge-request-list-buffer-name
     #'gitlab-merge-request-list-mode
     (lambda ()
       (setq-local gitlab-list--arguments arguments)))))

;;; Detail

(defun gitlab-merge-request--fetch (iid success error)
  "Fetch merge request IID for the current detail buffer.
Call SUCCESS with the decoded answer, or ERROR with a condition."
  (gitlab-merge-request-show-async iid success error))

(defun gitlab-merge-request--render (iid data)
  "Render merge request IID with DATA in the current buffer."
  (let ((title (gitlab-data-field-string "title" data)))
    (gitlab--render-fields
     (format "!%s %s" iid (if (string-empty-p title)
                              "(no title)"
                            title))
     data))
  (gitlab-merge-request--insert-commits data)
  (gitlab-merge-request--insert-notes))

(defun gitlab-merge-request--insert-commits (data)
  "Insert the local commits of DATA below the merge request fields.
Every line carries `gitlab-commit-sha', so RET opens the commit.
The function inserts nothing without a local merge request ref."
  (when gitlab-merge-request-show-commits
    (when-let* ((info (gitlab-git-merge-request-commits gitlab--id data)))
      (let ((inhibit-read-only t)
            (commits (plist-get info :commits))
            (total (plist-get info :total)))
        (goto-char (point-max))
        (insert "\n"
                (propertize (format "Commits (%d)" total)
                            'face 'gitlab-title)
                "\n\n")
        (if (null commits)
            (insert "No commits.\n")
          (dolist (commit commits)
            (insert
             (propertize
              (format "%s %s  (%s, %s)\n"
                      (alist-get 'short commit)
                      (alist-get 'subject commit)
                      (alist-get 'author commit)
                      (gitlab--format-date (alist-get 'date commit)))
              'gitlab-commit-sha (alist-get 'sha commit)
              'mouse-face 'highlight
              'help-echo "Open the commit"))))
        (when (< (length commits) total)
          (insert (format "\n%d more commits.\n"
                          (- total (length commits)))))))))

(defun gitlab-merge-request--insert-notes ()
  "Insert the fetched notes below the merge request fields."
  (when gitlab-merge-request--notes-loaded
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (insert "\n" (propertize "Notes" 'face 'gitlab-title) "\n\n")
      (if (null gitlab-merge-request--notes)
          (insert "No notes.\n")
        (dolist (note gitlab-merge-request--notes)
          (let ((author (gitlab--format-value
                         (gitlab-data-field "author" note)))
                (created (gitlab--format-date
                          (gitlab-data-field "created_at" note)))
                (body (gitlab-data-field-string "body" note))
                (system (gitlab-data-field "system" note)))
            (insert (propertize
                     (format "%s  %s%s\n" author created
                             (if system "  (system)" ""))
                     'face 'gitlab-field-name))
            (insert (if (string-empty-p body) "(no text)" body)
                    "\n\n")))))))

(defun gitlab-merge-request--notes-done (buffer notes)
  "Store the notes in BUFFER and render the merge request again.
NOTES is the decoded notes array."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq gitlab-merge-request--notes notes
            gitlab-merge-request--notes-loaded t)
      (gitlab--force-render))))

;;;###autoload
(defun gitlab-merge-request-show-notes ()
  "Fetch and display the notes of the current merge request.
The notes load once per call; an automatic refresh re-renders the
stored notes without another request."
  (interactive)
  (unless (derived-mode-p 'gitlab-merge-request-mode)
    (user-error "This is not a merge request buffer"))
  (let ((buffer (current-buffer))
        (iid gitlab--id))
    (gitlab-merge-request-notes-async
     iid
     (lambda (notes)
       (gitlab-merge-request--notes-done buffer notes))
     (lambda (error)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (gitlab--set-error error)))))))

(define-derived-mode gitlab-merge-request-mode gitlab-detail-mode
  "GitLab Merge Request"
  "Display one GitLab merge request.
Every top-level field of the glab JSON answer appears in a field
table.  A local merge request ref adds the commit list below the
fields, when `gitlab-merge-request-show-commits' is non-nil.
d shows the local changes and l the local commit log, and an
active region over commit lines limits both to those commits.
`gitlab-merge-request-show-notes' loads the notes below the fields.
RET opens the pipeline, the commit or the web page at point."
  :group 'gitlab
  (setq-local gitlab--kind 'merge-request)
  (setq-local gitlab--label "GitLab merge request")
  (setq-local gitlab--fetch-function #'gitlab-merge-request--fetch)
  (setq-local gitlab--render-function #'gitlab-merge-request--render)
  (setq-local gitlab-merge-request--notes nil)
  (setq-local gitlab-merge-request--notes-loaded nil))

(defun gitlab-merge-request--region-commits ()
  "Return the commit hashes on the lines of the active region.
The hashes come back in display order, newest first.  A line
without the `gitlab-commit-sha' property contributes nothing.
Return nil without an active region or without a commit line."
  (when (use-region-p)
    (save-excursion
      (let ((end (region-end))
            (commits nil))
        (goto-char (region-beginning))
        (beginning-of-line)
        (while (< (point) end)
          (when-let* ((sha (get-text-property (point) 'gitlab-commit-sha)))
            (push sha commits))
          (forward-line 1))
        (nreverse commits)))))

(defun gitlab-merge-request-show-changes ()
  "Show the local changes of the current merge request.
The view needs a fetched merge request ref.  With an active region
over commit lines, the view covers only those commits.  Magit, when
available, supplies the diff buffer and its Ediff command on E."
  (interactive)
  (unless (derived-mode-p 'gitlab-merge-request-mode)
    (user-error "This is not a merge request buffer"))
  (gitlab-git-show-changes gitlab--id gitlab--last-data
                           (gitlab-merge-request--region-commits)))

(defun gitlab-merge-request-show-log ()
  "Show the local commit log of the current merge request.
The log holds only the commits of the merge request.  With an
active region over commit lines, the log covers only those
commits.  Magit, when available, supplies the log buffer and its
Ediff commands."
  (interactive)
  (unless (derived-mode-p 'gitlab-merge-request-mode)
    (user-error "This is not a merge request buffer"))
  (gitlab-git-show-log gitlab--id gitlab--last-data
                       (gitlab-merge-request--region-commits)))

(define-key gitlab-merge-request-mode-map (kbd "n")
  #'gitlab-merge-request-show-notes)
(define-key gitlab-merge-request-mode-map (kbd "d")
  #'gitlab-merge-request-show-changes)
(define-key gitlab-merge-request-mode-map (kbd "l")
  #'gitlab-merge-request-show-log)

(defun gitlab-merge-request--buffer-name (iid)
  "Return the detail buffer name for merge request IID."
  (if gitlab-repository
      (format "*GitLab MR %s!%s*" gitlab-repository iid)
    (format "*GitLab MR !%s*" iid)))

;;;###autoload
(defun gitlab-display-merge-request (iid)
  "Display the merge request with IID in its own buffer.
IID is the project-scoped number, with or without a leading !."
  (interactive (list (gitlab-read-merge-request-iid)))
  (let ((iid (gitlab-data-id-string iid)))
    (when (string-prefix-p "!" iid)
      (setq iid (substring iid 1)))
    (gitlab--show-detail (gitlab-merge-request--buffer-name iid)
                         #'gitlab-merge-request-mode
                         iid)))

(provide 'gitlab-merge-request)

;;; gitlab-merge-request.el ends here
