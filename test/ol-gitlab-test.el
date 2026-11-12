;;; ol-gitlab-test.el --- Tests of the Org link types -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Daniel Nagy

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;;; Commentary:

;; Offline tests of the gitlab-mr, gitlab-work-item, gitlab-pipeline
;; and gitlab-job link types.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'gitlab-test-helper)
(require 'ol-gitlab)

(ert-deftest ol-gitlab-parameters ()
  "The four link types are registered."
  (dolist (type '("gitlab-mr" "gitlab-work-item" "gitlab-pipeline" "gitlab-job"))
    (should (functionp (org-link-get-parameter type :follow)))
    (should (functionp (org-link-get-parameter type :store)))
    (should (functionp (org-link-get-parameter type :export)))))

(ert-deftest ol-gitlab-export-html ()
  "Export writes an HTML anchor when the repository is known."
  (let ((gitlab-repository "group/project"))
    (should (equal
             "<a href=\"https://gitlab.com/group/project/-/merge_requests/12\">Review</a>"
             (gitlab-org--export "gitlab-mr" "12" "Review" 'html)))))

(ert-deftest ol-gitlab-export-keeps-url ()
  "Markdown, LaTeX and plain text keep the web URL."
  (let ((gitlab-repository "group/project"))
    (should (equal
             "[Review](https://gitlab.com/group/project/-/merge_requests/12)"
             (gitlab-org--export "gitlab-mr" "12" "Review" 'md)))
    (should (equal
             "\\href{https://gitlab.com/group/project/-/merge_requests/12}{Review}"
             (gitlab-org--export "gitlab-mr" "12" "Review" 'latex)))
    (should (equal
             "Review (https://gitlab.com/group/project/-/pipelines/301)"
             (gitlab-org--export "gitlab-pipeline" "301" "Review" 'ascii)))))

(ert-deftest ol-gitlab-export-without-repository ()
  "Export keeps the text when the repository is unknown."
  (let ((gitlab-repository nil))
    (should (equal "Review"
                   (gitlab-org--export "gitlab-mr" "12" "Review" 'html)))
    (should (equal "Review"
                   (gitlab-org--export "gitlab-mr" "12" "Review" 'md)))))

(defun ol-gitlab-tests--stored (mode id)
  "Return the link that `org-store-link' stores in MODE with ID."
  (with-temp-buffer
    (funcall mode)
    (setq-local gitlab--id id)
    (let ((org-stored-links nil))
      (org-store-link nil t)
      (car (car org-stored-links)))))

(ert-deftest ol-gitlab-store ()
  "Store reads the ID of a GitLab buffer."
  (gitlab-test-with-environment
   (should (equal "gitlab-mr:12"
                  (ol-gitlab-tests--stored #'gitlab-merge-request-mode "12")))
   (should (equal "gitlab-pipeline:301"
                  (ol-gitlab-tests--stored #'gitlab-pipeline-mode "301")))
   (should (equal "gitlab-job:176"
                  (ol-gitlab-tests--stored #'gitlab-job-log-mode "176")))))

(ert-deftest ol-gitlab-store-work-item ()
  "Store reads the ID of a work item buffer."
  (gitlab-test-with-environment
   (should (equal "gitlab-work-item:21"
                  (ol-gitlab-tests--stored #'gitlab-work-item-mode "21")))))

(ert-deftest ol-gitlab-follow-work-item ()
  "Follow calls the work item display command."
  (let (opened)
    (cl-letf (((symbol-function 'gitlab-display-work-item)
               (lambda (iid) (setq opened iid))))
      (gitlab-org--follow-work-item "%21" nil))
    (should (equal "21" opened))))

(ert-deftest ol-gitlab-store-outside-buffer ()
  "A store function outside a GitLab buffer signals no error.
Org calls the store function of every link type in every buffer,
so an error here would break `org-store-link' everywhere."
  (let ((file (make-temp-file "gitlab-modes-ol-test" nil ".txt")))
    (unwind-protect
        (with-current-buffer (find-file-noselect file)
          (let ((org-stored-links nil))
            (org-store-link nil t)
            (should (string-prefix-p "file:" (car (car org-stored-links))))))
      (when-let* ((buffer (get-file-buffer file)))
        (with-current-buffer buffer
          (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (delete-file file))))

(ert-deftest ol-gitlab-export-qualified-path ()
  "A path with a project exports a web URL without a global repository."
  (let ((gitlab-repository nil))
    (should (equal
             "<a href=\"https://gitlab.com/group/project/-/merge_requests/12\">Review</a>"
             (gitlab-org--export "gitlab-mr" "group/project!12"
                                 "Review" 'html)))
    (should (equal "Review"
                   (gitlab-org--export "gitlab-mr" "12" "Review" 'html)))))

(ert-deftest ol-gitlab-follow ()
  "Follow calls the display command."
  (let (opened)
    (cl-letf (((symbol-function 'gitlab-display-merge-request)
               (lambda (iid) (setq opened iid))))
      (gitlab-org--follow-mr "12" nil))
    (should (equal "12" opened))))

(ert-deftest ol-gitlab-follow-repository ()
  "A path with a project binds the project around the display command."
  (let (opened repository)
    (cl-letf (((symbol-function 'gitlab-display-merge-request)
               (lambda (iid)
                 (setq opened iid
                       repository gitlab-repository))))
      (gitlab-org--follow-mr "group/project!12" nil))
    (should (equal "12" opened))
    (should (equal "group/project" repository))))

(ert-deftest ol-gitlab-follow-empty-path ()
  "A path without an ID signals a `user-error'."
  (should-error (gitlab-org--follow-pipeline "group/project#" nil)
                :type 'user-error))

(ert-deftest ol-gitlab-store-repository ()
  "A set repository yields a project-qualified link."
  (let ((gitlab-repository "group/project"))
    (should (equal "gitlab-mr:group/project!12"
                   (gitlab-org--link "gitlab-mr" "12")))))

(ert-deftest ol-gitlab-store-job-row ()
  "A point on a job row of a pipeline buffer stores the job link."
  (gitlab-test-with-environment
   (with-temp-buffer
     (gitlab-pipeline-mode)
     (let ((inhibit-read-only t))
       (insert (propertize "row" 'gitlab-job-id "176"
                           'gitlab-job-name "unit-tests")))
     (goto-char (point-min))
     (let ((org-stored-links nil))
       (org-store-link nil t)
       (should (equal "gitlab-job:176" (car (car org-stored-links))))))))

(provide 'ol-gitlab-tests)

;;; ol-gitlab-test.el ends here
