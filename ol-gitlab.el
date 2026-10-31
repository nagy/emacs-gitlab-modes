;;; ol-gitlab.el --- Org link types for GitLab objects -*- lexical-binding: t; -*-

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

;; Optional Org link types.  Load this file to register them:
;;
;;   (require 'ol-gitlab)
;;
;;   [[gitlab-mr:8285][Review the export dialog fix]]
;;   [[gitlab-pipeline:3010647305][Watch the pipeline]]
;;   [[gitlab-job:17624043693][Read the job log]]
;;
;; The path is the project-scoped merge request IID or the pipeline or
;; job ID.  Follow opens the matching display buffer.  Store reads the
;; current GitLab buffer, so `org-store-link' in a merge request buffer
;; yields a `gitlab-mr:' link.  Export writes an HTML anchor when
;; `gitlab-repository' is set, because the web URL needs the project
;; path; without it the link keeps its text form.

;;; Code:

(require 'org)
(require 'gitlab-data)
(require 'gitlab-merge-request)
(require 'gitlab-pipeline)

(defun gitlab-org--html-escape (text)
  "Return TEXT with the HTML special characters escaped."
  (let ((text (replace-regexp-in-string "&" "&amp;" text)))
    (setq text (replace-regexp-in-string "<" "&lt;" text))
    (setq text (replace-regexp-in-string ">" "&gt;" text))
    text))

(defun gitlab-org--export (type path description backend)
  "Export a link of TYPE with PATH and DESCRIPTION for BACKEND.
A set `gitlab-repository' yields a web URL, so the HTML, markdown
and LaTeX backends keep the link target.  Every other backend
writes the URL after the text, and a nil repository leaves TEXT
alone."
  (let* ((kind (pcase type
                 ("gitlab-mr" 'merge-request)
                 ("gitlab-pipeline" 'pipeline)
                 ("gitlab-job" 'job)))
         (url (gitlab-web-url kind path))
         (text (or description path)))
    (cond
     ((null url) text)
     ((eq backend 'html)
      (format "<a href=\"%s\">%s</a>"
              (gitlab-org--html-escape url)
              (gitlab-org--html-escape text)))
     ((eq backend 'md) (format "[%s](%s)" text url))
     ((eq backend 'latex) (format "\\href{%s}{%s}" url text))
     (t (format "%s (%s)" text url)))))

(defun gitlab-org--follow-mr (path _prefix)
  "Open the merge request named by PATH."
  (gitlab-display-merge-request path))

(defun gitlab-org--follow-pipeline (path _prefix)
  "Open the pipeline named by PATH."
  (gitlab-display-pipeline path))

(defun gitlab-org--follow-job (path _prefix)
  "Open the job log named by PATH."
  (gitlab-display-job-log path))

(defun gitlab-org--store (type kind description)
  "Store a link of TYPE for the GitLab buffer KIND.
DESCRIPTION is a format string that receives the object ID.  The
function returns nil outside a GitLab buffer of KIND, because Org
calls the store function of every registered link type in every
buffer."
  (when (and (derived-mode-p kind) gitlab--id)
    (let ((id (gitlab-data-id-string gitlab--id)))
      (org-link-store-props
       :type type
       :link (format "%s:%s" type id)
       :description (format description id)))))

(defun gitlab-org--store-mr ()
  "Store a link to the merge request in the current buffer."
  (gitlab-org--store "gitlab-mr" 'gitlab-merge-request-mode
                     "Merge request !%s"))

(defun gitlab-org--store-pipeline ()
  "Store a link to the pipeline in the current buffer."
  (gitlab-org--store "gitlab-pipeline" 'gitlab-pipeline-mode
                     "Pipeline #%s"))

(defun gitlab-org--store-job ()
  "Store a link to the job in the current buffer."
  (gitlab-org--store "gitlab-job" 'gitlab-job-log-mode
                     "Job %s"))

(org-link-set-parameters
 "gitlab-mr"
 :follow #'gitlab-org--follow-mr
 :store #'gitlab-org--store-mr
 :export (lambda (path description backend)
           (gitlab-org--export "gitlab-mr" path description backend)))

(org-link-set-parameters
 "gitlab-pipeline"
 :follow #'gitlab-org--follow-pipeline
 :store #'gitlab-org--store-pipeline
 :export (lambda (path description backend)
           (gitlab-org--export "gitlab-pipeline" path description backend)))

(org-link-set-parameters
 "gitlab-job"
 :follow #'gitlab-org--follow-job
 :store #'gitlab-org--store-job
 :export (lambda (path description backend)
           (gitlab-org--export "gitlab-job" path description backend)))

(provide 'ol-gitlab)

;;; ol-gitlab.el ends here
