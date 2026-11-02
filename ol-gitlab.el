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
;;   [[gitlab-mr:12][Review the dialog]]
;;   [[gitlab-pipeline:1001][Watch the pipeline]]
;;   [[gitlab-job:5001][Read the job log]]
;;
;; Follow opens the matching display buffer.  Store reads the current
;; GitLab buffer, so `org-store-link' in a merge request buffer yields a
;; `gitlab-mr:' link, and a point on a job row of a pipeline buffer
;; yields a `gitlab-job:' link.  Export writes an HTML anchor when the
;; project is known, because the web URL needs the project path;
;; without it the link keeps its text form.
;;
;; A path names its project when it holds one:
;;
;;   [[gitlab-mr:group/project!12][Fix the dialog]]
;;   [[gitlab-pipeline:group/project#1001][Run]]
;;   [[gitlab-job:group/project&5001][Log]]
;;
;; The sigil comes from `gitlab-data-identifier', so a bookmark
;; location, an Org link and an xref identifier name one object with
;; one syntax.  A bare ID keeps its meaning and reads the project from
;; `gitlab-repository' or from the buffer that opens the link.

;;; Code:

(require 'org)
(require 'gitlab-data)
(require 'gitlab-merge-request)
(require 'gitlab-pipeline)

(defun gitlab-org--kind (type)
  "Return the GitLab kind of the Org link TYPE."
  (pcase type
    ("gitlab-mr" 'merge-request)
    ("gitlab-pipeline" 'pipeline)
    ("gitlab-job" 'job)
    (_ (signal 'gitlab-error
               (list (format "Unknown GitLab link type: %S" type))))))

(defun gitlab-org--link (type id)
  "Return the Org link text of TYPE to ID in the current project.
The project comes from `gitlab-git-context', so a buffer that takes
its project from the Git remote writes a self-contained link."
  (format "%s:%s" type
          (gitlab-data-identifier (gitlab-org--kind type) id
                                  (gitlab-git-context))))

(defun gitlab-org--identifier (kind path)
  "Return a cons of REPOSITORY and ID that KIND and PATH name.
Signal `user-error' for a PATH without an ID."
  (let* ((parts (gitlab-data-identifier-split kind path))
         (repository (car parts))
         (id (cdr parts)))
    (when (string-empty-p id)
      (user-error "Empty GitLab identifier: %s" path))
    (cons repository id)))

(defun gitlab-org--html-escape (text)
  "Return TEXT with the HTML special characters escaped."
  (let ((text (replace-regexp-in-string "&" "&amp;" text)))
    (setq text (replace-regexp-in-string "<" "&lt;" text))
    (setq text (replace-regexp-in-string ">" "&gt;" text))
    text))

(defun gitlab-org--export (type path description backend)
  "Export a link of TYPE with PATH and DESCRIPTION for BACKEND.
A PATH that names a project, or a set `gitlab-repository', yields a
web URL, so the HTML, markdown and LaTeX backends keep the link
target.  Every other backend writes the URL after the text, and an
unknown project leaves TEXT alone."
  (let* ((kind (gitlab-org--kind type))
         (identifier (gitlab-org--identifier kind path))
         (url (gitlab-web-url kind (cdr identifier) (car identifier)))
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

(defun gitlab-org--open (kind path open)
  "Open the GitLab object of KIND and PATH with OPEN.
KIND selects the identifier syntax.  A PATH that names a project
runs the display command with that project, so one link opens an
object of another project."
  (let* ((identifier (gitlab-org--identifier kind path))
         (repository (car identifier))
         (id (cdr identifier)))
    (let ((gitlab-repository (or repository gitlab-repository)))
      (funcall open id))))

(defun gitlab-org--follow-mr (path _prefix)
  "Open the merge request named by PATH."
  (gitlab-org--open 'merge-request path #'gitlab-display-merge-request))

(defun gitlab-org--follow-pipeline (path _prefix)
  "Open the pipeline named by PATH."
  (gitlab-org--open 'pipeline path #'gitlab-display-pipeline))

(defun gitlab-org--follow-job (path _prefix)
  "Open the job log named by PATH."
  (gitlab-org--open 'job path #'gitlab-display-job-log))

(defun gitlab-org--store (type id description)
  "Store a link of TYPE to ID with DESCRIPTION.
DESCRIPTION is a format string that receives ID."
  (org-link-store-props
   :type type
   :link (gitlab-org--link type id)
   :description (format description id)))

(defun gitlab-org--store-buffer (type kind description)
  "Store a link of TYPE to the current buffer of KIND.
DESCRIPTION is a format string that receives the object ID.  The
function returns nil outside a GitLab buffer of KIND, because Org
calls the store function of every registered link type in every
buffer, and it returns nil when the buffer has no object."
  (when (and (derived-mode-p kind) gitlab--id)
    (gitlab-org--store type (gitlab-data-id-string gitlab--id) description)))

(defun gitlab-org--store-mr ()
  "Store a link to the merge request in the current buffer."
  (gitlab-org--store-buffer "gitlab-mr" 'gitlab-merge-request-mode
                            "Merge request !%s"))

(defun gitlab-org--store-pipeline ()
  "Store a link to the pipeline in the current buffer.
A point on a job row belongs to the job, so the call returns nil
there and `gitlab-org--store-job' stores the job."
  (unless (gitlab-pipeline-job-id-at-point)
    (gitlab-org--store-buffer "gitlab-pipeline" 'gitlab-pipeline-mode
                              "Pipeline #%s")))

(defun gitlab-org--store-job ()
  "Store a link to the job in the current buffer.
A point on a job row of a pipeline buffer names that job.  The job
log buffer names its own job."
  (if-let* ((id (gitlab-pipeline-job-id-at-point)))
      (let ((name (get-text-property (point) 'gitlab-job-name)))
        (org-link-store-props
         :type "gitlab-job"
         :link (gitlab-org--link "gitlab-job" (gitlab-data-id-string id))
         :description (if name
                          (format "Job %s (%s)" id name)
                        (format "Job %s" id))))
    (gitlab-org--store-buffer "gitlab-job" 'gitlab-job-log-mode "Job %s")))

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
