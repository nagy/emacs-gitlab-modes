;;; gitlab-work-item.el --- Work item views -*- lexical-binding: t; -*-

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

;; Work item views.  GitLab renamed the issue object to work item, and
;; the web interface writes a work item as /-/work_items/12.  The
;; package reads the issue REST endpoint, because `glab issue' is the
;; stable command and answers every field of the object.  The
;; experimental `glab work-items' command covers every work item type
;; but answers five fields, so it serves no detail buffer.  A work item
;; family therefore lists and displays issues.
;;
;; `gitlab-work-item-mode' displays one work item per buffer and
;; `gitlab-work-item-list-mode' displays the collection.  Both refresh
;; themselves through the base modes of gitlab-mode.el.  The detail
;; buffer renders every field of `glab issue view --output json' as a
;; field table.
;;
;; The list columns are IID, Type, Title, State, Author, Labels and
;; Updated, and a group list puts the Project column first.  The row
;; identity is the IID, or the full identifier in a group list, so an
;; update keeps point on the same row.

;;; Code:

(require 'subr-x)
(require 'gitlab-data)
(require 'gitlab-mode)
(require 'gitlab-read)

(defcustom gitlab-work-item-list-buffer-name "*GitLab Work Items*"
  "Buffer name of the work item list.
The display layer inserts the project context before the closing
star, so the list of each project and of each instance has its own
buffer, for example \"*GitLab Work Items group/project*\".  The
buffer lookup reads the buffer-local identity and not the name, so a
renamed buffer stays reachable."
  :type 'string
  :group 'gitlab)

(defcustom gitlab-work-item-list-arguments nil
  "Extra glab arguments for the work item list.
The value is a list of strings, for example (\"--all\").  A prefix
argument on `gitlab-list-work-items' adds --all for that invocation
only."
  :type '(repeat string)
  :group 'gitlab)

