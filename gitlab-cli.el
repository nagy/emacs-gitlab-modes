;;; gitlab-cli.el --- GitLab command line transport -*- lexical-binding: t; -*-

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

;; The transport layer: run the glab command line program and return
;; its output.  Every read starts one process, so the synchronous
;; entry point serves prompts and tests while the asynchronous entry
;; point serves display buffers.  The stream entry point serves a
;; live job log.
;;
;; The Nix build substitutes the default value of `gitlab-program'
;; with the store path of the nixpkgs glab package, so the installed
;; package needs nothing on PATH.  Users who run the source tree set
;; the variable themselves.
;;
;; Commands run with GLAB_NO_PROMPT=1: a prompt would wait forever in
;; a batch Emacs or in an asynchronous process.  Set `gitlab-repository'
;; to pass --repo to every command; nil lets glab infer the project
;; from `default-directory'.
;;
;; A repository names a project and its instance: PATH means
;; `gitlab-cli-default-host', and PATH@HOST means another instance.  A
;; URL and a Git URL are accepted as input and come back in that
;; spelling, so one project has one name in a buffer, in a bookmark and
;; in an Org link.  `gitlab-cli--repo-argument' turns the spelling back
;; into what glab takes: PATH, or https://HOST/PATH for another
;; instance.
;;
;; JSON is decoded with symbol keys and the value :false for false,
;; so a null and a false stay distinct.  Empty output decodes to nil.
;; A non-zero exit status signals `gitlab-cli-error' with the stderr
;; text; a request that exceeds its timeout signals
;; `gitlab-cli-timeout'.
;;
;; The variable `gitlab-cli-response-text' carries the raw stdout of
;; the asynchronous answer into its SUCCESS callback, so a caller can
;; keep the exact glab text next to the decoded value.

;;; Code:

