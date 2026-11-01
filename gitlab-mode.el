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
;; Both modes keep themselves current through `auto-revert-mode'.
;; The buffer-local `buffer-stale-function' decides when a refresh is
;; due; `revert-buffer-function' starts the asynchronous fetch.  The
;; fetch never blocks Emacs, so a slow GitLab server does not freeze
;; the editor.  A refresh requested during a running fetch is served
;; when that fetch completes.
;;
;; Unchanged data is not rendered again.  `equal' compares the two
;; decoded alists, so point, marks and the window start survive an
;; automatic refresh that found no change.  A renderer that needs to
;; keep its own place receives the old data indirectly through the
;; buffer's own state.
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
;; `gitlab-job-id' opens a job log and `gitlab-url' opens the browser.
;; RET and mouse-2 run `gitlab-open-at-point'.

;;; Code:

(require 'autorevert)
(require 'bookmark)
(require 'browse-url)
(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'tabulated-list)
(require 'gitlab-data)
(require 'gitlab-error)

(declare-function gitlab-display-merge-request "gitlab-merge-request" (iid))
(declare-function gitlab-display-pipeline "gitlab-pipeline" (pipeline-id))
(declare-function gitlab-display-job-log "gitlab-pipeline" (job-id &optional name))
(declare-function gitlab-merge-request-list-mode "gitlab-merge-request" ())
(declare-function gitlab-pipeline-list-mode "gitlab-pipeline" ())

;; The bookmark handler names the list buffer of each family.  These
;; variables live in the resource files, which load after this one.
(defvar gitlab-merge-request-list-buffer-name)
(defvar gitlab-pipeline-list-buffer-name)

;;; Customization

(defcustom gitlab-auto-revert t
  "Whether GitLab display buffers refresh themselves.
When non-nil, a display buffer enables `auto-revert-mode'.  The
refresh is asynchronous, so Emacs never waits for glab."
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
    "committed_date")
  "Field names that take `gitlab-date'.
A list column compares a space against an underscore, so one
entry serves both views."
  :type '(repeat string)
  :group 'gitlab)

(defcustom gitlab-change-functions nil
  "Hook run after a display buffer renders changed data.
Each function receives KIND, ID and DATA: the resource kind, its
identifier and the decoded answer.  A list buffer passes its
collection kind in KIND and nil in ID."
  :type 'hook
  :group 'gitlab)

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
  '((t :inherit shadow))
  "Face of a timestamp field."
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
  "Non-nil when the current buffer holds a rendered answer.")

(defvar-local gitlab--last-fetch-time nil
  "Float time of the last fetch of the current buffer.")