(defcustom gitlab-work-item-sections-hook
  '(gitlab-insert-title gitlab-insert-fields)
  "Functions that insert the sections of a work item buffer.
`gitlab-detail-mode' runs the entries in order through
`magit-run-section-hook'.  Remove an entry to drop a section, or
move an entry to change the order of the sections.

An entry takes no arguments and inserts through
`magit-insert-section'.  It reads the decoded answer of the buffer
from `gitlab--buffer-data'."
  :type '(repeat function)
  :group 'gitlab)

;;; List

(defvar gitlab-work-item-list-format
  [("IID" 7 gitlab-list--number-sort :right-align t)
   ("Type" 10 t)
   ("Title" 44 t)
   ("State" 10 t)
   ("Author" 20 t)
   ("Labels" 18 t)
   ("Updated" 20 t)]
  "Table format of the work item list.
A list buffer fits every width to its rows, so these numbers apply
only with `gitlab-list-fit-columns' nil.  A numeric column aligns
its cells to the right, as a printed table does.")

(defvar gitlab-work-item-group-list-format
  [("Project" 28 t)
   ("IID" 7 gitlab-list--number-sort :right-align t)
   ("Type" 10 t)
   ("Title" 42 t)
   ("State" 10 t)
   ("Author" 20 t)
   ("Labels" 16 t)
   ("Updated" 20 t)]
  "Table format of the work item list of a group.
The Project column comes first, because one group holds the work
items of many projects.  A project list keeps
`gitlab-work-item-list-format' and shows no such column.")

(defun gitlab-work-item--group-p ()
  "Return non-nil when the current list buffer shows a group."
  (declare (side-effect-free t))
  (eq gitlab--scope 'group))

(defun gitlab-work-item--row-context (work-item)
  "Return the project context of WORK-ITEM, or nil.
The `web_url' field names the project of the row, so a group list
never reads the project from the buffer."
  (when-let* ((url (gitlab-data-field "web_url" work-item)))
    (nth 2 (gitlab--url-object url))))

(defun gitlab-work-item--row-id (work-item)
  "Return the row ID of WORK-ITEM in the current list.
A project list keeps the bare IID.  A group list writes the full
identifier, so two projects that both hold %12 stay apart."
  (let ((iid (gitlab-data-id-string
              (gitlab-data-field "iid" work-item))))
    (if (gitlab-work-item--group-p)
        (gitlab-data-identifier
         'work-item iid (gitlab-work-item--row-context work-item))
      iid)))

(defun gitlab-work-item--rows (data)
  "Return an alist of work item row ID to row for DATA."
  (mapcar (lambda (work-item)
            (cons (gitlab-work-item--row-id work-item) work-item))
          data))

(defun gitlab-work-item--entries (data)
  "Return `tabulated-list-entries' for work item DATA.
A group list puts the project of the row in the leftmost cell, and
the IID cell keeps the full identifier as its navigation target."
  (let ((group-p (gitlab-work-item--group-p)))
    (mapcar
     (lambda (work-item)
       (let* ((iid (gitlab-data-field "iid" work-item))
              (id (gitlab-work-item--row-id work-item))
              (type (gitlab--format-value
                     (gitlab-data-field "issue_type" work-item)))
              (title (gitlab-data-field-string "title" work-item))
              (state (gitlab-data-field-string "state" work-item))
              (author (gitlab--format-author
                       (gitlab-data-field "author" work-item)))
              (labels (gitlab--format-value
                       (gitlab-data-field "labels" work-item)))
              (updated (gitlab-list--date-cell
                        (gitlab-data-field "updated_at" work-item))))
         (list id
               (vconcat
                (when group-p
                  (vector (or (gitlab-work-item--row-context work-item)
                              "-")))
                (vector
                 (gitlab-list--id-cell (format "%%%s"
                                               (gitlab-data-id-string iid))
                                       'gitlab-work-item-iid id)
                 type
                 title
                 (propertize state 'face (or (gitlab--status-face state)
                                             'default))
                 author
                 labels
                 updated)))))
     data)))

(defun gitlab-work-item--fetch-list (success error)
  "Fetch the work item list for the current list buffer.
Call SUCCESS with the decoded array or ERROR with a condition."
  (gitlab-work-item-list-async
   success error gitlab-list--arguments
   (and gitlab--scope (cons gitlab--scope gitlab--context))))

(define-derived-mode gitlab-work-item-list-mode gitlab-list-mode
  "GitLab Work Items"
  "Display the work items of the current project or of a group.
A work item is an issue, so the table shows the issue types.  The
columns are IID, Type, Title, State, Author, Labels and Updated,
and a group list puts the Project column first.  RET opens the work
item at point; c copies its identifier and w opens its web page."
  :group 'gitlab
  (setq-local tabulated-list-format
              (if (gitlab-work-item--group-p)
                  gitlab-work-item-group-list-format
                gitlab-work-item-list-format))
  (setq-local tabulated-list-sort-key '("Updated" . t))
  (setq-local gitlab-list--kind 'work-item)
  (setq-local gitlab-list--fetch-function #'gitlab-work-item--fetch-list)
  (setq-local gitlab-list--entries-function #'gitlab-work-item--entries)
  (setq-local gitlab-list--rows-function #'gitlab-work-item--rows)
  (setq-local gitlab-list--open-function #'gitlab-display-work-item))

;;;###autoload
(defun gitlab-list-work-items (&optional all)
  "Display the work items of the current project.
A work item is an issue, and the web interface writes it in a
`/-/work_items/12' URL.  With prefix argument ALL, include closed
work items by adding --all to the glab arguments.  A directory
without a project context prompts for the project, because neither a
Git remote nor `gitlab-repository' names one."
  (interactive "P")
  (let ((repository (unless (gitlab-git-context)
                      (gitlab-read-repository)))
        (arguments (if all
                       (cons "--all" gitlab-work-item-list-arguments)
                     gitlab-work-item-list-arguments)))
    (let ((gitlab-repository (or repository gitlab-repository)))
      (gitlab-list--show
       gitlab-work-item-list-buffer-name
       #'gitlab-work-item-list-mode
       (lambda ()
         (setq-local gitlab-list--arguments arguments))))))

;;;###autoload
(defun gitlab-list-group-work-items (&optional all)
  "Display the work items of a group.
The command reads a group context and asks glab for the issues of
that group, so one buffer holds the work items of many projects.  A
Project column comes first, because a row alone names no project.
With prefix argument ALL, include closed work items by adding --all
to the glab arguments."
  (interactive "P")
  (let ((group (gitlab-read-group
                nil (and (eq gitlab--scope 'group) gitlab--context)))
        (arguments (if all
                       (cons "--all" gitlab-work-item-list-arguments)
                     gitlab-work-item-list-arguments)))
    (gitlab-list--show
     gitlab-work-item-list-buffer-name
     #'gitlab-work-item-list-mode
     (lambda ()
       (setq-local gitlab-list--arguments arguments))
     (cons 'group group))))

;;; Detail

(defun gitlab-work-item--fetch (iid success error)
  "Fetch work item IID for the current detail buffer.
Call SUCCESS with the decoded answer, or ERROR with a condition."
  (gitlab-work-item-show-async iid success error))

(defun gitlab-work-item--title (id data)
  "Return the title line of work item ID with DATA.
ID is the object ID and DATA the decoded answer."
  (declare (side-effect-free t))
  (let ((title (gitlab-data-field-string "title" data)))
    (format "%%%s %s" (gitlab-data-id-string id)
            (if (string-empty-p title) "(no title)" title))))

(define-derived-mode gitlab-work-item-mode gitlab-detail-mode
  "GitLab Work Item"
  "Display one GitLab work item.
A work item is an issue.  Every top-level field of the glab JSON
answer appears in a field table.  RET opens the web page or the
linked object at point."
  :group 'gitlab
  (setq-local gitlab--kind 'work-item)
  (setq-local gitlab--label "GitLab work item")
  (setq-local gitlab--parent-function #'gitlab-list-work-items)
  (setq-local gitlab--parent-identity-function
              (lambda () (list #'gitlab-work-item-list-mode nil)))
  (setq-local gitlab--parent-label "work item list")
  (setq-local gitlab--sibling-open-function
              (lambda (id _name) (gitlab-display-work-item id)))
  (setq-local gitlab--fetch-function #'gitlab-work-item--fetch)
  (setq-local gitlab--sections-hook 'gitlab-work-item-sections-hook)
  (setq-local gitlab--title-function #'gitlab-work-item--title))

(defun gitlab-work-item--buffer-name (iid &optional context)
  "Return the detail buffer name for work item IID.
CONTEXT is the project identity of the display buffer, nil when the
project is unknown."
  (declare (pure t) (side-effect-free t))
  (if context
      (format "*GitLab Work Item %s%%%s*" context iid)
    (format "*GitLab Work Item %%%s*" iid)))

;;;###autoload
(defun gitlab-display-work-item (iid &optional repository)
  "Display the work item with IID in its own buffer.
IID is the project-scoped number, with or without a leading %, or a
full identifier such as group/project%12.  REPOSITORY names the
project and the instance of the work item, and it defaults to the
repository part of IID, to the project of the current directory or
to the set `gitlab-repository'.  A work item of another project
opens in its own buffer."
  (interactive (list (gitlab-read-work-item-iid)))
  (let* ((split (gitlab-data-identifier-split
                 'work-item (gitlab-data-id-string iid)))
         (iid (cdr split))
         (repository (or repository (car split))))
    (when (string-prefix-p "%" iid)
      (setq iid (substring iid 1)))
    (gitlab--show-detail #'gitlab-work-item--buffer-name
                         #'gitlab-work-item-mode
                         iid repository)))

(provide 'gitlab-work-item)

;;; gitlab-work-item.el ends here
