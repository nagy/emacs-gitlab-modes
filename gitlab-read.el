;;; gitlab-read.el --- Completing read of GitLab IDs -*- lexical-binding: t; -*-

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

;; ID completion for the display commands.  The functions read the
;; cached lists of gitlab-data.el, so repeated prompts during one
;; session do not start one glab process each.  The cache expires
;; after `gitlab-cache-ttl' seconds.
;;
;; A prompt always accepts an ID typed by hand.  Completion is a
;; convenience, not a requirement, so a project whose list is too
;; large to fetch still works.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'gitlab-data)

(defun gitlab-read--strip (text prefixes)
  "Return TEXT without a leading character from PREFIXES."
  (let ((text (string-trim (or text ""))))
    (while (and (> (length text) 1)
                (memq (aref text 0) prefixes))
      (setq text (substring text 1)))
    text))

(defun gitlab-read--answer (choices input)
  "Return the selected value of CHOICES.
CHOICES is an alist of label to value and INPUT is the typed
text.  A matching label wins; otherwise the function returns
INPUT without a leading ! or #."
  (or (cdr (assoc input choices))
      (gitlab-read--strip input '(?! ?#))))

;;;###autoload
(defun gitlab-read-merge-request-iid (&optional prompt)
  "Read a merge request IID, completing from the cached list.
PROMPT defaults to \"Merge request: \".  A typed ID wins when the
list has no matching label."
  (let* ((merge-requests (gitlab-merge-request-list-cached))
         (choices
          (mapcar
           (lambda (merge-request)
             (let ((iid (gitlab-data-id-string
                         (gitlab-data-field "iid" merge-request)))
                   (title (gitlab-data-field-string "title" merge-request))
                   (state (gitlab-data-field-string "state" merge-request)))
               (cons (format "!%s  %s  [%s]" iid title state) iid)))
           merge-requests))
         (input (completing-read (or prompt "Merge request: ")
                                 choices nil nil)))
    (gitlab-read--answer choices input)))

;;;###autoload
(defun gitlab-read-pipeline-id (&optional prompt)
  "Read a pipeline ID, completing from the cached list.
PROMPT defaults to \"Pipeline: \".  A typed ID wins when the list
has no matching label."
  (let* ((pipelines (gitlab-pipeline-list-cached))
         (choices
          (mapcar
           (lambda (pipeline)
             (let ((id (gitlab-data-id-string
                        (gitlab-data-field "id" pipeline)))
                   (status (gitlab-data-field-string "status" pipeline))
                   (ref (gitlab-data-field-string "ref" pipeline)))
               (cons (format "#%s  %s  %s" id status ref) id)))
           pipelines))
         (input (completing-read (or prompt "Pipeline: ")
                                 choices nil nil)))
    (gitlab-read--answer choices input)))

;;;###autoload
(defun gitlab-read-job-id (&optional prompt)
  "Read a job ID from a pipeline, completing from the jobs list.
PROMPT defaults to \"Job: \".  The function first reads a
pipeline through `gitlab-read-pipeline-id', then completes over
its jobs.  A typed ID wins when the jobs list has no match."
  (let* ((pipeline-id (gitlab-read-pipeline-id "Pipeline of the job: "))
         (data (gitlab-pipeline-show pipeline-id))
         (jobs (gitlab-data-field "jobs" data))
         (choices
          (mapcar
           (lambda (job)
             (let ((id (gitlab-data-id-string
                        (gitlab-data-field "id" job)))
                   (name (gitlab-data-field-string "name" job))
                   (stage (gitlab-data-field-string "stage" job))
                   (status (gitlab-data-field-string "status" job)))
               (cons (format "%s  %s  %s" name stage status) id)))
           jobs))
         (input (completing-read (or prompt "Job: ")
                                 choices nil nil)))
    (gitlab-read--answer choices input)))

(provide 'gitlab-read)

;;; gitlab-read.el ends here