(defvar-local gitlab--pending nil
  "In-flight fetch of the current buffer.
The value is a process object, or t while a synchronous fetch
runs.")

(defvar-local gitlab--refresh-requested nil
  "Non-nil when a refresh arrived during a running fetch.")

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

;;; Small helpers

(defun gitlab--use-project-directory (&optional directory)
  "Set the directory of the current display buffer to a project root.
DIRECTORY defaults to `gitlab-cli-directory-of'.  The function
sets both `default-directory' and the buffer-local
`gitlab-cli-directory' to the project root that project.el
reports, because glab must run in the project.  A directory that
belongs to no project stays as it is.

The function also captures `gitlab-repository' buffer-locally.  A
bookmark jump or an xref definition binds another project around
the display command, and a later auto refresh must read that
project again.  A value of an earlier display in the same buffer
is dropped first, so the capture sees the binding of the caller."
  (let ((root (gitlab-cli--project-directory
               (or directory (gitlab-cli-directory-of)))))
    (kill-local-variable 'gitlab-repository)
    (let ((repository gitlab-repository))
      (setq-local default-directory root)
      (setq-local gitlab-cli-directory root)
      (setq-local gitlab-repository repository))))

(defun gitlab--status-state (data)
  "Return the status text of the decoded object DATA."
  (let ((status (gitlab-data-field "status" data)))
    (and (stringp status) status)))

(defun gitlab--transitional-state-p (state)
  "Return non-nil when STATE still changes without user action."
  (and (stringp state)
       (cl-some (lambda (name) (string-equal-ignore-case name state))
                gitlab-transitional-states)))

(defun gitlab--transitional-p (data)
  "Return non-nil when DATA holds a status that still changes.
DATA is one decoded object or a list of decoded objects."
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
stale."
  (and (not gitlab--pending)
       (or (not gitlab-refresh-visible-only)
           (get-buffer-window (current-buffer) t))
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

(defun gitlab--render ()
  "Render `gitlab--last-data' in the current buffer."
  (let ((inhibit-read-only t))
    (funcall (or gitlab--render-function #'gitlab--render-default)
             gitlab--id gitlab--last-data))
  (gitlab--apply-target))

(defun gitlab--force-render ()
  "Render the last data again, even when it did not change.
The notes command uses this after it fetched comments."
  (when gitlab--rendered
    (gitlab--render)
    (set-buffer-modified-p nil)))

;;; Value rendering

(defun gitlab--field-label (key)
  "Return the display label of the JSON field KEY."
  (capitalize (replace-regexp-in-string "_" " " (symbol-name key))))

(defun gitlab--json-encode (value)
  "Return VALUE as compact JSON, or its printed form on failure."
  (condition-case nil
      (json-encode value)
    (error (format "%S" value))))

(defun gitlab--nav-string (text property value &optional help)
  "Return TEXT with navigation PROPERTY set to VALUE.
The string also carries a mouse face and HELP, so a click and a
tooltip both work."
  (propertize text
              property value
              'mouse-face 'highlight
              'help-echo (or help (format "%s" value))))

(defun gitlab--format-object (object)
  "Return a readable one-line form of the decoded OBJECT."
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

(defun gitlab--format-date (value)
  "Return timestamp VALUE in a compact readable form."
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

(defun gitlab--status-face (status)
  "Return the face for STATUS, or nil."
  (when (stringp status)
    (cdr (assoc-string status gitlab-status-faces t))))

(defun gitlab--date-field-p (key)
  "Return non-nil when KEY names a date field."
  (and (stringp (symbol-name key))
       (cl-some (lambda (name)
                  (string-equal-ignore-case
                   (replace-regexp-in-string " " "_" name)
                   (symbol-name key)))
                gitlab-date-fields)))

(defun gitlab--field-value-face (key value)
  "Return the face for the value of field KEY holding VALUE."
  (cond
   ((and (stringp value) (gitlab--status-face value)))
   ((gitlab--status-face (symbol-name key)))
   ((gitlab--date-field-p key) 'gitlab-date)
   ((memq key '(id iid sha))
    'gitlab-id)
   ((eq key 'title) 'gitlab-title)
   (t nil)))

(defun gitlab--format-field-value (key value)
  "Return the display text of KEY with VALUE, including navigation."
  (let ((text
         (cond
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
          ((memq key '(created_at updated_at started_at finished_at
                       merged_at closed_at committed_at))
           (gitlab--format-date value))
          ((memq key '(duration queued_duration))
           (gitlab--format-duration value))
          (t (gitlab--format-value value)))))
    (if-let* ((face (gitlab--field-value-face key value)))
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
        (insert (gitlab--format-field-value key value))
        (insert "\n")))))

(defun gitlab--render-fields (title data &optional keys)
  "Render TITLE and the field table of DATA in the current buffer.
KEYS selects and orders the fields.  Keep point on the field that
point was on before the render."
  (let ((field (gitlab--field-at-point)))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (propertize title 'face 'gitlab-title))
      (insert "\n\n")
      (gitlab--insert-fields data keys)
      (goto-char (point-min))
      (when field (gitlab--goto-field field)))))

(defun gitlab--render-default (_id data)
  "Render DATA with the generic field table of the current buffer."
  (gitlab--render-fields
   (format "%s %s" gitlab--label (or gitlab--id ""))
   data))

;;; Imenu

(defun gitlab--imenu-index ()
  "Return an imenu index of the field lines of the current buffer."
  (let (index)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when-let* ((field (get-text-property (point) 'gitlab-field)))
          (push (cons (gitlab--field-label field) (point)) index))
        (forward-line 1)))
    (nreverse index)))

;;; Navigation

(defun gitlab-open-at-point ()
  "Open the GitLab object at point.
Read the text properties that the renderers attach: a job opens
its log, a pipeline opens its detail buffer, a merge request opens
its detail buffer and a web URL opens the browser."
  (interactive)
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
   ((get-text-property (point) 'gitlab-url)
    (browse-url (get-text-property (point) 'gitlab-url)))
   (t (user-error "No GitLab object at point"))))

(defun gitlab-mouse-open-at-point (event)
  "Open the GitLab object at the click EVENT."
  (interactive "e")
  (mouse-set-point event)
  (gitlab-open-at-point))

(defun gitlab-copy-id ()
  "Copy the identifier of the current buffer to the kill ring."
  (interactive)
  (if gitlab--id
      (progn
        (kill-new (gitlab-data-id-string gitlab--id))
        (message "Copied %s" gitlab--id))
    (user-error "This buffer has no GitLab identifier")))

(defun gitlab-open-web ()
  "Open the web page of the current object in a browser."
  (interactive)
  (let ((url (or (and gitlab--last-data
                      (gitlab-data-field "web_url" gitlab--last-data))
                 (and gitlab--id
                      (gitlab-web-url gitlab--kind gitlab--id)))))
    (if url
        (browse-url url)
      (user-error "No web URL for this buffer"))))

(defun gitlab-pop ()
  "Pop back to the buffer that opened the current display buffer."
  (interactive)
  (if (buffer-live-p gitlab--origin-buffer)
      (pop-to-buffer gitlab--origin-buffer)
    (user-error "The origin buffer is gone")))

;;; Detail mode

(defun gitlab--init-display-buffer ()
  "Wire the current buffer into the asynchronous refresh pipeline."
  (gitlab--kill-pending)
  (gitlab--use-project-directory)
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
  (setq-local imenu-create-index-function #'gitlab--imenu-index)
  (setq-local gitlab--render-function #'gitlab--render-default)
  (setq-local truncate-lines nil))

(define-key gitlab-detail-mode-map (kbd "RET") #'gitlab-open-at-point)
(define-key gitlab-detail-mode-map [mouse-2] #'gitlab-mouse-open-at-point)
(define-key gitlab-detail-mode-map (kbd "c") #'gitlab-copy-id)
(define-key gitlab-detail-mode-map (kbd "w") #'gitlab-open-web)
(define-key gitlab-detail-mode-map (kbd "p") #'gitlab-pop)

;;; List mode

(defun gitlab--init-list-buffer ()
  "Prepare the current buffer as a GitLab list buffer."
  (gitlab--init-display-buffer)
  (setq-local truncate-lines t))

(defun gitlab-list--show (buffer mode &optional setup)
  "Show the list BUFFER in MODE and refresh it.
SETUP runs in the buffer before the fetch, so a display command
can set the buffer-local arguments or the origin buffer."
  (let ((origin (current-buffer))
        (directory (gitlab-cli-directory-of))
        (buffer (get-buffer-create buffer)))
    (with-current-buffer buffer
      (funcall mode)
      (setq-local gitlab--origin-buffer origin)
      (gitlab--use-project-directory directory)
      (when setup (funcall setup))
      (gitlab-list--refresh))
    (pop-to-buffer buffer)))

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

(defun gitlab-list--header-line ()
  "Return the header line text of the current list buffer.
The text names the collection, its size, the sort column and the
refresh state.  A `:eval' entry of `header-line-format' calls this
function on every redisplay, so the text stays current."
  (let ((count (length tabulated-list-entries))
        (sort tabulated-list-sort-key)
        (name (if (stringp mode-name) mode-name
                (format-mode-line mode-name))))
    (concat (propertize (format " %s" name)
                        'face 'gitlab-table-header)
            (when gitlab-repository
              (format "  %s" gitlab-repository))
            (format "  %d %s" count (if (= count 1) "row" "rows"))
            (when sort
              (format "  by %s %s" (car sort)
                      (if (cdr sort) "descending" "ascending")))
            (cond (gitlab--pending "  refreshing")
                  (gitlab--last-error "  stale")
                  (t "")))))

(defun gitlab-list--date-cell (value)
  "Return timestamp VALUE as a table cell with `gitlab-date'."
  (propertize (gitlab--format-date value) 'face 'gitlab-date))

(defun gitlab-list--render (_id data)
  "Render collection DATA into the current list buffer."
  (when gitlab-list--rows-function
    (setq gitlab-list--rows (funcall gitlab-list--rows-function data)))
  (when gitlab-list--entries-function
    (setq tabulated-list-entries (funcall gitlab-list--entries-function data)))
  (tabulated-list-print t)
  (force-mode-line-update t))

(define-derived-mode gitlab-list-mode tabulated-list-mode "GitLab List"
  "Display a collection of GitLab objects in the current buffer.
This is the base mode for merge request and pipeline lists.  It
derives from `tabulated-list-mode', so column sorting, column
resizing and point keeping by row identity come for free.

A derived mode sets `gitlab-list--fetch-function',
`gitlab-list--entries-function', `gitlab-list--rows-function'
and `gitlab-list--open-function'.  The mode wires
`auto-revert-mode' through `buffer-stale-function' and
`revert-buffer-function'."
  :group 'gitlab
  (gitlab--init-list-buffer)
  (setq-local gitlab--render-function #'gitlab-list--render)
  (setq-local gitlab--header-line-format '(:eval (gitlab-list--header-line)))
  (setq-local header-line-format gitlab--header-line-format)
  (setq-local truncate-lines t))

(defun gitlab-list--id-at-point ()
  "Return the row ID at point, or nil."
  (tabulated-list-get-id))

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
  "Return the decoded row data at point, or nil."
  (when-let* ((id (gitlab-list--id-at-point)))
    (alist-get id gitlab-list--rows nil nil #'equal)))

(defun gitlab-list-open ()
  "Open the row at point."
  (interactive)
  (let ((id (gitlab-list--id-at-point)))
    (if id
        (funcall gitlab-list--open-function id)
      (user-error "No row at point"))))

(defun gitlab-list-mouse-open (event)
  "Open the row at the click EVENT."
  (interactive "e")
  (mouse-set-point event)
  (gitlab-list-open))

(defun gitlab-list-copy-id ()
  "Copy the ID of the row at point to the kill ring."
  (interactive)
  (let ((id (gitlab-list--id-at-point)))
    (if id
        (progn
          (kill-new (gitlab-data-id-string id))
          (message "Copied %s" id))
      (user-error "No row at point"))))

(defun gitlab-list-open-web ()
  "Open the web page of the row at point in a browser."
  (interactive)
  (let ((url (and (gitlab-list--row-at-point)
                  (gitlab-data-field "web_url"
                                     (gitlab-list--row-at-point)))))
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

(defun gitlab-list--id-cell (id property)
  "Return ID as a propertized table cell with PROPERTY set."
  (gitlab--nav-string id property id "Open"))

;; The commands are defined above the keymap bindings, so the
;; byte-compiler knows every key target.
(define-key gitlab-list-mode-map (kbd "RET") #'gitlab-list-open)
(define-key gitlab-list-mode-map [mouse-2] #'gitlab-list-mouse-open)
(define-key gitlab-list-mode-map (kbd "c") #'gitlab-list-copy-id)
(define-key gitlab-list-mode-map (kbd "w") #'gitlab-list-open-web)

;;; Bookmarks

(defconst gitlab--bookmark-labels
  '((merge-request . "GitLab MR")
    (pipeline . "GitLab Pipeline")
    (job . "GitLab Job")
    (merge-request-list . "GitLab Merge Requests")
    (pipeline-list . "GitLab Pipelines"))
  "Name prefix of each bookmarkable GitLab buffer kind.")

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
  (intern (string-remove-suffix "-list" (symbol-name kind))))

(defun gitlab--bookmark-repository ()
  "Return the project of the current buffer in identifier form."
  (let ((repository (string-trim (or gitlab-repository "") "/+" "/+")))
    (unless (string-empty-p repository) repository)))

(defun gitlab--bookmark-location (kind id)
  "Return the Org link text of KIND with ID.
A list KIND takes no ID and names the project alone, so a
collection bookmark keeps its meaning when the table changes."
  (let ((path (gitlab-data-identifier (gitlab--bookmark-base-kind kind)
                                      id
                                      (gitlab--bookmark-repository))))
    (if path
        (concat (alist-get kind gitlab--bookmark-link-types) ":" path)
      (alist-get kind gitlab--bookmark-link-types))))

(defun gitlab--bookmark-target ()
  "Return the position target of the current display buffer, or nil.
A list buffer returns its row, a pipeline buffer the job row or
the field line at point, and any other detail buffer the field
line at point."
  (cond
   ((derived-mode-p 'gitlab-list-mode)
    (when-let* ((id (gitlab-list--id-at-point)))
      (cons 'row (gitlab-data-id-string id))))
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
A list record adds the fetch arguments and the sort column, so a
filtered table comes back the same."
  (let* ((list-p (derived-mode-p 'gitlab-list-mode))
         (kind (if list-p
                   (intern (format "%s-list" gitlab-list--kind))
                 gitlab--kind))
         (id (unless list-p gitlab--id))
         (location (gitlab--bookmark-location kind id))
         (target (gitlab--bookmark-target)))
    (cons (format "%s %s" (alist-get kind gitlab--bookmark-labels)
                  location)
          (append
           `((kind . ,kind)
             (id . ,id)
             (handler . gitlab-bookmark-jump)
             (location . ,location)
             (repository . ,(gitlab--bookmark-repository))
             (directory . ,(gitlab-cli-directory-of)))
           (when list-p
             `((arguments . ,gitlab-list--arguments)
               (sort . ,tabulated-list-sort-key)))
           (when target
             (list (cons 'target target)))))))

(defun gitlab--apply-target ()
  "Move point to `gitlab--target' and clear it.
A bookmark jump stores the field line, job row or list row of the
saved view there, because the first render erases the buffer and
moves point to its start.  A later refresh keeps point through the
text property that the renderer reads."
  (when gitlab--target
    (let ((target (prog1 gitlab--target
                    (setq gitlab--target nil))))
      (pcase target
        (`(field . ,name) (gitlab--goto-property 'gitlab-field name))
        (`(job . ,id) (gitlab--goto-property 'gitlab-job-id id))
        (`(row . ,id) (gitlab-list--goto-id id))))))

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
the directory in which glab runs, the collection arguments and the
sort column, then moves point to the saved field line, job row or
list row.  A job log restarts its trace, because a trace streams
and has no snapshot."
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
        (sort (bookmark-prop-get bookmark 'sort)))
    (let ((gitlab-repository repository)
          (gitlab-cli-directory (or directory gitlab-cli-directory))
          (gitlab--pending-target (bookmark-prop-get bookmark 'target)))
      (pcase kind
        ('merge-request (gitlab-display-merge-request id))
        ('pipeline (gitlab-display-pipeline id))
        ('job (gitlab-display-job-log id name))
        ('merge-request-list
         (gitlab-list--show
          gitlab-merge-request-list-buffer-name
          #'gitlab-merge-request-list-mode
          (gitlab--bookmark-list-setup arguments sort)))
        ('pipeline-list
         (gitlab-list--show
          gitlab-pipeline-list-buffer-name
          #'gitlab-pipeline-list-mode
          (gitlab--bookmark-list-setup arguments sort)))
        (_ (user-error "Unknown GitLab bookmark kind: %S" kind))))))

(put 'gitlab-bookmark-jump 'bookmark-handler-type "GitLab")

;;; Detail display helper

(defun gitlab--prepare-detail (buffer mode id)
  "Prepare BUFFER in MODE for ID, start the fetch and return BUFFER.
The function captures the current buffer as the origin and the
directory in which glab must run, then does not display BUFFER."
  (let ((origin (current-buffer))
        (directory (gitlab-cli-directory-of))
        (buffer (get-buffer-create buffer)))
    (with-current-buffer buffer
      (funcall mode)
      (setq-local gitlab--origin-buffer origin)
      (gitlab--use-project-directory directory)
      (setq-local gitlab--id id)
      (gitlab--refresh))
    buffer))

(defun gitlab--show-detail (buffer mode id)
  "Show the detail BUFFER in MODE for ID.
Capture the current buffer as the origin, then pop to the display
buffer."
  (pop-to-buffer (gitlab--prepare-detail buffer mode id)))

(provide 'gitlab-mode)

;;; gitlab-mode.el ends here