(require 'ansi-color)
(require 'cl-lib)
(require 'json)
(require 'project)
(require 'subr-x)
(require 'url-util)
(require 'gitlab-error)

(defcustom gitlab-program "glab"
  "Program that talks to GitLab.
The default is the glab command line program.  The Nix build
substitutes its store path, so an installed package works without
the program on PATH."
  :type 'string
  :group 'gitlab)

(defcustom gitlab-repository nil
  "GitLab project that glab must use.
The value is OWNER/REPO or a full namespace path.  A nil value
lets glab infer the project from `default-directory'.  A display
buffer sets this buffer-locally when it belongs to another
project."
  :type '(choice (const :tag "Infer from the current directory" nil)
                 (string :tag "Project path"))
  :group 'gitlab)

(defcustom gitlab-cli-timeout 60
  "Seconds before a glab request times out.
A synchronous request signals `gitlab-cli-timeout'.  An
asynchronous request calls its error callback with the same
condition."
  :type 'natnum
  :group 'gitlab)

(defcustom gitlab-cli-ansi-color t
  "Non-nil if a streamed job log keeps its ANSI colors.
`gitlab-cli-stream' then converts SGR sequences into text
properties.  Set it to nil to keep the raw output."
  :type 'boolean
  :group 'gitlab)

(defvar gitlab-cli-response-text nil
  "Raw standard output of the request that produced the current answer.
`gitlab-cli-request-async' binds this variable around its SUCCESS
callback, so the callback reads the exact glab text next to the
decoded answer.  A request chain that merges two answers binds nil,
because no single text describes the merged answer.")

(defvar gitlab-cli--host nil
  "Instance host of the request that runs next, or nil for the default.
A request that names no repository, such as a group list, selects
its instance here, and `gitlab-cli--environment' adds GITLAB_HOST.
Bind this variable around the request and not around the whole
command.")

(defcustom gitlab-cli-directory nil
  "Directory in which glab runs.
A nil value uses `default-directory' of the calling buffer.  A
display buffer sets this buffer-locally to the project root of
the buffer that opened it, because the display buffer itself
shows remote data and not a file."
  :type '(choice (const :tag "Use default-directory" nil)
                 (directory :tag "Directory"))
  :group 'gitlab)

(defcustom gitlab-cli-default-host "gitlab.com"
  "GitLab instance that a project path without a host belongs to.
A repository string covers both a project and its instance, so a
display buffer of another instance never reuses the buffer of this
one.  The spelling is PATH for this instance and PATH@HOST for
another one.  A URL or a Git URL is accepted as input and always
comes back in that spelling."
  :type 'string
  :group 'gitlab)

;;; Repository identity

(defun gitlab-cli--split-url (repository)
  "Return a cons of HOST and PATH parsed from a URL REPOSITORY.
Return nil when REPOSITORY is not a URL.  The function knows the
form with a scheme, such as https://host/path, and the scp form,
such as git@host:path."
  (declare (pure t) (side-effect-free t))
  (cond
   ((string-match
     "\\`[[:alpha:]][[:alnum:]+.-]*://\\(?:[^@/]+@\\)?\\([^/:]+\\)\\(?::[0-9]+\\)?/\\(.+\\)\\'"
     repository)
    (cons (match-string 1 repository) (match-string 2 repository)))
   ((string-match "\\`\\(?:[^@/:]+@\\)?\\([^/:]+\\):\\(.+\\)\\'" repository)
    (cons (match-string 1 repository) (match-string 2 repository)))))

(defun gitlab-cli-repository-split (repository)
  "Return a cons of HOST and PATH of REPOSITORY.
REPOSITORY is PATH, PATH@HOST, or a URL such as
https://gitlab.example.com/group/project.git or
git@gitlab.example.com:group/project.git.  HOST is nil when the
text names no host or names `gitlab-cli-default-host', so the
default instance stays out of buffer names and out of the glab
arguments.  PATH carries no surrounding slash and no .git suffix."
  (declare (side-effect-free t))
  (let ((text (and repository (string-trim repository))))
    (if (or (null text) (string-empty-p text))
        (cons nil nil)
      (let* ((url (gitlab-cli--split-url text))
             (at (and (not url) (cl-search "@" text :from-end t)))
             (host (or (car url) (and at (substring text (1+ at)))))
             (path (or (cdr url) (if at (substring text 0 at) text)))
             (path (string-trim path "/+" "/+"))
             (path (if (string-suffix-p ".git" path)
                       (substring path 0 (- (length path) 4))
                     path)))
        (when (and host (string-match "\\`\\([^:]+\\)\\(?::[0-9]+\\)?\\'" host))
          (setq host (match-string 1 host)))
        (cons (if (or (null host)
                      (string-empty-p host)
                      (string-equal-ignore-case host gitlab-cli-default-host))
                  nil
                (downcase host))
              (string-trim path "/+" "/+"))))))

(defun gitlab-cli-repository-path (repository)
  "Return the project path of REPOSITORY, or nil."
  (declare (side-effect-free t))
  (cdr (gitlab-cli-repository-split repository)))

(defun gitlab-cli-repository-host (repository)
  "Return the instance host of REPOSITORY, or nil for the default."
  (declare (side-effect-free t))
  (car (gitlab-cli-repository-split repository)))

(defun gitlab-cli-repository-normalize (repository)
  "Return REPOSITORY as PATH or PATH@HOST, or nil.
The value names the project and its instance, so a prompt, a
bookmark and a buffer name spell one project one way.  A URL, a Git
URL and a bare path all come back in that spelling."
  (declare (side-effect-free t))
  (let* ((split (gitlab-cli-repository-split repository))
         (host (car split))
         (path (cdr split)))
    (cond
     ((and path host) (concat path "@" host))
     (path path)
     (host (concat "@" host)))))

(defun gitlab-cli--repo-argument (repository)
  "Return the --repo value of REPOSITORY.
glab selects another instance from a URL, so a host-carrying
project becomes https://HOST/PATH."
  (declare (side-effect-free t))
  (let* ((split (gitlab-cli-repository-split repository))
         (host (car split))
         (path (cdr split)))
    (if host (format "https://%s/%s" host path) path)))

;;; Commands

(defun gitlab-cli-directory-of (&optional buffer)
  "Return the directory in which glab runs for BUFFER.
BUFFER defaults to the current buffer.  The value is the
buffer-local `gitlab-cli-directory', or the `default-directory'
of BUFFER when the first is nil."
  (with-current-buffer (or buffer (current-buffer))
    (or gitlab-cli-directory default-directory)))

(defun gitlab-cli--project-directory (directory)
  "Return the root of the project that holds DIRECTORY.
The helper asks project.el.  DIRECTORY comes back unchanged
when it belongs to no project."
  (condition-case nil
      (let ((project (project-current nil directory)))
        (file-name-as-directory
         (if project
             (project-root project)
           (expand-file-name directory))))
    (error (file-name-as-directory (expand-file-name directory)))))

(defun gitlab-cli--repository-named-p (arguments)
  "Return non-nil when ARGUMENTS name a repository.
The helper knows the long form, both as a separate word and with
an equal sign, and the short form, both alone and joined."
  (declare (pure t) (side-effect-free t))
  (cl-some (lambda (argument)
             (or (string= argument "--repo")
                 (string-prefix-p "--repo=" argument)
                 (string-prefix-p "-R" argument)))
           arguments))

(defun gitlab-cli--group-named-p (arguments)
  "Return non-nil when ARGUMENTS select a group.
The long form works as a separate word and with an equal sign, and
the short form works alone and joined."
  (declare (pure t) (side-effect-free t))
  (cl-some (lambda (argument)
             (or (string= argument "--group")
                 (string-prefix-p "--group=" argument)
                 (string-prefix-p "-g" argument)))
           arguments))

(defun gitlab-cli--environment ()
  "Return the process environment for one glab request.
GLAB_NO_PROMPT stops glab from waiting for a terminal answer.
`gitlab-cli--host' names the instance of the request, because glab
selects no instance from a group argument."
  (let ((environment (cons "GLAB_NO_PROMPT=1" process-environment)))
    (if (and gitlab-cli--host (not (string-empty-p gitlab-cli--host)))
        (cons (concat "GITLAB_HOST=" gitlab-cli--host) environment)
      environment)))

(defun gitlab-cli--command (arguments)
  "Return the process command for ARGUMENTS."
  (cons gitlab-program arguments))

(defun gitlab-cli--repository-arguments (arguments)
  "Append the repository selection to ARGUMENTS when one is set.
A caller that already names --repo or -R keeps its own value.  A
caller that names --group gets no repository, because glab ignores
a repository beside a group.  The value comes from
`gitlab-cli--repo-argument', so a project of a second instance
selects that instance.  A repository that names no project
appends nothing."
  (let ((repository (and gitlab-repository
                         (gitlab-cli--repo-argument gitlab-repository))))
    (if (and repository
             (not (string-empty-p repository))
             (not (gitlab-cli--repository-named-p arguments))
             (not (gitlab-cli--group-named-p arguments)))
        (append arguments (list "--repo" repository))
      arguments)))

(defun gitlab-cli-project-endpoint (suffix)
  "Return a GitLab API endpoint for SUFFIX in the current project.
SUFFIX is the part after the project, for example
\"merge_requests/12/notes\".  A set `gitlab-repository' is URL
encoded, because a namespace path holds slashes; the host of the
project stays out, because the API request carries it.  A nil
value uses the glab placeholder :id, which glab expands from the
current repository."
  (format "projects/%s/%s"
          (if-let* ((path (gitlab-cli-repository-path gitlab-repository)))
              (url-hexify-string path)
            ":id")
          suffix))

;;; Output

(defun gitlab-cli--trim-message (text)
  "Return TEXT trimmed and shortened to a readable error message."
  (declare (pure t) (side-effect-free t))
  (let ((text (string-trim (or text ""))))
    (if (> (length text) 2000)
        (concat (substring text 0 2000) "...")
      text)))

(defun gitlab-cli--failure-message (status standard-error)
  "Return a message for exit STATUS and STANDARD-ERROR.
The stderr text wins when it holds a line; the status covers a
silent failure."
  (declare (pure t) (side-effect-free t))
  (let ((text (gitlab-cli--trim-message standard-error)))
    (if (string-empty-p text)
        (format "glab exited with status %s" status)
      text)))

(defun gitlab-cli--decode (text parse)
  "Decode TEXT according to PARSE.
PARSE is `json' for a JSON answer and nil for plain text.  An
empty JSON answer decodes to nil; invalid JSON signals
`gitlab-cli-error'."
  (declare (pure t) (side-effect-free t))
  (pcase parse
    ('json
     (if (string-blank-p text)
         nil
       (condition-case err
           (json-parse-string text
                              :object-type 'alist
                              :array-type 'list
                              :null-object nil
                              :false-object :false)
         (json-parse-error
          (signal 'gitlab-cli-error
                  (list (format "Cannot parse glab JSON: %s"
                                (error-message-string err))))))))
    (_ text)))

;;; Synchronous request

(defun gitlab-cli-request (arguments &optional parse timeout)
  "Run glab with ARGUMENTS and return the decoded answer.
PARSE is `json' by default, so a JSON object becomes an alist
with symbol keys, a JSON array becomes a list of alists and false
becomes :false.  The value `text' returns the raw text.

TIMEOUT defaults to `gitlab-cli-timeout' seconds.  A non-zero
exit status signals `gitlab-cli-error'; an expired timeout signals
`gitlab-cli-timeout'."
  (let* ((parse (if (eq parse 'text) 'text 'json))
         (timeout (or timeout gitlab-cli-timeout))
         (stdout (generate-new-buffer " *gitlab-cli-stdout*"))
         (stderr (generate-new-buffer " *gitlab-cli-stderr*"))
         (timer nil)
         (timed-out nil)
         (process
          (let ((process-environment (gitlab-cli--environment))
                (default-directory (gitlab-cli-directory-of)))
            (make-process
             :name "gitlab-cli"
             :buffer stdout
             :stderr stderr
             :command (gitlab-cli--command arguments)
             :connection-type 'pipe
             :coding 'utf-8-unix
             :noquery t
             :sentinel #'ignore))))
    (unwind-protect
        (progn
          (setq timer
                (run-at-time
                 timeout nil
                 (lambda ()
                   (setq timed-out t)
                   (when (process-live-p process)
                     (delete-process process)))))
          (while (process-live-p process)
            (accept-process-output process 0.1))
          (when (timerp timer)
            (cancel-timer timer))
          (when timed-out
            (signal 'gitlab-cli-timeout
                    (list (format "glab did not finish in %s seconds" timeout))))
          (let ((status (process-exit-status process))
                (text (with-current-buffer stdout (buffer-string)))
                (errors (with-current-buffer stderr (buffer-string))))
            (if (zerop status)
                (gitlab-cli--decode text parse)
              (signal 'gitlab-cli-error
                      (list (gitlab-cli--failure-message status errors))))))
      (when (timerp timer)
        (cancel-timer timer))
      (when (process-live-p process)
        (delete-process process))
      (when (buffer-live-p stdout)
        (kill-buffer stdout))
      (when (buffer-live-p stderr)
        (kill-buffer stderr)))))

;;; Asynchronous request

(defun gitlab-cli-request-async (arguments success error &optional parse timeout)
  "Run glab with ARGUMENTS and deliver the answer to a callback.
SUCCESS receives the decoded answer.  ERROR receives a condition
list that `error-message-string' prints.  PARSE and TIMEOUT behave
as in `gitlab-cli-request'.  The function returns the process
object, so a caller can cancel it."
  (let* ((parse (if (eq parse 'text) 'text 'json))
         (timeout (or timeout gitlab-cli-timeout))
         (stdout (generate-new-buffer " *gitlab-cli-stdout*"))
         (stderr (generate-new-buffer " *gitlab-cli-stderr*"))
         (timer nil)
         process)
    (setq process
          (let ((process-environment (gitlab-cli--environment))
                (default-directory (gitlab-cli-directory-of)))
            (make-process
             :name "gitlab-cli"
           :buffer stdout
           :stderr stderr
           :command (gitlab-cli--command arguments)
           :connection-type 'pipe
           :coding 'utf-8-unix
             :noquery t
             :sentinel
             (lambda (proc _event)
             (when (and (memq (process-status proc) '(exit signal))
                        (not (process-get proc 'gitlab-cli-done)))
               (process-put proc 'gitlab-cli-done t)
               (when-let* ((proc-timer (process-get proc 'gitlab-cli-timer)))
                 (when (timerp proc-timer)
                   (cancel-timer proc-timer)))
               (let ((status (process-exit-status proc))
                     (timed-out (process-get proc 'gitlab-cli-timed-out))
                     (text (if (buffer-live-p stdout)
                               (with-current-buffer stdout (buffer-string))
                             ""))
                     (errors (if (buffer-live-p stderr)
                                 (with-current-buffer stderr (buffer-string))
                               "")))
                 (when (buffer-live-p stdout)
                   (kill-buffer stdout))
                 (when (buffer-live-p stderr)
                   (kill-buffer stderr))
                 (if timed-out
                     (funcall error
                              (list 'gitlab-cli-timeout
                                    (format "glab did not finish in %s seconds"
                                            timeout)))
                   (if (zerop status)
                       (let ((gitlab-cli-response-text text))
                         (condition-case err
                             (funcall success (gitlab-cli--decode text parse))
                           (error (funcall error err))))
                       (funcall error
                                (list 'gitlab-cli-error
                                      (gitlab-cli--failure-message
                                       status errors)))))))))))
    (setq timer
          (run-at-time
           timeout nil
           (lambda ()
             (when (process-live-p process)
               (process-put process 'gitlab-cli-timed-out t)
               (delete-process process)))))
    (process-put process 'gitlab-cli-timer timer)
    process))

;;; Streaming request

(defun gitlab-cli--insert-chunk (text)
  "Insert TEXT at the end of the current buffer.
The buffer may be read-only and stays unmodified.  With
`gitlab-cli-ansi-color', SGR sequences become faces.  Return the
start position of the inserted text.  The helper keeps point, so a
stream never moves the cursor of its buffer.  A caller that follows
the tail moves point itself."
  (let ((inhibit-read-only t)
        (start (point-max)))
    (save-excursion
      (goto-char start)
      (insert text))
    (when gitlab-cli-ansi-color
      (ansi-color-apply-on-region start (point-max)))
    (set-buffer-modified-p nil)
    start))

(defun gitlab-cli--insert-filter (process chunk)
  "Insert a chunk of PROCESS output into its buffer.
CHUNK holds the text."
  (let ((buffer (process-buffer process)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (gitlab-cli--insert-chunk chunk)))))

(defun gitlab-cli-stream (arguments buffer success error
                                    &optional timeout chunk-filter)
  "Run glab with ARGUMENTS and stream its output into BUFFER.
SUCCESS runs when glab exits with status zero.  ERROR receives a
condition list on a non-zero exit or on TIMEOUT.  A nil TIMEOUT,
the default, streams until glab exits, because a job trace can
run for hours.  CHUNK-FILTER replaces the insertion of the
output: it receives the process and one chunk of text and writes
the chunk itself, so a caller can assemble lines or transform the
text.  The function returns the process object."
  (let* ((stderr (generate-new-buffer " *gitlab-cli-stderr*"))
         (timer nil)
         process)
    (with-current-buffer buffer
      (setq-local ansi-color-context-region nil))
    (setq process
          (let ((process-environment (gitlab-cli--environment))
                (default-directory (gitlab-cli-directory-of)))
            (make-process
             :name "gitlab-cli-trace"
           :buffer buffer
           :stderr stderr
           :command (gitlab-cli--command arguments)
           :connection-type 'pipe
           :coding 'utf-8-unix
             :noquery t
             :filter (or chunk-filter #'gitlab-cli--insert-filter)
             :sentinel
             (lambda (proc _event)
             (when (and (memq (process-status proc) '(exit signal))
                        (not (process-get proc 'gitlab-cli-done)))
               (process-put proc 'gitlab-cli-done t)
               (when-let* ((proc-timer (process-get proc 'gitlab-cli-timer)))
                 (when (timerp proc-timer)
                   (cancel-timer proc-timer)))
               (let ((status (process-exit-status proc))
                     (timed-out (process-get proc 'gitlab-cli-timed-out))
                     (errors (if (buffer-live-p stderr)
                                 (with-current-buffer stderr (buffer-string))
                               "")))
                 (when (buffer-live-p stderr)
                   (kill-buffer stderr))
                 (if timed-out
                     (funcall error
                              (list 'gitlab-cli-timeout
                                    (format "glab did not finish in %s seconds"
                                            timeout)))
                   (if (zerop status)
                       (funcall success)
                       (funcall error
                                (list 'gitlab-cli-error
                                      (gitlab-cli--failure-message
                                       status errors)))))))))))
    (when timeout
      (setq timer
            (run-at-time
             timeout nil
             (lambda ()
               (when (process-live-p process)
                 (process-put process 'gitlab-cli-timed-out t)
                 (delete-process process))))))
    (process-put process 'gitlab-cli-timer timer)
    process))

(provide 'gitlab-cli)

;;; gitlab-cli.el ends here
