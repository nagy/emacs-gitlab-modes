;;; gitlab-pipeline.el --- Pipeline and job views -*- lexical-binding: t; -*-

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

;; Pipeline views.  `gitlab-pipeline-mode' displays one pipeline: the
;; pipeline fields at the top and the jobs table below, all in one
;; read-only buffer.  `gitlab-pipeline-list-mode' displays the
;; collection.  `gitlab-job-log-mode' streams one job trace.
;;
;; The jobs come from the jobs array of `glab ci get --output json'.
;; When a glab version omits the array, the data layer fetches the
;; documented jobs endpoint once and merges it into the answer, so the
;; renderer always sees the same shape.
;;
;; The job table is written by hand, not by `tabulated-list-mode',
;; because the pipeline fields occupy the top of the same buffer.
;; Every row carries `gitlab-job-id' and `gitlab-job-name', so RET at a
;; row opens the job log and a refresh restores point to the same job.
;;
;; The job log streams `glab ci trace JOB-ID' into a read-only buffer.
;; ANSI colors become faces.  Killing the buffer deletes the process.
;; A finished log stays readable; `g' starts the trace again.
;;
;; The trace arrives in arbitrary chunks, so the job log filter
;; assembles whole lines before it writes them.  It drops the banner
;; that glab prints on every run, because the header line already
;; names the job.  GitLab prefixes a trace line with an ISO 8601
;; timestamp when the job enables runner timestamps; the option
;; `gitlab-job-log-show-timestamps' and the command
;; `gitlab-job-log-toggle-timestamps' decide whether the buffer shows
;; it.  The prefix stays in the buffer as text with a `display'
;; property, so a toggle never asks GitLab again.  A copy of a region
;; leaves out every range that a property replaces, so the kill ring
;; and the clipboard receive the text that the buffer shows.
;;
;; A job log knows its parent pipeline: the display command passes the
;; ID, the bookmark record keeps it, and `gitlab-job-pipeline-id' asks
;; GitLab once when neither holds it.  `gitlab-go-to-parent' opens the
;; pipeline buffer.
;;
;; The pipeline buffer holds the order of its jobs, so
;; `gitlab-next-sibling' and `gitlab-previous-sibling' in a job log
;; read the job rows of the open pipeline buffer.  The log passes the
;; pipeline and the name of the next job on, so the new log can walk
;; up without a request.  A pipeline detail takes its own siblings
;; from the open pipeline list.
;;
;; GitLab writes a section marker into the trace before and after each
;; section.  The job log turns the start marker into a header line with
;; the name and the duration of the section, and it hides the end
;; marker.  The marker text stays in the buffer, so the imenu index and
;; the `display' properties never need the text again.  The buffer runs
;; `outline-minor-mode' over the header lines, so `outline-toggle-children'
;; folds a section and `gitlab-job-log-toggle-section' folds it from any
;; line of the section.

;;; Code:

(require 'cl-lib)
(require 'outline)
(require 'subr-x)
(require 'gitlab-data)
(require 'gitlab-mode)
(require 'gitlab-read)

(declare-function gitlab-cli--insert-chunk "gitlab-cli" (text))

(defcustom gitlab-pipeline-list-buffer-name "*GitLab Pipelines*"
  "Buffer name of the pipeline list.
The display layer inserts the project context before the closing
star, so the list of each project and of each instance has its own
buffer, for example \"*GitLab Pipelines group/project*\".  The buffer
lookup reads the buffer-local identity and not the name, so a
renamed buffer stays reachable."
  :type 'string
  :group 'gitlab)

(defcustom gitlab-pipeline-list-arguments nil
  "Extra glab arguments for the pipeline list.
The value is a list of strings, for example (\"--status=failed\")."
  :type '(repeat string)
  :group 'gitlab)

(defcustom gitlab-pipeline-job-name-width 36
  "Width of the job name column in the pipeline detail buffer.
A longer name is truncated by the table layout, not by the data."
  :type 'natnum
  :group 'gitlab)

;;; Pipeline list

(defvar gitlab-pipeline-list-format
  [("ID" 14 gitlab-list--number-sort)
   ("Status" 12 t)
   ("Ref" 34 t)
   ("Source" 20 t)
   ("Updated" 20 t)]
  "Table format of the pipeline list.")

(defun gitlab-pipeline--rows (data)
  "Return an alist of pipeline ID to row for DATA."
  (mapcar (lambda (pipeline)
            (cons (gitlab-data-id-string
                   (gitlab-data-field "id" pipeline))
                  pipeline))
          data))

(defun gitlab-pipeline--entries (data)
  "Return `tabulated-list-entries' for pipeline DATA."
  (mapcar
   (lambda (pipeline)
     (let* ((id (gitlab-data-id-string
                 (gitlab-data-field "id" pipeline)))
            (status (gitlab-data-field-string "status" pipeline))
            (ref (gitlab-data-field-string "ref" pipeline))
            (source (gitlab-data-field-string "source" pipeline))
            (updated (gitlab-list--date-cell
                      (gitlab-data-field "updated_at" pipeline))))
       (list id
             (vector
              (gitlab-list--id-cell id 'gitlab-pipeline-id)
              (propertize status 'face (or (gitlab--status-face status)
                                           'default))
              ref
              source
              updated))))
   data))

(defun gitlab-pipeline--fetch-list (success error)
  "Fetch the pipeline list for the current list buffer.
Call SUCCESS with the decoded array, or ERROR with a condition."
  (gitlab-pipeline-list-async success error gitlab-list--arguments))

(define-derived-mode gitlab-pipeline-list-mode gitlab-list-mode
  "GitLab Pipelines"
  "Display the CI pipelines of the current project.
The table columns are ID, Status, Ref, Source and Updated.  RET
opens the pipeline at point; c copies its ID and w opens its web
page."
  :group 'gitlab
  (setq-local tabulated-list-format gitlab-pipeline-list-format)
  (setq-local tabulated-list-sort-key '("Updated" . t))
  (setq-local gitlab-list--kind 'pipeline)
  (setq-local gitlab-list--fetch-function #'gitlab-pipeline--fetch-list)
  (setq-local gitlab-list--entries-function #'gitlab-pipeline--entries)
  (setq-local gitlab-list--rows-function #'gitlab-pipeline--rows)
  (setq-local gitlab-list--open-function #'gitlab-display-pipeline))

;;;###autoload
(defun gitlab-list-pipelines (&optional arguments)
  "Display the CI pipelines of the current project.
ARGUMENTS holds extra glab flags.  Interactively, a prefix
argument reads them.  The default flags come from
`gitlab-pipeline-list-arguments'.  A directory without a project
context prompts for the project, because neither a Git remote nor
`gitlab-repository' names one."
  (interactive
   (list (when current-prefix-arg
           (split-string-and-unquote
            (read-string "Extra glab arguments: ")))))
  (let ((arguments (or arguments gitlab-pipeline-list-arguments))
        (repository (unless (gitlab-git-context)
                      (gitlab-read-repository))))
    (let ((gitlab-repository (or repository gitlab-repository)))
      (gitlab-list--show
       gitlab-pipeline-list-buffer-name
       #'gitlab-pipeline-list-mode
       (lambda ()
         (setq-local gitlab-list--arguments arguments))))))

;;; Pipeline detail

(defun gitlab-pipeline--fetch (pipeline-id success error)
  "Fetch pipeline PIPELINE-ID for the current detail buffer.
Call SUCCESS with the decoded answer, or ERROR with a condition."
  (gitlab-pipeline-show-async pipeline-id success error))

(defun gitlab-pipeline--fields (data)
  "Return the pipeline detail field order of DATA without jobs."
  (delq 'jobs (mapcar #'car data)))

(defun gitlab-pipeline--render (pipeline-id data)
  "Render pipeline PIPELINE-ID with DATA in the current buffer."
  (let ((job-id (get-text-property (point) 'gitlab-job-id))
        (field (gitlab--field-at-point))
        (status (gitlab-data-field-string "status" data)))
    (gitlab--render-fields
     (format "Pipeline #%s %s" pipeline-id status)
     data
     (gitlab-pipeline--fields data))
    (let ((inhibit-read-only t))
      (gitlab-pipeline--insert-jobs data))
    (cond
     (job-id (gitlab-pipeline--goto-job job-id))
     (field (gitlab--goto-field field))
     (t (goto-char (point-min))))))

(defun gitlab-pipeline--insert-jobs (data)
  "Insert the jobs table of pipeline DATA at the end of the buffer."
  (goto-char (point-max))
  (insert "\n" (propertize "Jobs" 'face 'gitlab-title) "\n\n")
  (let ((jobs (gitlab-data-field "jobs" data)))
    (if (null jobs)
        (insert "No jobs.\n")
      (let* ((name-width (max 12 gitlab-pipeline-job-name-width))
             (header (format (format "%%-12s %%-12s %%-%ds %%-12s %%14s\n"
                                     name-width)
                             "Status" "Stage" "Name"
                             "Duration" "ID")))
        (insert (propertize header 'face 'gitlab-table-header))
        (dolist (job jobs)
          (gitlab-pipeline--insert-job job name-width))))))

(defun gitlab-pipeline--insert-job (job name-width)
  "Insert one JOB row with NAME-WIDTH for the name column."
  (let* ((id (gitlab-data-id-string (gitlab-data-field "id" job)))
         (status (gitlab-data-field-string "status" job))
         (stage (gitlab-data-field-string "stage" job))
         (name (gitlab-data-field-string "name" job))
         (duration (gitlab--format-duration
                    (gitlab-data-field "duration" job)))
         (status-cell (propertize (format "%-12s" status)
                                  'face (or (gitlab--status-face status)
                                            'default)))
         (line (format (format "%%s %%-12s %%-%ds %%-12s %%14s\n"
                               name-width)
                       status-cell stage name duration id)))
    (insert (propertize line
                        'gitlab-job-id id
                        'gitlab-job-name name
                        'mouse-face 'highlight
                        'help-echo (format "Job %s (%s)" name id)))))

(defun gitlab-pipeline--children ()
  "Return the job rows of the current pipeline buffer in display order.
Every entry is a cons of the job ID and the job name.  The jobs
array of the pipeline answer fixes that order, so the table and the
sibling commands never disagree."
  (save-excursion
    (goto-char (point-min))
    (let (entries)
      (while (not (eobp))
        (when-let* ((id (get-text-property (point) 'gitlab-job-id)))
          (push (cons id (get-text-property (point) 'gitlab-job-name))
                entries))
        (forward-line 1))
      (nreverse entries))))

(defun gitlab-pipeline--goto-job (job-id)
  "Move point to the row of JOB-ID."
  (gitlab--goto-property 'gitlab-job-id job-id))

(defun gitlab-pipeline-job-id-at-point ()
  "Return the job ID at point in a pipeline buffer, or nil."
  (get-text-property (point) 'gitlab-job-id))

(defun gitlab-pipeline-open-job-at-point ()
  "Open the job log of the job at point."
  (interactive)
  (let ((id (gitlab-pipeline-job-id-at-point))
        (name (get-text-property (point) 'gitlab-job-name)))
    (if id
        (gitlab-display-job-log id name gitlab--id)
      (user-error "No job at point"))))

(define-derived-mode gitlab-pipeline-mode gitlab-detail-mode
  "GitLab Pipeline"
  "Display one GitLab CI pipeline.
The pipeline fields occupy the top of the buffer and the jobs
table the bottom.  RET on a job opens its log.  `g' refreshes the
pipeline and its jobs."
  :group 'gitlab
  (setq-local gitlab--kind 'pipeline)
  (setq-local gitlab--label "GitLab pipeline")
  (setq-local gitlab--parent-function #'gitlab-list-pipelines)
  (setq-local gitlab--parent-identity-function
              (lambda () (list #'gitlab-pipeline-list-mode nil)))
  (setq-local gitlab--parent-label "pipeline list")
  (setq-local gitlab--children-function #'gitlab-pipeline--children)
  (setq-local gitlab--sibling-open-function
              (lambda (id _name) (gitlab-display-pipeline id)))
  (setq-local gitlab--fetch-function #'gitlab-pipeline--fetch)
  (setq-local gitlab--render-function #'gitlab-pipeline--render))

(define-key gitlab-pipeline-mode-map (kbd "C-c C-j")
  #'gitlab-pipeline-open-job-at-point)

(defun gitlab-pipeline--buffer-name (pipeline-id &optional context)
  "Return the detail buffer name for PIPELINE-ID.
CONTEXT is the project identity of the display buffer, nil when the
project is unknown."
  (if context
      (format "*GitLab Pipeline %s#%s*" context pipeline-id)
    (format "*GitLab Pipeline #%s*" pipeline-id)))

;;;###autoload
(defun gitlab-display-pipeline (pipeline-id)
  "Display the pipeline with PIPELINE-ID in its own buffer.
The buffer belongs to the project of the current directory or to
the set `gitlab-repository', so a pipeline of another project opens
in its own buffer."
  (interactive (list (gitlab-read-pipeline-id)))
  (let ((id (gitlab-data-id-string pipeline-id)))
    (gitlab--show-detail #'gitlab-pipeline--buffer-name
                         #'gitlab-pipeline-mode
                         id)))

;;; Job log

(defcustom gitlab-job-log-show-timestamps t
  "Whether the job log shows the prefix of a trace line.
GitLab writes an ISO 8601 timestamp in front of every line when
the job enables runner timestamps.  A stream identifier such as
00O, 01O, 01E or 00O+ follows the timestamp.  A nil value hides
the timestamp, the identifier and the space before the text,
without dropping the received text, so
`gitlab-job-log-toggle-timestamps' shows the prefix again."
  :type 'boolean
  :group 'gitlab)

(defcustom gitlab-job-log-show-region-duration t
  "Whether the job log shows the duration of the active region.
When a region is active, the mode line shows the number of trace
lines that carry a timestamp and the time between the first and the
last of them.  The section sits on the right edge of the mode line
and disappears while no region is active."
  :type 'boolean
  :group 'gitlab)

(defvar-local gitlab-job-log--process nil
  "Streaming trace process of the current job log buffer.")

(defvar-local gitlab-job-log--name nil
  "Human name of the job in the current job log buffer.")

(defvar-local gitlab-job-log--pipeline-id nil
  "ID of the pipeline that holds the job of the current job log.
A job log opened from a pipeline buffer or restored from a
bookmark knows its pipeline.  A nil value asks GitLab once, in
`gitlab-job-log-pipeline-id'.")

(defvar-local gitlab-job-log--finished nil
  "Non-nil when the trace process of the current buffer finished.")

(defvar-local gitlab-job-log--pending nil
  "Tail of the trace that waits for the end of its line.
A process filter receives arbitrary chunks, so an incomplete line
stays here until the next chunk or until the process ends.")

(defvar-local gitlab-job-log--banner t
  "Non-nil while the buffer holds no line of the trace itself.
The empty lines before the first trace line belong to the banner
of glab and never reach the buffer.")

(defvar-local gitlab-job-log--mode-line-base nil
  "Mode line format of the job log buffer without the region section.
`gitlab-job-log--update-mode-line' appends the section to this list.")

(defvar-local gitlab-job-log--mode-line-cache ""
  "Region section of the mode line, as last installed.
An unchanged string never rebuilds `mode-line-format'.")

(defvar-local gitlab-job-log--mode-line-region nil
  "Region state that `gitlab-job-log--mode-line-cache' was built from.
`gitlab-job-log--mode-line-maybe-update' compares it against the
current state.")

(defconst gitlab-job-log--banner-regexps
  '("\\`Getting job trace\\.\\.\\.\\'"
    "\\`Showing logs for .+ job #[0-9]+\\.\\'")
  "Lines that `glab ci trace' writes before the trace itself.
The command prints them on every run, so the buffer drops them.")

(defconst gitlab-job-log--timestamp-regexp
  (concat "\\(?:\\r\\)?"
          "\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}"
          "T[0-9]\\{2\\}:[0-9]\\{2\\}:[0-9]\\{2\\}"
          "\\(?:\\.[0-9]+\\)?Z\\)[ \t]")
  "Regexp that matches the timestamp prefix of a trace line.
GitLab prefixes a line with an ISO 8601 timestamp and a stream
identifier such as 00O.  Group 1 is the timestamp.")

(defconst gitlab-job-log--stream-regexp
  "[ \t]+\\([0-9][0-9][A-Z]\\+?\\)[ \t]?"
  "Regexp that matches the stream identifier after a timestamp.
GitLab writes 00O for the runner, 01O for the standard output,
01E for the standard error and 00O+ for the boundary of a
section.  Group 1 is the identifier.")

(defconst gitlab-job-log--section-regexp
  (concat "section_\\(start\\|end\\):\\([0-9]+\\):"
          "\\([[:alnum:]_.-]+\\)\\(?:\\[[^]\n]*\\]\\)?")
  "Regexp that matches a section marker of a job trace.
GitLab writes section_start:UNIX:NAME[collapsed=true] before a
section and section_end:UNIX:NAME after it.  Group 1 holds start
or end, group 2 the UNIX time and group 3 the name.")

(defconst gitlab-job-log--section-heading-regexp
  "^.*section_start:[0-9]+:"
  "Regexp that matches the heading line of a section.
The line starts with the timestamp prefix of the trace, so the
regexp looks for the marker anywhere before the end of the line.")

(defvar-local gitlab-job-log--sections nil
  "Open sections of the current job log, innermost first.
Each entry holds the section name, a marker at the start of its
marker line, a marker at the start of the marker text, a marker
at the end of the marker text and the UNIX time of the marker.")

(put 'gitlab-job-log--sections 'permanent-local t)

(defvar-local gitlab-job-log--collapsed nil
  "Names of the sections that the current buffer keeps folded.
A restart of the trace erases the buffer, so the list holds the
folds of the old text and the helper applies them again.  The
value stays in the buffer and never reaches a file.")

(put 'gitlab-job-log--collapsed 'permanent-local t)

(defun gitlab-job-log--kill ()
  "Delete the streaming process of the current job log buffer."
  (when (processp gitlab-job-log--process)
    (delete-process gitlab-job-log--process))
  (setq gitlab-job-log--process nil))

(put 'gitlab-job-log--kill 'permanent-local-hook t)

(defun gitlab-job-log--set-header (text &optional face)
  "Set the header line of the current buffer to TEXT with FACE."
  (setq-local header-line-format
              (propertize (format " %s" text) 'face face)))

(defun gitlab-job-log--banner-line-p (line)
  "Return non-nil when LINE is a line of the banner of glab."
  (cl-some (lambda (regexp) (string-match-p regexp line))
           gitlab-job-log--banner-regexps))

(defun gitlab-job-log--prefix-end (timestamp-end)
  "Return the end of the trace prefix that starts with a timestamp.
TIMESTAMP-END bounds the timestamp itself.  A stream identifier
such as 00O, 01O, 01E or 00O+ follows the timestamp.  Without an
identifier the prefix holds the one separator that the timestamp
regexp consumed, so the text of the line starts at column 0.  The
helper keeps every further space, because such a space belongs to
the text."
  (save-excursion
    (goto-char timestamp-end)
    (if (looking-at gitlab-job-log--stream-regexp)
        (match-end 0)
      (1+ timestamp-end))))

(defun gitlab-job-log--apply-timestamps (start end)
  "Apply the timestamp option to the lines between START and END.
The helper marks the prefix of each trace line, the timestamp and
the stream identifier, with the text property
`gitlab-job-log-timestamp' and hides it when
`gitlab-job-log-show-timestamps' is nil.  A hidden end marker
stays hidden, because the option says nothing about it."
  (save-excursion
    (let ((inhibit-read-only t))
      (goto-char start)
      (while (< (point) end)
        (unless (get-text-property (point) 'gitlab-job-log-section-end)
          (when (looking-at gitlab-job-log--timestamp-regexp)
            (let ((prefix (match-beginning 1))
                  (prefix-end (gitlab-job-log--prefix-end (match-end 1))))
              (add-text-properties prefix prefix-end
                                   '(gitlab-job-log-timestamp t))
              (if gitlab-job-log-show-timestamps
                  (remove-list-of-text-properties prefix prefix-end
                                                  '(display))
                (put-text-property prefix prefix-end 'display "")))))
        (forward-line 1)))))

(defun gitlab-job-log--delete-trailing-carriage-returns (start)
  "Delete the carriage returns at the end of the line at START.
GitLab ends a trace line with `\\r\\e[0K', which overwrites the
line on a terminal.  The ANSI conversion drops the escape
sequence, and the log keeps whole lines, so the carriage return
would only show as ^M."
  (save-excursion
    (goto-char start)
    (end-of-line)
    (let ((inhibit-read-only t))
      (while (eq (char-before) ?\r)
        (delete-char -1)))))

(defun gitlab-job-log--insert-line (line)
  "Insert one complete LINE of trace output into the current buffer.
The helper drops the banner of glab and, according to
`gitlab-job-log-show-timestamps', the prefix of the line.  It
removes the trailing carriage return of the redraw sequence.  A
section marker becomes its header line, and new output reopens a
section that a fold closed."
  (unless (or (gitlab-job-log--banner-line-p line)
              (and gitlab-job-log--banner (string-blank-p line)))
    (setq gitlab-job-log--banner nil)
    (let ((start (gitlab-cli--insert-chunk (concat line "\n"))))
      (gitlab-job-log--delete-trailing-carriage-returns start)
      ;; Inserted text inherits properties from the line above, which
      ;; may hide a folded section or the text of an end marker.
      (let ((inhibit-read-only t))
        (remove-list-of-text-properties
         start (point-max)
         '(invisible display gitlab-job-log-section-start
           gitlab-job-log-section-name gitlab-job-log-section-duration
           gitlab-job-log-section-end)))
      (gitlab-job-log--apply-timestamps start (point-max))
      (unless (gitlab-job-log--apply-section start (point-max))
        (gitlab-job-log--reveal-open-section))
      (set-buffer-modified-p nil))))

(defun gitlab-job-log--section-header (name &optional duration)
  "Return the header text of the section NAME.
DURATION counts the seconds between the start marker and the end
marker.  A section without an end marker shows no duration."
  (if duration
      (format "── %s (%s) ── " name
              (gitlab-job-log--duration-string duration))
    (format "── %s ── " name)))

(defun gitlab-job-log--show-section-header (start end name &optional duration)
  "Show the header of the marker text between START and END.
NAME is the section name and DURATION the optional number of
seconds between the start marker and the end marker."
  (let ((inhibit-read-only t))
    (put-text-property
     start end 'display
     (propertize (gitlab-job-log--section-header name duration)
                 'face 'gitlab-title))))

(defun gitlab-job-log--marker-start (position floor)
  "Return the start of the section marker that ends at POSITION.
GitLab writes a carriage return before the marker and glab may pass
an escape sequence through, so the header covers both.  Stop at
FLOOR."
  (save-excursion
    (goto-char position)
    (while (and (> (point) floor) (memq (char-before) '(?\r ?\e)))
      (backward-char 1))
    (point)))

(defun gitlab-job-log--marker-end (position limit)
  "Return the end of the section marker that starts at POSITION.
GitLab writes a carriage return after the marker and glab may pass
an escape sequence through, so the header covers both.  LIMIT
bounds the search."
  (save-excursion
    (goto-char position)
    (while (and (< (point) limit) (memq (char-after) '(?\r ?\e)))
      (forward-char 1))
    (point)))

(defun gitlab-job-log--hide-section (position)
  "Hide the body of the section whose heading line starts at POSITION.
Do nothing when the line at POSITION is no heading line."
  (save-excursion
    (goto-char position)
    (when (looking-at outline-regexp)
      (let ((inhibit-read-only t))
        (outline-hide-subtree)))))

(defun gitlab-job-log--reveal-open-section ()
  "Show the section that the trace writes into.
A folded section opens again when new output arrives, so a live
trace never hides behind a fold."
  (when-let* ((entry (car gitlab-job-log--sections))
              (line-start (marker-position (nth 1 entry))))
    (save-excursion
      (goto-char line-start)
      (when (and (looking-at outline-regexp)
                 (outline-invisible-p (line-end-position)))
        (let ((inhibit-read-only t))
          (outline-show-subtree))))))

(defun gitlab-job-log--push-section (line-start marker-start marker-end
                                                name time)
  "Record the open section of the line at LINE-START.
MARKER-START and MARKER-END bound the marker text, NAME is the
section name and TIME the UNIX time of the marker.  The name
becomes a text property of the marker, so the imenu index and the
fold record read it without a search of the buffer text."
  (push (list name (copy-marker line-start) (copy-marker marker-start)
              (copy-marker marker-end) time)
        gitlab-job-log--sections)
  (gitlab-job-log--show-section-header marker-start marker-end name)
  (let ((inhibit-read-only t))
    (add-text-properties line-start marker-end
                         (list 'gitlab-job-log-section-start t
                               'gitlab-job-log-section-name name))))

(defun gitlab-job-log--take-section (name)
  "Remove the open section NAME from the stack and return its entry.
A section that opened after NAME and never closed goes too, so a
missing end marker never breaks the stack."
  (when-let* ((entry (assoc name gitlab-job-log--sections)))
    (setq gitlab-job-log--sections
          (cdr (memq entry gitlab-job-log--sections)))
    entry))

(defun gitlab-job-log--close-section (line-start name time)
  "Close the section of the marker line that starts at LINE-START.
NAME is the section name and TIME the UNIX time of the end marker.
The helper fills the duration of the header and hides the marker
text.  The marker joins the line above instead of keeping a line
of its own, because a hidden newline inside a folded section makes
Emacs draw the header of the next section on the same line.  The
helper folds the section again when the buffer recorded it as
folded."
  (let* ((entry (gitlab-job-log--take-section name))
         (line-end (save-excursion (goto-char line-start)
                                   (line-end-position)))
         (join (> line-start (point-min))))
    (let ((inhibit-read-only t))
      ;; A marker line at the start of the buffer has no line above, so
      ;; it hides together with its newline.
      (add-text-properties line-start
                           (if join line-end
                             (min (point-max) (1+ line-end)))
                           '(display "" gitlab-job-log-section-end t))
      (when join
        (delete-region (1- line-start) line-start)))
    (when entry
      (gitlab-job-log--show-section-header
       (marker-position (nth 2 entry))
       (marker-position (nth 3 entry))
       name
       (max 0 (- time (nth 4 entry))))
      ;; A later imenu entry reads the duration of the closed section.
      (let ((inhibit-read-only t))
        (put-text-property (marker-position (nth 1 entry))
                           (marker-position (nth 3 entry))
                           'gitlab-job-log-section-duration
                           (max 0 (- time (nth 4 entry)))))
      (when (member name gitlab-job-log--collapsed)
        (gitlab-job-log--hide-section (marker-position (nth 1 entry)))))))

(defun gitlab-job-log--delete-carriage-returns (start end)
  "Delete the carriage returns between START and END.
GitLab ends a line with `\\r\\e[0K', which a terminal uses to
overwrite the line.  The log keeps whole lines, so the ANSI
conversion drops the escape sequence and leaves a carriage
return that a reader sees as ^M."
  (save-excursion
    (goto-char start)
    (let ((inhibit-read-only t)
          (limit (copy-marker end)))
      (unwind-protect
          (while (search-forward "\r" limit t)
            (delete-char -1))
        (set-marker limit nil)))))

(defun gitlab-job-log--apply-section (start end)
  "Handle the section marker of the line between START and END.
Return non-nil when the line holds a marker.  The helper reads the
marker before the carriage returns of the line go, because a
carriage return ends the name of a marker and keeps the message
that follows it out of the name.  The marker line then loses its
carriage returns, so neither a header nor an end marker keeps the
^M of the redraw sequence."
  (save-excursion
    (goto-char start)
    (when (re-search-forward gitlab-job-log--section-regexp end t)
      (let* ((line-start (line-beginning-position))
             (line-end (copy-marker (line-end-position)))
             (kind (match-string-no-properties 1))
             (time (string-to-number (match-string-no-properties 2)))
             (name (match-string-no-properties 3))
             (marker-start (copy-marker
                            (gitlab-job-log--marker-start
                             (match-beginning 0) start)))
             (marker-end (copy-marker
                          (gitlab-job-log--marker-end
                           (match-end 0) line-end))))
        (unwind-protect
            (progn
              (gitlab-job-log--delete-carriage-returns line-start line-end)
              (if (string= kind "start")
                  (gitlab-job-log--push-section line-start marker-start
                                                marker-end name time)
                (gitlab-job-log--close-section line-start name time))
              t)
          (set-marker marker-start nil)
          (set-marker marker-end nil)
          (set-marker line-end nil))))))

(defun gitlab-job-log--replaced-p (position string)
  "Return non-nil when a copy leaves out POSITION of STRING.
The log replaces a hidden timestamp prefix, the text of a section
marker and the text of an end marker with text properties, so a copy
matches what the buffer shows."
  (or (stringp (get-text-property position 'display string))
      (get-text-property position 'gitlab-job-log-section-start string)
      (get-text-property position 'gitlab-job-log-section-end string)))

(defun gitlab-job-log--replaced-ranges (string)
  "Return the ranges of STRING that a copy leaves out.
The ranges come in order and never overlap."
  (let ((length (length string))
        (position 0)
        ranges)
    (while (< position length)
      (let ((next (min (next-single-property-change
                        position 'display string length)
                       (next-single-property-change
                        position 'gitlab-job-log-section-start
                        string length)
                       (next-single-property-change
                        position 'gitlab-job-log-section-end
                        string length))))
        (when (gitlab-job-log--replaced-p position string)
          (push (cons position next) ranges))
        (setq position next)))
    (nreverse ranges)))

(defun gitlab-job-log--strip-replaced (string)
  "Return STRING without the text that a copy leaves out.
A line that keeps no text keeps no newline either, so a hidden end
marker or the header of a section never leaves an empty line
behind."
  (let* ((length (length string))
         (keep (make-vector length t)))
    (dolist (range (gitlab-job-log--replaced-ranges string))
      (let ((index (car range)))
        (while (< index (cdr range))
          (aset keep index nil)
          (setq index (1+ index)))))
    (let ((line-start 0))
      (while (< line-start length)
        (let* ((newline (string-search "\n" string line-start))
               (line-end (or newline length))
               (kept nil)
               (dropped nil)
               (index line-start))
          (while (< index line-end)
            (if (aref keep index)
                (setq kept t)
              (setq dropped t))
            (setq index (1+ index)))
          (when (and dropped (not kept) newline)
            (aset keep newline nil))
          (setq line-start (1+ line-end)))))
    (let ((parts nil)
          (position 0))
      (while (< position length)
        (let ((next position))
          (if (aref keep position)
              (progn
                (while (and (< next length) (aref keep next))
                  (setq next (1+ next)))
                (push (substring string position next) parts))
            (while (and (< next length) (not (aref keep next)))
              (setq next (1+ next))))
          (setq position next)))
      (apply #'concat (nreverse parts)))))

(defun gitlab-job-log--filter-buffer-substring (beg end delete)
  "Return the text between BEG and END without the replaced ranges.
DELETE non-nil asks for the deletion of the region, as
`filter-buffer-substring' documents.  A hidden timestamp prefix, a
section header and an end marker leave the copy, so a kill
command never saves text that a reader did not see."
  (let ((string (if delete
                    (delete-and-extract-region beg end)
                  (buffer-substring beg end))))
    (gitlab-job-log--strip-replaced string)))

(defun gitlab-job-log--section-starts ()
  "Return the start of every section marker of the current buffer.
The positions come in buffer order.  The helper reads the text
property `gitlab-job-log-section-start', so a marker that shares a
line with the marker of its neighbour never confuses it."
  (let (starts
        (position (point-min)))
    (save-excursion
      (while (< position (point-max))
        (when (get-text-property position 'gitlab-job-log-section-start)
          (push position starts))
        (setq position (or (next-single-property-change
                            position 'gitlab-job-log-section-start
                            nil (point-max))
                           (point-max)))))
    (nreverse starts)))

(defun gitlab-job-log--collapsed-names ()
  "Return the names of the folded sections of the current buffer.
`gitlab-job-log--start' calls this before it erases the buffer, so
a restart keeps the folds of the old trace."
  (let (names)
    (dolist (position (gitlab-job-log--section-starts))
      (save-excursion
        (goto-char position)
        (when (outline-invisible-p (line-end-position))
          (push (get-text-property position 'gitlab-job-log-section-name)
                names))))
    names))

(defun gitlab-job-log--enclosing-heading ()
  "Return the start of the heading line of the section around point.
Return nil when point sits above the first section."
  (save-excursion
    (beginning-of-line)
    (if (looking-at outline-regexp)
        (point)
      (when (re-search-backward outline-regexp nil t)
        (point)))))

(defun gitlab-job-log-toggle-section ()
  "Fold or unfold the section around point.
The command works on every line of a section, not only on the line
that shows its header, so a reader folds a long step from the
middle of it."
  (interactive)
  (let ((heading (gitlab-job-log--enclosing-heading)))
    (unless heading
      (user-error "No GitLab section at point"))
    (save-excursion
      (goto-char heading)
      (outline-toggle-children))))

(defun gitlab-job-log--imenu-index ()
  "Return an imenu index of the sections of the current job log.
The label holds the section name and, once the end marker arrived,
the duration of the section.  The helper reads both from the text
properties of the start marker, so the index follows a marker that
shares a line with the marker of its neighbour."
  (let (index)
    (dolist (position (gitlab-job-log--section-starts))
      (save-excursion
        (goto-char position)
        (let* ((name (get-text-property position
                                        'gitlab-job-log-section-name))
               (duration (get-text-property
                          position 'gitlab-job-log-section-duration))
               (label (if duration
                          (format "%s (%s)" name
                                  (gitlab-job-log--duration-string duration))
                        name)))
          (push (cons label (line-beginning-position)) index))))
    (nreverse index)))

(defun gitlab-job-log--write (chunk)
  "Write one CHUNK of trace output into the current buffer.
The helper keeps the tail of the previous chunk, so a line that a
chunk cut in two reaches the buffer as one line."
  (let* ((text (concat gitlab-job-log--pending chunk))
         (lines (split-string text "\n"))
         (tail (car (last lines))))
    (setq gitlab-job-log--pending tail)
    (dolist (line (butlast lines))
      (gitlab-job-log--insert-line line))
    (gitlab-job-log--mode-line-maybe-update)))

(defun gitlab-job-log--flush ()
  "Write the incomplete line that waits for its end."
  (let ((line gitlab-job-log--pending))
    (setq gitlab-job-log--pending nil)
    (when (and line (not (string-empty-p line)))
      (gitlab-job-log--insert-line line)))
  (gitlab-job-log--mode-line-maybe-update))

(defun gitlab-job-log--filter (process chunk)
  "Write the output of PROCESS that arrives in CHUNK into its buffer."
  (let ((buffer (process-buffer process)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (gitlab-job-log--write chunk)))))

(defun gitlab-job-log--timestamp-value (timestamp)
  "Return TIMESTAMP as a time value in seconds.
TIMESTAMP has the form that `gitlab-job-log--timestamp-regexp'
matches, so the fields sit at fixed offsets."
  (let ((fraction (if (string-match "\\.\\([0-9]+\\)" timestamp)
                      (string-to-number
                       (concat "0." (match-string 1 timestamp)))
                    0)))
    (float-time
     (encode-time
      (list (+ (string-to-number (substring timestamp 17 19)) fraction)
            (string-to-number (substring timestamp 14 16))
            (string-to-number (substring timestamp 11 13))
            (string-to-number (substring timestamp 8 10))
            (string-to-number (substring timestamp 5 7))
            (string-to-number (substring timestamp 0 4))
            nil t t)))))

(defun gitlab-job-log--line-time ()
  "Return the timestamp at the start of the current line, or nil."
  (when (looking-at gitlab-job-log--timestamp-regexp)
    (gitlab-job-log--timestamp-value (match-string 1))))

(defun gitlab-job-log--region-span ()
  "Return the count and the duration of the active region as a cons.
The count holds the trace lines with a timestamp, and the duration
runs from the first such line to the last.  Return nil without an
active region, with the option off, or with fewer than two stamped
lines.  A line without a timestamp neither starts nor ends the
span."
  (when (and gitlab-job-log-show-region-duration (use-region-p))
    (save-excursion
      (save-restriction
        (widen)
        (let* ((start (progn (goto-char (region-beginning))
                             (line-beginning-position)))
               (end (progn (goto-char (region-end))
                           (line-end-position)))
               (first nil)
               (last nil)
               (count 0))
          (goto-char start)
          (while (and (< (point) end) (not (eobp)))
            (let ((time (gitlab-job-log--line-time)))
              (when time
                (setq count (1+ count))
                (unless first
                  (setq first time))
                (setq last time)))
            (forward-line 1))
          (when (and first last (> count 1))
            (cons count (- last first))))))))

(defun gitlab-job-log--duration-string (seconds)
  "Return SECONDS as a compact duration string.
Keep three decimals, so a short step and a long job both read
exactly.  The form grows by hours and minutes only when needed."
  (let* ((milliseconds (round (* 1000 (max 0 seconds))))
         (millis (% milliseconds 1000))
         (total (/ (- milliseconds millis) 1000))
         (secs (% total 60))
         (total-minutes (/ (- total secs) 60))
         (minutes (% total-minutes 60))
         (hours (/ (- total-minutes minutes) 60)))
    (cond
     ((> hours 0)
      (format "%dh %dm %d.%03ds" hours minutes secs millis))
     ((> minutes 0)
      (format "%dm %d.%03ds" minutes secs millis))
     (t (format "%d.%03ds" secs millis)))))

(defun gitlab-job-log--escape-mode-line (text)
  "Return TEXT with every percent sign doubled.
The mode line reads a percent sign as the start of a substitution."
  (replace-regexp-in-string "%" "%%" text t t))

(defun gitlab-job-log--mode-line-text ()
  "Return the region section of the mode line, or the empty string."
  (let ((span (gitlab-job-log--region-span)))
    (if (null span)
        ""
      (format " [%d in region, %s]"
              (car span)
              (gitlab-job-log--duration-string (cdr span))))))

(defun gitlab-job-log--region-signature ()
  "Return a value that changes when the active region changes.
The mode line reports the region, so point motion inside an active
region and a new trace line both change this value."
  (when (use-region-p)
    (list (region-beginning) (region-end) (buffer-chars-modified-tick))))

(defun gitlab-job-log--update-mode-line ()
  "Rebuild the region section of the mode line and install it.
The section right-aligns, so it sits on the right edge of the mode
line.  The helper rebuilds the format only when the text changes,
because `post-command-hook' runs it after every command."
  (setq gitlab-job-log--mode-line-region
        (gitlab-job-log--region-signature))
  (let ((text (gitlab-job-log--escape-mode-line
               (gitlab-job-log--mode-line-text))))
    (unless (equal text gitlab-job-log--mode-line-cache)
      (setq gitlab-job-log--mode-line-cache text)
      (setq mode-line-format
            (if (string-empty-p text)
                gitlab-job-log--mode-line-base
              (append gitlab-job-log--mode-line-base
                      (list 'mode-line-format-right-align text))))))
  (force-mode-line-update))

(defun gitlab-job-log--mode-line-maybe-update ()
  "Rebuild the region section when the active region changed.
`gitlab-job-log-mode' runs this from `post-command-hook', so a moved
point or a new trace line reaches the mode line without a redraw."
  (unless (equal (gitlab-job-log--region-signature)
                 gitlab-job-log--mode-line-region)
    (gitlab-job-log--update-mode-line)))

(defun gitlab-job-log-toggle-timestamps ()
  "Show or hide the timestamp prefix of every trace line.
The prefix holds the timestamp and the stream identifier, so the
command leaves the text of each line at column 0.  It sets the
buffer-local value of `gitlab-job-log-show-timestamps' and applies
it to the lines that the buffer already holds."
  (interactive)
  (setq-local gitlab-job-log-show-timestamps
              (not gitlab-job-log-show-timestamps))
  (let ((inhibit-read-only t))
    (with-silent-modifications
      (gitlab-job-log--apply-timestamps (point-min) (point-max))))
  (message "Job log prefix %s"
           (if gitlab-job-log-show-timestamps "shown" "hidden")))

(defun gitlab-job-log-pipeline-id ()
  "Return the ID of the pipeline that holds the current job, or nil.
The function prefers `gitlab-job-log--pipeline-id', which the
display command and a bookmark jump fill without a request.  A
nil value asks GitLab once for the details of the job and keeps
the answer, so the parent command works in a log that a bookmark,
an Org link or an xref definition opened."
  (unless gitlab-job-log--pipeline-id
    (setq-local gitlab-job-log--pipeline-id
                (gitlab-job-pipeline-id gitlab--id)))
  gitlab-job-log--pipeline-id)

(defun gitlab-job-log-go-to-parent ()
  "Open the pipeline buffer that holds the current job.
Signal `user-error' when GitLab names no pipeline for the job."
  (interactive)
  (let ((pipeline-id (gitlab-job-log-pipeline-id)))
    (if pipeline-id
        (gitlab-display-pipeline pipeline-id)
      (user-error "No pipeline for job %s" gitlab--id))))

(defun gitlab-job-log-parent-identity ()
  "Return the identity of the pipeline that holds the current job.
The value is the pair of the pipeline detail mode and the pipeline
ID, so the sibling commands find the pipeline buffer by identity."
  (when-let* ((pipeline-id (gitlab-job-log-pipeline-id)))
    (list #'gitlab-pipeline-mode pipeline-id)))

(defun gitlab-job-log-open-sibling (job-id name)
  "Open the log of JOB-ID with NAME in the current pipeline.
The current log passes its pipeline on, so the opened log can walk
up without a request."
  (gitlab-display-job-log job-id name (gitlab-job-log-pipeline-id)))

(defun gitlab-job-log--start ()
  "Clear the current buffer and start the trace process.
The helper reads the folded sections of the old trace first, so a
restart folds the same sections again when their markers arrive."
  (gitlab-job-log--kill)
  (setq-local gitlab-job-log--collapsed (gitlab-job-log--collapsed-names))
  (setq gitlab-job-log--finished nil
        gitlab-job-log--sections nil
        gitlab-job-log--pending nil
        gitlab-job-log--banner t)
  (let ((inhibit-read-only t))
    (erase-buffer))
  (set-buffer-modified-p nil)
  (gitlab-job-log--mode-line-maybe-update)
  (gitlab-job-log--set-header
   (format "Job %s%s - streaming"
           gitlab--id
           (if gitlab-job-log--name
               (format " (%s)" gitlab-job-log--name)
             "")))
  (let ((buffer (current-buffer)))
    (setq gitlab-job-log--process
          (gitlab-job-trace-stream
           gitlab--id
           buffer
           (lambda ()
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (gitlab-job-log--flush)
                 (setq gitlab-job-log--finished t
                       gitlab-job-log--process nil)
                 (gitlab-job-log--set-header
                  (format "Job %s - finished" gitlab--id)
                  'gitlab-status-success))))
           (lambda (error)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (gitlab-job-log--flush)
                 (setq gitlab-job-log--process nil)
                 (gitlab-job-log--set-header
                  (format "Job %s - %s" gitlab--id
                          (gitlab--error-message error))
                  'gitlab-error))))
           #'gitlab-job-log--filter))))

(defun gitlab-job-log-restart (&rest _arguments)
  "Clear the current job log and stream the trace again.
Ignoring ARGUMENTS, because `revert-buffer-function' calls this
function with the two `revert-buffer' arguments."
  (interactive)
  (gitlab-job-log--start))

(defun gitlab-job-log--bookmark-make-record ()
  "Return a bookmark record for the current job log buffer.
The record adds the job name, so the header line of the restored
log names the job, and the pipeline, so the restored log can walk
up to its pipeline without a request.  A job log restarts its
trace on a jump, because a trace streams and has no snapshot."
  (let ((record (gitlab--bookmark-make-record)))
    (cons (car record)
          (append (cdr record)
                  (when gitlab-job-log--name
                    (list (cons 'name gitlab-job-log--name)))
                  (let ((pipeline-id gitlab-job-log--pipeline-id))
                    (when pipeline-id
                      (list (cons 'pipeline pipeline-id))))))))

(define-derived-mode gitlab-job-log-mode special-mode "GitLab Job Log"
  "Display the live trace of one GitLab CI job.
The buffer is read-only and fills while `glab ci trace' runs.  The
banner that glab prints before the trace never reaches the buffer.
g restarts the trace and ~ toggles the timestamp prefix of every
line, which holds the timestamp and the stream identifier.  An
active region adds the number of selected trace lines and
their duration to the right edge of the mode line, when
`gitlab-job-log-show-region-duration' is non-nil.  A section of the
trace shows a header line with its name and duration.  TAB folds
the section around point, S-TAB cycles the whole buffer and imenu
lists the sections.  The parent command opens the pipeline that
holds the job.  Killing the buffer deletes the process.  A copy of
a region leaves out the timestamp prefix while it stays hidden, the
text of a section header and the text of every end marker."
  :group 'gitlab
  (gitlab--use-project-directory)
  (setq-local bookmark-make-record-function
              #'gitlab-job-log--bookmark-make-record)
  (setq-local gitlab--kind 'job)
  (setq-local gitlab--label "GitLab job")
  (setq-local gitlab--parent-function #'gitlab-job-log-go-to-parent)
  (setq-local gitlab--parent-identity-function
              #'gitlab-job-log-parent-identity)
  (setq-local gitlab--parent-label "pipeline")
  (setq-local gitlab--sibling-open-function
              #'gitlab-job-log-open-sibling)
  (setq-local buffer-stale-function nil)
  (setq-local revert-buffer-function #'gitlab-job-log-restart)
  (setq-local filter-buffer-substring-function
              #'gitlab-job-log--filter-buffer-substring)
  (setq-local truncate-lines t)
  (setq-local imenu-create-index-function #'gitlab-job-log--imenu-index)
  (setq-local outline-regexp gitlab-job-log--section-heading-regexp)
  (outline-minor-mode 1)
  ;; The mode line of a log already carries the region section, so the
  ;; outline lighter stays out of it.
  (setq-local minor-mode-alist (cons '(outline-minor-mode "")
                                     minor-mode-alist))
  (setq-local gitlab-job-log--mode-line-base
              (default-value 'mode-line-format))
  (setq-local gitlab-job-log--mode-line-cache "")
  (setq-local gitlab-job-log--mode-line-region nil)
  (setq-local mode-line-format gitlab-job-log--mode-line-base)
  (add-hook 'post-command-hook #'gitlab-job-log--mode-line-maybe-update nil t)
  (add-hook 'kill-buffer-hook #'gitlab-job-log--kill nil t))

(define-key gitlab-job-log-mode-map (kbd "TAB")
  #'gitlab-job-log-toggle-section)
(define-key gitlab-job-log-mode-map (kbd "~")
  #'gitlab-job-log-toggle-timestamps)
(define-key gitlab-job-log-mode-map (kbd "C-c C-n") #'gitlab-next-sibling)
(define-key gitlab-job-log-mode-map (kbd "C-c C-p")
  #'gitlab-previous-sibling)
(define-key gitlab-job-log-mode-map [mouse-9] #'gitlab-next-sibling)
(define-key gitlab-job-log-mode-map [mouse-8] #'gitlab-previous-sibling)
(define-key gitlab-job-log-mode-map [remap dired-jump] #'gitlab-go-to-parent)
(define-key gitlab-job-log-mode-map [remap dired-up-directory]
  #'gitlab-go-to-parent)

(defun gitlab-pipeline--job-log-buffer-name (job-id context)
  "Return the job log buffer name of JOB-ID in CONTEXT."
  (if context
      (format "*GitLab Job %s&%s*" context job-id)
    (format "*GitLab Job %s*" job-id)))

(defun gitlab-pipeline--prepare-job-log (job-id &optional name pipeline-id)
  "Prepare the job log buffer of JOB-ID and return it.
NAME is the optional job name for the header line.  PIPELINE-ID is
the optional ID of the pipeline that holds the job, so the parent
command costs no request.  The function captures the directory in
which glab must run, starts `glab ci trace JOB-ID' and does not
display the buffer.  An open job log of the same job and project
wins, whatever its current name is."
  (let* ((directory (gitlab-cli-directory-of))
         (repository (gitlab-cli-repository-normalize gitlab-repository))
         (context (gitlab-git-context directory))
         (id (gitlab-data-id-string job-id))
         (pipeline (and pipeline-id (gitlab-data-id-string pipeline-id)))
         (buffer (or (gitlab--identity-buffer
                      #'gitlab-job-log-mode id context)
                     (get-buffer-create
                      (generate-new-buffer-name
                       (gitlab-pipeline--job-log-buffer-name id context))))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (processp gitlab-job-log--process)
          (delete-process gitlab-job-log--process))))
    (with-current-buffer buffer
      (gitlab-job-log-mode)
      (gitlab--use-project-directory directory repository)
      (setq-local gitlab--id id)
      (setq-local gitlab--identity (list #'gitlab-job-log-mode id gitlab--context))
      (setq-local gitlab-job-log--name name)
      (setq-local gitlab-job-log--pipeline-id pipeline)
      (gitlab--update-list-buffers-directory)
      (gitlab-job-log--start))
    buffer))

;;;###autoload
(defun gitlab-display-job-log (job-id &optional name pipeline-id)
  "Display the live log of JOB-ID in its own buffer.
NAME is the optional job name for the header line.  PIPELINE-ID is
the optional ID of the pipeline that holds the job.  The command
starts `glab ci trace JOB-ID' and returns immediately."
  (interactive (list (gitlab-read-job-id)))
  (pop-to-buffer (gitlab-pipeline--prepare-job-log job-id name pipeline-id)))

(provide 'gitlab-pipeline)

;;; gitlab-pipeline.el ends here
