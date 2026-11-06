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
;;   mr:12              a merge request
;;   work-item:12       a work item
;;   pipeline:1001      a pipeline
;;   job:5001           a job log
;;
;; A path names its project when it holds one, with the sigil of
;; `gitlab-data-identifier', so the same text serves an Org link and a
;; bookmark location:
;;
;;   mr:group/project!12
;;   work-item:group/project%12
;;   pipeline:group/project#1001
;;   job:group/project&5001
;;
;; The backend reads the text properties that the renderers attach
;; first, so xref on a pipeline, merge request, work item or job row in
;; a display buffer works without a typed prefix.  Outside a display
;; buffer it accepts the prefixed form under point.
;;
;; Completion reads the cached lists of gitlab-data.el, so the first
;; xref in a session may fetch the merge request, work item and
;; pipeline lists.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'xref)
(require 'gitlab-data)
(require 'gitlab-merge-request)
(require 'gitlab-work-item)
(require 'gitlab-pipeline)

(defun gitlab-xref--merge-request-iid (iid)
  "Return IID without a leading !.
A merge request list row shows !IID in its cell, so the text
property may carry the sigil.  The glab command needs the number."
  (declare (pure t) (side-effect-free t))
  (string-remove-prefix "!" iid))

(defun gitlab-xref--property-identifier ()
  "Return the identifier that a text property at point names."
  (let ((repository gitlab-repository))
    (cond
     ((get-text-property (point) 'gitlab-merge-request-iid)
      (format "mr:%s"
              (gitlab-data-identifier
               'merge-request
               (gitlab-xref--merge-request-iid
                (get-text-property (point) 'gitlab-merge-request-iid))
               repository)))
     ((get-text-property (point) 'gitlab-pipeline-id)
      (format "pipeline:%s"
              (gitlab-data-identifier
               'pipeline
               (get-text-property (point) 'gitlab-pipeline-id)
               repository)))
     ((get-text-property (point) 'gitlab-work-item-iid)
      (let* ((parts (gitlab-data-identifier-split
                     'work-item
                     (gitlab-data-id-string
                      (get-text-property (point) 'gitlab-work-item-iid))))
             (id (string-remove-prefix "%" (cdr parts)))
             (context (or (car parts) repository)))
        (format "work-item:%s"
                (gitlab-data-identifier 'work-item id context))))
     ((get-text-property (point) 'gitlab-job-id)
      (format "job:%s"
              (gitlab-data-identifier
               'job (get-text-property (point) 'gitlab-job-id)
               repository))))))

(defun gitlab-xref--text-identifier ()
  "Return the prefixed GitLab identifier under point, or nil."
  (save-excursion
    (let ((case-fold-search nil)
          (point (point))
          found)
      (goto-char (line-beginning-position))
      (while (and (not found)
                  (re-search-forward
                   "\\(mr\\|work-item\\|pipeline\\|job\\):[^][(){}<>[:space:]]+"
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
IDENTIFIER is a prefixed form of `gitlab-data-identifier', so it
names the project when it holds one.  The function prepares the
display buffer without popping to it, so a definition does not
move the window configuration."
  (let ((case-fold-search nil))
    (cond
     ((string-match "\\`mr:\\(.+\\)\\'" identifier)
      (let* ((parts (gitlab-data-identifier-split
                     'merge-request (match-string 1 identifier)))
             (iid (gitlab-xref--merge-request-iid (cdr parts)))
             (gitlab-repository (or (car parts) gitlab-repository))
             (buffer (gitlab--prepare-detail
                      #'gitlab-merge-request--buffer-name
                      #'gitlab-merge-request-mode iid)))
        (list (gitlab-xref--buffer-item
               (format "Merge request !%s" iid) buffer))))
     ((string-match "\\`work-item:\\(.+\\)\\'" identifier)
      (let* ((parts (gitlab-data-identifier-split
                     'work-item (match-string 1 identifier)))
             (iid (string-remove-prefix "%" (cdr parts)))
             (gitlab-repository (or (car parts) gitlab-repository))
             (buffer (gitlab--prepare-detail
                      #'gitlab-work-item--buffer-name
                      #'gitlab-work-item-mode iid)))
        (list (gitlab-xref--buffer-item
               (format "Work item %%%s" iid) buffer))))
     ((string-match "\\`pipeline:\\(.+\\)\\'" identifier)
      (let* ((parts (gitlab-data-identifier-split
                     'pipeline (match-string 1 identifier)))
             (id (cdr parts))
             (gitlab-repository (or (car parts) gitlab-repository))
             (buffer (gitlab--prepare-detail
                      #'gitlab-pipeline--buffer-name
                      #'gitlab-pipeline-mode id)))
        (list (gitlab-xref--buffer-item
               (format "Pipeline #%s" id) buffer))))
     ((string-match "\\`job:\\(.+\\)\\'" identifier)
      (let* ((parts (gitlab-data-identifier-split
                     'job (match-string 1 identifier)))
             (id (cdr parts))
             (gitlab-repository (or (car parts) gitlab-repository))
             (buffer (gitlab-pipeline--prepare-job-log id)))
        (list (gitlab-xref--buffer-item
               (format "Job %s" id) buffer))))
     (t nil))))

(cl-defmethod xref-backend-identifier-completion-table ((_backend (eql gitlab)))
  "Return the known GitLab identifiers."
  (let ((repository gitlab-repository)
        identifiers)
    (dolist (merge-request (gitlab-merge-request-list-cached))
      (push (format "mr:%s"
                    (gitlab-data-identifier
                     'merge-request
                     (gitlab-data-id-string
                      (gitlab-data-field "iid" merge-request))
                     repository))
            identifiers))
    (dolist (work-item (gitlab-work-item-list-cached))
      (push (format "work-item:%s"
                    (gitlab-data-identifier
                     'work-item
                     (gitlab-data-id-string
                      (gitlab-data-field "iid" work-item))
                     repository))
            identifiers))
    (dolist (pipeline (gitlab-pipeline-list-cached))
      (push (format "pipeline:%s"
                    (gitlab-data-identifier
                     'pipeline
                     (gitlab-data-id-string
                      (gitlab-data-field "id" pipeline))
                     repository))
            identifiers))
    (nreverse identifiers)))

;;;###autoload
(add-hook 'xref-backend-functions #'gitlab-xref-backend)

(provide 'gitlab-xref)

;;; gitlab-xref.el ends here
