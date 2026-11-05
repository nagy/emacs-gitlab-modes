;;; gitlab-mode.el --- Display layer of the GitLab modes -*- lexical-binding: t; -*-

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

;; The display layer: a detail base mode and a list base mode.  The
;; detail mode derives from `special-mode' and renders one GitLab
;; object as a read-only field table.  The list mode derives from
;; `tabulated-list-mode' and renders a collection as a table.
;;
;; A row of a list buffer expands into child rows through
;; `gitlab-list--child-function', and a mode that fetches the child
;; rows answers the row that reports a fetch in flight.  The child
;; rows follow their parent in the table, so the sort of the table
;; keeps a row and its children together.  The set of expanded rows
;; belongs to the buffer, so an automatic refresh never collapses a
;; row under the reader.  `gitlab-list--stamp-child' marks every cell
;; of a child row with its parent, so a command at a child row
;; reaches the parent and a render keeps the line of the parent.
;;
;; Both modes keep themselves current through `auto-revert-mode'.
;; The buffer-local `buffer-stale-function' decides when a refresh is
;; due; `revert-buffer-function' starts the asynchronous fetch.  The
;; fetch never blocks Emacs, so a slow GitLab server does not freeze
;; the editor.  A refresh requested during a running fetch is served
;; when that fetch completes.
;;
;; Unchanged data is not rendered again.  `equal' compares the two
;; decoded alists, so point, marks and the window start survive an
;; automatic refresh that found no change.
;;
;; A render erases the buffer, so `gitlab--render' records the line
;; of point before the render and restores it after the render.  The
;; record names the line and not its buffer position: the field name,
;; the job ID, the commit SHA, the list row ID or, for a line without
;; such an identity, the text of the line and its ordinal among the
;; equal lines above it.  A blank line leans on the nearest line above
;; that has an identity, and the column of point travels with the
;; line.  So a refresh keeps the reader on the same value even when
;; the lines above changed their length.
;;
;; Display buffers are views, not files: `default-directory' is the
;; project root of the buffer that opened the display, so project.el,
;; version control and language servers find the project.  The buffer
;; bookmarks no file, `buffer-modified-p' stays nil and the buffer asks
;; no question on kill.
;;
;; A display buffer carries a bookmark record function, so
;; `bookmark-set' names the object, the project and the field line, job
;; row or list row at point.  The record stores the same identifier text
;; that an Org link and an xref identifier use, and
;; `gitlab-bookmark-jump' rebuilds the buffer from that record.
;;
;; The renderers attach text properties that the navigation commands
;; read: `gitlab-field' names a field line, `gitlab-pipeline-id' opens
;; a pipeline, `gitlab-merge-request-iid' opens a merge request,
;; `gitlab-job-id' opens a job log, `gitlab-commit-sha' opens a commit
;; and `gitlab-url' opens the browser.  A link and a table row are
;; text buttons of the type `gitlab-object', so `button.el' carries the
;; mouse face, the tooltip and the action.  RET and mouse-2 run
;; `gitlab-open-at-point'.
;;
;; `gitlab-go-to-parent' walks up one level: a merge request or a
;; pipeline opens its list, a job log opens the pipeline that holds
;; the job.  A list buffer has no parent.  The detail and job log
;; keymaps remap `dired-jump' and `dired-up-directory' to it.
;;
;; `gitlab-next-sibling' and `gitlab-previous-sibling' walk inside one
;; collection.  The parent view holds the order of its children: a
;; pipeline buffer holds its job rows, and a list buffer holds its
;; rows.  A child buffer names its parent with
;; `gitlab--parent-identity-function', and the commands read the
;; children of the open parent buffer, so a sibling command fetches
;; no collection.  A parent buffer answers with
;; `gitlab--children-function'
;; or, for a list buffer, with the rows that it displays.  The child
;; opens a sibling with `gitlab--sibling-open-function'.  The keys are
;; `C-c C-n' and `C-c C-p', and the back and forward mouse buttons run
;; the same commands.
;;
;; Every display buffer knows its project context: the project path
;; and the instance host, in the PATH or PATH@HOST spelling of
;; `gitlab-cli-repository-normalize'.  The context names the buffer,
;; so two projects and two instances never share one buffer.  The
;; buffer-local `gitlab--identity' holds the mode, the object ID and
;; the context, and a display command finds an open buffer by that
;; identity, so a renamed buffer stays reachable.

;;; Code:

