;;; gitlab-data.el --- GitLab data entry points -*- lexical-binding: t; -*-

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

;; The data layer: one entry point per GitLab resource, synchronous
;; for prompts and tests, asynchronous for display buffers.  No
;; buffer, mode, face or key code lives here, so a consumer can use
;; the data without loading the display layer.
;;
;; The first version reads through the glab command line program.
;; `gitlab-backend' names the transport and accepts `cli' today.  The
;; `api' value reserves the native url.el transport described in the
;; repository bug tracker, so a future backend replaces this file's
;; private CLI functions and the modes stay unchanged.
;;
;; JSON decodes to an alist with symbol keys.  Read a field with
;; `gitlab-data-field'; it never normalizes keys, so raw data keeps
;; the shape that glab prints.  `:false' is JSON false and nil is
;; JSON null.
;;
;; The cache serves prompts, not display buffers.  Display buffers
;; fetch fresh data on every refresh; the cache answers repeated
;; completion requests for `gitlab-cache-ttl' seconds.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'gitlab-cli)
(require 'gitlab-error)

(defcustom gitlab-backend 'cli
  "Transport that the data entry points use.
`cli' runs the glab program.  `api' is reserved for the native
url.el transport and currently signals `gitlab-backend-error'."
  :type '(choice (const :tag "glab command line" cli)
                 (const :tag "Native GitLab API" api))
  :group 'gitlab)

(defcustom gitlab-cache-ttl 60
  "Seconds a cached list stays valid for prompts.
A nil value keeps an entry until `gitlab-cache-clear'.  Display
buffers bypass the cache on purpose."
  :type '(choice (natnum :tag "Seconds") (const :tag "Never expire" nil))
  :group 'gitlab)

(defcustom gitlab-web-base-url "https://gitlab.com"
  "Base URL of the GitLab web interface.
Org links use it to export a web URL when `gitlab-repository' is
set."
  :type 'string
  :group 'gitlab)

(defcustom gitlab-transitional-states
  '("created" "waiting_for_resource" "preparing" "pending" "running"
    "scheduled")
  "Status values that still change without user action.
A display buffer with one of these values polls faster than a
buffer with a final status.  The comparison ignores case."
  :type '(repeat string)
  :group 'gitlab)

;;; Field access

(defun gitlab-data-alist-p (value)
  "Return non-nil when VALUE is a non-empty alist.
A JSON object decodes to an alist with symbol keys.  A JSON array
of objects is a list of alists, not an alist."
  (declare (pure t) (side-effect-free t))
  (and (consp value)
       (consp (car value))
       (not (consp (caar value)))))

(defun gitlab-data-field (name data &optional default)
  "Return field NAME of the decoded JSON object DATA.
NAME is a string or a symbol, compared as a symbol.  Return
DEFAULT when DATA has no such field.  Nested objects stay
alists; call this function again to read them."
  (declare (side-effect-free t))
  (let* ((key (if (symbolp name) name (intern name)))
         (pair (and (consp data) (assq key data))))
    (if pair (cdr pair) default)))

(defun gitlab-data-set-field (name data value)
  "Set field NAME of the decoded JSON object DATA to VALUE.
Return DATA.  A missing field is appended."
  (let* ((key (if (symbolp name) name (intern name)))
         (pair (and (consp data) (assq key data))))
    (if pair
        (setcdr pair value)
      (setq data (nconc data (list (cons key value))))))
  data)

(defun gitlab-data-field-string (name data &optional default)
  "Return field NAME of DATA as a string.
A nil field returns DEFAULT, which defaults to the empty string."
  (declare (side-effect-free t))
  (let ((value (gitlab-data-field name data)))
    (cond
     ((null value) (or default ""))
     ((stringp value) value)
     ((numberp value) (number-to-string value))
     ((eq value :false) "false")
     ((eq value t) "true")
     (t (format "%s" value)))))

(defun gitlab-data-id-string (id)
  "Return ID as a string suitable for a glab argument.
ID is a number, a string or a symbol."
  (declare (pure t) (side-effect-free t))
  (cond
   ((stringp id) id)
   ((numberp id) (number-to-string id))
   (t (format "%s" id))))

;;; Identifiers

(defconst gitlab-data-identifier-signs
  '((merge-request . "!")
    (pipeline . "#")
    (job . "&"))
  "Sigil that separates a repository from the ID of each kind.
A GitLab project path holds letters, digits, dots, hyphens and
underscores only, so a sigil never appears in a path.")

(defun gitlab-data-identifier-sign (kind)
  "Return the sigil of KIND.
KIND is `merge-request', `pipeline' or `job'.  Signal `gitlab-error'
for another value."
  (declare (pure t) (side-effect-free t))
  (or (alist-get kind gitlab-data-identifier-signs)
      (signal 'gitlab-error
              (list (format "Unknown GitLab kind: %S" kind)))))

(defun gitlab-data-identifier (kind id &optional repository)
  "Return the identifier text of KIND and ID in REPOSITORY.
The text reads REPOSITORY<SIGIL>ID, or ID alone without a
repository.  Org links, bookmarks and xref share the form, so one
parser serves all three.  KIND is `merge-request', `pipeline' or
`job'.  A nil ID returns the repository path alone, which names a
collection rather than one object."
  (declare (pure t) (side-effect-free t))
  (let ((id (and id (gitlab-data-id-string id))))
    (cond
     ((or (null id) (string-empty-p id))
      (and repository (string-trim repository "/+" "/+")))
     ((or (null repository) (string-empty-p repository)) id)
     (t (concat (string-trim repository "/+" "/+")
                (gitlab-data-identifier-sign kind)
                id)))))

(defun gitlab-data-identifier-split (kind text)
  "Return a cons of REPOSITORY and ID parsed from KIND and TEXT.
TEXT is an identifier of `gitlab-data-identifier'.  A TEXT without
the sigil of KIND yields ID alone, so an older Org link or
bookmark stays valid; REPOSITORY is nil then.  A TEXT that holds
the sigil in the first position yields an empty repository, which
the caller reads as nil."
  (declare (pure t) (side-effect-free t))
  (let* ((text (string-trim (or text "")))
         (sign (gitlab-data-identifier-sign kind))
         (position (cl-search sign text :from-end t)))
    (cond
     ((null position) (cons nil text))
     ((zerop position) (cons nil (substring text (length sign))))
     (t (cons (substring text 0 position)
              (substring text (+ position (length sign))))))))

;;; Known projects

(defvar gitlab-repositories nil
  "Projects that this session displayed, newest first.
A display buffer adds its own context, so a later repository
prompt offers it.  The value uses the PATH or PATH@HOST spelling of
`gitlab-cli-repository-normalize'.  Set this variable to offer your
own projects from the first prompt of a session.")

(defun gitlab--remember-repository (repository)
  "Add REPOSITORY to the front of `gitlab-repositories'.
Return the normalized value, or nil for an empty REPOSITORY, so a
display command can call this with its own context."
  (let ((repository (gitlab-cli-repository-normalize repository)))
    (when repository
      (setq gitlab-repositories
            (cons repository (delete repository gitlab-repositories))))
    repository))

;;; Cache

(defvar gitlab--cache (make-hash-table :test #'equal)
  "Cached list answers, keyed by resource and arguments.")

(defun gitlab-cache-clear ()
  "Drop every cached list answer."
  (interactive)
  (clrhash gitlab--cache))

(defun gitlab-cache-invalidate (&optional kind)
  "Drop cached answers of KIND, or every answer when KIND is nil.
KIND is `merge-request' or `pipeline'."
  (if kind
      (maphash (lambda (key _value)
                 (when (eq (car key) kind)
                   (remhash key gitlab--cache)))
               gitlab--cache)
    (clrhash gitlab--cache)))

(defun gitlab--cached (key thunk)
  "Return the cached value of KEY, or call THUNK and cache it.
The entry expires after `gitlab-cache-ttl' seconds, unless that
variable is nil."
  (let ((entry (gethash key gitlab--cache)))
    (if (and entry
             (or (null gitlab-cache-ttl)
                 (< (- (float-time) (car entry)) gitlab-cache-ttl)))
        (cdr entry)
      (let ((value (funcall thunk)))
        (puthash key (cons (float-time) value) gitlab--cache)
        value))))

;;; Backend dispatch

(defun gitlab--api-not-implemented ()
  "Signal that the native API backend has no implementation yet."
  (signal 'gitlab-backend-error
          (list "The api backend is not implemented; set gitlab-backend to cli")))

(defmacro gitlab--with-backend (cli-form)
  "Evaluate CLI-FORM for the cli backend, or signal for another one."
  `(pcase gitlab-backend
     ('cli ,cli-form)
     ('api (gitlab--api-not-implemented))
     (_ (signal 'gitlab-backend-error
                (list (format "Unknown gitlab-backend: %S" gitlab-backend))))))

;;; Writes

(defun gitlab--write (arguments)
  "Run the write request ARGUMENTS and return the text answer.
ARGUMENTS holds the glab arguments of a command that changes an
object, such as an approval or a merge.  Every write goes through
this function and its asynchronous form, so one place holds the
PARSE value and one place reports the condition."
  (gitlab--with-backend
   (gitlab-cli-request arguments 'text)))

(defun gitlab--write-async (arguments success error)
  "Run the write request ARGUMENTS and deliver the text to SUCCESS.
ERROR receives a condition.  Return the process object."
  (gitlab--with-backend
   (gitlab-cli-request-async arguments success error 'text)))

;;; Merge requests

(defun gitlab--cli-merge-request-list-arguments (arguments)
  "Return the glab arguments for a merge request list.
ARGUMENTS holds extra flags such as --all."
  (gitlab-cli--repository-arguments
   (append (list "mr" "list" "--output" "json") arguments)))

(defun gitlab--cli-merge-request-show-arguments (iid)
  "Return the glab arguments for merge request IID."
  (gitlab-cli--repository-arguments
   (list "mr" "view" (gitlab-data-id-string iid) "--output" "json")))

(defun gitlab--cli-merge-request-notes-arguments (iid)
  "Return the glab arguments for the notes of merge request IID.
The request asks for one full page of 100 notes, because
`--paginate' would concatenate several JSON arrays and one
decode cannot read that."
  (gitlab-cli--repository-arguments
   (list "api"
         (gitlab-cli-project-endpoint
          (format "merge_requests/%s/notes?per_page=100"
                  (gitlab-data-id-string iid))))))

(defun gitlab-merge-request-list (&optional arguments)
  "Return the merge requests of the current project.
ARGUMENTS holds extra glab flags.  This synchronous call serves
prompts and tests; display buffers use
`gitlab-merge-request-list-async'."
  (gitlab--with-backend
   (gitlab-cli-request
    (gitlab--cli-merge-request-list-arguments arguments))))

(defun gitlab-merge-request-list-async (success error &optional arguments)
  "Fetch the merge request list and deliver it to SUCCESS or ERROR.
ARGUMENTS holds extra glab flags.  Return the process object."
  (gitlab--with-backend
   (gitlab-cli-request-async
    (gitlab--cli-merge-request-list-arguments arguments)
    success error)))

(defun gitlab-merge-request-show (iid)
  "Return one merge request by IID.
IID is the project-scoped number that the web interface writes
as !123."
  (gitlab--with-backend
   (gitlab-cli-request (gitlab--cli-merge-request-show-arguments iid))))

(defun gitlab-merge-request-show-async (iid success error)
  "Fetch merge request IID and deliver it to SUCCESS or ERROR.
Return the process object."
  (gitlab--with-backend
   (gitlab-cli-request-async
    (gitlab--cli-merge-request-show-arguments iid)
    success error)))

(defun gitlab-merge-request-notes (iid)
  "Return the notes of merge request IID.
The notes endpoint returns a JSON array in creation order."
  (gitlab--with-backend
   (gitlab-cli-request
    (gitlab--cli-merge-request-notes-arguments iid))))

(defun gitlab-merge-request-notes-async (iid success error)
  "Fetch the notes of merge request IID and deliver them.
SUCCESS receives the JSON array, ERROR a condition.  Return the
process object."
  (gitlab--with-backend
   (gitlab-cli-request-async
    (gitlab--cli-merge-request-notes-arguments iid)
    success error)))

(defun gitlab--cli-merge-request-approve-arguments (iid)
  "Return the glab arguments that approve merge request IID."
  (gitlab-cli--repository-arguments
   (list "mr" "approve" (gitlab-data-id-string iid))))

(defun gitlab-merge-request-approve (iid)
  "Approve merge request IID on behalf of the current user.
IID is the project-scoped number that the web interface writes
as !123.  Return the text answer of glab, which names the merge
request and its new approval state.  A failing request signals
`gitlab-cli-error'."
  (gitlab--write (gitlab--cli-merge-request-approve-arguments iid)))

(defun gitlab-merge-request-approve-async (iid success error)
  "Approve merge request IID and deliver the text answer to SUCCESS.
ERROR receives a condition.  Return the process object."
  (gitlab--write-async (gitlab--cli-merge-request-approve-arguments iid)
                       success error))

(defun gitlab--cli-merge-request-merge-arguments (iid)
  "Return the glab arguments that merge merge request IID.
The arguments pass --yes, because the CLI must never prompt."
  (gitlab-cli--repository-arguments
   (list "mr" "merge" (gitlab-data-id-string iid) "--yes")))

(defun gitlab-merge-request-merge (iid)
  "Merge merge request IID on behalf of the current user.
IID is the project-scoped number that the web interface writes
as !123.  Return the text answer of glab, which names the merge
request and its new state.  A failing request signals
`gitlab-cli-error'."
  (gitlab--write (gitlab--cli-merge-request-merge-arguments iid)))

(defun gitlab-merge-request-merge-async (iid success error)
  "Merge merge request IID and deliver the text answer to SUCCESS.
ERROR receives a condition.  Return the process object."
  (gitlab--write-async (gitlab--cli-merge-request-merge-arguments iid)
                       success error))

(defun gitlab-merge-request-list-cached (&optional arguments)
  "Return the cached merge request list, fetching it when stale.
ARGUMENTS holds extra glab flags.  Prompts use this; display
buffers never do."
  (gitlab--cached (list 'merge-request gitlab-repository arguments)
                  (lambda () (gitlab-merge-request-list arguments))))

;;; Pipelines

(defun gitlab--cli-pipeline-list-arguments (arguments)
  "Return the glab arguments for a pipeline list.
ARGUMENTS holds extra flags such as --status=failed."
  (gitlab-cli--repository-arguments
   (append (list "ci" "list" "--output" "json") arguments)))

(defun gitlab--cli-pipeline-show-arguments (pipeline-id)
  "Return the glab arguments for pipeline PIPELINE-ID."
  (gitlab-cli--repository-arguments
   (list "ci" "get"
         "--pipeline-id" (gitlab-data-id-string pipeline-id)
         "--output" "json")))

(defun gitlab--cli-pipeline-jobs-arguments (pipeline-id)
  "Return the glab arguments for the jobs of pipeline PIPELINE-ID.
The request asks for one full page of 100 jobs, because
`--paginate' would concatenate several JSON arrays and one
decode cannot read that."
  (gitlab-cli--repository-arguments
   (list "api"
         (gitlab-cli-project-endpoint
          (format "pipelines/%s/jobs?per_page=100"
                  (gitlab-data-id-string pipeline-id))))))

(defun gitlab-pipeline-list (&optional arguments)
  "Return the pipelines of the current project.
ARGUMENTS holds extra glab flags.  This synchronous call serves
prompts and tests; display buffers use
`gitlab-pipeline-list-async'."
  (gitlab--with-backend
   (gitlab-cli-request
    (gitlab--cli-pipeline-list-arguments arguments))))

(defun gitlab-pipeline-list-async (success error &optional arguments)
  "Fetch the pipeline list and deliver it to SUCCESS or ERROR.
ARGUMENTS holds extra glab flags.  Return the process object."
  (gitlab--with-backend
   (gitlab-cli-request-async
    (gitlab--cli-pipeline-list-arguments arguments)
    success error)))

(defun gitlab-pipeline-show (pipeline-id)
  "Return one pipeline by PIPELINE-ID, with its jobs when present.
When glab omits the jobs field, fetch them from the jobs
endpoint and merge the array into the answer."
  (gitlab--with-backend
   (let ((data (gitlab-cli-request
                (gitlab--cli-pipeline-show-arguments pipeline-id))))
     (if (assq 'jobs data)
         data
       (gitlab-data-set-field
        "jobs" data
        (gitlab-cli-request
         (gitlab--cli-pipeline-jobs-arguments pipeline-id)))))))

(defun gitlab-pipeline-show-async (pipeline-id success error)
  "Fetch pipeline PIPELINE-ID and deliver it to SUCCESS or ERROR.
A missing jobs field triggers one more request to the jobs
endpoint.  Return the first process object.  It also carries the
jobs request in the `gitlab-cli-follow-up' property, so
`gitlab--kill-pending' cancels both."
  (gitlab--with-backend
   (let (process)
     (setq process
           (gitlab-cli-request-async
            (gitlab--cli-pipeline-show-arguments pipeline-id)
            (lambda (data)
              (if (assq 'jobs data)
                  (funcall success data)
                (let ((jobs-process
                       (gitlab-cli-request-async
                        (gitlab--cli-pipeline-jobs-arguments pipeline-id)
                        (lambda (jobs)
                          (gitlab-data-set-field "jobs" data jobs)
                          ;; Two answers merged: no single glab text
                          ;; describes DATA.
                          (let ((gitlab-cli-response-text nil))
                            (funcall success data)))
                        error)))
                  (when (and (processp process) (processp jobs-process))
                    (process-put process 'gitlab-cli-follow-up jobs-process))
                  jobs-process)))
            error))
     process)))

(defun gitlab-pipeline-jobs (pipeline-id)
  "Return the jobs of pipeline PIPELINE-ID."
  (gitlab--with-backend
   (gitlab-cli-request
    (gitlab--cli-pipeline-jobs-arguments pipeline-id))))

(defun gitlab-pipeline-jobs-async (pipeline-id success error)
  "Fetch the jobs of pipeline PIPELINE-ID.
SUCCESS receives the JSON array, ERROR a condition.  Return the
process object."
  (gitlab--with-backend
   (gitlab-cli-request-async
    (gitlab--cli-pipeline-jobs-arguments pipeline-id)
    success error)))

(defun gitlab-pipeline-list-cached (&optional arguments)
  "Return the cached pipeline list, fetching it when stale.
ARGUMENTS holds extra glab flags."
  (gitlab--cached (list 'pipeline gitlab-repository arguments)
                  (lambda () (gitlab-pipeline-list arguments))))

;;; Job log

(defun gitlab--cli-job-show-arguments (job-id)
  "Return the glab arguments for the details of JOB-ID."
  (gitlab-cli--repository-arguments
   (list "api"
         (gitlab-cli-project-endpoint
          (format "jobs/%s" (gitlab-data-id-string job-id))))))

(defun gitlab--cli-job-trace-arguments (job-id)
  "Return the glab arguments for the trace of JOB-ID."
  (gitlab-cli--repository-arguments
   (list "ci" "trace" (gitlab-data-id-string job-id))))

(defun gitlab-job-show (job-id)
  "Return the details of JOB-ID.
The answer holds the `pipeline' object that owns the job, so a
caller can name the parent pipeline of a job log."
  (gitlab--with-backend
   (gitlab-cli-request (gitlab--cli-job-show-arguments job-id))))

(defun gitlab-job-show-async (job-id success error)
  "Fetch the details of JOB-ID and deliver them.
SUCCESS receives the decoded answer, ERROR a condition.  Return
the process object."
  (gitlab--with-backend
   (gitlab-cli-request-async
    (gitlab--cli-job-show-arguments job-id)
    success error)))

(defun gitlab-job-pipeline-id (job-id)
  "Return the ID of the pipeline that holds JOB-ID, or nil.
The answer of the job endpoint names the pipeline, so a job log
finds its parent without a stored ID.  The value is a string,
ready for a glab argument.  A job without a pipeline field
returns nil."
  (let ((pipeline (gitlab-data-field "pipeline"
                                     (gitlab-job-show job-id))))
    (when pipeline
      (let ((id (gitlab-data-field "id" pipeline)))
        (and id (gitlab-data-id-string id))))))

(defun gitlab-job-trace (job-id)
  "Return the complete trace of JOB-ID as text."
  (gitlab--with-backend
   (gitlab-cli-request
    (gitlab--cli-job-trace-arguments job-id) 'text)))

(defun gitlab-job-trace-stream (job-id buffer success error &optional chunk-filter)
  "Stream the trace of JOB-ID into BUFFER.
SUCCESS runs when glab exits cleanly, ERROR receives a condition
on failure.  CHUNK-FILTER replaces the insertion of the streamed
text, as `gitlab-cli-stream' documents.  Return the process
object."
  (gitlab--with-backend
   (gitlab-cli-stream
    (gitlab--cli-job-trace-arguments job-id)
    buffer success error nil chunk-filter)))

;;; Web URLs

(defun gitlab-web-url (kind id &optional repository)
  "Return a GitLab web URL for KIND and ID, or nil.
KIND is `merge-request', `pipeline' or `job'.  REPOSITORY
defaults to `gitlab-repository', because the URL needs the project
path; display buffers prefer the web_url field of their own data.
A repository of another instance makes the URL use that instance,
and `gitlab-web-base-url' serves the default one."
  (declare (side-effect-free t))
  (let* ((repository (or repository gitlab-repository))
         (split (gitlab-cli-repository-split repository))
         (host (car split))
         (path (cdr split)))
    (when (and path (not (string-empty-p path)))
      (let ((base (if host
                      (format "https://%s" host)
                    (string-trim-right gitlab-web-base-url "/")))
            (section (pcase kind
                       ('merge-request "merge_requests")
                       ('pipeline "pipelines")
                       ('job "jobs")
                       (_ (signal 'gitlab-error
                                  (list (format "Unknown GitLab kind: %S"
                                                kind)))))))
        (format "%s/%s/-/%s/%s" base path section
                (gitlab-data-id-string id))))))

(provide 'gitlab-data)

;;; gitlab-data.el ends here
