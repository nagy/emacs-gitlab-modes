;;; gitlab-evil.el --- Evil bindings for GitLab modes -*- lexical-binding: t; -*-

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

;; Optional evil integration.  The file needs evil, but the package
;; does not declare it, so a user without evil installs nothing.  The
;; entry library enables the mode as soon as evil loads:
;;
;;   (require 'gitlab-evil)
;;   (gitlab-evil-mode 1)
;;
;; Both lines are optional.  When `gitlab-evil-auto-enable' is non-nil,
;; which is the default, the autoloaded `gitlab-evil-auto-setup'
;; enables `gitlab-evil-mode' once evil is loaded.
;;
;; The mode installs one local minor mode per GitLab buffer.  Evil
;; state maps take precedence over a major mode map, so every command
;; key needs a state binding to reach the buffer.  The evil motions
;; stay untouched: j, k, gg, G, C-d, C-u, /, n and N keep their
;; meaning.
;;
;; Every key that evil already binds goes through a key remap of the
;; evil command, for example [remap evil-ret].  A remap follows the
;; command and not the key, so a user who moves evil-ret to another
;; key keeps the GitLab behaviour on the new key.  A key with no evil
;; command, such as gr, stays a plain key binding.
;;
;; Detail buffers: RET opens the pipeline, merge request, web page
;; or commit at point; q quits the window; gr refreshes; p pops back;
;; C-x C-j opens the parent list; c copies the ID; w opens the web
;; page.
;;
;; List buffers: RET opens the row; c or Y copies its ID; w opens its
;; web page; S sorts the current column.  A visual line selection
;; followed by y copies every selected row ID, one per line.
;;
;; Job log buffers: q quits; gr restarts the trace; ~ toggles the
;; timestamps; C-x C-j opens the pipeline; c copies the job ID; G and
;; gg reach the end and the start.

;;; Code:

(require 'gitlab-mode)
(require 'gitlab-merge-request)
(require 'gitlab-pipeline)

(declare-function evil-define-minor-mode-key "evil" (state mode key def))
(declare-function gitlab-export-json "gitlab-export" ())

;; Evil defines `evil-define-minor-mode-key' before it provides its
;; feature, and `evil-after-load-hook' runs between the two, so a plain
;; `require' of evil recurses at that moment.  Load evil only when its
;; functions are absent.
(unless (fboundp 'evil-define-minor-mode-key)
  (require 'evil))

(defcustom gitlab-evil-auto-enable t
  "Whether to install the evil bindings without an explicit call.
When non-nil, `gitlab-evil-auto-setup' enables `gitlab-evil-mode'
once evil loads.  Set this option to nil before evil loads to keep
the bindings off until a user calls `gitlab-evil-mode'."
  :type 'boolean
  :group 'gitlab)

(defvar gitlab-evil-detail-keys
  '(([remap evil-ret] . gitlab-open-at-point)
    ("<mouse-2>" . gitlab-mouse-open-at-point)
    ([remap evil-record-macro] . quit-window)
    ("gr" . revert-buffer)
    ([remap evil-paste-after] . gitlab-pop)
    ([remap dired-jump] . gitlab-go-to-parent)
    ([remap dired-up-directory] . gitlab-go-to-parent)
    ([remap evil-change] . gitlab-copy-id)
    ([remap evil-yank] . gitlab-export-json)
    ([remap evil-forward-word-begin] . gitlab-open-web))
  "Keys that `gitlab-evil-mode' binds in detail buffers.
A key is a key string, or a `[remap COMMAND]' vector for a command
that evil already binds.")

(defvar gitlab-evil-list-keys
  '(([remap evil-ret] . gitlab-list-open)
    ("<mouse-2>" . gitlab-list-mouse-open)
    ([remap evil-record-macro] . quit-window)
    ("gr" . revert-buffer)
    ([remap evil-change-whole-line] . tabulated-list-sort)
    ([remap evil-change] . gitlab-list-copy-id)
    ([remap evil-yank-line] . gitlab-list-copy-id)
    ([remap evil-yank] . gitlab-export-json)
    ([remap evil-forward-word-begin] . gitlab-list-open-web))
  "Keys that `gitlab-evil-mode' binds in list buffers.
A key is a key string, or a `[remap COMMAND]' vector for a command
that evil already binds.")

(defvar gitlab-evil-list-visual-keys
  '(([remap evil-yank] . gitlab-evil-list-copy-ids))
  "Keys that `gitlab-evil-mode' binds in visual state of list buffers.
A key is a key string, or a `[remap COMMAND]' vector for a command
that evil already binds.")

(defvar gitlab-evil-job-log-keys
  '(([remap evil-record-macro] . quit-window)
    ("gr" . gitlab-job-log-restart)
    ([remap dired-jump] . gitlab-go-to-parent)
    ([remap dired-up-directory] . gitlab-go-to-parent)
    ([remap evil-invert-char] . gitlab-job-log-toggle-timestamps)
    ([remap evil-change] . gitlab-copy-id))
  "Keys that `gitlab-evil-mode' binds in job log buffers.
A key is a key string, or a `[remap COMMAND]' vector for a command
that evil already binds.")

;;; Local minor modes

(define-minor-mode gitlab-evil-detail-mode
  "Install the evil bindings of GitLab detail buffers.
Do not enable this mode directly: enable `gitlab-evil-mode'."
  :group 'gitlab
  :lighter nil)

(define-minor-mode gitlab-evil-list-mode
  "Install the evil bindings of GitLab list buffers.
Do not enable this mode directly: enable `gitlab-evil-mode'."
  :group 'gitlab
  :lighter nil)

(define-minor-mode gitlab-evil-job-log-mode
  "Install the evil bindings of GitLab job log buffers.
Do not enable this mode directly: enable `gitlab-evil-mode'."
  :group 'gitlab
  :lighter nil)

(defun gitlab-evil--key-sequence (key)
  "Return the key sequence of KEY.
KEY is a key string or a key vector, so a `[remap COMMAND]' entry
passes through unchanged."
  (if (vectorp key) key (key-parse key)))

(defun gitlab-evil--bind (state mode keys)
  "Bind STATE's evil keys for MODE from the KEYS list."
  (apply #'evil-define-minor-mode-key state mode
         (mapcan (lambda (binding)
                   (list (gitlab-evil--key-sequence (car binding))
                         (cdr binding)))
                 keys)))

(gitlab-evil--bind 'normal 'gitlab-evil-detail-mode gitlab-evil-detail-keys)
(gitlab-evil--bind 'normal 'gitlab-evil-list-mode gitlab-evil-list-keys)
(gitlab-evil--bind 'visual 'gitlab-evil-list-mode gitlab-evil-list-visual-keys)
(gitlab-evil--bind 'normal 'gitlab-evil-job-log-mode gitlab-evil-job-log-keys)

;;; Selection

(defun gitlab-evil--ids-between (start end)
  "Return the row IDs of the GitLab list rows between START and END."
  (let ((ids nil))
    (save-excursion
      (goto-char start)
      (while (< (point) end)
        (when-let* ((id (tabulated-list-get-id)))
          (push (gitlab-data-id-string id) ids))
        (forward-line 1)))
    (nreverse ids)))

(defun gitlab-evil-list-copy-ids (start end)
  "Copy the IDs of the selected list rows between START and END."
  (interactive "r")
  (let ((ids (gitlab-evil--ids-between start end)))
    (if ids
        (progn
          (kill-new (mapconcat #'identity ids "\n"))
          (message "Copied %d IDs" (length ids)))
      (user-error "No rows selected"))))

;;; Global mode

(defun gitlab-evil--maybe-enable ()
  "Enable the matching local evil mode in the current buffer."
  (cond
   ((derived-mode-p 'gitlab-pipeline-mode)
    (gitlab-evil-detail-mode 1))
   ((derived-mode-p 'gitlab-merge-request-mode)
    (gitlab-evil-detail-mode 1))
   ((derived-mode-p 'gitlab-job-log-mode)
    (gitlab-evil-job-log-mode 1))
   ((derived-mode-p 'gitlab-list-mode)
    (gitlab-evil-list-mode 1))))

(defun gitlab-evil--disable ()
  "Disable every local evil mode in the current buffer."
  (gitlab-evil-detail-mode -1)
  (gitlab-evil-list-mode -1)
  (gitlab-evil-job-log-mode -1))

;;;###autoload
(defun gitlab-evil-auto-setup ()
  "Enable `gitlab-evil-mode' when the option allows it.
The entry library puts this function on `evil-after-load-hook', so a
user who has no evil loads no evil code."
  (when gitlab-evil-auto-enable
    (gitlab-evil-mode 1)))

;;;###autoload
(define-minor-mode gitlab-evil-mode
  "Install the evil bindings of the GitLab modes.
The mode is global; it enables one local minor mode in each
GitLab buffer and follows new buffers through the major mode
hook.  The package never requires evil.  The autoloaded
`gitlab-evil-auto-setup' calls this mode once evil is loaded."
  :global t
  :group 'gitlab
  (if gitlab-evil-mode
      (progn
        (add-hook 'after-change-major-mode-hook
                  #'gitlab-evil--maybe-enable)
        (dolist (buffer (buffer-list))
          (with-current-buffer buffer
            (gitlab-evil--maybe-enable))))
    (remove-hook 'after-change-major-mode-hook
                 #'gitlab-evil--maybe-enable)
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (gitlab-evil--disable)))))

(provide 'gitlab-evil)

;;; gitlab-evil.el ends here
