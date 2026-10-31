;;; gitlab-xref.el --- Xref backend for GitLab identifiers -*- lexical-binding: t; -*-

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

;; Optional xref backend.  Load this file to make the xref command
;; open a GitLab object from an identifier:
;;
;;   mr:8285          a merge request
;;   pipeline:3010647305
;;   job:17624043693
;;
;; The backend reads the text properties that the renderers attach
;; first, so xref on a pipeline, merge request or job row in a display
;; buffer works without a typed prefix.  Outside a display buffer it
;; accepts the prefixed form under point.
;;
;; Completion reads the cached lists of gitlab-data.el, so the first
;; xref in a session may fetch the merge request and pipeline lists.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'xref)
(require 'gitlab-data)
(require 'gitlab-merge-request)
(require 'gitlab-pipeline)

(defun gitlab-xref--merge-request-iid (iid)
  "Return IID without a leading !.
A merge request list row shows !IID in its cell, so the text
property may carry the sigil.  The glab command needs the number."
  (string-remove-prefix "!" iid))

(defun gitlab-xref--property-identifier ()
  "Return the identifier that a text property at point names."
  (cond
   ((get-text-property (point) 'gitlab-merge-request-iid)
    (format "mr:%s"
            (gitlab-xref--merge-request-iid
             (get-text-property (point) 'gitlab-merge-request-iid))))
   ((get-text-property (point) 'gitlab-pipeline-id)
    (format "pipeline:%s"
            (get-text-property (point) 'gitlab-pipeline-id)))
   ((get-text-property (point) 'gitlab-job-id)
    (format "job:%s"
            (get-text-property (point) 'gitlab-job-id)))))

(defun gitlab-xref--text-identifier ()
  "Return the prefixed GitLab identifier under point, or nil."
  (save-excursion
    (let ((case-fold-search nil)
          (point (point))
          found)
      (goto-char (line-beginning-position))
      (while (and (not found)
                  (re-search-forward
                   "\\(mr\\|pipeline\\|job\\):[0-9]+"
                   (line-end-position) t))
        (when (and (<= (match-beginning 0) point)
                   (<= point (match-end 0)))
          (setq found (buffer-substring-no-properties
                       (match-beginning 0) (match-end 0)))))
      found)))

(defun gitlab-xref-backend ()
  "Return the GitLab xref backend symbol when it claims the buffer."
  (when (or (gitlab-xref--property-identifier)
            (gitlab-xref--text-identifier))
    'gitlab))

(cl-defmethod xref-backend-identifier-at-point ((_backend (eql gitlab)))
  "Return the GitLab identifier at point."
  (or (gitlab-xref--property-identifier)
      (gitlab-xref--text-identifier)))

(defun gitlab-xref--buffer-item (description buffer)
  "Return an xref item for DESCRIPTION in BUFFER."
  (xref-make description
             (xref-make-buffer-location buffer (point-min))))

(cl-defmethod xref-backend-definitions ((_backend (eql gitlab)) identifier)
  "Return the GitLab definition of IDENTIFIER.
The function prepares the display buffer without popping to it,
so a definition does not move the window configuration."
  (let ((case-fold-search nil))
    (cond
     ((string-match "\\`mr:\\(.+\\)\\'" identifier)
      (let* ((iid (gitlab-xref--merge-request-iid
                   (match-string 1 identifier)))
             (buffer (gitlab--prepare-detail
                      (gitlab-merge-request--buffer-name iid)
                      #'gitlab-merge-request-mode iid)))
        (list (gitlab-xref--buffer-item
               (format "Merge request !%s" iid) buffer))))
     ((string-match "\\`pipeline:\\(.+\\)\\'" identifier)
      (let* ((id (match-string 1 identifier))
             (buffer (gitlab--prepare-detail
                      (gitlab-pipeline--buffer-name id)
                      #'gitlab-pipeline-mode id)))
        (list (gitlab-xref--buffer-item
               (format "Pipeline #%s" id) buffer))))
     ((string-match "\\`job:\\(.+\\)\\'" identifier)
      (let* ((id (match-string 1 identifier))
             (buffer (gitlab-pipeline--prepare-job-log id)))
        (list (gitlab-xref--buffer-item
               (format "Job %s" id) buffer))))
     (t nil))))

(cl-defmethod xref-backend-identifier-completion-table ((_backend (eql gitlab)))
  "Return the known GitLab identifiers."
  (let (identifiers)
    (dolist (merge-request (gitlab-merge-request-list-cached))
      (push (format "mr:%s"
                    (gitlab-data-id-string
                     (gitlab-data-field "iid" merge-request)))
            identifiers))
    (dolist (pipeline (gitlab-pipeline-list-cached))
      (push (format "pipeline:%s"
                    (gitlab-data-id-string
                     (gitlab-data-field "id" pipeline)))
            identifiers))
    (nreverse identifiers)))

;;;###autoload
(add-hook 'xref-backend-functions #'gitlab-xref-backend)

(provide 'gitlab-xref)

;;; gitlab-xref.el ends here