(require 'autorevert)
(require 'bookmark)
(require 'browse-url)
(require 'bug-reference)
(require 'button)
(require 'cl-lib)
(require 'goto-addr)
(require 'json)
(require 'outline)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)
(require 'thingatpt)
(require 'gitlab-data)
(require 'gitlab-error)
(require 'gitlab-git)

(declare-function gitlab-display-merge-request "gitlab-merge-request"
                  (iid &optional repository))
(declare-function gitlab-git-show-commit "gitlab-git" (sha))
(declare-function gitlab-display-pipeline "gitlab-pipeline"
                  (pipeline-id &optional repository))
(declare-function gitlab-display-job-log "gitlab-pipeline"
                  (job-id &optional name pipeline-id repository))
(declare-function gitlab-job-log-mode "gitlab-pipeline" ())
(declare-function gitlab-merge-request-mode "gitlab-merge-request" ())
(declare-function gitlab-pipeline-mode "gitlab-pipeline" ())
(declare-function gitlab-merge-request-list-mode "gitlab-merge-request" ())
(declare-function gitlab-pipeline-list-mode "gitlab-pipeline" ())
(declare-function gitlab-export-json "gitlab-export" ())

;; The bookmark handler names the list buffer of each family.  These
;; variables live in the resource files, which load after this one.
(defvar gitlab-merge-request-list-buffer-name)
(defvar gitlab-pipeline-list-buffer-name)

;;; Web URLs

;; A web URL names one GitLab object of one project on one instance, so
;; the package answers it with its own buffer.  The entry lives in
;; `browse-url-default-handlers', the alist that Emacs and packages
;; own, and `browse-url-handlers' stays with the user.  The shape of a
;; GitLab URL carries everything that the display needs: the host, the
;; project path, the object family and the number.  No list of
;; instances is necessary.

(defconst gitlab--browse-url-regexp
  (concat "\\`https?://\\([^/?#]+\\)/"
          "\\(.+?\\)/-/\\(merge_requests\\|pipelines\\|jobs\\)/"
          "\\([0-9]+\\)")
  "Regexp that matches the web URL of a GitLab object.
Group 1 is the instance host, group 2 the project path, group 3 the
object family and group 4 the number.  The text behind the number
stays free, so a /diffs suffix, a query string and a note anchor
still match.")

(defun gitlab-browse-url (url &rest _arguments)
  "Open the GitLab object that URL names in its own buffer.
The function serves `browse-url-default-handlers', so `browse-url',
`browse-url-at-point' and every other caller reach the detail
buffer of a merge request, a pipeline or a job log.  URL names its
own instance and project, so a link of another project or of a
private instance opens the buffer of that project.  Return nil
when URL names no known object, and ignore ARGUMENTS, because a
display buffer takes a new window flag from its own command."
  (when-let* ((object (gitlab--url-object url)))
    (pcase (car object)
      ('merge-request (gitlab-display-merge-request
                       (nth 1 object) (nth 2 object)))
      ('pipeline (gitlab-display-pipeline (nth 1 object) (nth 2 object)))
      ('job (gitlab-display-job-log
             (nth 1 object) nil nil (nth 2 object))))
    t))

(defconst gitlab--browse-url-handler-entry
  (cons gitlab--browse-url-regexp #'gitlab-browse-url)
  "The alist entry that `gitlab-browse-url-handler' registers.")

(defun gitlab--set-browse-url-handler (symbol value)
  "Set SYMBOL to VALUE and register or remove the URL handler.
The handler lives in `browse-url-default-handlers', the alist that
Emacs and packages own.  `browse-url-handlers' stays with the
user."
  (set-default symbol value)
  (if value
      (add-to-list 'browse-url-default-handlers
                   gitlab--browse-url-handler-entry)
    (setq browse-url-default-handlers
          (delete gitlab--browse-url-handler-entry
                  browse-url-default-handlers))))

;;; Customization

(defcustom gitlab-auto-revert t
  "Non-nil if GitLab display buffers refresh themselves.
A display buffer then enables `auto-revert-mode'.  The refresh is
asynchronous, so Emacs never waits for glab."
  :type 'boolean
  :group 'gitlab)

(defcustom gitlab-refresh-interval 30
  "Minimum seconds between automatic refreshes of a display buffer.
A manual \\[revert-buffer] always fetches.  A buffer whose status
still changes uses `gitlab-refresh-fast-interval' instead."
  :type 'natnum
  :group 'gitlab)

(defcustom gitlab-refresh-fast-interval 5
  "Minimum seconds between refreshes while a status still changes.
The value never exceeds `gitlab-refresh-interval'."
  :type 'natnum
  :group 'gitlab)

(defcustom gitlab-refresh-visible-only t
  "When non-nil, only a visible buffer refreshes automatically.
A buffer in no window is not stale, so an idle Emacs does not poll
GitLab for buffers that nobody reads.  A manual
\\[revert-buffer] always fetches."
  :type 'boolean
  :group 'gitlab)

(defcustom gitlab-refresh-finished-pipelines t
  "When non-nil, a finished pipeline buffer does not poll.
A pipeline with a final status and no job whose status still
changes cannot change without a user action, so the stale check
returns nil and `auto-revert-mode' sends no request.  A manual
\\[revert-buffer] always fetches, so a restarted job appears
again."
  :type 'boolean
  :group 'gitlab)

(defcustom gitlab-status-faces
  '(("success" . gitlab-status-success)
    ("passed" . gitlab-status-success)
    ("merged" . gitlab-status-success)
    ("failed" . gitlab-status-failed)
    ("error" . gitlab-status-failed)
    ("running" . gitlab-status-running)
    ("pending" . gitlab-status-pending)
    ("preparing" . gitlab-status-pending)
    ("created" . gitlab-status-pending)
    ("scheduled" . gitlab-status-pending)
    ("waiting_for_resource" . gitlab-status-pending)
    ("manual" . gitlab-status-manual)
    ("canceled" . gitlab-status-canceled)
    ("cancelled" . gitlab-status-canceled)
    ("skipped" . gitlab-status-skipped)
    ("closed" . gitlab-status-skipped)
    ("opened" . gitlab-status-running))
  "Alist of status text to face.
The comparison ignores case.  A status that the alist does not
name keeps the default face."
  :type '(alist :key-type string :value-type face)
  :group 'gitlab)

(defcustom gitlab-date-fields
  '("created_at" "updated_at" "started_at" "finished_at" "merged_at"
    "closed_at" "prepared_at" "committed_at" "authored_date"
    "committed_date" "latest_build_started_at"
    "latest_build_finished_at")
  "Field names that take `gitlab-date'.
A list column compares a space against an underscore, so one
entry serves both views."
  :type '(repeat string)
  :group 'gitlab)

(defcustom gitlab-id-fields
  '("id" "iid" "sha" "before_sha" "project_id" "source_project_id"
    "target_project_id" "pipeline_id" "job_id" "runner_id"
    "merge_commit_sha" "squash_commit_sha")
  "Field names that take `gitlab-id'.
Every field that names one object or one commit belongs here, so
`id', `iid', `project_id', `sha' and `before_sha' look alike."
  :type '(repeat string)
  :group 'gitlab)

(defcustom gitlab-author-fields
  '("author" "assignee" "assignees" "reviewers" "user"
    "merge_user" "merged_by")
  "Field names that take `gitlab-author'.
A field that names a user belongs here.  A field that holds an
array of users takes the same faces on every entry."
  :type '(repeat string)
  :group 'gitlab)

(defcustom gitlab-branch-fields
  '("source_branch" "target_branch" "ref")
  "Field names that take `gitlab-branch'.
A field that names a branch or a ref belongs here, so the branch
fields of a merge request and the ref of a pipeline look alike."
  :type '(repeat string)
  :group 'gitlab)

(defcustom gitlab-tag-fields
  '("ref")
  "Field names that take `gitlab-tag' for a tag.
A pipeline answers a `tag' flag beside its ref, so a ref that the
flag marks a tag takes `gitlab-tag' instead of `gitlab-branch'."
  :type '(repeat string)
  :group 'gitlab)

(defcustom gitlab-change-functions nil
  "Hook run after a display buffer renders changed data.
Each function receives KIND, ID and DATA: the resource kind, its
identifier and the decoded answer.  A list buffer passes its
collection kind in KIND and nil in ID."
  :type 'hook
  :group 'gitlab)

(defcustom gitlab-list-expand-indent 3
  "Number of spaces that indent the child rows of an expanded row.
A list mode that expands a row answers its child rows through
`gitlab-list--child-function', and every cell of a child row takes
that many spaces in front of its first column."
  :type 'natnum
  :group 'gitlab)

(defcustom gitlab-list-fit-columns t
  "Non-nil if a list buffer sizes its columns to the shown content.
A fitted column takes the width of its widest cell, or the width of
its header when that is wider.  When the columns are wider than the
window, the widest columns shrink to one common cap, so no column
goes below its header.  A nil value keeps the widths of the table
format of the collection."
  :type 'boolean
  :group 'gitlab)

(defcustom gitlab-bug-reference t
  "Non-nil if a display buffer links the identifiers in its text.
A commit subject, a note body and a job trace then turn a reference
such as !12, #34 or &56 into a link to the web page of the object,
and a reference that starts with a project path links that
project.  The sigils follow `gitlab-data-identifier-signs'.  The
link comes from `bug-reference-mode', so its own keys follow it."
  :type 'boolean
  :group 'gitlab)

(defcustom gitlab-goto-address t
  "Non-nil if a display buffer links the URLs in its text.
`goto-address-mode' then turns a URL of a job trace or of a note
body into a link, so the reader opens it with the keys of that
mode."
  :type 'boolean
  :group 'gitlab)

(defcustom gitlab-browse-url-handler t
  "Non-nil if Emacs opens a GitLab web URL in a GitLab buffer.
A URL such as
https://gitlab.com/group/project/-/merge_requests/12 then opens the
buffer of that merge request, and a pipeline URL and a job URL
behave the same.  The package adds its entry to
`browse-url-default-handlers'; `browse-url-handlers' stays with
the user.  Set the option through Customize or `setopt', because a
plain `setq' leaves the entry in the alist."
  :type 'boolean
  :group 'gitlab
  :set #'gitlab--set-browse-url-handler)

;;; Faces

(defface gitlab-title
  '((t :inherit bold :height 1.1))
  "Face of the title line in a GitLab detail buffer."
  :group 'gitlab)

(defface gitlab-field-name
  '((t :inherit font-lock-variable-name-face))
  "Face of a field name in a GitLab detail buffer."
  :group 'gitlab)

(defface gitlab-id
  '((t :inherit font-lock-constant-face))
  "Face of a GitLab identifier."
  :group 'gitlab)

(defface gitlab-date
  '((t :inherit org-date))
  "Face of a timestamp field.
The face inherits `org-date', so a timestamp looks the same as in an
Org buffer.  Org stays optional, because Emacs ignores an undefined
parent face."
  :group 'gitlab)

(defface gitlab-author
  '((t :inherit magit-log-author))
  "Face of an author name.
The face inherits `magit-log-author', so an author looks the same
as in a Magit log.  Magit stays optional, because Emacs ignores an
undefined parent face."
  :group 'gitlab)

(defface gitlab-branch
  '((t :inherit magit-branch-remote))
  "Face of a branch name.
The face inherits `magit-branch-remote', so a branch looks the
same as in a Magit buffer.  Magit stays optional, because Emacs
ignores an undefined parent face."
  :group 'gitlab)

(defface gitlab-tag
  '((t :inherit magit-tag))
  "Face of a tag name.
The face inherits `magit-tag', so a tag looks the same as in a
Magit buffer.  Magit stays optional, because Emacs ignores an
undefined parent face."
  :group 'gitlab)

(defface gitlab-error
  '((t :inherit error))
  "Face of an error message."
  :group 'gitlab)

(defface gitlab-status-success
  '((t :inherit success))
  "Face of a successful status."
  :group 'gitlab)

(defface gitlab-status-failed
  '((t :inherit error))
  "Face of a failed status."
  :group 'gitlab)

(defface gitlab-status-running
  '((t :inherit warning))
  "Face of a running status."
  :group 'gitlab)

(defface gitlab-status-pending
  '((t :inherit warning))
  "Face of a pending status."
  :group 'gitlab)

(defface gitlab-status-manual
  '((t :inherit font-lock-constant-face))
  "Face of a manual job status."
  :group 'gitlab)

(defface gitlab-status-canceled
  '((t :inherit shadow))
  "Face of a canceled status."
  :group 'gitlab)

(defface gitlab-status-skipped
  '((t :inherit shadow))
  "Face of a skipped status."
  :group 'gitlab)

(defface gitlab-table-header
  '((t :inherit bold))
  "Face of a hand-written table header."
  :group 'gitlab)

;;; Buffer state

(defvar-local gitlab--id nil
  "Identifier of the object in the current display buffer.")

(defvar-local gitlab--context nil
  "Project context of the current display buffer.
The value is the project path, with @HOST when the project lives on
another instance.  `gitlab--use-project-directory' sets it.  Buffer
names and the identity lookup use it.")

(defvar-local gitlab--context-local nil
  "Non-nil if `gitlab--context' is the checkout of the buffer.
A buffer of another project reads no local merge request ref, so
the Git views stay out of the way.")

(defvar-local gitlab--identity nil
  "Identity of the current display buffer.
A list of the major mode, the object ID and the project context.
A display command compares it, so it finds an open buffer whatever
the user renamed it to.")

(defvar-local gitlab--scope nil
  "Scope of the current list buffer.
The value is `group' for a group list, and nil for a project, the
default scope.  `gitlab--use-project-directory' sets it, and
`gitlab--context' carries the group or the project context.")

(defvar gitlab--pending-scope nil
  "Scope that the next display buffer adopts.
A list command binds this variable around the mode call, because
`define-derived-mode' kills every local variable that a caller set
first and the mode body must know the scope of the collection.")

(defvar-local gitlab--target nil
  "Position target of the current display buffer, or nil.
A cons of the symbol `field' and a field name, of `job' and a job
ID, or of `row' and a list row ID.  A bookmark jump stores it
before the first fetch, and `gitlab--apply-target' moves point
there after that render.")

(defvar gitlab--pending-target nil
  "Position target that the next display buffer must honor.
A bookmark jump binds this variable around the display command,
because the target belongs to the new buffer and not to the
caller.  `gitlab--init-display-buffer' copies it into the
buffer-local `gitlab--target'.")

(defvar-local gitlab--kind nil
  "Kind of the object in the current display buffer.
The value is `merge-request', `pipeline' or `job'.")

(defvar-local gitlab--label "GitLab"
  "Human name of the object kind in the current buffer.")

(defvar-local gitlab--parent-function nil
  "Function that opens the parent view of the current buffer.
`gitlab-go-to-parent' calls it.  A list buffer leaves it nil,
because a collection has no parent.  The merge request mode, the
pipeline mode and the job log mode set it.")

(defvar-local gitlab--parent-identity-function nil
  "Function that returns the identity of the parent view.
`gitlab--siblings' calls it with no argument.  The value is a list
of the major mode function of the parent buffer and the parent
object ID, or nil when the buffer knows no parent.  A parent that
is a list buffer passes nil as the ID, because a collection is one
object.  The project context of the current buffer completes the
identity, so the function is the sibling of `gitlab--parent-function'.")

(defvar-local gitlab--parent-label "parent view"
  "Human name of the parent view of the current buffer.
`gitlab-next-sibling' and `gitlab-previous-sibling' name it in a
`user-error' when the parent view is not open.")

(defvar-local gitlab--children-function nil
  "Function that returns the children of the current buffer in display order.
The function takes no argument and returns a list of cons cells of
the child ID and its optional name.  A detail buffer that holds a
collection of GitLab objects sets this, for example the job rows of
a pipeline.  A list buffer does not need it: `gitlab--children'
reads the rows that the buffer displays.")

(defvar-local gitlab--sibling-open-function nil
  "Function that opens a sibling of the current buffer.
It receives the ID and the optional name of the sibling entry.
`gitlab-next-sibling' and `gitlab-previous-sibling' call it.")

(defvar-local gitlab--fetch-function nil
  "Function that fetches the data of the current detail buffer.
It receives ID, SUCCESS and ERROR and returns a process object or
nil.")

(defvar-local gitlab--render-function nil
  "Function that renders the data of the current detail buffer.
It receives ID and DATA.")

(defvar-local gitlab--last-data nil
  "Last decoded answer rendered in the current buffer.")

(defvar-local gitlab--raw-text nil
  "Raw glab answer of the last successful fetch.
The value is the exact standard output that `gitlab--last-data' was
decoded from.  A nil value means that the data layer merged more
than one answer, so a JSON export encodes `gitlab--last-data'.")

(defvar-local gitlab--rendered nil
  "Non-nil if the current buffer holds a rendered answer.")

(defvar-local gitlab--last-fetch-time nil
  "Float time of the last fetch of the current buffer.")

(defvar-local gitlab--pending nil
  "In-flight fetch of the current buffer.
The value is a process object, or t while a synchronous fetch
runs.")

(defvar-local gitlab--refresh-requested nil
  "Non-nil if a refresh arrived during a running fetch.")

(defvar-local gitlab--last-error nil
  "Last fetch error of the current buffer, or nil.")

(defvar-local gitlab--fetch-marker nil
  "Token that identifies the running fetch of the current buffer.")

(defvar-local gitlab--origin-buffer nil
  "Buffer from which the current display buffer was opened.")

(defvar-local gitlab--header-line-format nil
  "Header line format of the current display buffer.
A list buffer sets a format that reports the collection, a detail
buffer keeps nil.  `gitlab--set-error' shows the error text in the
header line and `gitlab--clear-error' restores this value.")

(defvar-local gitlab-list--fetch-function nil
  "Function that fetches the collection of the current list buffer.
It receives SUCCESS and ERROR and returns a process object or nil.")

(defvar-local gitlab-list--entries-function nil
  "Function that turns collection DATA into `tabulated-list-entries'.")

(defvar-local gitlab-list--rows-function nil
  "Function that turns collection DATA into an alist of ID to row.")

(defvar-local gitlab-list--rows nil
  "Alist of row ID to decoded row data in the current list buffer.")

(defvar-local gitlab-list--open-function nil
  "Function that opens the row ID at point in the current list buffer.")

(defvar-local gitlab-list--arguments nil
  "Extra glab arguments of the current list buffer.")

(defvar-local gitlab-list--kind nil
  "Kind of the collection in the current list buffer.
The value is `merge-request' or `pipeline'.  `gitlab-change-functions'
receives this value because a list buffer has no single ID.")

(defvar-local gitlab-list--child-function nil
  "Function that returns the child rows of an expanded list row.
The function receives the row ID and answers nil for a row without
child rows, or a list of table entries in the form that
`tabulated-list-entries' documents.  The base mode indents no cell
of its own, so a mode that shows a child row in a table puts the
indentation of `gitlab-list-expand-indent' in that row.  A mode
that fetches the child rows starts the fetch here and answers the
row that reports a fetch in flight.")

(defvar-local gitlab-list--child-reset-function nil
  "Function that forgets the child rows of one list row.
The function receives a row ID.  `gitlab-list-toggle-expansion'
calls it just before it expands the row, so a mode can retry a
fetch that failed.  A nil value keeps the child rows of the mode.")

(defvar-local gitlab-list--row-id-function nil
  "Function that returns the plain ID string of a list row ID.
The value is nil when the row ID already serves, as it does for a
merge request IID.  A mode that keys a child row by a composite ID
sets this function, so `c', the bookmark target and the export read
the object ID and not the composite.")

(defvar-local gitlab-list--row-data-function nil
  "Function that returns the decoded data of one list row.
The function receives a row ID and answers an alist or nil.  A list
mode sets it when the row data of a child row lives outside
`gitlab-list--rows'.")

(defvar-local gitlab-list--expanded nil
  "Hash table of the row IDs that the current list buffer shows expanded.
The table speaks of the buffer alone, so an automatic refresh keeps
every expanded row open.  Killing the buffer drops the table.")

(put 'gitlab-list--expanded 'permanent-local t)

;;; Small helpers

(defun gitlab--use-project-directory (&optional directory repository scope)
  "Set the directory and the project context of the current buffer.
DIRECTORY defaults to `gitlab-cli-directory-of', and REPOSITORY is
the explicit project of the display, or nil to read the context of
the directory.  The function sets both `default-directory' and the
buffer-local `gitlab-cli-directory' to the project root that
project.el reports, because glab must run in the project.  A
directory that belongs to no project stays as it is.

SCOPE names the collection of a list buffer as a cons of `group'
and a group context, or nil for a project.  A group buffer keeps no
`gitlab-repository', because glab takes a group and not a project,
and its context comes from SCOPE.  The buffer keeps REPOSITORY
buffer-locally, so a later auto refresh reads the same project.  A
bookmark jump and an xref definition take the project of their
record, and a display of another project replaces the value.  Pass
the value of the caller and not the value of an earlier display in
the same buffer.

The function also sets `gitlab--context', the identity of the
buffer, and remembers a project in `gitlab-repositories'.  A group
never enters that list, because the project prompt would offer it
as a project."
  (let* ((root (gitlab-cli--project-directory
                (or directory (gitlab-cli-directory-of))))
         (group (gitlab--scope-group scope))
         (repository (and (not group)
                          (gitlab-cli-repository-normalize repository)))
         (remote (gitlab-git-remote-context root))
         (context (if group
                      group
                    (or repository
                        (and gitlab-git-context-from-git remote)))))
    (setq-local default-directory root)
    (setq-local gitlab-cli-directory root)
    (setq-local gitlab-repository repository)
    (setq-local gitlab--scope (and group 'group))
    (setq-local gitlab--context context)
    (setq-local gitlab--context-local (and context (equal context remote)))
    (unless group
      (gitlab--remember-repository context))))

(defun gitlab--local-checkout-p ()
  "Return non-nil when the buffer shows the local checkout.
A display buffer without a project context keeps the old behavior
and reads the local refs, because its project is the directory the
user opened it from."
  (or (null gitlab--context) gitlab--context-local))

(defun gitlab--contextual-name (name context)
  "Return NAME with CONTEXT before the closing star."
  (declare (pure t) (side-effect-free t))
  (cond
   ((null context) name)
   ((string-suffix-p "*" name)
    (concat (substring name 0 -1) " " context "*"))
   (t (concat name " " context "*"))))

(defun gitlab--identity-buffer (mode id context)
  "Return the display buffer of MODE, ID and CONTEXT, or nil.
The function reads the buffer-local `gitlab--identity' of every
buffer, so the name of a buffer does not matter and a renamed
buffer stays reachable.  An indirect buffer never answers."
  (seq-find (lambda (buffer)
              (and (not (buffer-base-buffer buffer))
                   (with-current-buffer buffer
                     (equal gitlab--identity (list mode id context)))))
            (buffer-list)))

(defun gitlab--update-list-buffers-directory ()
  "Name the current buffer in `list-buffers-directory' by identifier.
`list-buffers' then shows the project and the object in the
identifier syntax of `gitlab-data-identifier'.  A list buffer has
no object ID and shows the project path alone.  A buffer without
a project leaves the variable nil, so `list-buffers' shows the
`default-directory'.

The value comes from the buffer-local `gitlab--kind', `gitlab--id'
and `gitlab--context', never from the buffer name, so a renamed
buffer keeps its identifier.  `gitlab--use-project-directory' sets
the context, so the helper reads no Git remote again."
  (let ((kind (or gitlab--kind gitlab-list--kind)))
    (setq-local list-buffers-directory
                (and kind
                     (gitlab-data-identifier
                      kind
                      gitlab--id
                      gitlab--context)))))

(defun gitlab--status-state (data)
  "Return the status text of the decoded object DATA."
  (declare (side-effect-free t))
  (let ((status (gitlab-data-field "status" data)))
    (and (stringp status) status)))

(defun gitlab--transitional-state-p (state)
  "Return non-nil when STATE still changes without user action."
  (declare (side-effect-free t))
  (and (stringp state)
       (cl-some (lambda (name) (string-equal-ignore-case name state))
                gitlab-transitional-states)))

(defun gitlab--transitional-p (data)
  "Return non-nil when DATA holds a status that still changes.
DATA is one decoded object or a list of decoded objects."
  (declare (side-effect-free t))
  (cond
   ((gitlab-data-alist-p data)
    (gitlab--transitional-state-p (gitlab--status-state data)))
   ((listp data)
    (cl-some (lambda (row)
               (and (gitlab-data-alist-p row)
                    (gitlab--transitional-state-p
                     (gitlab--status-state row))))
             data))
   (t nil)))

(defun gitlab--final-state-p (state)
  "Return non-nil when STATE cannot change without a user action."
  (declare (side-effect-free t))
  (and (stringp state)
       (not (gitlab--transitional-state-p state))))

(defun gitlab--settled-p ()
  "Return non-nil when the current buffer needs no polling.
A pipeline buffer is settled when the pipeline status is final
and every job status is final too.  A list buffer is never
settled, because a new merge request or pipeline can arrive."
  (and (eq gitlab--kind 'pipeline)
       (gitlab-data-alist-p gitlab--last-data)
       (gitlab--final-state-p
        (gitlab--status-state gitlab--last-data))
       (let ((jobs (gitlab-data-field "jobs" gitlab--last-data)))
         (or (not (listp jobs))
             (cl-every (lambda (job)
                         (and (gitlab-data-alist-p job)
                              (gitlab--final-state-p
                               (gitlab--status-state job))))
                       jobs)))))

(defun gitlab--refresh-delay ()
  "Return seconds to wait before the next automatic refresh.
A buffer with a status that still changes polls faster, up to the
upper bound of `gitlab-refresh-interval'."
  (if (gitlab--transitional-p gitlab--last-data)
      (min gitlab-refresh-fast-interval gitlab-refresh-interval)
    gitlab-refresh-interval))

(defun gitlab--buffer-stale-p (&optional _noconfirm)
  "Return non-nil when the current display buffer needs a refresh.
This is `buffer-stale-function' for both display modes.  An
in-flight fetch is never interrupted.  With
`gitlab-refresh-visible-only', a buffer in no window is never
stale.  With `gitlab-refresh-finished-pipelines', a settled
pipeline buffer is never stale."
  (and (not gitlab--pending)
       (or (not gitlab-refresh-visible-only)
           (get-buffer-window (current-buffer) t))
       (not (and gitlab-refresh-finished-pipelines
                 (gitlab--settled-p)))
       (or (null gitlab--last-fetch-time)
           (>= (- (float-time) gitlab--last-fetch-time)
               (gitlab--refresh-delay)))))

(defun gitlab--error-message (error)
  "Return a printable message for ERROR."
  (cond
   ((null error) "")
   ((stringp error) error)
   ((and (consp error) (symbolp (car error)))
    (error-message-string error))
   (t (format "%s" error))))

(defun gitlab--clear-error ()
  "Forget the last fetch error of the current buffer."
  (setq gitlab--last-error nil)
  (setq-local header-line-format gitlab--header-line-format)
  (setq-local mode-line-process nil))

(defun gitlab--set-error (error)
  "Show ERROR in the current buffer without losing old content."
  (setq gitlab--last-error error)
  (let ((message (propertize
                  (format " Error: %s" (gitlab--error-message error))
                  'face 'gitlab-error)))
    (if (derived-mode-p 'tabulated-list-mode)
        (setq-local mode-line-process (list message))
      (setq-local header-line-format message))))

(defun gitlab--kill-pending ()
  "Cancel an in-flight fetch and forget its handle.
A fetch that chains a second request stores it in the
`gitlab-cli-follow-up' property, so this function cancels both."
  (dolist (process (gitlab--pending-processes gitlab--pending))
    (delete-process process))
  (setq gitlab--pending nil
        gitlab--refresh-requested nil
        gitlab--fetch-marker nil))

(defun gitlab--pending-processes (pending)
  "Return PENDING and every process that it chains."
  (when (processp pending)
    (cons pending
          (gitlab--pending-processes
           (process-get pending 'gitlab-cli-follow-up)))))

(put 'gitlab--kill-pending 'permanent-local-hook t)

;;; Refresh pipeline

(defun gitlab--revert-buffer (&rest _arguments)
  "Fetch and render the current display buffer again.
Ignoring ARGUMENTS, as `revert-buffer-function' requires.  A
list buffer fetches its collection, a detail buffer its object.
The fetch is asynchronous, so this function returns immediately."
  (if gitlab-list--fetch-function
      (gitlab-list--refresh)
    (gitlab--refresh)))

(defun gitlab--refresh ()
  "Fetch fresh data for the current detail buffer.
Run `gitlab--fetch-function' with the object ID and the two
callbacks.  A refresh requested while a fetch runs is remembered
and served when that fetch completes."
  (cond
   ((or (null gitlab--id) (null gitlab--fetch-function)) nil)
   (gitlab--pending
    (setq gitlab--refresh-requested t))
   (t
    (let* ((buffer (current-buffer))
           (id gitlab--id)
           (marker (list nil))
           (settled nil))
      (setq gitlab--pending t
            gitlab--fetch-marker marker)
      (let ((handle
             (condition-case error
                 (funcall gitlab--fetch-function
                          id
                          (lambda (data)
                            (setq settled t)
                            (gitlab--refresh-done buffer marker data nil
                                                  gitlab-cli-response-text))
                          (lambda (error)
                            (setq settled t)
                            (gitlab--refresh-done buffer marker nil error)))
               (error
                (setq settled t)
                (gitlab--refresh-done buffer marker nil error)
                nil))))
        (when (and (not settled) handle)
          (setq gitlab--pending handle)))))))

(defun gitlab--refresh-done (buffer marker data error &optional raw)
  "Finish one refresh of BUFFER.
MARKER identifies the fetch, DATA is the decoded answer and
ERROR is a condition or nil.  RAW is the exact glab text that DATA
was decoded from, or nil when the data layer merged two answers.
An error keeps the old content and shows the message in the header
line or the mode line."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (eq marker gitlab--fetch-marker)
        (setq gitlab--pending nil
              gitlab--fetch-marker nil
              gitlab--last-fetch-time (float-time))
        (if error
            (gitlab--set-error error)
          (gitlab--clear-error)
          (setq gitlab--raw-text (and (stringp raw) raw))
          (let ((changed (not (and gitlab--rendered
                                   (equal data gitlab--last-data)))))
            (when changed
              (setq gitlab--last-data data
                    gitlab--rendered t)
              (gitlab--render)
              (set-buffer-modified-p nil)
              (run-hook-with-args 'gitlab-change-functions
                                  (or gitlab--kind gitlab-list--kind)
                                  gitlab--id data))))
        (when gitlab--refresh-requested
          (setq gitlab--refresh-requested nil)
          (gitlab--refresh))))))

(defun gitlab--refresh-after-write (buffer)
  "Refresh BUFFER after a write that changed the object it shows.
Drop the cached list answer of the buffer kind, because a later
prompt must not offer the state before the write, and fetch a live
buffer again.  BUFFER may be dead, because a write outlives the
buffer that sent it, and a dead buffer drops every cached list."
  (if (buffer-live-p buffer)
      (with-current-buffer buffer
        (gitlab-cache-invalidate (or gitlab--kind gitlab-list--kind))
        (gitlab--revert-buffer))
    (gitlab-cache-invalidate)))

(defun gitlab--render ()
  "Render `gitlab--last-data' in the current buffer.
Keep point on the line that it was on before the render, by the
identity of that line, and keep its column.  Every other window
that shows the buffer keeps the line of its own point too, because
the render erases the text that a window point marker points into.
A buffer with a position target moves point to that target
instead."
  (let ((record (gitlab--point-record))
        (windows (gitlab--window-records))
        (collapsed (gitlab--collapsed-sections)))
    (let ((inhibit-read-only t))
      (funcall (or gitlab--render-function #'gitlab--render-default)
               gitlab--id gitlab--last-data))
    (gitlab--restore-sections collapsed)
    (unless (gitlab--apply-target)
      (gitlab--restore-point record))
    (gitlab--restore-window-points windows)
    (gitlab--update-list-buffers-directory)))

;;; Point keeping

(defun gitlab--line-text ()
  "Return the text of the current line without properties or padding."
  (string-trim-right
   (buffer-substring-no-properties (line-beginning-position)
                                   (line-end-position))))

(defun gitlab--line-occurrence (text)
  "Return the number of lines above point that hold TEXT.
The count is the ordinal of the line of point among the equal
lines of the buffer, so a renderer that keeps one of two equal
lines keeps the right one."
  (let ((origin (line-beginning-position)))
    (save-excursion
      (goto-char (point-min))
      (let ((count 0))
        (while (< (point) origin)
          (when (equal (gitlab--line-text) text)
            (setq count (1+ count)))
          (forward-line 1))
        count))))

(defun gitlab--line-property (property)
  "Return the first value of PROPERTY on the current line, or nil.
A table row splits its cells into many runs of text, so a property
of a child row can start after the padding that the printer put in
front of the first cell."
  (declare (side-effect-free t))
  (save-excursion
    (goto-char (line-beginning-position))
    (let ((end (line-end-position))
          (value nil))
      (while (and (not value) (< (point) end))
        (setq value (get-text-property (point) property))
        (unless value (forward-char 1)))
      value)))

(defun gitlab--line-identity ()
  "Return the identity of the line of point, or nil.
The identity is a cons of a kind and a value: `job' and the job
ID, `sha' and the commit SHA, `field' and the field name, `row'
and the list row ID, or `text' and a cons of the text of the line
and its ordinal among the equal lines above it.  A child row of an
expanded list row answers with the parent row, so a render that
replaces the child row keeps the place through the parent.  A line
of whitespace alone has no identity, because its text would match
every blank line."
  (let ((start (line-beginning-position)))
    (or (when-let* ((id (get-text-property start 'gitlab-job-id)))
          (cons 'job id))
        (when-let* ((sha (get-text-property start 'gitlab-commit-sha)))
          (cons 'sha sha))
        (when-let* ((field (get-text-property start 'gitlab-field)))
          (cons 'field field))
        (when-let* ((id (tabulated-list-get-id)))
          (cons 'row (or (gitlab--line-property 'gitlab-list-parent-id)
                         id)))
        (let ((text (gitlab--line-text)))
          (unless (string-empty-p text)
            (cons 'text (cons text (gitlab--line-occurrence text))))))))

(defun gitlab--point-record (&optional position)
  "Return a semantic record of the line at POSITION, or nil.
POSITION defaults to point.  The record holds the identity of the
line, the number of lines from the line that the identity names to
the line of POSITION, and the column of POSITION.  A line of
whitespace alone leans on the nearest line above that has an
identity, so the record keeps the distance from that line.  Return
nil when no line of the buffer has an identity, because then there
is no place to keep."
  (let ((offset 0)
        column
        identity)
    (save-excursion
      (goto-char (or position (point)))
      (setq column (- (point) (line-beginning-position)))
      (beginning-of-line)
      (let ((done nil))
        (while (not done)
          (setq identity (gitlab--line-identity))
          (cond (identity (setq done t))
                ((bobp) (setq done t))
                (t
                 (setq offset (1+ offset))
                 (forward-line -1))))))
    (when identity
      (list :identity identity :offset offset :column column))))

(defun gitlab--goto-text (line)
  "Move point to the line that LINE names.
LINE is a cons of the text of a line and its ordinal among the
equal lines above it.  Return non-nil when the function found
such a line.  When the buffer holds fewer equal lines than the
ordinal, the last one serves, because a new line can push an old
one down, and the reader stays in the same part of the buffer."
  (let ((text (car line))
        (ordinal (cdr line))
        (index 0)
        (found nil)
        (last nil))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward (concat "^" (regexp-quote text) "[ \t]*$")
                                nil t)
        (setq last (line-beginning-position))
        (unless (or found (< index ordinal))
          (setq found last))
        (setq index (1+ index))))
    (when (or found last)
      (goto-char (or found last))
      t)))

(defun gitlab--goto-identity (identity)
  "Move point to the line that IDENTITY names.
Return non-nil when the function found that line.  It leaves
point at `point-min' when it found none."
  (pcase identity
    (`(job . ,id) (gitlab--goto-property 'gitlab-job-id id))
    (`(sha . ,sha) (gitlab--goto-property 'gitlab-commit-sha sha))
    (`(field . ,key) (gitlab--goto-property 'gitlab-field key))
    (`(row . ,id) (gitlab-list--goto-id id))
    (`(text . ,line) (gitlab--goto-text line))
    (_ nil)))

(defun gitlab--record-position (record)
  "Return the buffer position that RECORD names, or nil.
The position is the start of the line that the identity of RECORD
names, moved down by the recorded number of lines and set to the
recorded column.  A shorter line clips the column to its end."
  (when record
    (save-excursion
      (goto-char (point-min))
      (when (gitlab--goto-identity (plist-get record :identity))
        (forward-line (plist-get record :offset))
        (let ((column (plist-get record :column)))
          (unless (zerop column)
            (goto-char (min (+ (line-beginning-position) column)
                            (line-end-position)))))
        (point)))))

(defun gitlab--restore-point (record)
  "Move point to the position that RECORD describes.
A nil RECORD moves point to the start of the buffer, because no
line carried an identity before the render.  The column of point
travels with the line, so a reader stays on the same column of the
same value."
  (goto-char (or (gitlab--record-position record) (point-min))))

(defun gitlab--window-records ()
  "Return the point record of every other window that shows the buffer.
Every window but the selected one contributes one cons of the
window and its record.  The selected window needs no entry,
because its point is the point of the buffer.  A window whose line
has no identity contributes a nil record."
  (let ((buffer (current-buffer))
        (selected (selected-window))
        records)
    (dolist (window (get-buffer-window-list buffer nil t))
      (unless (eq window selected)
        (push (cons window (gitlab--point-record (window-point window)))
              records)))
    records))

(defun gitlab--restore-window-points (records)
  "Move the point of every window of RECORDS to its recorded line.
A window whose line is gone shows the start of the buffer, and a
dead window stays alone."
  (dolist (record records)
    (let ((window (car record)))
      (when (window-live-p window)
        (set-window-point window
                          (or (gitlab--record-position (cdr record))
                              (point-min)))))))

(defun gitlab--force-render ()
  "Render the last data again, even when it did not change.
The notes command uses this after it fetched comments."
  (when gitlab--rendered
    (gitlab--render)
    (set-buffer-modified-p nil)))

;;; Value rendering

(defun gitlab--field-label (key)
  "Return the display label of the JSON field KEY."
  (declare (pure t) (side-effect-free t))
  (capitalize (replace-regexp-in-string "_" " " (symbol-name key))))

(defun gitlab--json-encode (value)
  "Return VALUE as compact JSON, or its printed form on failure."
  (condition-case nil
      (json-encode value)
    (error (format "%S" value))))

;;; Text buttons

;; A link and a table row are text buttons of the type `gitlab-object'.
;; The type carries the mouse face, the follow link rule and the
;; action, so a renderer adds no mouse face of its own and the mode
;; keymap keeps RET, TAB and mouse-2.  Button properties are plain
;; symbols here, because `define-button-type' reserves the keyword
;; `:type' and `:supertype' alone.  The type keeps no keymap, because
;; an inherited `button-map' would bind RET and TAB and shadow the
;; mode keymap of a list row.

(defun gitlab--button-push (button)
  "Open the GitLab object of BUTTON.
A list buffer opens the row of the table, and every other buffer
opens the object at point, as `gitlab-open-at-point' documents."
  (when (integer-or-marker-p button)
    (goto-char button))
  (if (derived-mode-p 'gitlab-list-mode)
      (gitlab-list-open)
    (gitlab-open-at-point)))

(defun gitlab--button-follow-mouse-1-p (_position)
  "Return non-nil when one click follows the button at POSITION.
A list buffer keeps the left click for the selection, so a double
click toggles the row and the middle button opens it."
  (not (derived-mode-p 'gitlab-list-mode)))

(define-button-type 'gitlab-object
  'action #'gitlab--button-push
  'face nil
  'mouse-face 'highlight
  'follow-link #'gitlab--button-follow-mouse-1-p
  'keymap nil)

(defun gitlab--buttonize (start end &optional help)
  "Make the text between START and END a GitLab object button.
HELP is the text of the tooltip.  The text keeps its own faces,
because the type names no face."
  (make-text-button start end
                    :type 'gitlab-object
                    'help-echo help))

(defun gitlab--button-string (text &optional help)
  "Return TEXT as a GitLab object button.
HELP is the text of the tooltip."
  (make-text-button text nil
                    :type 'gitlab-object
                    'help-echo help))

(defun gitlab--nav-string (text property value &optional help)
  "Return TEXT as a button with navigation PROPERTY set to VALUE.
HELP is the text of the tooltip, and it defaults to VALUE.  The
button carries the mouse face and the action, so a renderer names
no mouse face of its own."
  (declare (pure t) (side-effect-free t))
  (gitlab--button-string (propertize text property value)
                         (or help (format "%s" value))))

;;; Text links

;; A display buffer links the object references of its text through
;; `bug-reference-mode' and the URLs of its text through
;; `goto-address-mode'.  Both modes fontify through jit-lock and mark
;; their text with an overlay, so no renderer carries a link of its
;; own and a copy of the text stays plain.

(defun gitlab--bug-reference-regexp ()
  "Return the regexp that matches a GitLab reference in text.
Group 1 is the link region, as `bug-reference-bug-regexp'
requires, and it covers group 2 to group 4.  Group 2 holds the
optional project path, group 3 the sigil and group 4 the number.
The sigils come from `gitlab-data-identifier-signs', and the path
needs one slash, so a bare word before a sigil never reads as a
project."
  (declare (side-effect-free t))
  (let ((signs (mapconcat (lambda (entry) (regexp-quote (cdr entry)))
                          gitlab-data-identifier-signs
                          "\\|"))
        (path "[[:alnum:]_.-]+\\(?:/[[:alnum:]_.-]+\\)+"))
    (concat "\\(?1:\\(?2:" path "\\)?\\(?3:" signs "\\)\\(?4:[0-9]+\\)\\)"
            "\\b")))

(defun gitlab--bug-reference-repository (project)
  "Return PROJECT on the instance of the current buffer.
A nil PROJECT answers the project context of the buffer.  A
reference of another project keeps the instance of the buffer,
because a project path alone names no instance."
  (declare (side-effect-free t))
  (let* ((context (or gitlab--context gitlab-repository))
         (host (car (gitlab-cli-repository-split context))))
    (cond
     ((null project) context)
     (host (concat project "@" host))
     (t project))))

(defun gitlab--bug-reference-url ()
  "Return the web URL of the reference at point.
`bug-reference-url-format' names this function, so the match data
of `bug-reference-bug-regexp' carries the sigil, the number and
the optional project."
  (let* ((kind (car (rassoc (match-string-no-properties 3)
                            gitlab-data-identifier-signs)))
         (id (match-string-no-properties 4))
         (project (match-string-no-properties 2)))
    (when kind
      (gitlab-web-url kind id (gitlab--bug-reference-repository project)))))

(defun gitlab--init-text-links ()
  "Link the references and the URLs of the current buffer.
The helper sets the buffer-local `bug-reference-bug-regexp' and
`bug-reference-url-format' before it enables the mode, because
`bug-reference-mode' runs no auto setup of its own when both hold
a value already."
  (when gitlab-bug-reference
    (setq-local bug-reference-bug-regexp (gitlab--bug-reference-regexp))
    (setq-local bug-reference-url-format #'gitlab--bug-reference-url)
    (bug-reference-mode 1))
  (when gitlab-goto-address
    (goto-address-mode 1)))

(defun gitlab--format-object (object)
  "Return a readable one-line form of the decoded OBJECT."
  (declare (pure t) (side-effect-free t))
  (let ((username (gitlab-data-field "username" object))
        (name (gitlab-data-field "name" object))
        (title (gitlab-data-field "title" object))
        (iid (gitlab-data-field "iid" object))
        (status (gitlab-data-field "status" object))
        (id (gitlab-data-field "id" object))
        (web-url (gitlab-data-field "web_url" object))
        (text (gitlab-data-field "text" object))
        (label (gitlab-data-field "label" object)))
    (cond
     ((and username name)
      (format "%s (@%s)" name username))
     (username
      (format "@%s" username))
     ((and id status)
      (if (or (gitlab-data-field "ref" object)
              (gitlab-data-field "sha" object))
          (gitlab--nav-string (format "#%s %s" id status)
                              'gitlab-pipeline-id (gitlab-data-id-string id)
                              "Open the pipeline")
        (if web-url
            (gitlab--nav-string (format "#%s %s" id status)
                                'gitlab-url web-url
                                "Open in the browser")
          (format "#%s %s" id status))))
     ((and title iid)
      (if web-url
          (gitlab--nav-string (format "%s (!%s)" title iid)
                              'gitlab-url web-url "Open in the browser")
        (format "%s (!%s)" title iid)))
     ((and text label) text)
     (t (gitlab--json-encode object)))))

(defun gitlab--format-value (value)
  "Return VALUE as display text."
  (declare (pure t) (side-effect-free t))
  (cond
   ((eq value :false) "no")
   ((eq value t) "yes")
   ((null value) "-")
   ((stringp value) (if (string-empty-p value) "-" value))
   ((numberp value) (number-to-string value))
   ((gitlab-data-alist-p value) (gitlab--format-object value))
   ((listp value)
    (if value
        (mapconcat #'gitlab--format-value value ", ")
      "-"))
   (t (format "%s" value))))

(defun gitlab--format-author (value)
  "Return author VALUE as display text with the `gitlab-author' face.
The name takes `gitlab-author' and the account name takes
`gitlab-id'.  VALUE is a decoded user object, a plain name, or
nil."
  (declare (pure t) (side-effect-free t))
  (cond
   ((gitlab-data-alist-p value)
    (let ((name (gitlab-data-field "name" value))
          (username (gitlab-data-field "username" value)))
      (cond
       ((and name username)
        (concat (propertize (format "%s" name) 'face 'gitlab-author)
                " ("
                (propertize (format "@%s" username) 'face 'gitlab-id)
                ")"))
       (username
        (propertize (format "@%s" username) 'face 'gitlab-id))
       (t (propertize (gitlab--format-object value)
                      'face 'gitlab-author)))))
   ((and (stringp value) (not (string-empty-p value)))
    (propertize value 'face 'gitlab-author))
   (t (gitlab--format-value value))))

(defun gitlab--format-author-list (value)
  "Return the users of VALUE as display text with their faces.
VALUE is a decoded user object, an array of user objects, a plain
name or nil.  Every name takes `gitlab-author' and every account
name takes `gitlab-id', so a detail field looks like a list
column."
  (declare (pure t) (side-effect-free t))
  (if (and (listp value)
           value
           (not (gitlab-data-alist-p value)))
      (mapconcat #'gitlab--format-author value ", ")
    (gitlab--format-author value)))

(defun gitlab--format-branch (value &optional tag)
  "Return branch or ref VALUE as display text with `gitlab-branch'.
TAG is the decoded `tag' flag of the object that holds VALUE, so a
ref of a tag takes `gitlab-tag'."
  (declare (pure t) (side-effect-free t))
  (if (and (stringp value) (not (string-empty-p value)))
      (propertize value 'face (if (gitlab--tag-flag-p tag)
                                  'gitlab-tag
                                'gitlab-branch))
    (gitlab--format-value value)))

(defun gitlab--format-date (value)
  "Return timestamp VALUE in a compact readable form."
  (declare (pure t) (side-effect-free t))
  (if (stringp value)
      (let ((text (replace-regexp-in-string "T" " " value)))
        (setq text (replace-regexp-in-string "\\.[0-9]+" "" text))
        (setq text (replace-regexp-in-string "Z\\'" "" text))
        (setq text (replace-regexp-in-string "[+-][0-9][0-9]:[0-9][0-9]\\'"
                                             "" text))
        text)
    (gitlab--format-value value)))

(defun gitlab--format-duration (value)
  "Return seconds VALUE as hours, minutes and seconds."
  (declare (pure t) (side-effect-free t))
  (if (numberp value)
      (let* ((total (round value))
             (hours (/ total 3600))
             (minutes (/ (% total 3600) 60))
             (seconds (% total 60)))
        (cond
         ((> hours 0) (format "%dh %dm %ds" hours minutes seconds))
         ((> minutes 0) (format "%dm %ds" minutes seconds))
         (t (format "%ds" seconds))))
    (gitlab--format-value value)))

(defun gitlab--elapsed-seconds (timestamp)
  "Return the seconds between TIMESTAMP and now, or nil.
TIMESTAMP is the ISO 8601 text of a GitLab answer, and the answer
takes no negative value."
  (declare (side-effect-free t))
  (when (and (stringp timestamp) (not (string-empty-p timestamp)))
    (let ((start (ignore-errors (float-time (date-to-time timestamp)))))
      (when start
        (max 0 (- (float-time) start))))))

(defun gitlab--status-face (status)
  "Return the face for STATUS, or nil."
  (declare (side-effect-free t))
  (when (stringp status)
    (cdr (assoc-string status gitlab-status-faces t))))

(defun gitlab--date-field-p (key)
  "Return non-nil when KEY names a date field.
A space and an underscore are the same, so one entry serves a
field name and a list column name."
  (declare (side-effect-free t))
  (gitlab--field-name-p
   (replace-regexp-in-string " " "_" (format "%s" key))
   gitlab-date-fields))

(defun gitlab--id-field-p (key)
  "Return non-nil when KEY names an identifier field."
  (declare (side-effect-free t))
  (gitlab--field-name-p key gitlab-id-fields))

(defun gitlab--field-name-p (key names)
  "Return non-nil when KEY names a field of the list NAMES.
KEY is a symbol or a string, and the comparison ignores case."
  (declare (pure t) (side-effect-free t))
  (when (or (symbolp key) (stringp key))
    (let ((name (if (symbolp key) (symbol-name key) key)))
      (cl-some (lambda (other)
                 (string-equal-ignore-case other name))
               names))))

(defun gitlab--author-field-p (key)
  "Return non-nil when KEY names an author field."
  (declare (side-effect-free t))
  (gitlab--field-name-p key gitlab-author-fields))

(defun gitlab--branch-field-p (key)
  "Return non-nil when KEY names a branch or a ref field."
  (declare (side-effect-free t))
  (gitlab--field-name-p key gitlab-branch-fields))

(defun gitlab--tag-field-p (key)
  "Return non-nil when KEY names a field that a tag flag can mark."
  (declare (side-effect-free t))
  (gitlab--field-name-p key gitlab-tag-fields))

(defun gitlab--tag-flag-p (value)
  "Return non-nil when VALUE is a true flag.
JSON false decodes to `:false', so a plain truth test would read a
false flag as true."
  (declare (pure t) (side-effect-free t))
  (and value (not (eq value :false))))

(defun gitlab--tag-p (data)
  "Return non-nil when the `tag' flag of DATA marks a tag."
  (declare (side-effect-free t))
  (gitlab--tag-flag-p (gitlab-data-field "tag" data)))

(defun gitlab--field-value-face (key value &optional data)
  "Return the face for the value of field KEY holding VALUE.
DATA is the object that holds KEY, when the caller has it.  A ref
that the `tag' flag of DATA marks a tag takes `gitlab-tag'."
  (declare (side-effect-free t))
  (cond
   ((and (stringp value) (gitlab--status-face value)))
   ((gitlab--status-face (symbol-name key)))
   ((gitlab--author-field-p key) 'gitlab-author)
   ((and (gitlab--tag-field-p key) (gitlab--tag-p data)) 'gitlab-tag)
   ((gitlab--branch-field-p key) 'gitlab-branch)
   ((gitlab--date-field-p key) 'gitlab-date)
   ((gitlab--id-field-p key) 'gitlab-id)
   ((eq key 'title) 'gitlab-title)
   (t nil)))

(defun gitlab--format-field-value (key value &optional data)
  "Return the display text of KEY with VALUE, including navigation.
DATA is the object that holds KEY, when the caller has it."
  (declare (side-effect-free t))
  (let ((text
         (cond
          ((gitlab--author-field-p key)
           (gitlab--format-author-list value))
          ((eq key 'web_url)
           (if (stringp value)
               (gitlab--nav-string value 'gitlab-url value "Open in the browser")
             (gitlab--format-value value)))
          ((and (memq key '(pipeline head_pipeline))
                (gitlab-data-alist-p value))
           (let ((id (gitlab-data-field "id" value))
                 (status (gitlab-data-field "status" value)))
             (if id
                 (gitlab--nav-string
                  (format "#%s %s" id (or status "pipeline"))
                  'gitlab-pipeline-id (gitlab-data-id-string id)
                  "Open the pipeline")
               (gitlab--format-value value))))
          ((gitlab--date-field-p key)
           (gitlab--format-date value))
          ((memq key '(duration queued_duration))
           (gitlab--format-duration value))
          (t (gitlab--format-value value)))))
    (if-let* ((face (and (not (gitlab--author-field-p key))
                         (gitlab--field-value-face key value data))))
        (propertize text 'face face)
      text)))

(defun gitlab--field-at-point ()
  "Return the field name at point or just before it."
  (or (get-text-property (point) 'gitlab-field)
      (and (> (point) (point-min))
           (get-text-property (1- (point)) 'gitlab-field))))

(defun gitlab--goto-field (field)
  "Move point to the first line of FIELD."
  (gitlab--goto-property 'gitlab-field field))

(defun gitlab--goto-property (property value)
  "Move point to the first line whose PROPERTY equals VALUE.
Return non-nil when the function found a line.  The renderers
attach the text properties that this helper reads, so a bookmark
can name a field line or a job row instead of a buffer position."
  (goto-char (point-min))
  (let ((found nil))
    (while (and (not found) (not (eobp)))
      (when (equal (get-text-property (point) property) value)
        (setq found t))
      (unless found (forward-line 1)))
    (if found
        (beginning-of-line)
      (goto-char (point-min)))
    found))

;;; Sections

;; A detail buffer folds its sections through `outline-minor-mode'.  A
;; heading is a title line that carries the text property
;; `gitlab-section' with the name of the section, and
;; `outline-search-function' finds it, so no heading needs a special
;; character in the text.  Every section is a top level section, so
;; `outline-level' answers one for each of them.

(defun gitlab--insert-section-title (title)
  "Insert TITLE as the heading line of a foldable section.
The line keeps `gitlab-title' and carries `gitlab-section' with
TITLE, so the outline search of the detail mode finds it and a
render restores a fold by name."
  (insert (propertize title
                      'face 'gitlab-title
                      'gitlab-section title)
          "\n"))

(defun gitlab--outline-search (&optional bound move backward looking-at)
  "Search for the next text property `gitlab-section'.
BOUND, MOVE, BACKWARD and LOOKING-AT have the meaning that
`outline-search-function' documents."
  (outline-search-text-property 'gitlab-section nil bound move backward
                                looking-at))

(defun gitlab--section-headings ()
  "Return the start of every section heading of the current buffer.
The positions come in buffer order."
  (let (headings
        (position (point-min)))
    (save-excursion
      (while (< position (point-max))
        (when (get-text-property position 'gitlab-section)
          (push position headings))
        (setq position (or (next-single-property-change
                            position 'gitlab-section nil (point-max))
                           (point-max)))))
    (nreverse headings)))

(defun gitlab--collapsed-sections ()
  "Return the names of the folded sections of the current buffer.
`gitlab--render' reads this before it erases the buffer, so a
refresh keeps the fold of a reader."
  (when (bound-and-true-p outline-minor-mode)
    (let (names)
      (dolist (heading (gitlab--section-headings))
        (save-excursion
          (goto-char heading)
          (when (outline-invisible-p (line-end-position))
            (push (get-text-property heading 'gitlab-section) names))))
      names)))

(defun gitlab--hide-section (name)
  "Fold the section NAME of the current buffer when it is present."
  (when-let* ((heading (seq-find
                        (lambda (position)
                          (equal (get-text-property position 'gitlab-section)
                                 name))
                        (gitlab--section-headings)))
              (inhibit-read-only t))
    (save-excursion
      (goto-char heading)
      (outline-hide-subtree))))

(defun gitlab--restore-sections (names)
  "Fold the sections of NAMES in the current buffer."
  (dolist (name names)
    (gitlab--hide-section name)))

(defun gitlab--enclosing-section ()
  "Return the start of the heading line of the section around point.
Return nil when point sits above the first section."
  (save-excursion
    (beginning-of-line)
    (if (get-text-property (point) 'gitlab-section)
        (point)
      (when (outline-previous-heading)
        (point)))))

(defun gitlab-detail-toggle-section ()
  "Fold or unfold the GitLab section around point.
The command works on every line of a section, not only on the line
that shows its heading, so a reader folds a long field table from
the middle of it."
  (interactive nil gitlab-detail-mode)
  (let ((heading (gitlab--enclosing-section)))
    (unless heading
      (user-error "No GitLab section at point"))
    (save-excursion
      (goto-char heading)
      (outline-toggle-children))))

(defun gitlab--insert-fields (data &optional keys)
  "Insert the field table of DATA into the current buffer.
KEYS selects and orders the fields; nil uses the JSON order.
Return the position before the first field."
  (let* ((keys (or keys (mapcar #'car data)))
         (labels (mapcar (lambda (key)
                           (concat (gitlab--field-label key) ":"))
                         keys))
         (width (apply #'max 0 (mapcar #'length labels))))
    (dolist (key keys)
      (let ((label (concat (gitlab--field-label key) ":"))
            (value (gitlab-data-field key data)))
        (insert (propertize (format (format "%%-%ds " width) label)
                            'gitlab-field key
                            'face 'gitlab-field-name))
        (insert (gitlab--format-field-value key value data))
        (insert "\n")))))

(defun gitlab--render-fields (title data &optional keys)
  "Render TITLE and the field table of DATA in the current buffer.
KEYS selects and orders the fields.  The function erases the
buffer first, so `gitlab--render' records the line of point before
the render and restores it after the render."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (gitlab--insert-section-title title)
    (insert "\n")
    (gitlab--insert-fields data keys)))

(defun gitlab--render-default (_id data)
  "Render DATA with the generic field table of the current buffer."
  (gitlab--render-fields
   (format "%s %s" gitlab--label (or gitlab--id ""))
   data))

;;; Imenu

(defun gitlab--imenu-index ()
  "Return an imenu index of the sections and the field lines."
  (let (index)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (cond
         ((get-text-property (point) 'gitlab-section)
          (push (cons (get-text-property (point) 'gitlab-section) (point))
                index))
         ((get-text-property (point) 'gitlab-field)
          (push (cons (gitlab--field-label (get-text-property (point)
                                                              'gitlab-field))
                      (point))
                index)))
        (forward-line 1)))
    (nreverse index)))

;;; Navigation

(defun gitlab--url-object (url)
  "Return (KIND ID CONTEXT) of the GitLab object that URL names, or nil.
A URL of another family, such as an issue page, answers nil."
  (when (and (stringp url)
             (string-match gitlab--browse-url-regexp url))
    (let ((host (match-string 1 url))
          (path (match-string 2 url))
          (kind (match-string 3 url))
          (id (match-string 4 url)))
      (list (pcase kind
              ("merge_requests" 'merge-request)
              ("pipelines" 'pipeline)
              ("jobs" 'job))
            id
            (gitlab-cli-repository-normalize
             (format "https://%s/%s" host path))))))

(defun gitlab--identifier-object (kind text context source)
  "Return the object of KIND that TEXT names, as a list.
The answer holds KIND, ID, CONTEXT and SOURCE.  A TEXT that carries
a repository part, such as group/project!12, names that repository;
otherwise CONTEXT serves.  A list cell of a group list carries the
full identifier, so one row of another project keeps its own
project."
  (when (and text (not (string-empty-p (format "%s" text))))
    (let* ((split (gitlab-data-identifier-split kind
                                                (gitlab-data-id-string text)))
           (repository (car split)))
      (list kind (cdr split)
            (if (and repository (not (string-empty-p repository)))
                repository
              context)
            source))))

(defun gitlab--property-object ()
  "Return (KIND ID CONTEXT SOURCE) from the text property at point.
SOURCE is `property', or `url' for a web URL of the object."
  (cond
   ((get-text-property (point) 'gitlab-job-id)
    (gitlab--identifier-object
     'job (get-text-property (point) 'gitlab-job-id)
     gitlab--context 'property))
   ((get-text-property (point) 'gitlab-pipeline-id)
    (gitlab--identifier-object
     'pipeline (get-text-property (point) 'gitlab-pipeline-id)
     gitlab--context 'property))
   ((get-text-property (point) 'gitlab-merge-request-iid)
    (gitlab--identifier-object
     'merge-request (get-text-property (point) 'gitlab-merge-request-iid)
     gitlab--context 'property))
   ((get-text-property (point) 'gitlab-url)
    (when-let* ((object (gitlab--url-object
                         (get-text-property (point) 'gitlab-url))))
      (append object '(url))))))

(defun gitlab--buffer-object ()
  "Return (KIND ID CONTEXT buffer) of the display buffer, or nil."
  (when (and gitlab--kind gitlab--id)
    (list gitlab--kind gitlab--id gitlab--context 'buffer)))

(defun gitlab--point-object ()
  "Return (KIND ID CONTEXT SOURCE) of the GitLab object at point, or nil.
SOURCE is `property' for a text property, `buffer' for the display
buffer and `url' for a web URL.  A property and the buffer win over
the URL, because they name the object that the reader sees."
  (or (gitlab--property-object)
      (gitlab--buffer-object)
      (when-let* ((url (thing-at-point 'url t)))
        (when-let* ((object (gitlab--url-object url)))
          (append object '(url))))))

(defun gitlab--object-id (kind value)
  "Return the ID text of KIND for VALUE, without a leading sigil.
A list cell writes a pipeline as #ID and a merge request as !IID."
  (cdr (gitlab-data-identifier-split kind (gitlab-data-id-string value))))

(defun gitlab--object-at-point (&optional kind)
  "Return (KIND ID CONTEXT SOURCE) of the GitLab object at point, or nil.
KIND, when non-nil, names the wanted kind.  A target of another
kind signals a user error, because a silent fallback would act on a
different object than point names."
  (when-let* ((object (gitlab--point-object)))
    (let ((object-kind (car object))
          (id (gitlab--object-id (car object) (nth 1 object)))
          (context (nth 2 object))
          (source (nth 3 object)))
      (when (and kind (not (eq object-kind kind)))
        (user-error "Point names %s, not a %s"
                    (gitlab-data-identifier object-kind id context)
                    (replace-regexp-in-string
                     "-" " " (symbol-name kind))))
      (list object-kind id context source))))

(defun gitlab--target-elsewhere-p (object)
  "Return non-nil when OBJECT is not the object of the current buffer.
A write from a list row, from a web URL or from another buffer acts
on an object that the reader does not see in a detail buffer, so the
command confirms it."
  (not (and (derived-mode-p 'gitlab-detail-mode)
            (eq (car object) gitlab--kind)
            (equal (nth 1 object) (gitlab-data-id-string gitlab--id))
            (equal (nth 2 object) gitlab--context))))

(defun gitlab--kind-mode (kind)
  "Return the detail mode function of KIND."
  (declare (pure t) (side-effect-free t))
  (pcase kind
    ('merge-request #'gitlab-merge-request-mode)
    ('pipeline #'gitlab-pipeline-mode)
    ('job #'gitlab-job-log-mode)))

(defun gitlab--write-buffer (kind id context)
  "Return the buffer that a write of KIND, ID and CONTEXT refreshes.
A live detail buffer of that object wins.  The current buffer serves
next when it shows GitLab data, because a list buffer shows the
collection that holds the object.  Return nil in every other
buffer, so the write touches no foreign buffer."
  (or (gitlab--identity-buffer (gitlab--kind-mode kind) id context)
      (when (derived-mode-p 'gitlab-detail-mode 'gitlab-list-mode)
        (current-buffer))))

(defun gitlab--report-error (buffer error)
  "Report in BUFFER the ERROR, or in the echo area without a GitLab buffer."
  (if (and (buffer-live-p buffer)
           (with-current-buffer buffer
             (derived-mode-p 'gitlab-detail-mode 'gitlab-list-mode)))
      (with-current-buffer buffer
        (gitlab--set-error error))
    (message "%s" (gitlab--error-message error))))

(defun gitlab-open-at-point ()
  "Open the GitLab object at point.
Read the text properties that the renderers attach: a job opens
its log, a pipeline opens its detail buffer, a merge request opens
its detail buffer, a commit opens its own view and a web URL opens
the browser."
  (interactive nil gitlab-detail-mode)
  (cond
   ((get-text-property (point) 'gitlab-job-id)
    (gitlab-display-job-log
     (get-text-property (point) 'gitlab-job-id)
     (get-text-property (point) 'gitlab-job-name)))
   ((get-text-property (point) 'gitlab-pipeline-id)
    (gitlab-display-pipeline
     (get-text-property (point) 'gitlab-pipeline-id)))
   ((get-text-property (point) 'gitlab-merge-request-iid)
    (gitlab-display-merge-request
     (get-text-property (point) 'gitlab-merge-request-iid)))
   ((get-text-property (point) 'gitlab-commit-sha)
    (gitlab-git-show-commit (get-text-property (point) 'gitlab-commit-sha)))
   ((get-text-property (point) 'gitlab-url)
    (browse-url (get-text-property (point) 'gitlab-url)))
   (t (user-error "No GitLab object at point"))))

(defun gitlab-mouse-open-at-point (event)
  "Open the GitLab object at the click EVENT."
  (interactive "e" gitlab-detail-mode)
  (mouse-set-point event)
  (gitlab-open-at-point))

(defun gitlab-go-to-parent ()
  "Open the view one level above the current GitLab buffer.
A merge request opens the merge request list, a pipeline opens the
pipeline list and a job log opens the pipeline that holds the job.
A list buffer is already the top level, so it signals `user-error'.
The buffer-local `gitlab--parent-function' names the command of
each kind."
  (interactive nil gitlab-detail-mode gitlab-job-log-mode)
  (if gitlab--parent-function
      (funcall gitlab--parent-function)
    (user-error "The current GitLab buffer has no parent")))

(defun gitlab--parent-buffer (&optional identity)
  "Return the open parent buffer of the current buffer, or nil.
IDENTITY defaults to the answer of
`gitlab--parent-identity-function', a list of the major mode
function and the object ID of the parent.  The lookup reads the
buffer-local identity of every buffer, so a renamed parent buffer
still answers."
  (when-let* ((identity (or identity
                           (and gitlab--parent-identity-function
                                (funcall gitlab--parent-identity-function)))))
    (gitlab--identity-buffer (car identity) (cadr identity)
                             gitlab--context)))

(defun gitlab--children ()
  "Return the children of the current buffer in display order.
Every entry is a cons of the child ID and its optional name.  A
buffer with `gitlab--children-function' answers with it.  A list
buffer reads the rows that it displays, so the sort column decides
the order.  A buffer that holds no collection answers nil."
  (cond
   (gitlab--children-function (funcall gitlab--children-function))
   ((derived-mode-p 'gitlab-list-mode) (gitlab-list--children))))

(defun gitlab--siblings ()
  "Return the ordered sibling entries of the current buffer.
The function reads the children of the open parent buffer, because
that buffer holds the order of its collection.  Signal `user-error'
when the buffer names no parent, when the parent view is not open
or when the parent view holds no child."
  (unless gitlab--parent-identity-function
    (user-error "The current GitLab buffer has no parent"))
  (let ((identity (funcall gitlab--parent-identity-function)))
    (unless identity
      (user-error "No parent is known for %s" (or gitlab--id "this buffer")))
    (let ((parent (gitlab--parent-buffer identity)))
      (unless parent
        (user-error "Open the %s first" gitlab--parent-label))
      (let ((entries (with-current-buffer parent (gitlab--children))))
        (unless entries
          (user-error "The %s holds no children" gitlab--parent-label))
        entries))))

(defun gitlab--sibling-position (entries)
  "Return the position of the current object in ENTRIES, or nil.
The ID of the current buffer names the entry, so a changed sort
order keeps its meaning."
  (seq-position entries gitlab--id
                (lambda (entry id) (equal (car entry) id))))

(defun gitlab--move-sibling (n)
  "Open the sibling N entries after the current object.
A negative N walks back.  Signal `user-error' when the buffer has
no parent view, when the current object is not a child of that
view or when the walk leaves the collection."
  (unless gitlab--sibling-open-function
    (user-error "The current GitLab buffer has no siblings"))
  (let* ((entries (gitlab--siblings))
         (position (gitlab--sibling-position entries)))
    (unless position
      (user-error "%s is not in the %s" gitlab--id gitlab--parent-label))
    (let ((target (+ position n)))
      (unless (and (<= 0 target) (< target (length entries)))
        (user-error "No %s sibling for %s"
                    (if (> n 0) "next" "previous") gitlab--id))
      (let ((entry (nth target entries)))
        (funcall gitlab--sibling-open-function (car entry) (cdr entry))))))

(defun gitlab-next-sibling (&optional n)
  "Open the N-th next sibling of the current GitLab object.
The parent view must be open, because it holds the order of its
children.  A job log reads the jobs of its pipeline buffer, a
pipeline detail reads the rows of its pipeline list and a merge
request detail reads the rows of its merge request list.  N
defaults to 1, and a negative N walks back.

Signal `user-error' when the buffer has no parent, when the parent
view is not open, when the current object is not a child of the
parent view and when the walk leaves the collection."
  (interactive "p" gitlab-detail-mode gitlab-job-log-mode)
  (gitlab--move-sibling (or n 1)))

(defun gitlab-previous-sibling (&optional n)
  "Open the N-th previous sibling of the current GitLab object.
This is `gitlab-next-sibling' with the opposite direction, so it
reads the same parent view.  N defaults to 1, and a negative N
walks forward."
  (interactive "p" gitlab-detail-mode gitlab-job-log-mode)
  (gitlab--move-sibling (- (or n 1))))

(defun gitlab-copy-id ()
  "Copy the identifier of the GitLab object at point to the kill ring.
The object comes from the text property at point, the display
buffer or the web URL at point, so the command works in a detail
buffer and on a list row."
  (interactive)
  (let ((object (gitlab--object-at-point)))
    (unless object
      (user-error "No GitLab object at point"))
    (let ((id (gitlab-data-id-string (nth 1 object))))
      (kill-new id)
      (message "Copied %s" id))))

(defun gitlab-open-web ()
  "Open the web page of the current object in a browser."
  (interactive nil gitlab-detail-mode)
  (let ((url (or (and gitlab--last-data
                      (gitlab-data-field "web_url" gitlab--last-data))
                 (and gitlab--id
                      (gitlab-web-url gitlab--kind gitlab--id)))))
    (if url
        (browse-url url)
      (user-error "No web URL for this buffer"))))

(defun gitlab-pop ()
  "Pop back to the buffer that opened the current display buffer."
  (interactive nil gitlab-detail-mode)
  (if (buffer-live-p gitlab--origin-buffer)
      (pop-to-buffer gitlab--origin-buffer)
    (user-error "The origin buffer is gone")))

;;; Detail mode

(defun gitlab--init-display-buffer ()
  "Wire the current buffer into the asynchronous refresh pipeline."
  (gitlab--kill-pending)
  (gitlab--use-project-directory
   nil gitlab-repository
   (or gitlab--pending-scope
       (and gitlab--scope (cons gitlab--scope gitlab--context))))
  (setq-local bookmark-make-record-function #'gitlab--bookmark-make-record)
  (when gitlab--pending-target
    (setq-local gitlab--target gitlab--pending-target))
  (setq-local revert-buffer-function #'gitlab--revert-buffer)
  (setq-local buffer-stale-function #'gitlab--buffer-stale-p)
  (add-hook 'kill-buffer-hook #'gitlab--kill-pending nil t)
  (when gitlab-auto-revert
    (setq-local auto-revert-verbose nil)
    (auto-revert-mode 1)))

(define-derived-mode gitlab-detail-mode special-mode "GitLab"
  "Display one GitLab object in the current buffer.
This is the base mode for merge request, pipeline and other
detail buffers.  It derives from `special-mode', so the buffer
is read-only and `q' buries it.

A derived mode sets `gitlab--fetch-function' and
`gitlab--render-function', then the display command sets
`gitlab--id' and calls `gitlab--refresh'.  The mode wires
`auto-revert-mode' through `buffer-stale-function' and
`revert-buffer-function', so the buffer keeps itself current
without blocking Emacs."
  :group 'gitlab
  (gitlab--init-display-buffer)
  (gitlab--init-text-links)
  (setq-local imenu-create-index-function #'gitlab--imenu-index)
  (setq-local gitlab--render-function #'gitlab--render-default)
  ;; A title line carries `gitlab-section', so the outline search finds
  ;; it and no heading needs a special character.  Every section is a
  ;; top level section, so the level answers one.  The faces of the
  ;; renderer stay, because the title already carries `gitlab-title'.
  (setq-local outline-search-function #'gitlab--outline-search)
  (setq-local outline-level (lambda () 1))
  (setq-local outline-minor-mode-highlight nil)
  (outline-minor-mode 1)
  (setq-local truncate-lines nil))

(define-key gitlab-detail-mode-map (kbd "TAB") #'gitlab-detail-toggle-section)
(define-key gitlab-detail-mode-map (kbd "RET") #'gitlab-open-at-point)
(define-key gitlab-detail-mode-map [mouse-2] #'gitlab-mouse-open-at-point)
(define-key gitlab-detail-mode-map (kbd "C-c C-n") #'gitlab-next-sibling)
(define-key gitlab-detail-mode-map (kbd "C-c C-p") #'gitlab-previous-sibling)
(define-key gitlab-detail-mode-map [mouse-9] #'gitlab-next-sibling)
(define-key gitlab-detail-mode-map [mouse-8] #'gitlab-previous-sibling)
(define-key gitlab-detail-mode-map (kbd "c") #'gitlab-copy-id)
(define-key gitlab-detail-mode-map (kbd "w") #'gitlab-open-web)
(define-key gitlab-detail-mode-map (kbd "p") #'gitlab-pop)
(define-key gitlab-detail-mode-map [remap dired-jump] #'gitlab-go-to-parent)
(define-key gitlab-detail-mode-map [remap dired-up-directory]
  #'gitlab-go-to-parent)

;; The remap of a JSON major mode belongs to the display layer, not to
;; `gitlab-export'.  An autoloaded display command loads this file and
;; not the entry library, so a remap that `gitlab-export' installs at
;; its own load never appears in a package with an autoload file.  The
;; target is autoloaded, so the first key that reaches it loads the
;; export layer.  `js-json-mode' serves a buffer without
;; tree-sitter, and `json-ts-mode' serves one with it.
(define-key gitlab-detail-mode-map [remap js-json-mode] #'gitlab-export-json)
(define-key gitlab-detail-mode-map [remap json-ts-mode] #'gitlab-export-json)

;;; List mode

(defun gitlab--init-list-buffer ()
  "Prepare the current buffer as a GitLab list buffer."
  (gitlab--init-display-buffer)
  (setq-local truncate-lines t))

(defun gitlab-list--show (buffer mode &optional setup scope)
  "Show the list BUFFER in MODE and refresh it.
BUFFER is the name to use when no display buffer holds the
collection yet; an open display buffer of the same MODE and project
wins, whatever its current name is.  SETUP runs in the buffer
before the fetch, so a display command can set the buffer-local
arguments or the origin buffer.  SCOPE names a group collection as
a cons of `group' and a group context, or nil for a project."
  (let* ((origin (current-buffer))
         (directory (gitlab-cli-directory-of))
         (group (gitlab--scope-group scope))
         (repository (and (not group)
                          (gitlab-cli-repository-normalize
                           gitlab-repository)))
         (context (or group (gitlab-git-context directory)))
         (target (or (gitlab--identity-buffer mode nil context)
                     (get-buffer-create
                      (generate-new-buffer-name
                       (gitlab--contextual-name buffer context))))))
    (with-current-buffer target
      (let ((gitlab--pending-scope scope))
        (funcall mode))
      (setq-local gitlab--origin-buffer origin)
      (gitlab--use-project-directory directory repository scope)
      (setq-local gitlab--identity (list mode nil gitlab--context))
      (when setup (funcall setup))
      (gitlab--update-list-buffers-directory)
      (gitlab-list--refresh))
    (pop-to-buffer target)))

(defun gitlab-list--refresh ()
  "Fetch fresh data for the current list buffer."
  (cond
   ((null gitlab-list--fetch-function) nil)
   (gitlab--pending
    (setq gitlab--refresh-requested t))
   (t
    (let* ((buffer (current-buffer))
           (marker (list nil))
           (settled nil))
      (setq gitlab--pending t
            gitlab--fetch-marker marker)
      (let ((handle
             (condition-case error
                 (funcall gitlab-list--fetch-function
                          (lambda (data)
                            (setq settled t)
                            (gitlab--refresh-done buffer marker data nil
                                                  gitlab-cli-response-text))
                          (lambda (error)
                            (setq settled t)
                            (gitlab--refresh-done buffer marker nil error)))
               (error
                (setq settled t)
                (gitlab--refresh-done buffer marker nil error)
                nil))))
        (when (and (not settled) handle)
          (setq gitlab--pending handle)))))))

(defun gitlab-list--date-cell (value)
  "Return timestamp VALUE as a table cell with `gitlab-date'."
  (declare (pure t) (side-effect-free t))
  (propertize (gitlab--format-date value) 'face 'gitlab-date))

(defvar-local gitlab-list--base-format nil
  "Table format of the current list buffer before fitting.
`tabulated-list-format' holds the fitted format, so the fitting
reads this value and never compounds its own answer.")

(defvar-local gitlab-list--fitted-format nil
  "Last table format that `gitlab-list--fit-columns' installed.")

(defvar-local gitlab-list--fit-width nil
  "Column budget of the last fitting, or nil before the first one.")

(defun gitlab-list--width-window (&optional hint)
  "Return the window whose width decides the columns.
Prefer HINT while it shows the buffer, then the selected window
while it shows the buffer, then the first window that shows it.
The selected window alone is no answer, because it can show another
buffer in another frame, and one buffer holds one
`tabulated-list-format' for every window."
  (let ((shown (get-buffer-window-list (current-buffer) nil t)))
    (cond
     ((memq hint shown) hint)
     ((memq (selected-window) shown) (selected-window))
     ((car shown))
     (t (selected-window)))))

(defun gitlab-list--available-width (&optional window)
  "Return the column budget of WINDOW in the current buffer.
The budget is the body width of the window less the table padding."
  (let ((window (gitlab-list--width-window window)))
    (max (- (window-width window) (max tabulated-list-padding 0)) 1)))

(defun gitlab-list--cell-text (cell)
  "Return the text of table CELL, or nil for a cell without text."
  (declare (pure t) (side-effect-free t))
  (cond
   ((stringp cell) cell)
   ((and (consp cell) (stringp (car cell))) (car cell))
   (t nil)))

(defun gitlab-list--cell-at (cells index)
  "Return one cell of a table row.
CELLS holds the cells of one entry, and INDEX names the column.
The answer is nil when the row holds no such column."
  (declare (pure t) (side-effect-free t))
  (cond
   ((vectorp cells) (and (< index (length cells)) (aref cells index)))
   ((listp cells) (nth index cells))
   (t nil)))

(defun gitlab-list--entry-cells (entry)
  "Return the column list of table ENTRY.
An entry is a list of an ID and a vector of cells, or a cons of an
ID and that vector."
  (declare (pure t) (side-effect-free t))
  (let ((cells (cdr entry)))
    (cond
     ((vectorp cells) cells)
     ((and (consp cells) (null (cdr cells)) (vectorp (car cells)))
      (car cells))
     (t cells))))

(defun gitlab-list--column-minimum (column sort-key)
  "Return the smallest width that COLUMN can take in a fitted table.
SORT-KEY names the sorted column, whose header takes the indicator.
The limit holds the header label, its right padding and the sort
indicator of the sorted column.  `tabulated-list-init-header'
adds that indicator as two characters."
  (declare (pure t) (side-effect-free t))
  (let* ((label (or (car-safe column) ""))
         (pad (or (plist-get (nthcdr 3 column) :pad-right) 1))
         (width (string-width label)))
    (+ width
       (max pad 0)
       (if (and sort-key (equal sort-key label)) 2 0))))

(defun gitlab-list--fit-widths (wants minimums available)
  "Return the column widths that fit the content into the window.
WANTS and MINIMUMS are vectors of one width per column, and
AVAILABLE is the column budget.  No width goes below the minimum
of its column.  The function finds the largest cap that keeps the
total within AVAILABLE and clips every wider column to it, so the
widest columns shrink together."
  (declare (pure t) (side-effect-free t))
  (let ((cap (let ((low 0) (high 1) (widths (length wants)))
               (dotimes (index widths)
                 (setq high (max high (aref wants index))))
               (while (< low high)
                 (let* ((middle (/ (+ low high 1) 2))
                        (total 0))
                   (dotimes (index widths)
                     (setq total (+ total (max (aref minimums index)
                                               (min (aref wants index)
                                                    middle)))))
                   (if (<= total available)
                       (setq low middle)
                     (setq high (1- middle)))))
               low))
        (fitted (make-vector (length wants) 0)))
    (dotimes (index (length wants))
      (aset fitted index (max (aref minimums index)
                              (min (aref wants index) cap))))
    fitted))

(defun gitlab-list--fit-format (format entries available)
  "Return FORMAT with the column widths fitted to ENTRIES.
AVAILABLE is the number of columns that the window offers.  Every
column keeps its label, its sort predicate and its properties."
  (let* ((count (length format))
         (sort-key (car-safe tabulated-list-sort-key))
         (wants (make-vector count 0))
         (minimums (make-vector count 0)))
    (dotimes (index count)
      (let ((minimum (gitlab-list--column-minimum
                      (aref format index)
                      sort-key)))
        (aset minimums index minimum)
        (aset wants index minimum)))
    (dolist (entry entries)
      (let ((cells (gitlab-list--entry-cells entry)))
        (dotimes (index count)
          (when-let* ((text (gitlab-list--cell-text
                             (gitlab-list--cell-at cells index))))
            (aset wants index (max (aref wants index)
                                   (string-width text)))))))
    (let ((widths (gitlab-list--fit-widths wants minimums available))
          (fitted (make-vector count nil)))
      (dotimes (index count)
        (let ((column (copy-sequence (aref format index))))
          (when (listp column)
            (setcar (nthcdr 1 column) (aref widths index)))
          (aset fitted index column)))
      (vconcat fitted))))

(defun gitlab-list--fit-columns (&optional window)
  "Fit the table columns of the current list buffer to its content.
WINDOW hints the window whose width limits the columns.  With
`gitlab-list-fit-columns' nil the function restores the widths of
the table format of the collection."
  (unless (equal tabulated-list-format gitlab-list--fitted-format)
    (setq gitlab-list--base-format tabulated-list-format))
  (when (and gitlab-list--base-format (derived-mode-p 'gitlab-list-mode))
    (let ((width (gitlab-list--available-width window)))
      (setq gitlab-list--fitted-format
            (when gitlab-list-fit-columns
              (gitlab-list--fit-format gitlab-list--base-format
                                       tabulated-list-entries
                                       width))
            gitlab-list--fit-width
            (when gitlab-list-fit-columns width))
      (setq tabulated-list-format (or gitlab-list--fitted-format
                                      gitlab-list--base-format)))))

(defun gitlab-list--refit (window)
  "Fit the columns of the current list buffer and print the rows again.
WINDOW supplies the new width.  The reprint keeps point on the
row that holds it."
  (gitlab-list--fit-columns window)
  (gitlab-list--print)
  (tabulated-list-init-header)
  (setq-local gitlab--header-line-format header-line-format))

(defvar gitlab-list--refit-buffers nil
  "List buffers that wait for a column refit.")

(defvar gitlab-list--refit-timer nil
  "Timer that runs the pending column refits, or nil.")

(defun gitlab-list--run-refits ()
  "Refit the columns of the list buffers that wait for it."
  (setq gitlab-list--refit-timer nil)
  (dolist (buffer (prog1 gitlab-list--refit-buffers
                    (setq gitlab-list--refit-buffers nil)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (and (derived-mode-p 'gitlab-list-mode)
                   gitlab-list-fit-columns
                   gitlab-list--base-format
                   (not (equal (gitlab-list--available-width)
                               gitlab-list--fit-width)))
          (gitlab-list--refit (gitlab-list--width-window)))))))

(defun gitlab-list--schedule-refit ()
  "Queue a column refit of the current list buffer.
`window-size-change-functions' runs during redisplay, and a reprint
must wait for the redisplay to end, so the refit goes through a
zero delay timer."
  (cl-pushnew (current-buffer) gitlab-list--refit-buffers)
  (unless (timerp gitlab-list--refit-timer)
    (setq gitlab-list--refit-timer
          (run-at-time 0 nil #'gitlab-list--run-refits))))

(defun gitlab-list--window-size-changed (frame)
  "Queue a column refit for the list buffers that FRAME shows.
A resize changes the space that the columns share.  A buffer that
no window of FRAME shows keeps the widths that it already holds."
  (dolist (window (window-list frame 'nomini))
    (with-current-buffer (window-buffer window)
      (when (and (derived-mode-p 'gitlab-list-mode)
                 gitlab-list-fit-columns
                 gitlab-list--base-format
                 (not (equal (gitlab-list--available-width window)
                             gitlab-list--fit-width)))
        (gitlab-list--schedule-refit)))))

(add-hook 'window-size-change-functions #'gitlab-list--window-size-changed)

;;; Sorting

(defun gitlab-list--cell-sort-text (cell)
  "Return the text that the sorting of a list column compares for CELL.
A cell that holds no text compares as the empty string."
  (declare (pure t) (side-effect-free t))
  (or (gitlab-list--cell-text cell) ""))

(defun gitlab-list--sorter ()
  "Return the sorting predicate of the current list buffer, or nil.
The predicate comes from the SORT element of the sorted column, and
an element of t requests the default of `tabulated-list-mode', a
string comparison of the cells.  A descending key reverses the
predicate, so the caller sorts the parent rows alone, because the
reversal would turn a child row in front of its parent."
  (when (and tabulated-list-sort-key (car tabulated-list-sort-key))
    (let* ((index (tabulated-list--column-number
                   (car tabulated-list-sort-key)))
           (predicate (nth 2 (aref tabulated-list-format index))))
      (when (eq predicate t)
        (setq predicate
              (lambda (a b)
                (string< (gitlab-list--cell-sort-text
                          (gitlab-list--cell-at (cadr a) index))
                         (gitlab-list--cell-sort-text
                          (gitlab-list--cell-at (cadr b) index))))))
      (when predicate
        (if (cdr tabulated-list-sort-key)
            (lambda (a b) (funcall predicate b a))
          predicate)))))

(defun gitlab-list--weave (entries)
  "Return ENTRIES with the child rows of every expanded row.
The child rows follow their parent in the list, so the sort of the
printer never separates a row from its children."
  (if (null gitlab-list--child-function)
      entries
    (let (rows)
      (dolist (entry entries)
        (push entry rows)
        (when (gitlab-list--row-expanded-p (car entry))
          (dolist (child (funcall gitlab-list--child-function (car entry)))
            (push (list (car child)
                        (gitlab-list--stamp-child
                         (gitlab-list--entry-cells child) (car entry)))
                  rows))))
      (nreverse rows))))

(defun gitlab-list--ordered-entries (entries)
  "Return ENTRIES sorted, with the child rows behind their parent.
ENTRIES holds the rows of the collection alone.  The sort stays
out of reach of the child rows, so a descending order never turns
a child in front of its parent."
  (let ((sorter (gitlab-list--sorter)))
    (gitlab-list--weave (if sorter
                            (sort (copy-sequence entries) sorter)
                          entries))))

(defun gitlab-list--print ()
  "Print the rows of the current list buffer in the order they hold.
`tabulated-list-print' sorts the list that it receives, so the sort
key steps aside while the function runs.  The sorted order and the
child rows already stand in `tabulated-list-entries'."
  (let ((tabulated-list-sort-key nil))
    (tabulated-list-print t)))

;;; Row expansion

(defun gitlab-list--row-id-string (id)
  "Return ID as the plain ID string of a list row."
  (if gitlab-list--row-id-function
      (funcall gitlab-list--row-id-function id)
    (gitlab-data-id-string id)))

(defun gitlab-list--expanded-p (id)
  "Return non-nil when the table shows the child rows of row ID."
  (declare (side-effect-free t))
  (and (hash-table-p gitlab-list--expanded)
       (gethash id gitlab-list--expanded)))

(defun gitlab-list--set-expanded (id value)
  "Show the child rows of row ID when VALUE is non-nil, else hide them.
Return VALUE."
  (unless (hash-table-p gitlab-list--expanded)
    (setq gitlab-list--expanded (make-hash-table :test #'equal)))
  (if value
      (puthash id t gitlab-list--expanded)
    (remhash id gitlab-list--expanded))
  value)

(defun gitlab-list--parent-id-at-point ()
  "Return the ID of the row that holds the child row at point, or nil."
  (declare (side-effect-free t))
  (gitlab--line-property 'gitlab-list-parent-id))

(defun gitlab-list--target-expands-p (id)
  "Return non-nil when a pending target names a child row of ID.
A bookmark that a child row made expands the row that holds it, so
the first render shows the child row and the jump reaches it."
  (declare (side-effect-free t))
  (pcase gitlab--target
    (`(job-row ,_job ,parent) (equal parent id))
    (_ nil)))

(defun gitlab-list--row-expanded-p (id)
  "Return non-nil when the table shows the child rows of row ID.
A pending target that names a child row of ID expands the row for
the whole life of the buffer, so a bookmark jump opens the row."
  (or (gitlab-list--expanded-p id)
      (and (gitlab-list--target-expands-p id)
           (gitlab-list--set-expanded id t))))

(defun gitlab-list--stamp-child (cells parent)
  "Return CELLS marked as a child row of the row PARENT.
Every cell takes the text property `gitlab-list-parent-id', so a
command at a child row reaches its parent and a render keeps the
line of the parent."
  (let ((copy (copy-sequence cells)))
    (dotimes (index (length copy))
      (let ((cell (aref copy index)))
        (when (and (stringp cell) (not (string-empty-p cell)))
          (aset copy index
                (propertize cell 'gitlab-list-parent-id parent)))))
    copy))

(defun gitlab-list--reprint ()
  "Print the rows of the current list buffer again without a fetch."
  (if gitlab--last-data
      (gitlab--render)
    (user-error "The list holds no rows")))

(defun gitlab-list-toggle-expansion (&optional row)
  "Expand or collapse the row at point, or the row ROW.
A child row collapses the row of its parent.  Expanding a row asks
its mode to forget an answer that this call retries, and the mode
starts a fetch when the table prints the expanded row."
  (interactive nil gitlab-list-mode)
  (let* ((child (gitlab-list--parent-id-at-point))
         (id (or row child (gitlab-list--id-at-point))))
    (cond
     ((null id)
      (user-error "No row at point"))
     ((null gitlab-list--child-function)
      (user-error "The current list holds no child rows"))
     ((gitlab-list--expanded-p id)
      (gitlab-list--set-expanded id nil))
     (t
      (when gitlab-list--child-reset-function
        (funcall gitlab-list--child-reset-function id))
      (gitlab-list--set-expanded id t)))
    (gitlab-list--reprint)))

(defun gitlab-list-mouse-toggle (event)
  "Expand or collapse the row of the click EVENT.
A double click makes no region, so the function drops the one that
the click started."
  (interactive "e" gitlab-list-mode)
  (mouse-set-point event)
  (deactivate-mark)
  (gitlab-list-toggle-expansion))

(defun gitlab-list--parent-rows ()
  "Return the row IDs of the collection of the current list buffer."
  (if gitlab-list--entries-function
      (mapcar #'car (funcall gitlab-list--entries-function gitlab--last-data))
    nil))

(defun gitlab-list-expand-all ()
  "Expand every row of the current list buffer.
A mode that fetches the child rows runs one fetch per row."
  (interactive nil gitlab-list-mode)
  (unless gitlab-list--child-function
    (user-error "The current list holds no child rows"))
  (dolist (id (gitlab-list--parent-rows))
    (gitlab-list--set-expanded id t))
  (gitlab-list--reprint))

(defun gitlab-list-collapse-all ()
  "Collapse every row of the current list buffer."
  (interactive nil gitlab-list-mode)
  (when (hash-table-p gitlab-list--expanded)
    (clrhash gitlab-list--expanded))
  (gitlab-list--reprint))

(defun gitlab-list--click-selects-row (&rest _arguments)
  "Return nil, so one click selects a row and follows no link.
`tabulated-list-mode' binds `follow-link' to `mouse-face', and one
click on a cell with a mouse face would then open the row.  A list
buffer keeps the click for the selection, so a double click can
toggle the row and the middle button can open it."
  nil)

(defun gitlab-list--render (_id data)
  "Render collection DATA into the current list buffer.
`gitlab-list--ordered-entries' sorts the parent rows and puts the
child rows of every expanded row behind its parent.
`gitlab-list--fit-columns' sizes the columns to the rows.
`tabulated-list-init-header' then builds the header line from
`tabulated-list-format' and `tabulated-list-sort-key', so the
header line names the columns and marks the sort column.  The
function keeps that value in `gitlab--header-line-format', because
`gitlab--clear-error' restores the value that an earlier render
installed."
  (when gitlab-list--rows-function
    (setq gitlab-list--rows (funcall gitlab-list--rows-function data)))
  (when gitlab-list--entries-function
    (setq tabulated-list-entries
          (gitlab-list--ordered-entries
           (funcall gitlab-list--entries-function data))))
  (gitlab-list--fit-columns)
  (gitlab-list--print)
  (tabulated-list-init-header)
  (setq-local gitlab--header-line-format header-line-format))

(define-derived-mode gitlab-list-mode tabulated-list-mode "GitLab List"
  "Display a collection of GitLab objects in the current buffer.
This is the base mode for merge request and pipeline lists.  It
derives from `tabulated-list-mode', so column sorting, column
resizing and point keeping by row identity come for free.

A derived mode sets `gitlab-list--fetch-function',
`gitlab-list--entries-function', `gitlab-list--rows-function'
and `gitlab-list--open-function'.  A mode whose rows expand sets
`gitlab-list--child-function' as well, and
`gitlab-list--child-reset-function' when its child rows load from
a request.  The mode wires `auto-revert-mode' through
`buffer-stale-function' and `revert-buffer-function'."
  :group 'gitlab
  (gitlab--init-list-buffer)
  (setq-local thing-at-point-provider-alist
              (cons '(url . gitlab-list--thing-at-point-url)
                    thing-at-point-provider-alist))
  (setq-local gitlab--render-function #'gitlab-list--render)
  (setq-local truncate-lines t))

(defun gitlab-list--id-at-point ()
  "Return the row ID at point, or nil."
  (tabulated-list-get-id))

(defun gitlab-list--children ()
  "Return the rows of the current list buffer in display order.
Every entry is a cons of the row ID and a nil name, because a
collection holds no name for its objects.  The function reads the
rows that the buffer displays, so the sort column decides the order
and a renamed buffer or a moved row keeps its meaning.  A child row
of an expanded row stays out, because it belongs to the parent row
and not to the collection."
  (save-excursion
    (goto-char (point-min))
    (let (entries)
      (while (not (eobp))
        (when-let* ((id (gitlab-list--id-at-point)))
          (unless (gitlab-list--parent-id-at-point)
            (push (cons id nil) entries)))
        (forward-line 1))
      (nreverse entries))))

(defun gitlab-list--goto-id (id)
  "Move point to the row of ID.
Return non-nil when the function found the row."
  (goto-char (point-min))
  (let ((found nil))
    (while (and (not found) (not (eobp)))
      (when (equal (gitlab-list--id-at-point) id)
        (setq found t))
      (unless found (forward-line 1)))
    (if found
        (beginning-of-line)
      (goto-char (point-min)))
    found))

(defun gitlab-list--row-at-point ()
  "Return the decoded row data at point, or nil.
`gitlab-list--row-data-function' answers first, so a mode can read
the data of a child row, and the collection alist answers last."
  (when-let* ((id (gitlab-list--id-at-point)))
    (or (and gitlab-list--row-data-function
             (funcall gitlab-list--row-data-function id))
        (alist-get id gitlab-list--rows nil nil #'equal))))

(defun gitlab-list--thing-at-point-url ()
  "Return the upstream web URL of the row at point.
The provider answers the `url' thing of the current list line
with the `web_url' field of the decoded row, so
`thing-at-point', `browse-url-at-point' and every other caller
that reads a URL work on a table row."
  (when-let* ((row (gitlab-list--row-at-point)))
    (gitlab-data-field "web_url" row)))

(defun gitlab-list-open ()
  "Open the row at point."
  (interactive nil gitlab-list-mode)
  (let ((id (gitlab-list--id-at-point)))
    (if id
        (funcall gitlab-list--open-function id)
      (user-error "No row at point"))))

(defun gitlab-list-mouse-open (event)
  "Open the row at the click EVENT."
  (interactive "e" gitlab-list-mode)
  (mouse-set-point event)
  (gitlab-list-open))

(defun gitlab-list-copy-id ()
  "Copy the ID of the row at point to the kill ring."
  (interactive nil gitlab-list-mode)
  (let ((id (gitlab-list--id-at-point)))
    (if id
        (let ((text (gitlab-list--row-id-string id)))
          (kill-new text)
          (message "Copied %s" text))
      (user-error "No row at point"))))

(defun gitlab-list-open-web ()
  "Open the web page of the row at point in a browser."
  (interactive nil gitlab-list-mode)
  (let ((url (gitlab-list--thing-at-point-url)))
    (if url
        (browse-url url)
      (user-error "The row has no web URL"))))

(defun gitlab-list--number-sort (a b)
  "Compare entries A and B by the number in the sort column.
`tabulated-list-mode' passes whole `tabulated-list-entries'
elements to a SORT predicate, not the cell strings.  The cell of
a merge request IID carries a leading !, so keep the digits only."
  (let* ((column (tabulated-list--column-number
                  (car tabulated-list-sort-key)))
         (number (lambda (entry)
                   (string-to-number
                    (replace-regexp-in-string
                     "[^0-9]" "" (aref (cadr entry) column))))))
    (< (funcall number a) (funcall number b))))

(defun gitlab-list--id-cell (id property &optional value)
  "Return ID as a table cell with PROPERTY set and `gitlab-id'.
VALUE defaults to ID, and it names the object behind the cell when
the cell text differs from the identifier, as in a group list."
  (declare (pure t) (side-effect-free t))
  (gitlab--nav-string (propertize id 'face 'gitlab-id)
                      property (or value id) "Open"))

(defun gitlab-list-sort (&optional column)
  "Sort the rows of the current list buffer by the column at point.
A numeric prefix COLUMN names the column, and a prefix of -1
returns the order of the collection.  A second call on the column
that already sorts the table reverses the direction.  The child
rows of an expanded row travel with their parent, so a sort never
separates a row from the rows that it holds."
  (interactive "P")
  (when (and column (or (>= column (length tabulated-list-format))
                        (< column -1)))
    (user-error "Invalid column number"))
  (if (equal column -1)
      (setq tabulated-list-sort-key nil)
    (let ((name (if column
                    (car (aref tabulated-list-format column))
                  (get-text-property (point) 'tabulated-list-column-name))))
      (unless name
        (user-error "Point is not in a column"))
      (unless (nth 2 (assoc name (append tabulated-list-format nil)))
        (user-error "Cannot sort by %s" name))
      (if (equal name (car-safe tabulated-list-sort-key))
          (setcdr tabulated-list-sort-key
                  (not (cdr tabulated-list-sort-key)))
        (setq tabulated-list-sort-key (cons name nil)))))
  (gitlab--render))

;; The commands are defined above the keymap bindings, so the
;; byte-compiler knows every key target.
(define-key gitlab-list-mode-map (kbd "RET") #'gitlab-list-open)
(define-key gitlab-list-mode-map [mouse-2] #'gitlab-list-mouse-open)
(define-key gitlab-list-mode-map (kbd "TAB") #'gitlab-list-toggle-expansion)
(define-key gitlab-list-mode-map (kbd "S") #'gitlab-list-sort)
(define-key gitlab-list-mode-map (kbd "c") #'gitlab-list-copy-id)
(define-key gitlab-list-mode-map (kbd "w") #'gitlab-list-open-web)
(define-key gitlab-list-mode-map [remap js-json-mode] #'gitlab-export-json)
(define-key gitlab-list-mode-map [remap json-ts-mode] #'gitlab-export-json)

;;; Bookmarks

(defconst gitlab--bookmark-labels
  '((merge-request . "GitLab MR")
    (pipeline . "GitLab Pipeline")
    (job . "GitLab Job")
    (merge-request-list . "GitLab Merge Requests")
    (pipeline-list . "GitLab Pipelines"))
  "Name prefix of each bookmarkable GitLab buffer kind.")

(defun gitlab--bookmark-label (kind)
  "Return the bookmark name prefix of KIND in the current buffer.
A merge request list of a group says so, because the context alone
names a group and a project the same way to a reader."
  (declare (side-effect-free t))
  (if (and (eq kind 'merge-request-list) (eq gitlab--scope 'group))
      "GitLab Group Merge Requests"
    (alist-get kind gitlab--bookmark-labels)))

(defconst gitlab--bookmark-link-types
  '((merge-request . "gitlab-mr")
    (pipeline . "gitlab-pipeline")
    (job . "gitlab-job")
    (merge-request-list . "gitlab-mr-list")
    (pipeline-list . "gitlab-pipeline-list"))
  "Org link type of each bookmarkable GitLab buffer kind.
A bookmark stores the same text as its location, so a bookmark
record, an Org link and an xref identifier name one object with
one syntax.")

(defun gitlab--bookmark-base-kind (kind)
  "Return the object kind of the list KIND, or KIND itself."
  (declare (pure t) (side-effect-free t))
  (intern (string-remove-suffix "-list" (symbol-name kind))))

(defun gitlab--identifier-repository ()
  "Return the context of the current buffer in identifier form.
The explicit `gitlab-repository' and the context from the Git
remote serve the same purpose here, so a bookmark and an Org link
of a derived context carry the project too.  A group list carries
its group, because no project names it."
  (or gitlab--context (gitlab-git-context)))

(defun gitlab--bookmark-location (kind id)
  "Return the Org link text of KIND with ID.
A list KIND takes no ID and names the project alone, so a
collection bookmark keeps its meaning when the table changes."
  (let ((path (gitlab-data-identifier (gitlab--bookmark-base-kind kind)
                                      id
                                      (gitlab--identifier-repository))))
    (if path
        (concat (alist-get kind gitlab--bookmark-link-types) ":" path)
      (alist-get kind gitlab--bookmark-link-types))))

(defun gitlab--bookmark-target ()
  "Return the position target of the current display buffer, or nil.
A list buffer returns its row, a pipeline buffer the job row or
the field line at point, and any other detail buffer the field
line at point.  A child row of an expanded list row names the row
of the job and the parent row, so a jump opens the parent again."
  (cond
   ((derived-mode-p 'gitlab-list-mode)
    (when-let* ((id (gitlab-list--id-at-point)))
      (if-let* ((job (gitlab--line-property 'gitlab-job-id)))
          (cons 'job-row
                (list job (gitlab-list--parent-id-at-point)))
        (cons 'row (gitlab-list--row-id-string id)))))
   (t
    (or (when-let* ((job (get-text-property (point) 'gitlab-job-id)))
          (cons 'job job))
        (when-let* ((field (gitlab--field-at-point)))
          (cons 'field field))))))

(defun gitlab--bookmark-make-record ()
  "Return a bookmark record for the current GitLab display buffer.
Intended for use as `bookmark-make-record-function'.  The record
names the object or the collection, the project, the directory in
which glab runs and the field line, job row or list row at point.
A list record adds the fetch arguments, the sort column and the
scope, so a filtered table and a group table come back the same."
  (let* ((list-p (derived-mode-p 'gitlab-list-mode))
         (kind (if list-p
                   (intern (format "%s-list" gitlab-list--kind))
                 gitlab--kind))
         (id (unless list-p gitlab--id))
         (location (gitlab--bookmark-location kind id))
         (target (gitlab--bookmark-target)))
    (cons (format "%s %s" (gitlab--bookmark-label kind)
                  location)
          (append
           `((kind . ,kind)
             (id . ,id)
             (handler . gitlab-bookmark-jump)
             (location . ,location)
             (repository . ,(gitlab--identifier-repository))
             (directory . ,(gitlab-cli-directory-of)))
           (when list-p
             `((arguments . ,gitlab-list--arguments)
               (sort . ,tabulated-list-sort-key)
               (scope . ,gitlab--scope)))
           (when target
             (list (cons 'target target)))))))

(defun gitlab--apply-target ()
  "Move point to `gitlab--target' and clear it.
A bookmark jump stores the field line, job row or list row of the
saved view there, because the first render erases the buffer and
moves point to its start.  A later refresh keeps point through the
text property that the renderer reads.  A child row of a list
buffer expands its parent before the render, so the child row
stands in the table.  A child row whose fetch still runs keeps the
target until a render shows the row, and the jump waits on the
parent row meanwhile.  Return non-nil when a target was applied,
so `gitlab--render' leaves that position alone."
  (when gitlab--target
    (let ((target gitlab--target))
      (pcase target
        (`(job-row ,job ,parent)
         (cond
          ((gitlab--goto-property 'gitlab-job-id job)
           (setq gitlab--target nil))
          ((gitlab-list--goto-id parent)
           ;; The jobs of the row still load, so the target waits for
           ;; the render that shows the job row.
           nil)
          (t (setq gitlab--target nil))))
        (_
         (setq gitlab--target nil)
         (pcase target
           (`(field . ,name) (gitlab--goto-property 'gitlab-field name))
           (`(job . ,id) (gitlab--goto-property 'gitlab-job-id id))
           (`(row . ,id) (gitlab-list--goto-id id)))))
      t)))

(defun gitlab--bookmark-list-setup (arguments sort)
  "Return a setup function for a list buffer.
ARGUMENTS and SORT come from a bookmark record.  The list mode
sets its own sort column, so the setup runs after the mode and
replaces it."
  (lambda ()
    (setq-local gitlab-list--arguments arguments)
    (when sort
      (setq-local tabulated-list-sort-key sort))))

;;;###autoload
(defun gitlab-bookmark-jump (bookmark)
  "Open the GitLab buffer that BOOKMARK names.
BOOKMARK is a bookmark record, not a bookmark name, so
`bookmark-jump' passes it here.  The jump restores the project,
the directory in which glab runs, the collection arguments, the
scope and the sort column, then moves point to the saved field
line, job row or list row.  A job log restarts its trace, because
a trace streams and has no snapshot."
  (interactive
   (let ((bookmark-alist
          (cl-remove-if-not (lambda (record)
                              (bookmark-prop-get record 'kind))
                            bookmark-alist)))
     (list (bookmark-get-bookmark
            (bookmark-completing-read "GitLab bookmark")))))
  (let ((kind (bookmark-prop-get bookmark 'kind))
        (id (bookmark-prop-get bookmark 'id))
        (repository (bookmark-prop-get bookmark 'repository))
        (directory (bookmark-prop-get bookmark 'directory))
        (name (bookmark-prop-get bookmark 'name))
        (arguments (bookmark-prop-get bookmark 'arguments))
        (sort (bookmark-prop-get bookmark 'sort))
        (scope (bookmark-prop-get bookmark 'scope)))
    (let ((gitlab-repository (unless (eq scope 'group) repository))
          (gitlab-cli-directory (or directory gitlab-cli-directory))
          (gitlab--pending-target (bookmark-prop-get bookmark 'target)))
      (pcase kind
        ('merge-request (gitlab-display-merge-request id))
        ('pipeline (gitlab-display-pipeline id))
        ('job (gitlab-display-job-log
               id name (bookmark-prop-get bookmark 'pipeline)))
        ('merge-request-list
         (gitlab-list--show
          gitlab-merge-request-list-buffer-name
          #'gitlab-merge-request-list-mode
          (gitlab--bookmark-list-setup arguments sort)
          (when (eq scope 'group) (cons 'group repository))))
        ('pipeline-list
         (gitlab-list--show
          gitlab-pipeline-list-buffer-name
          #'gitlab-pipeline-list-mode
          (gitlab--bookmark-list-setup arguments sort)))
        (_ (user-error "Unknown GitLab bookmark kind: %S" kind))))))

(put 'gitlab-bookmark-jump 'bookmark-handler-type "GitLab")

;;; Detail display helper

(defun gitlab--prepare-detail (name mode id &optional repository)
  "Prepare NAME in MODE for ID, start the fetch and return BUFFER.
NAME is a function of ID and the project context that returns the
buffer name.  REPOSITORY names the project and the instance of the
object, and it defaults to `gitlab-repository'.  An open display
buffer of the same MODE, ID and context wins, whatever its current
name is, so a renamed buffer stays in use.  The function captures
the current buffer as the origin and the directory in which glab
must run, then does not display the buffer."
  (let* ((origin (current-buffer))
         (directory (gitlab-cli-directory-of))
         (repository (gitlab-cli-repository-normalize
                      (or repository gitlab-repository)))
         (context (or repository (gitlab-git-context directory)))
         (target (or (gitlab--identity-buffer mode id context)
                     (get-buffer-create
                      (generate-new-buffer-name
                       (funcall name id context))))))
    (with-current-buffer target
      (funcall mode)
      (setq-local gitlab--origin-buffer origin)
      (gitlab--use-project-directory directory repository)
      (setq-local gitlab--id id)
      (setq-local gitlab--identity (list mode id gitlab--context))
      (gitlab--update-list-buffers-directory)
      (gitlab--refresh))
    target))

(defun gitlab--show-detail (name mode id &optional repository)
  "Show NAME in MODE for ID.
NAME is the namer function of `gitlab--prepare-detail', and
REPOSITORY is the optional project of the object.  The function
captures the current buffer as the origin, then pops to the
display buffer."
  (pop-to-buffer (gitlab--prepare-detail name mode id repository)))

(provide 'gitlab-mode)

;;; gitlab-mode.el ends here
