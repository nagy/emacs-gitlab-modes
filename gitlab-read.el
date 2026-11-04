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
;;
;; Every prompt announces a completion category and an annotation
;; function, so a completion UI that reads the metadata of
;; `completion-extra-properties' shows the title of a merge request,
;; the status of a pipeline or the name of a job beside its ID.
;; Marginalia, Embark and `completion-category-overrides' therefore
;; treat one kind of object as one kind of object.
;;
;; `gitlab-read-repository' is the other direction: it reads the project
;; itself, for a directory that names no project.  It completes from
;; `gitlab-repositories', the projects of this session, and from the
;; project of the current directory, and it answers in the PATH or
;; PATH@HOST spelling.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'gitlab-data)
(require 'gitlab-git)

(defvar gitlab-read-repository-history nil
  "History of the repository prompts.")

(defvar gitlab-read-merge-request-history nil
  "History of the merge request prompts.")

(defvar gitlab-read-pipeline-history nil
  "History of the pipeline prompts.")

(defvar gitlab-read-job-history nil
  "History of the job prompts.")

;;;###autoload
(defun gitlab-read-repository (&optional prompt)
  "Read a GitLab project and return it as PATH or PATH@HOST.
PROMPT defaults to \"Repository: \".  Completion offers the
projects that this session displayed, from `gitlab-repositories',
and the project of the current directory, which is also the
default answer.  A project of another instance reads PATH@HOST, so
one prompt reaches every instance the user can authenticate to.
The candidate of the current directory carries a mark, and the
prompt keeps the order of the list, because the project of the
current directory comes first."
  (let* ((current (gitlab-git-context))
         (candidates (delete-dups (delq nil (cons current gitlab-repositories))))
         (completion-extra-properties
          (list :category 'gitlab-repository
                :annotation-function
                (lambda (candidate)
                  (when (equal candidate current) "  (current)"))
                :display-sort-function #'identity))
         (input (completing-read (or prompt "Repository: ")
                                 candidates nil nil nil
                                 'gitlab-read-repository-history
                                 current)))
    (gitlab-cli-repository-normalize input)))

(defun gitlab-read--strip (text prefixes)
  "Return TEXT without a leading character from PREFIXES."
  (declare (pure t) (side-effect-free t))
  (let ((text (string-trim (or text ""))))
    (while (and (> (length text) 1)
                (memq (aref text 0) prefixes))
      (setq text (substring text 1)))
    text))

(defun gitlab-read--number (candidate)
  "Return the number that CANDIDATE names, or 0."
  (declare (pure t) (side-effect-free t))
  (string-to-number (replace-regexp-in-string "[^0-9]" "" candidate)))

(defun gitlab-read--sort-by-number (candidates)
  "Return CANDIDATES in the order of the number that each one names.
The sort orders a typed identifier list by ID and not by the first
character of the text."
  (sort (copy-sequence candidates)
        (lambda (left right)
          (< (gitlab-read--number left)
             (gitlab-read--number right)))))

(defun gitlab-read--candidates (objects id-function)
  "Return a completion alist of OBJECTS.
The candidate of an object is the text that ID-FUNCTION returns,
and the value keeps the object, so an annotation and the default
answer read the object and not its candidate text."
  (mapcar (lambda (object) (cons (funcall id-function object) object))
          objects))

(defun gitlab-read--selected (input candidates id-function)
  "Return the ID that INPUT names in CANDIDATES.
INPUT is the text of the prompt, CANDIDATES the alist of
`gitlab-read--candidates' and ID-FUNCTION the ID string of an
object.  A candidate wins; otherwise the function returns INPUT
without a leading !, # or &."
  (declare (pure t) (side-effect-free t))
  (if-let* ((object (cdr (assoc input candidates))))
      (funcall id-function object)
    (gitlab-read--strip input '(?! ?# ?&))))

(defun gitlab-read--annotator (candidates description)
  "Return an annotation function for CANDIDATES.
CANDIDATES is the alist of `gitlab-read--candidates', and
DESCRIPTION is a function of one object that returns the text
that follows its candidate in the completions buffer."
  (lambda (candidate)
    (when-let* ((object (cdr (assoc candidate candidates)))
                (text (funcall description object)))
      (concat "  " text))))

;;;###autoload
(defun gitlab-read-merge-request-iid (&optional prompt)
  "Read a merge request IID, completing from the cached list.
PROMPT defaults to \"Merge request: \".  A typed ID wins when the
list holds no matching candidate.  A candidate is the whole !IID,
and its annotation holds the title and the state."
  (let* ((merge-requests (gitlab-merge-request-list-cached))
         (id-function
          (lambda (merge-request)
            (format "!%s" (gitlab-data-id-string
                           (gitlab-data-field "iid" merge-request)))))
         (candidates (gitlab-read--candidates merge-requests id-function))
         (completion-extra-properties
          (list :category 'gitlab-merge-request
                :annotation-function
                (gitlab-read--annotator
                 candidates
                 (lambda (merge-request)
                   (format "%s  [%s]"
                           (gitlab-data-field-string "title" merge-request)
                           (gitlab-data-field-string "state" merge-request))))
                :display-sort-function #'gitlab-read--sort-by-number))
         (input (completing-read (or prompt "Merge request: ")
                                 (mapcar #'car candidates)
                                 nil nil nil
                                 'gitlab-read-merge-request-history)))
    (gitlab-read--selected
     input candidates
     (lambda (merge-request)
       (gitlab-data-id-string (gitlab-data-field "iid" merge-request))))))

;;;###autoload
(defun gitlab-read-pipeline-id (&optional prompt)
  "Read a pipeline ID, completing from the cached list.
PROMPT defaults to \"Pipeline: \".  A typed ID wins when the list
holds no matching candidate.  A candidate is the whole #ID, and
its annotation holds the status and the ref."
  (let* ((pipelines (gitlab-pipeline-list-cached))
         (id-function
          (lambda (pipeline)
            (format "#%s" (gitlab-data-id-string
                           (gitlab-data-field "id" pipeline)))))
         (candidates (gitlab-read--candidates pipelines id-function))
         (completion-extra-properties
          (list :category 'gitlab-pipeline
                :annotation-function
                (gitlab-read--annotator
                 candidates
                 (lambda (pipeline)
                   (format "%s  %s"
                           (gitlab-data-field-string "status" pipeline)
                           (gitlab-data-field-string "ref" pipeline))))
                :display-sort-function #'gitlab-read--sort-by-number))
         (input (completing-read (or prompt "Pipeline: ")
                                 (mapcar #'car candidates)
                                 nil nil nil
                                 'gitlab-read-pipeline-history)))
    (gitlab-read--selected
     input candidates
     (lambda (pipeline)
       (gitlab-data-id-string (gitlab-data-field "id" pipeline))))))

;;;###autoload
(defun gitlab-read-job-id (&optional prompt)
  "Read a job ID from a pipeline, completing from the jobs list.
PROMPT defaults to \"Job: \".  The function first reads a
pipeline through `gitlab-read-pipeline-id', then completes over
its jobs.  A typed ID wins when the jobs list holds no matching
candidate.  A candidate is the job ID, and its annotation holds
the name, the stage and the status."
  (let* ((pipeline-id (gitlab-read-pipeline-id "Pipeline of the job: "))
         (data (gitlab-pipeline-show pipeline-id))
         (jobs (gitlab-data-field "jobs" data))
         (id-function
          (lambda (job)
            (gitlab-data-id-string (gitlab-data-field "id" job))))
         (candidates (gitlab-read--candidates jobs id-function))
         (completion-extra-properties
          (list :category 'gitlab-job
                :annotation-function
                (gitlab-read--annotator
                 candidates
                 (lambda (job)
                   (format "%s  %s  %s"
                           (gitlab-data-field-string "name" job)
                           (gitlab-data-field-string "stage" job)
                           (gitlab-data-field-string "status" job))))
                :display-sort-function #'gitlab-read--sort-by-number))
         (input (completing-read (or prompt "Job: ")
                                 (mapcar #'car candidates)
                                 nil nil nil
                                 'gitlab-read-job-history)))
    (gitlab-read--selected
     input candidates
     (lambda (job) (gitlab-data-id-string (gitlab-data-field "id" job))))))

(provide 'gitlab-read)

;;; gitlab-read.el ends here
