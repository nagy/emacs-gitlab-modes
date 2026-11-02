;;; gitlab-export.el --- Export the current view as JSON -*- lexical-binding: t; -*-

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

;; `gitlab-export-json' writes the glab JSON answer of the current
;; display buffer into one read-only `js-json-mode' buffer.  A detail
;; buffer exports one object and a list buffer exports one array.  The
;; command keeps the raw standard output of the fetch, so the text
;; matches `glab ... --output json' byte for byte, up to one trailing
;; newline, including empty arrays and false values.
;;
;; A fetch that merges two answers, as the pipeline jobs fallback
;; does, has no single glab text.  The export then encodes the decoded
;; data again.  The decoder maps JSON null to nil, so an empty object
;; in that answer becomes null.
;;
;; The export buffer keeps its source buffer and sets
;; `revert-buffer-function', so `revert-buffer' reads the source
;; again.
;;
;; The display base modes remap `js-json-mode' to the command, so a
;; key or a menu that runs the JSON major mode exports the view
;; instead.  That remap lives in `gitlab-mode.el', because an
;; autoloaded display command loads the display layer and not this
;; file.  This library installs no key.

;;; Code:

(require 'json)
(require 'subr-x)
(require 'gitlab-mode)

(defcustom gitlab-export-json-buffer-name "*GitLab JSON*"
  "Buffer name of the JSON export.
One buffer serves every export, so a second export replaces its
text instead of collecting buffers."
  :type 'string
  :group 'gitlab)

(defun gitlab-export--json-text (data)
  "Return DATA as indented JSON text.
The decoder uses the keyword `:false' for JSON false and nil for
JSON null.  Bind `json-false' and `json-null' so both values keep
their JSON form."
  (let ((json-false :false)
        (json-null nil)
        (json-encoding-pretty-print t)
        (json-encoding-default-indentation "  "))
    (json-encode data)))

(defun gitlab-export--text ()
  "Return the JSON text of the current display buffer.
Use the raw glab answer when the fetch kept one.  Otherwise encode
`gitlab--last-data'."
  (cond
   ((and (stringp gitlab--raw-text)
         (not (string-blank-p gitlab--raw-text)))
    gitlab--raw-text)
   (gitlab--rendered
    (gitlab-export--json-text gitlab--last-data))
   (t (user-error "This GitLab buffer has no data yet"))))

(defun gitlab-export--mode ()
  "Return the major mode of the JSON export buffer.
Use `js-json-mode' when the library is present and
`fundamental-mode' otherwise."
  (if (require 'js nil t) 'js-json-mode 'fundamental-mode))

(defvar-local gitlab-export--source nil
  "Buffer that holds the GitLab view of the current export.")

(defun gitlab-export--fill (buffer text source)
  "Replace the text of BUFFER with TEXT.
SOURCE holds the GitLab view that TEXT came from.  BUFFER takes the
project root of SOURCE through `gitlab--use-project-directory',
copies the `list-buffers-directory' of SOURCE, keeps SOURCE for
`gitlab-export--revert-buffer', and stays read-only and unmodified.
Two buffers then show one identifier in `list-buffers', because an
export is a snapshot of its source and not a second object."
  (with-current-buffer buffer
    (funcall (gitlab-export--mode))
    (gitlab--use-project-directory
     (with-current-buffer source (gitlab-cli-directory-of))
     (with-current-buffer source
       (gitlab-cli-repository-normalize gitlab-repository)))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert text)
      (unless (bolp)
        (insert "\n")))
    (setq buffer-read-only t)
    (setq-local list-buffers-directory
                (with-current-buffer source list-buffers-directory))
    (setq-local gitlab-export--source source)
    (setq-local revert-buffer-function #'gitlab-export--revert-buffer)
    (set-buffer-modified-p nil)))

(defun gitlab-export--revert-buffer (&rest _arguments)
  "Rewrite the export buffer from its source buffer.
Ignore ARGUMENTS, as `revert-buffer-function' requires.  Signal a
`user-error' when the source buffer died."
  (let ((source gitlab-export--source))
    (unless (buffer-live-p source)
      (user-error "The source GitLab buffer no longer exists"))
    (gitlab-export--fill (current-buffer)
                         (with-current-buffer source
                           (gitlab-export--text))
                         source)))

;;;###autoload
(defun gitlab-export-json ()
  "Export the data of the current GitLab buffer as JSON.
Write one read-only `js-json-mode' buffer and reuse it on the next
call.  A detail buffer exports one object and a list buffer exports
one array, as the glab command that filled the buffer prints them.
The command refuses a buffer without data, such as a job log.
`revert-buffer' in the export buffer reads the source buffer again.
The display base modes remap `js-json-mode' to this command."
  (interactive nil gitlab-detail-mode gitlab-list-mode)
  (unless (derived-mode-p 'gitlab-detail-mode 'gitlab-list-mode)
    (user-error "This buffer has no GitLab JSON data"))
  (let ((source (current-buffer))
        (buffer (get-buffer-create gitlab-export-json-buffer-name)))
    (gitlab-export--fill buffer (gitlab-export--text) source)
    (pop-to-buffer buffer)
    (goto-char (point-min))
    buffer))

(provide 'gitlab-export)

;;; gitlab-export.el ends here
