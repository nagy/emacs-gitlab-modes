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
;; The command `gitlab-approve-merge-request' approves the merge
;; request on behalf of the user, and the command
;; `gitlab-merge-merge-request' merges it.
;;
;; The list columns are IID, Title, State, Author, Branches, Labels and
;; Updated.  The row identity is the IID, so an update keeps point on
;; the same merge request.

;;; Code:

(require 'seq)
(require 'subr-x)
(require 'gitlab-data)
(require 'gitlab-git)
(require 'gitlab-mode)
(require 'gitlab-read)

(defcustom gitlab-merge-request-list-buffer-name "*GitLab Merge Requests*"
  "Buffer name of the merge request list.
The display layer inserts the project context before the closing
star, so the list of each project and of each instance has its own
buffer, for example \"*GitLab Merge Requests group/project*\".  The
buffer lookup reads the buffer-local identity and not the name, so
a renamed buffer stays reachable."
  :type 'string
  :group 'gitlab)

(defcustom gitlab-merge-request-show-commits t
  "Non-nil if a merge request buffer lists the local commits.
The list needs a fetched merge request ref, for example through
this fetch refspec:

  +refs/merge-requests/*/head:refs/remotes/origin/merge-requests/*

A project without the ref shows no commit section."
  :type 'boolean
  :group 'gitlab)

(defcustom gitlab-merge-request-sections-hook
  '(gitlab-insert-title
    gitlab-insert-fields
    gitlab-merge-request-insert-commits
    gitlab-merge-request-insert-notes)
  "Functions that insert the sections of a merge request buffer.
`gitlab-detail-mode' runs the entries in order through
`magit-run-section-hook'.  Remove an entry to drop a section, or
move an entry to change the order of the sections.

An entry takes no arguments and inserts through
`magit-insert-section'.  It reads the decoded answer of the buffer
from `gitlab--buffer-data'."
  :type '(repeat function)
  :group 'gitlab)

(defcustom gitlab-merge-request-show-behind t
  "Non-nil if the list marks a merge request that sits behind its target.
The check reads the local merge request refs and compares them
with the target branch, so it needs the fetch refspec that the
GitLab documentation names:

  +refs/merge-requests/*/head:refs/remotes/origin/merge-requests/*

The package reads the destination of the refspec, so any prefix
works.  A row whose local ref does not hold the head commit of the
answer stays unmarked, because a stale ref would answer about
another head.  A merge request behind its target cannot merge with
a fast-forward merge, and it merges cleanly with a merge commit."
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
  "Non-nil if the notes of the current buffer were fetched.")

;;; List

(defvar gitlab-merge-request-list-format
  [("IID" 7 gitlab-list--number-sort :right-align t)
   ("Title" 42 t)
   ("State" 10 t)
   ("Author" 20 t)
   ("Branches" 32 t)
   ("Labels" 18 t)
   ("Updated" 20 t)]
  "Table format of the merge request list.
A list buffer fits every width to its rows, so these numbers apply
only with `gitlab-list-fit-columns' nil.  A numeric column aligns
its cells to the right, as a printed table does.")

(defvar gitlab-merge-request-group-list-format
  [("Project" 28 t)
   ("IID" 7 gitlab-list--number-sort :right-align t)
   ("Title" 40 t)
   ("State" 10 t)
   ("Author" 20 t)
   ("Branches" 30 t)
   ("Labels" 16 t)
   ("Updated" 20 t)]
  "Table format of the merge request list of a group.
The Project column comes first, because one group holds the merge
requests of many projects.  A project list keeps
`gitlab-merge-request-list-format' and shows no such column.")

(defun gitlab-merge-request--group-p ()
  "Return non-nil when the current list buffer shows a group."
  (declare (side-effect-free t))
  (eq gitlab--scope 'group))

(defun gitlab-merge-request--row-context (merge-request)
  "Return the project context of MERGE-REQUEST, or nil.
The `web_url' field names the project of the row, so a group list
never reads the project from the buffer."
  (when-let* ((url (gitlab-data-field "web_url" merge-request)))
    (nth 2 (gitlab--url-object url))))

(defun gitlab-merge-request--row-id (merge-request)
  "Return the row ID of MERGE-REQUEST in the current list.
A project list keeps the bare IID.  A group list writes the full
identifier, so two projects that both hold !12 stay apart."
  (let ((iid (gitlab-data-id-string
              (gitlab-data-field "iid" merge-request))))
    (if (gitlab-merge-request--group-p)
        (gitlab-data-identifier
         'merge-request iid (gitlab-merge-request--row-context merge-request))
      iid)))

(defconst gitlab-merge-request-conflict-marker "⚠"
  "Marker that the State cell of a conflicted merge request shows.
The marker follows the state text, so the column grows by the
width of the marker only while the table holds a conflicted row.")

(defconst gitlab-merge-request-behind-marker "↓"
  "Marker that the State cell of a merge request behind its target shows.
The marker follows the conflict marker, so a row that holds both
reads \"opened ⚠ ↓\".")

(defvar-local gitlab-merge-request--behind nil
  "Hash of the rows whose place behind the target branch is known.
The key is a cons of the row ID and the `sha' field, and the value
is the answer.  The key holds the head commit, so a refreshed
answer with a new head commits again, and an unchanged table reads
no Git ref twice.")

(defun gitlab-merge-request--behind-key (merge-request)
  "Return the cache key of MERGE-REQUEST."
  (declare (side-effect-free t))
  (cons (gitlab-merge-request--row-id merge-request)
        (gitlab-data-field-string "sha" merge-request)))

(defun gitlab-merge-request--behind-table ()
  "Return the behind cache of the current buffer."
  (or gitlab-merge-request--behind
      (setq-local gitlab-merge-request--behind
                  (make-hash-table :test #'equal))))

(defun gitlab-merge-request--behind-state (merge-request)
  "Return non-nil when MERGE-REQUEST is known to sit behind its target."
  (eq t (gethash (gitlab-merge-request--behind-key merge-request)
                 (gitlab-merge-request--behind-table))))

(defun gitlab-merge-request--check-behind (data)
  "Fill the behind cache of the current buffer from DATA.
The check reads the local merge request refs once and answers every
row that the cache does not hold yet, so an unchanged table runs no
Git command on a later render.  It stays away from a buffer of
another project, and from a row that is no longer open."
  (when (and gitlab-merge-request-show-behind
             (gitlab--local-checkout-p))
    (let ((table (gitlab-merge-request--behind-table)))
      (when (> (hash-table-count table) 2048)
        (setq table (setq-local gitlab-merge-request--behind
                                (make-hash-table :test #'equal))))
      (let ((pending (seq-filter
                      (lambda (merge-request)
                        (and (equal "opened"
                                    (gitlab-data-field-string
                                     "state" merge-request))
                             (not (gethash
                                   (gitlab-merge-request--behind-key
                                    merge-request)
                                   table))))
                      data)))
        (when pending
          (let ((answer (gitlab-git-merge-requests-behind pending)))
            (dolist (merge-request pending)
              (puthash (gitlab-merge-request--behind-key merge-request)
                       (and (gethash (gitlab-data-id-string
                                      (gitlab-data-field "iid"
                                                         merge-request))
                                     answer)
                            t)
                       table))))))))

(defun gitlab-merge-request--marker (glyph face)
  "Return GLYPH as a State cell marker that carries FACE."
  (declare (pure t) (side-effect-free t))
  (concat " " (propertize glyph 'face face)))

(defun gitlab-merge-request--state-cell (merge-request)
  "Return the State cell of MERGE-REQUEST.
A merge request with a merge conflict carries
`gitlab-merge-request-conflict-marker' behind its state text, and a
merge request that sits behind its target branch carries
`gitlab-merge-request-behind-marker' behind that."
  (let ((state (gitlab-data-field-string "state" merge-request)))
    (concat (propertize state 'face (or (gitlab--status-face state)
                                        'default))
            (when (gitlab--conflict-p merge-request)
              (gitlab-merge-request--marker
               gitlab-merge-request-conflict-marker 'gitlab-conflict))
            (when (gitlab-merge-request--behind-state merge-request)
              (gitlab-merge-request--marker
               gitlab-merge-request-behind-marker 'gitlab-behind)))))

(defun gitlab-merge-request--rows (data)
  "Return an alist of merge request row ID to row for DATA."
  (mapcar (lambda (merge-request)
            (cons (gitlab-merge-request--row-id merge-request) merge-request))
          data))

(defun gitlab-merge-request--entries (data)
  "Return `tabulated-list-entries' for merge request DATA.
A group list puts the project of the row in the leftmost cell, and
the IID cell keeps the full identifier as its navigation target."
  (let ((group-p (gitlab-merge-request--group-p)))
    (gitlab-merge-request--check-behind data)
    (mapcar
     (lambda (merge-request)
       (let* ((iid (gitlab-data-field "iid" merge-request))
              (id (gitlab-merge-request--row-id merge-request))
              (title (let ((title (gitlab-data-field-string
                                  "title" merge-request)))
                       (if (gitlab--draft-p merge-request)
                           (propertize title 'face 'gitlab-draft)
                         title)))
              (state (gitlab-merge-request--state-cell merge-request))
              (author (gitlab--format-author
                       (gitlab-data-field "author" merge-request)))
              (source (gitlab--format-branch
                       (gitlab-data-field "source_branch" merge-request)))
              (target (gitlab--format-branch
                       (gitlab-data-field "target_branch" merge-request)))
              (labels (gitlab--format-value
                       (gitlab-data-field "labels" merge-request)))
              (updated (gitlab-list--date-cell
                        (gitlab-data-field "updated_at" merge-request))))
         (list id
               (vconcat
                (when group-p
                  (vector (or (gitlab-merge-request--row-context merge-request)
                              "-")))
                (vector
                 (gitlab-list--id-cell (format "!%s"
                                               (gitlab-data-id-string iid))
                                       'gitlab-merge-request-iid id)
                 title
                 state
                 author
                 (format "%s -> %s" source target)
                 labels
                 updated)))))
     data)))

(defun gitlab-merge-request--fetch-list (success error)
  "Fetch the merge request list for the current list buffer.
Call SUCCESS with the decoded array or ERROR with a condition."
  (gitlab-merge-request-list-async
   success error gitlab-list--arguments
   (and gitlab--scope (cons gitlab--scope gitlab--context))))

;;; Expanded commit rows

(defvar-local gitlab-merge-request--commits nil
  "Hash of the commit answer of the expanded list rows.
The key is a cons of the row ID and the head commit of the answer,
so a refreshed head reads Git again and an unchanged table reads
nothing.")

(defun gitlab-merge-request--commit-table ()
  "Return the commit cache of the current buffer."
  (or gitlab-merge-request--commits
      (setq-local gitlab-merge-request--commits
                  (make-hash-table :test #'equal))))

(defun gitlab-merge-request--row-data-at (id)
  "Return the decoded merge request data of the list row ID."
  (alist-get id gitlab-list--rows nil nil #'equal))

(defun gitlab-merge-request--commit-answer (id)
  "Return the commit answer of the merge request list row ID.
The value is a plist with `:kind' and, for the `commits' kind, the
`:info' plist of `gitlab-git-merge-request-commits'.  KIND is
`commits', `foreign' for a row of another project or of a group,
`none' for a row without a local ref, and `stale' for a local ref
that holds an older head than the answer names."
  (let* ((row (gitlab-merge-request--row-data-at id))
         (sha (and row (gitlab-data-field-string "sha" row)))
         (key (cons id sha))
         (table (gitlab-merge-request--commit-table)))
    (or (gethash key table)
        (puthash key (gitlab-merge-request--commit-answer-compute row sha)
                 table))))

(defun gitlab-merge-request--commit-answer-compute (row sha)
  "Return the commit answer of the merge request ROW at head SHA."
  (if (or (null row) (not (gitlab--local-checkout-p)))
      (list :kind (if row 'foreign 'none))
    (let* ((iid (gitlab-data-id-string (gitlab-data-field "iid" row)))
           (entry (cdr (assoc iid (gitlab-git-merge-request-refs))))
           (info (and entry
                      (equal sha (cdr entry))
                      (gitlab-git-merge-request-commits iid row))))
      (cond
       ((null entry) (list :kind 'none))
       ((not (equal sha (cdr entry))) (list :kind 'stale))
       (info (list :kind 'commits :info info))
       (t (list :kind 'none))))))

(defun gitlab-merge-request--commit-record (id sha)
  "Return the commit record of ID at the commit SHA."
  (when-let* ((info (plist-get (gitlab-merge-request--commit-answer id) :info)))
    (seq-find (lambda (commit)
                (equal sha (alist-get 'sha commit)))
              (plist-get info :commits))))

(defun gitlab-merge-request--row-data (id)
  "Return the decoded data of the child row ID.
A commit row answers its commit record, with the `web_url' of the
commit page, so `w' and `thing-at-point' reach the commit.  A
parent row answers nil, so the collection alist serves it."
  (when (and (consp id) (stringp (car id)))
    (when-let* ((record (gitlab-merge-request--commit-record (car id)
                                                             (cdr id))))
      (append record
              (list (cons 'web_url (gitlab-web-url 'commit (cdr id))))))))

(defun gitlab-merge-request--row-id-string (id)
  "Return the plain ID string of a merge request list row ID.
A commit row names the full commit, and a note row names the merge
request that holds it."
  (if (consp id)
      (format "%s" (cdr id))
    (gitlab-data-id-string id)))

(defun gitlab-merge-request--open-row (id)
  "Open the merge request list row ID.
A parent row opens its detail buffer, a commit row opens the
commit, and a note row opens the merge request that it belongs
to."
  (cond
   ((not (consp id)) (gitlab-display-merge-request id))
   ((stringp (car id)) (gitlab-git-show-commit (cdr id)))
   (t (gitlab-display-merge-request (cdr id)))))

(defun gitlab-merge-request--indent ()
  "Return the indentation of a child row of the merge request list."
  (declare (pure t) (side-effect-free t))
  (make-string (max gitlab-list-expand-indent 0) ?\s))

(defun gitlab-merge-request--id-index ()
  "Return the column index of the IID cell of the current list."
  (declare (side-effect-free t))
  (if (gitlab-merge-request--group-p) 1 0))

(defun gitlab-merge-request--child-cells ()
  "Return the empty cells of a child row of the current list."
  (declare (side-effect-free t))
  (make-vector (if (gitlab-merge-request--group-p) 8 7) ""))

(defun gitlab-merge-request--note-entry (id text)
  "Return a child row of the merge request list row ID that reads TEXT.
The row reports why a merge request shows no commit, so it takes no
command of its own."
  (let ((cells (gitlab-merge-request--child-cells)))
    (aset cells (gitlab-merge-request--id-index)
          (concat (gitlab-merge-request--indent)
                  (propertize text 'face 'gitlab-date)))
    (list (cons 'note id) cells)))

(defun gitlab-merge-request--commit-entry (id commit)
  "Return the table entry of ID for the commit COMMIT.
The IID cell holds the short hash, and the Title, Author and
Updated cells hold the subject, the author and the author date."
  (let* ((sha (alist-get 'sha commit))
         (short (alist-get 'short commit))
         (cells (gitlab-merge-request--child-cells))
         (index (gitlab-merge-request--id-index)))
    (aset cells index
          (gitlab--nav-string
           (concat (gitlab-merge-request--indent)
                   (propertize short 'face 'gitlab-id))
           'gitlab-commit-sha sha
           (format "Commit %s" short)))
    (aset cells (1+ index) (or (alist-get 'subject commit) ""))
    (aset cells (+ 3 index)
          (gitlab--format-author (alist-get 'author commit)))
    (aset cells (+ 6 index)
          (gitlab-list--date-cell (alist-get 'date commit)))
    (list (cons id sha) cells)))

(defun gitlab-merge-request--child-entries (id)
  "Return the commit rows of the merge request list row ID.
A row of another project, a row without a local ref and a row
whose local ref holds an older head answer one note row.  The
commit rows come newest first, as a log does, and
`gitlab-git-commit-limit' caps them."
  (let* ((answer (gitlab-merge-request--commit-answer id))
         (info (plist-get answer :info))
         (commits (plist-get info :commits))
         (total (plist-get info :total)))
    (pcase (plist-get answer :kind)
      ('foreign (list (gitlab-merge-request--note-entry id "No local ref.")))
      ('none (list (gitlab-merge-request--note-entry id "No local ref.")))
      ('stale (list (gitlab-merge-request--note-entry
                     id "The local ref is outdated.  Fetch again.")))
      (_
       (if (null commits)
           (list (gitlab-merge-request--note-entry id "No commits."))
         (append (mapcar (lambda (commit)
                           (gitlab-merge-request--commit-entry id commit))
                         commits)
                 (when (< (length commits) total)
                   (list (gitlab-merge-request--note-entry
                          id (format "%d more commits."
                                     (- total (length commits))))))))))))

(define-derived-mode gitlab-merge-request-list-mode gitlab-list-mode
  "GitLab Merge Requests"
  "Display the merge requests of the current project or of a group.
The table columns are IID, Title, State, Author, Branches, Labels
and Updated, and a group list puts the Project column first.  RET
opens the merge request at point; c copies its identifier and w
opens its web page.  TAB expands a row into its local commits: the
short hash, the subject, the author and the author date."
  :group 'gitlab
  :interactive nil
  (setq-local tabulated-list-format
              (if (gitlab-merge-request--group-p)
                  gitlab-merge-request-group-list-format
                gitlab-merge-request-list-format))
  (setq-local tabulated-list-sort-key '("Updated" . t))
  (setq-local gitlab-list--kind 'merge-request)
  (setq-local gitlab-list--fetch-function #'gitlab-merge-request--fetch-list)
  (setq-local gitlab-list--entries-function #'gitlab-merge-request--entries)
  (setq-local gitlab-list--rows-function #'gitlab-merge-request--rows)
  (setq-local gitlab-list--open-function #'gitlab-merge-request--open-row)
  (setq-local gitlab-list--child-function
              #'gitlab-merge-request--child-entries)
  (setq-local gitlab-list--row-id-function
              #'gitlab-merge-request--row-id-string)
  (setq-local gitlab-list--row-data-function
              #'gitlab-merge-request--row-data))

;;;###autoload
(defun gitlab-list-merge-requests (&optional all)
  "Display the merge requests of the current project.
With prefix argument ALL, include closed and merged requests by
adding --all to the glab arguments.  A directory without a project
context prompts for the project, because neither a Git remote nor
`gitlab-repository' names one."
  (interactive "P")
  (let ((repository (unless (gitlab-git-context)
                      (gitlab-read-repository)))
        (arguments (if all
                       (cons "--all" gitlab-merge-request-list-arguments)
                     gitlab-merge-request-list-arguments)))
    (let ((gitlab-repository (or repository gitlab-repository)))
      (gitlab-list--show
       gitlab-merge-request-list-buffer-name
       #'gitlab-merge-request-list-mode
       (lambda ()
         (setq-local gitlab-list--arguments arguments))))))

;;;###autoload
(defun gitlab-list-group-merge-requests (&optional all)
  "Display the merge requests of a group.
The command reads a group context and asks glab for the merge
requests of that group, so one buffer holds the merge requests of
many projects.  A Project column comes first, because a row alone
names no project.  With prefix argument ALL, include closed and
merged requests by adding --all to the glab arguments."
  (interactive "P")
  (let ((group (gitlab-read-group
                nil (and (eq gitlab--scope 'group) gitlab--context)))
        (arguments (if all
                       (cons "--all" gitlab-merge-request-list-arguments)
                     gitlab-merge-request-list-arguments)))
    (gitlab-list--show
     gitlab-merge-request-list-buffer-name
     #'gitlab-merge-request-list-mode
     (lambda ()
       (setq-local gitlab-list--arguments arguments))
     (cons 'group group))))

;;; Detail

(defun gitlab-merge-request--fetch (iid success error)
  "Fetch merge request IID for the current detail buffer.
Call SUCCESS with the decoded answer, or ERROR with a condition."
  (gitlab-merge-request-show-async iid success error))

(defun gitlab-merge-request--title (id data)
  "Return the title line of merge request ID with DATA.
ID is the object ID and DATA the decoded answer."
  (declare (side-effect-free t))
  (let ((title (gitlab-data-field-string "title" data)))
    (format "!%s %s" (gitlab-data-id-string id)
            (if (string-empty-p title) "(no title)" title))))

(defun gitlab-merge-request--render (iid data)
  "Render merge request IID with DATA in the current buffer.
The function serves a caller that already holds the answer, so the
Git views and their tests render without a fetch.  `iid' is unused,
because the title reads the buffer-local `gitlab--id'."
  (ignore iid)
  (let ((gitlab--last-data data)
        (gitlab--sections-hook 'gitlab-merge-request-sections-hook))
    (gitlab--render-sections 'merge-request)
    (let ((magit-section-cache-visibility nil))
      (magit-section-show magit-root-section))))

(defun gitlab-merge-request-insert-commits ()
  "Insert the local commits of the merge request as a group section.
Every commit is a child section, so a render keeps the place of the
reader on a commit.  Every line carries `gitlab-commit-sha', so RET
opens the commit.  Every line is also one text button, so the mouse
face covers the line without joining the lines above and below.
The function inserts nothing without a local merge request ref, and
nothing for a buffer whose project is not the local checkout,
because a ref of another project would be wrong."
  (when (and gitlab-merge-request-show-commits
             (gitlab--local-checkout-p))
    (when-let* ((info (gitlab-git-merge-request-commits
                       gitlab--id gitlab--buffer-data)))
      (let ((commits (plist-get info :commits))
            (total (plist-get info :total)))
        (insert "\n")
        (magit-insert-section (gitlab-group "Commits")
          (gitlab--insert-group-heading (format "Commits (%d)" total))
          (if (null commits)
              (insert "No commits.\n")
            (dolist (commit commits)
              (magit-insert-section (gitlab-commit (alist-get 'sha commit))
                (let ((start (point)))
                  (insert
                   (format "%s %s  (%s, %s)"
                           (propertize (alist-get 'short commit)
                                       'face 'gitlab-id)
                           (alist-get 'subject commit)
                           (gitlab--format-author (alist-get 'author commit))
                           (gitlab--format-date (alist-get 'date commit))))
                  (add-text-properties
                   start (point)
                   (list 'gitlab-commit-sha (alist-get 'sha commit)))
                  (gitlab--buttonize start (point) "Open the commit")
                  (insert "\n")))))
          (when (< (length commits) total)
            (insert (format "\n%d more commits.\n"
                            (- total (length commits))))))))))

(defun gitlab-merge-request--note-heading (note)
  "Return the heading line of NOTE with its author and its date."
  (let ((created (gitlab--format-date (gitlab-data-field "created_at" note)))
        (system (gitlab-data-field "system" note)))
    (concat (gitlab--format-author (gitlab-data-field "author" note))
            "  "
            (propertize (format "%s%s" created (if system "  (system)" ""))
                        'face 'gitlab-field-name))))

(defun gitlab-merge-request-insert-notes ()
  "Insert the fetched notes as a group section.
Every note is a child section with its author line as the heading,
so TAB folds the text of one note and a render keeps the place of
the reader inside it.  The section of a note keys on the note ID,
and on the position of the note when the answer carries no ID."
  (when gitlab-merge-request--notes-loaded
    (let ((notes gitlab-merge-request--notes)
          (index 0))
      (insert "\n")
      (magit-insert-section (gitlab-group "Notes")
        (gitlab--insert-group-heading "Notes")
        (if (null notes)
            (insert "No notes.\n")
          (dolist (note notes)
            (setq index (1+ index))
            (magit-insert-section
                (gitlab-note (or (gitlab-data-field "id" note) index))
              (magit-insert-heading
               (gitlab-merge-request--note-heading note))
              (let ((body (gitlab-data-field-string "body" note)))
                (insert (if (string-empty-p body) "(no text)" body)
                        "\n\n")))))))))

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
  (interactive nil gitlab-merge-request-mode)
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

(defun gitlab-merge-request--approve-done (buffer iid context)
  "Report in BUFFER that the user approved merge request IID in CONTEXT.
Fetch BUFFER again, so the new approval state shows."
  (message "Approved %s"
           (gitlab-data-identifier 'merge-request iid context))
  (gitlab--refresh-after-write buffer))

;;;###autoload
(defun gitlab-approve-merge-request ()
  "Approve the merge request at point on behalf of the current user.
Point names the merge request through its text property, its
display buffer or its web URL, so the command works in a merge
request buffer, on a list row and on a link in any buffer.  A
target outside a merge request buffer asks for confirmation first.
The request runs in the background, so the buffer never blocks.  The
answer of the approve request holds no merge request field, so the
command fetches the merge request again and the buffer shows the
new approval state.  A failing request shows its condition in the
header line of a GitLab buffer and in the echo area elsewhere."
  (interactive)
  (let ((object (gitlab--object-at-point 'merge-request)))
    (unless object
      (user-error "No merge request at point"))
    (let* ((iid (nth 1 object))
           (context (nth 2 object))
           (buffer (gitlab--write-buffer 'merge-request iid context))
           (identifier (gitlab-data-identifier 'merge-request iid context)))
      (if (and (gitlab--target-elsewhere-p object)
               (not (yes-or-no-p (format "Approve %s? " identifier))))
          (message "Approval cancelled")
        (let ((gitlab-repository context)
              (gitlab-cli-directory (gitlab-cli-directory-of)))
          (gitlab-merge-request-approve-async
           iid
           (lambda (_text)
             (gitlab-merge-request--approve-done buffer iid context))
           (lambda (error)
             (gitlab--report-error buffer error))))))))

(defun gitlab-merge-request--merge-done (buffer iid context)
  "Report in BUFFER that the user merged merge request IID in CONTEXT.
Fetch BUFFER again, so the new state shows."
  (message "Merged %s"
           (gitlab-data-identifier 'merge-request iid context))
  (gitlab--refresh-after-write buffer))

;;;###autoload
(defun gitlab-merge-merge-request ()
  "Merge the merge request at point.
Point names the merge request through its text property, its
display buffer or its web URL, so the command works in a merge
request buffer, on a list row and on a link in any buffer.  Ask for
confirmation, because a merge changes the target branch, and run
`glab mr merge' in the background, so the buffer never blocks.  The
answer of the merge request holds no merge request field, so the
command fetches the merge request again and the buffer shows the
new state.  A failing request shows its condition in the header
line of a GitLab buffer and in the echo area elsewhere."
  (interactive)
  (let ((object (gitlab--object-at-point 'merge-request)))
    (unless object
      (user-error "No merge request at point"))
    (let* ((iid (nth 1 object))
           (context (nth 2 object))
           (buffer (gitlab--write-buffer 'merge-request iid context))
           (identifier (gitlab-data-identifier 'merge-request iid context)))
      (when (yes-or-no-p (format "Merge %s? " identifier))
        (let ((gitlab-repository context)
              (gitlab-cli-directory (gitlab-cli-directory-of)))
          (gitlab-merge-request-merge-async
           iid
           (lambda (_text)
             (gitlab-merge-request--merge-done buffer iid context))
           (lambda (error)
             (gitlab--report-error buffer error))))))))

(define-derived-mode gitlab-merge-request-mode gitlab-detail-mode
  "GitLab Merge Request"
  "Display one GitLab merge request.
Every top-level field of the glab JSON answer appears in a field
table.  A local merge request ref adds the commit list below the
fields, when `gitlab-merge-request-show-commits' is non-nil.
d shows the local changes and l the local commit log, and an
active region over commit lines limits both to those commits.
`gitlab-merge-request-show-notes' loads the notes below the fields.
`gitlab-approve-merge-request' approves the merge request on
behalf of the user, and `gitlab-merge-merge-request' merges it.
RET opens the pipeline, the commit or the web page at point."
  :group 'gitlab
  :interactive nil
  (setq-local gitlab--kind 'merge-request)
  (setq-local gitlab--label "GitLab merge request")
  (setq-local gitlab--parent-function #'gitlab-list-merge-requests)
  (setq-local gitlab--parent-identity-function
              (lambda () (list #'gitlab-merge-request-list-mode nil)))
  (setq-local gitlab--parent-label "merge request list")
  (setq-local gitlab--sibling-open-function
              (lambda (id _name) (gitlab-display-merge-request id)))
  (setq-local gitlab--fetch-function #'gitlab-merge-request--fetch)
  (setq-local gitlab--sections-hook 'gitlab-merge-request-sections-hook)
  (setq-local gitlab--title-function #'gitlab-merge-request--title)
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

(defun gitlab-merge-request--target-data (iid context)
  "Return the merge request data of IID in CONTEXT, or nil.
The data of the current detail buffer wins, and the merge request
row at point serves next, so the local commit range reads the same
base that the display shows.  A group row compares its own project
too, because two projects can both hold the same IID."
  (let ((iid (gitlab-data-id-string iid)))
    (cond
     ((and (eq gitlab--kind 'merge-request)
           (equal (gitlab-data-id-string gitlab--id) iid)
           (equal gitlab--context context))
      gitlab--last-data)
     ((derived-mode-p 'gitlab-merge-request-list-mode)
      (when-let* ((row (gitlab-list--row-at-point)))
        (when (and (equal (gitlab-data-id-string
                           (gitlab-data-field "iid" row))
                          iid)
                   (or (not (gitlab-merge-request--group-p))
                       (equal (gitlab-merge-request--row-context row)
                              context)))
          row))))))

(defun gitlab-merge-request--checkout-p (context)
  "Return non-nil when the current directory holds CONTEXT.
A nil CONTEXT keeps the old behavior, because then the buffer of
the user names its own project."
  (or (null context)
      (equal context (gitlab-git-remote-context (gitlab-cli-directory-of)))))

(defun gitlab-merge-request-show-changes ()
  "Show the local changes of the merge request at point.
Point names the merge request through its text property, its
display buffer or its web URL, so the command works in a merge
request buffer, on a list row and on a link in any buffer.  The
view needs a fetched merge request ref.  With an active region over
commit lines, the view covers only those commits.  Magit, when
available, supplies the diff buffer and its Ediff command on E.
Signal a user error in a buffer of another project, because the
local checkout holds no ref of that project."
  (interactive)
  (let ((object (gitlab--object-at-point 'merge-request)))
    (unless object
      (user-error "No merge request at point"))
    (let ((iid (nth 1 object))
          (context (nth 2 object)))
      (unless (gitlab-merge-request--checkout-p context)
        (user-error "No local checkout of %s" context))
      (gitlab-git-show-changes iid
                               (gitlab-merge-request--target-data iid context)
                               (gitlab-merge-request--region-commits)))))

(defun gitlab-merge-request-show-log ()
  "Show the local commit log of the merge request at point.
Point names the merge request through its text property, its
display buffer or its web URL, so the command works in a merge
request buffer, on a list row and on a link in any buffer.  The
log holds only the commits of the merge request.  With an active
region over commit lines, the log covers only those commits.
Magit, when available, supplies the log buffer and its Ediff
commands.  Signal a user error in a buffer of another project,
because the local checkout holds no ref of that project."
  (interactive)
  (let ((object (gitlab--object-at-point 'merge-request)))
    (unless object
      (user-error "No merge request at point"))
    (let ((iid (nth 1 object))
          (context (nth 2 object)))
      (unless (gitlab-merge-request--checkout-p context)
        (user-error "No local checkout of %s" context))
      (gitlab-git-show-log iid
                           (gitlab-merge-request--target-data iid context)
                           (gitlab-merge-request--region-commits)))))

(define-key gitlab-merge-request-mode-map (kbd "n")
  #'gitlab-merge-request-show-notes)
(define-key gitlab-merge-request-mode-map (kbd "d")
  #'gitlab-merge-request-show-changes)
(define-key gitlab-merge-request-mode-map (kbd "l")
  #'gitlab-merge-request-show-log)

(defun gitlab-merge-request--buffer-name (iid &optional context)
  "Return the detail buffer name for merge request IID.
CONTEXT is the project identity of the display buffer, nil when the
project is unknown."
  (declare (pure t) (side-effect-free t))
  (if context
      (format "*GitLab MR %s!%s*" context iid)
    (format "*GitLab MR !%s*" iid)))

;;;###autoload
(defun gitlab-display-merge-request (iid &optional repository)
  "Display the merge request with IID in its own buffer.
IID is the project-scoped number, with or without a leading !, or
a full identifier such as group/project!12.  REPOSITORY names the
project and the instance of the merge request, and it defaults to
the repository part of IID, to the project of the current directory
or to the set `gitlab-repository'.  A merge request of another
project opens in its own buffer."
  (interactive (list (gitlab-read-merge-request-iid)))
  (let* ((split (gitlab-data-identifier-split
                 'merge-request (gitlab-data-id-string iid)))
         (iid (cdr split))
         (repository (or repository (car split))))
    (when (string-prefix-p "!" iid)
      (setq iid (substring iid 1)))
    (gitlab--show-detail #'gitlab-merge-request--buffer-name
                         #'gitlab-merge-request-mode
                         iid repository)))

(provide 'gitlab-merge-request)

;;; gitlab-merge-request.el ends here
