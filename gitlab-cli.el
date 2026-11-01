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
;; JSON is decoded with symbol keys and the value :false for false,
;; so a null and a false stay distinct.  Empty output decodes to nil.
;; A non-zero exit status signals `gitlab-cli-error' with the stderr
;; text; a request that exceeds its timeout signals
;; `gitlab-cli-timeout'.

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
  "Whether a streamed job log keeps its ANSI colors.
When non-nil, `gitlab-cli-stream' converts SGR sequences into
text properties.  Set it to nil to keep the raw output."
  :type 'boolean
  :group 'gitlab)

(defcustom gitlab-cli-directory nil
  "Directory in which glab runs.
A nil value uses `default-directory' of the calling buffer.  A
display buffer sets this buffer-locally to the project root of
the buffer that opened it, because the display buffer itself
shows remote data and not a file."
  :type '(choice (const :tag "Use default-directory" nil)
                 (directory :tag "Directory"))
  :group 'gitlab)

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
  (cl-some (lambda (argument)
             (or (string= argument "--repo")
                 (string-prefix-p "--repo=" argument)
                 (string-prefix-p "-R" argument)))
           arguments))

(defun gitlab-cli--environment ()
  "Return the process environment for one glab request.
GLAB_NO_PROMPT stops glab from waiting for a terminal answer."
  (cons "GLAB_NO_PROMPT=1" process-environment))

(defun gitlab-cli--command (arguments)
  "Return the process command for ARGUMENTS."
  (cons gitlab-program arguments))

(defun gitlab-cli--repository-arguments (arguments)
  "Append the repository selection to ARGUMENTS when one is set.
A caller that already names --repo or -R keeps its own value."
  (if (and gitlab-repository
           (not (gitlab-cli--repository-named-p arguments)))
      (append arguments (list "--repo" gitlab-repository))
    arguments))

(defun gitlab-cli-project-endpoint (suffix)
  "Return a GitLab API endpoint for SUFFIX in the current project.
SUFFIX is the part after the project, for example
\"merge_requests/12/notes\".  A set `gitlab-repository' is URL
encoded, because a namespace path holds slashes.  A nil value
uses the glab placeholder :id, which glab expands from the
current repository."
  (format "projects/%s/%s"
          (if gitlab-repository
              (url-hexify-string gitlab-repository)
            ":id")
          suffix))

;;; Output

(defun gitlab-cli--trim-message (text)
  "Return TEXT trimmed and shortened to a readable error message."
  (let ((text (string-trim (or text ""))))
    (if (> (length text) 2000)
        (concat (substring text 0 2000) "...")
      text)))

(defun gitlab-cli--failure-message (status standard-error)
  "Return a message for exit STATUS and STANDARD-ERROR.
The stderr text wins when it holds a line; the status covers a
silent failure."
  (let ((text (gitlab-cli--trim-message standard-error)))
    (if (string-empty-p text)
        (format "glab exited with status %s" status)
      text)))

(defun gitlab-cli--decode (text parse)
  "Decode TEXT according to PARSE.
PARSE is `json' for a JSON answer and nil for plain text.  An
empty JSON answer decodes to nil; invalid JSON signals
`gitlab-cli-error'."
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
                       (condition-case err
                           (funcall success (gitlab-cli--decode text parse))
                         (error (funcall error err)))
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

(defun gitlab-cli--insert-filter (process chunk)
  "Insert a chunk of PROCESS output into its buffer.
CHUNK holds the text.  The buffer may be read-only.  With
`gitlab-cli-ansi-color', SGR sequences become faces."
  (let ((buffer (process-buffer process)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((inhibit-read-only t)
              (start (point-max)))
          (goto-char (point-max))
          (insert chunk)
          (when gitlab-cli-ansi-color
            (ansi-color-apply-on-region start (point-max)))
          (set-buffer-modified-p nil))))))

(defun gitlab-cli-stream (arguments buffer success error &optional timeout)
  "Run glab with ARGUMENTS and stream its output into BUFFER.
SUCCESS runs when glab exits with status zero.  ERROR receives a
condition list on a non-zero exit or on TIMEOUT.  A nil TIMEOUT,
the default, streams until glab exits, because a job trace can
run for hours.  The function returns the process object."
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
             :filter #'gitlab-cli--insert-filter
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
