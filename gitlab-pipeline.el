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
;; property, so a toggle never asks GitLab again.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'gitlab-data)
(require 'gitlab-mode)

(declare-function gitlab-read-pipeline-id "gitlab-read" (&optional prompt))
(declare-function gitlab-read-job-id "gitlab-read" (&optional prompt))
(declare-function gitlab-cli--insert-chunk "gitlab-cli" (text))

(defcustom gitlab-pipeline-list-buffer-name "*GitLab Pipelines*"
  "Buffer name of the pipeline list."
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
`gitlab-pipeline-list-arguments'."
  (interactive
   (list (when current-prefix-arg
           (split-string-and-unquote
            (read-string "Extra glab arguments: ")))))
  (let ((arguments (or arguments gitlab-pipeline-list-arguments)))
    (gitlab-list--show
     gitlab-pipeline-list-buffer-name
     #'gitlab-pipeline-list-mode
     (lambda ()
       (setq-local gitlab-list--arguments arguments)))))

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

(defun gitlab-pipeline--goto-job (job-id)
  "Move point to the row of JOB-ID."
  (goto-char (point-min))
  (let ((found nil))
    (while (and (not found) (not (eobp)))
      (when (equal (get-text-property (point) 'gitlab-job-id) job-id)
        (setq found t))
      (unless found (forward-line 1)))
    (when found (beginning-of-line))))

(defun gitlab-pipeline-job-id-at-point ()
  "Return the job ID at point in a pipeline buffer, or nil."
  (get-text-property (point) 'gitlab-job-id))

(defun gitlab-pipeline-open-job-at-point ()
  "Open the job log of the job at point."
  (interactive)
  (let ((id (gitlab-pipeline-job-id-at-point))
        (name (get-text-property (point) 'gitlab-job-name)))
    (if id
        (gitlab-display-job-log id name)
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
  (setq-local gitlab--fetch-function #'gitlab-pipeline--fetch)
  (setq-local gitlab--render-function #'gitlab-pipeline--render))

(define-key gitlab-pipeline-mode-map (kbd "C-c C-j")
  #'gitlab-pipeline-open-job-at-point)

(defun gitlab-pipeline--buffer-name (pipeline-id)
  "Return the detail buffer name for PIPELINE-ID."
  (if gitlab-repository
      (format "*GitLab Pipeline %s#%s*" gitlab-repository pipeline-id)
    (format "*GitLab Pipeline #%s*" pipeline-id)))

;;;###autoload
(defun gitlab-display-pipeline (pipeline-id)
  "Display the pipeline with PIPELINE-ID in its own buffer."
  (interactive (list (gitlab-read-pipeline-id)))
  (let ((id (gitlab-data-id-string pipeline-id)))
    (gitlab--show-detail (gitlab-pipeline--buffer-name id)
                         #'gitlab-pipeline-mode
                         id)))

;;; Job log

(defcustom gitlab-job-log-show-timestamps t
  "Whether the job log shows the timestamp prefix of a trace line.
GitLab writes an ISO 8601 timestamp in front of every line when
the job enables runner timestamps.  A nil value hides the prefix
without dropping the received text, so
`gitlab-job-log-toggle-timestamps' shows it again."
  :type 'boolean
  :group 'gitlab)

(defvar-local gitlab-job-log--process nil
  "Streaming trace process of the current job log buffer.")

(defvar-local gitlab-job-log--name nil
  "Human name of the job in the current job log buffer.")

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

(defun gitlab-job-log--apply-timestamps (start end)
  "Apply the timestamp option to the lines between START and END.
The helper marks the timestamp of each line with the text
property `gitlab-job-log-timestamp' and hides it when
`gitlab-job-log-show-timestamps' is nil."
  (save-excursion
    (let ((inhibit-read-only t))
      (goto-char start)
      (while (< (point) end)
        (when (looking-at gitlab-job-log--timestamp-regexp)
          (let ((prefix (match-beginning 1))
                (prefix-end (match-end 1)))
            (add-text-properties prefix prefix-end
                                 '(gitlab-job-log-timestamp t))
            (if gitlab-job-log-show-timestamps
                (remove-list-of-text-properties prefix prefix-end
                                                '(display))
              (put-text-property prefix prefix-end 'display ""))))
        (forward-line 1)))))

(defun gitlab-job-log--insert-line (line)
  "Insert one complete LINE of trace output into the current buffer.
The helper drops the banner of glab and, according to
`gitlab-job-log-show-timestamps', the timestamp of the line."
  (unless (or (gitlab-job-log--banner-line-p line)
              (and gitlab-job-log--banner (string-blank-p line)))
    (setq gitlab-job-log--banner nil)
    (let ((start (gitlab-cli--insert-chunk (concat line "\n"))))
      (gitlab-job-log--apply-timestamps start (point-max))
      (set-buffer-modified-p nil))))

(defun gitlab-job-log--write (chunk)
  "Write one CHUNK of trace output into the current buffer.
The helper keeps the tail of the previous chunk, so a line that a
chunk cut in two reaches the buffer as one line."
  (let* ((text (concat gitlab-job-log--pending chunk))
         (lines (split-string text "\n"))
         (tail (car (last lines))))
    (setq gitlab-job-log--pending tail)
    (dolist (line (butlast lines))
      (gitlab-job-log--insert-line line))))

(defun gitlab-job-log--flush ()
  "Write the incomplete line that waits for its end."
  (let ((line gitlab-job-log--pending))
    (setq gitlab-job-log--pending nil)
    (when (and line (not (string-empty-p line)))
      (gitlab-job-log--insert-line line))))

(defun gitlab-job-log--filter (process chunk)
  "Write the output of PROCESS that arrives in CHUNK into its buffer."
  (let ((buffer (process-buffer process)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (gitlab-job-log--write chunk)))))

(defun gitlab-job-log-toggle-timestamps ()
  "Show or hide the timestamp prefix of every trace line.
The command sets the buffer-local value of
`gitlab-job-log-show-timestamps' and applies it to the lines that
the buffer already holds."
  (interactive)
  (setq-local gitlab-job-log-show-timestamps
              (not gitlab-job-log-show-timestamps))
  (let ((inhibit-read-only t))
    (with-silent-modifications
      (gitlab-job-log--apply-timestamps (point-min) (point-max))))
  (message "Job log timestamps %s"
           (if gitlab-job-log-show-timestamps "shown" "hidden")))

(defun gitlab-job-log--start ()
  "Clear the current buffer and start the trace process."
  (gitlab-job-log--kill)
  (setq gitlab-job-log--finished nil
        gitlab-job-log--pending nil
        gitlab-job-log--banner t)
  (let ((inhibit-read-only t))
    (erase-buffer))
  (set-buffer-modified-p nil)
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

(define-derived-mode gitlab-job-log-mode special-mode "GitLab Job Log"
  "Display the live trace of one GitLab CI job.
The buffer is read-only and fills while `glab ci trace' runs.  The
banner that glab prints before the trace never reaches the buffer.
g restarts the trace and ~ toggles the timestamp prefix of every
line.  Killing the buffer deletes the process."
  :group 'gitlab
  (gitlab--use-project-directory)
  (setq-local gitlab--kind 'job)
  (setq-local gitlab--label "GitLab job")
  (setq-local buffer-stale-function nil)
  (setq-local revert-buffer-function #'gitlab-job-log-restart)
  (setq-local truncate-lines t)
  (add-hook 'kill-buffer-hook #'gitlab-job-log--kill nil t))

(define-key gitlab-job-log-mode-map (kbd "~") #'gitlab-job-log-toggle-timestamps)

(defun gitlab-pipeline--prepare-job-log (job-id &optional name)
  "Prepare the job log buffer of JOB-ID and return it.
NAME is the optional job name for the header line.  The function
captures the directory in which glab must run, starts `glab ci
trace JOB-ID' and does not display the buffer."
  (let* ((directory (gitlab-cli-directory-of))
         (id (gitlab-data-id-string job-id))
         (buffer (get-buffer-create (format "*GitLab Job %s*" id))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (processp gitlab-job-log--process)
          (delete-process gitlab-job-log--process))))
    (with-current-buffer buffer
      (gitlab-job-log-mode)
      (gitlab--use-project-directory directory)
      (setq-local gitlab--id id)
      (setq-local gitlab-job-log--name name)
      (gitlab-job-log--start))
    buffer))

;;;###autoload
(defun gitlab-display-job-log (job-id &optional name)
  "Display the live log of JOB-ID in its own buffer.
NAME is the optional job name for the header line.  The command
starts `glab ci trace JOB-ID' and returns immediately."
  (interactive (list (gitlab-read-job-id)))
  (pop-to-buffer (gitlab-pipeline--prepare-job-log job-id name)))

(provide 'gitlab-pipeline)

;;; gitlab-pipeline.el ends here
