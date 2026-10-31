;;; gitlab-test-helpers.el --- Shared helpers of the ERT suite -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Daniel Nagy

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;;; Commentary:

;; Shared fixtures and wait helpers for the GitLab ERT suite.  The
;; suite never opens a network connection: every request runs the
;; mock-glab script in the test directory.

;;; Code:

(require 'subr-x)

;; The helper binds these variables even in a test that loads only one
;; layer.  Marking them special at compile time keeps the byte-compiler
;; quiet.  The runtime declaration stays out of the way, so a defcustom
;; that the test loads keeps its own default.
(eval-when-compile
  (defvar gitlab-auto-revert nil)
  (defvar gitlab-cache-ttl nil)
  (defvar gitlab-cli-timeout nil)
  (defvar gitlab-program nil)
  (defvar gitlab-refresh-visible-only nil)
  (defvar gitlab-repository nil))

(defvar gitlab-test--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory that holds the mock program and the fixtures.")

(defvar gitlab-test--program
  (expand-file-name "mock-glab" gitlab-test--directory)
  "Absolute path of the offline glab stand-in.")

(defmacro gitlab-test-with-environment (&rest body)
  "Run BODY with the mock glab program and no automatic refresh."
  `(let ((gitlab-program gitlab-test--program)
         (gitlab-repository nil)
         (gitlab-auto-revert nil)
         (gitlab-refresh-visible-only nil)
         (gitlab-cache-ttl nil)
         (gitlab-cli-timeout 10))
     (when (fboundp 'gitlab-cache-clear)
       (gitlab-cache-clear))
     ,@body))

(defun gitlab-test-wait (predicate &optional timeout)
  "Wait until PREDICATE returns non-nil, up to TIMEOUT seconds.
Return the last value of PREDICATE.  The function pumps process
output, so an asynchronous glab request completes."
  (let ((deadline (+ (float-time) (or timeout 10))))
    (while (and (not (funcall predicate))
                (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (funcall predicate)))

(defun gitlab-test-buffer-string (buffer)
  "Return the text of BUFFER."
  (with-current-buffer buffer
    (buffer-substring-no-properties (point-min) (point-max))))

(provide 'gitlab-test-helpers)

;;; gitlab-test-helpers.el ends here
