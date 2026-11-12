;;; gitlab-bookmark-test.el --- Tests of the GitLab bookmark records -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Daniel Nagy

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;;; Commentary:

;; Offline tests of the identifier syntax, the bookmark records and the
;; jump handler.  The display commands are replaced in the handler
;; tests, and the render tests use the mock glab program.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'bookmark)
(require 'gitlab-test-helper)
(require 'gitlab-merge-request)
(require 'gitlab-pipeline)

;;; Identifier syntax

(ert-deftest gitlab-bookmark-identifier-format ()
  "An identifier holds the project and the sigil of its kind."
  (should (equal "group/project!12"
                 (gitlab-data-identifier 'merge-request "12" "group/project")))
  (should (equal "group/project#301"
                 (gitlab-data-identifier 'pipeline 301 "group/project/")))
  (should (equal "group/project&176"
                 (gitlab-data-identifier 'job "176" "group/project")))
  (should (equal "group/project%21"
                 (gitlab-data-identifier 'work-item "21" "group/project")))
  (should (equal "12" (gitlab-data-identifier 'merge-request "12")))
  (should (equal "12" (gitlab-data-identifier 'merge-request "12" "")))
  (should (equal "group/project"
                 (gitlab-data-identifier 'merge-request nil "group/project"))))

(ert-deftest gitlab-bookmark-identifier-split ()
  "A split returns the project and the ID of an identifier."
  (should (equal '("group/project" . "12")
                 (gitlab-data-identifier-split 'merge-request
                                               "group/project!12")))
  (should (equal '("a/b.c-d_e" . "7")
                 (gitlab-data-identifier-split 'job "a/b.c-d_e&7")))
  (should (equal '("group/project" . "21")
                 (gitlab-data-identifier-split 'work-item
                                               "group/project%21")))
  (should (equal '(nil . "12")
                 (gitlab-data-identifier-split 'merge-request "12")))
  (should (equal '(nil . "12")
                 (gitlab-data-identifier-split 'merge-request "!12")))
  (should (equal '("group/project" . "")
                 (gitlab-data-identifier-split 'pipeline
                                               "group/project#"))))

(ert-deftest gitlab-bookmark-identifier-unknown-kind ()
  "An unknown kind signals a `gitlab-error'."
  (should-error (gitlab-data-identifier 'epic "1" "group/project")
                :type 'gitlab-error))

(ert-deftest gitlab-bookmark-identifier-round-trip ()
  "A formatted identifier splits back to its parts."
  (dolist (kind '(merge-request pipeline job work-item))
    (let* ((text (gitlab-data-identifier kind "42" "group/project"))
           (parts (gitlab-data-identifier-split kind text)))
      (should (equal "group/project" (car parts)))
      (should (equal "42" (cdr parts))))))

;;; Records

(defun gitlab-bookmark-tests--record (&optional buffer)
  "Return the bookmark record of BUFFER, or of the current buffer."
  (with-current-buffer (or buffer (current-buffer))
    (funcall bookmark-make-record-function)))

(ert-deftest gitlab-bookmark-detail-record ()
  "A detail record names the object, the project and the field."
  (gitlab-test-with-environment
   (let ((buffer (generate-new-buffer "*GitLab MR bookmark test*")))
     (unwind-protect
         (with-current-buffer buffer
           (gitlab-merge-request-mode)
           (setq-local gitlab--id "12")
           (let ((inhibit-read-only t))
             (insert (propertize "Title: Fix" 'gitlab-field 'title) "\n"))
           (goto-char (point-min))
           (let ((record (gitlab-bookmark-tests--record)))
             (should (equal "GitLab MR gitlab-mr:12" (car record)))
             (should (eq 'merge-request (alist-get 'kind (cdr record))))
             (should (equal "12" (alist-get 'id (cdr record))))
             (should (equal "gitlab-mr:12" (alist-get 'location (cdr record))))
             (should (eq 'gitlab-bookmark-jump
                         (alist-get 'handler (cdr record))))
             (should (equal '(field . title)
                            (alist-get 'target (cdr record))))
             (should (equal default-directory
                            (alist-get 'directory (cdr record))))))
       (kill-buffer buffer)))))

(ert-deftest gitlab-bookmark-record-repository ()
  "A set repository names the project in the name and the location."
  (gitlab-test-with-environment
   (let ((gitlab-repository "group/project")
         (buffer (generate-new-buffer "*GitLab pipeline bookmark test*")))
     (unwind-protect
         (with-current-buffer buffer
           (gitlab-pipeline-mode)
           (setq-local gitlab--id "1001")
           (let ((record (gitlab-bookmark-tests--record)))
             (should (equal "GitLab Pipeline gitlab-pipeline:group/project#1001"
                            (car record)))
             (should (equal "group/project"
                            (alist-get 'repository (cdr record))))
             (should (equal "gitlab-pipeline:group/project#1001"
                            (alist-get 'location (cdr record))))))
       (kill-buffer buffer)))))

(ert-deftest gitlab-bookmark-pipeline-record-job-row ()
  "A record made on a job row keeps that job as the target."
  (gitlab-test-with-environment
   (let ((buffer (generate-new-buffer "*GitLab pipeline bookmark test*")))
     (unwind-protect
         (progn
           (with-current-buffer buffer
             (gitlab-pipeline-mode)
             (setq-local gitlab--id "1001")
             (gitlab--refresh))
           (should (gitlab-test-wait
                    (lambda ()
                      (with-current-buffer buffer
                        (string-match-p "lint:linux"
                                        (buffer-string))))))
           (with-current-buffer buffer
             (should (gitlab--goto-property 'gitlab-job-id "5002"))
             (let ((record (gitlab-bookmark-tests--record)))
               (should (equal '(job . "5002")
                              (alist-get 'target (cdr record)))))))
       (kill-buffer buffer)))))

(ert-deftest gitlab-bookmark-list-record ()
  "A list record keeps the arguments, the sort column and the row."
  (gitlab-test-with-environment
   (let ((buffer (generate-new-buffer "*GitLab pipeline list bookmark test*")))
     (unwind-protect
         (progn
           (with-current-buffer buffer
             (gitlab-pipeline-list-mode)
             (setq-local gitlab-list--arguments '("--all"))
             (gitlab-list--refresh))
           (should (gitlab-test-wait
                    (lambda ()
                      (with-current-buffer buffer
                        (= 2 (length tabulated-list-entries))))))
           (with-current-buffer buffer
             (should (gitlab-list--goto-id "1003"))
             (let ((record (gitlab-bookmark-tests--record)))
               (should (eq 'pipeline-list (alist-get 'kind (cdr record))))
               (should (equal '("--all")
                              (alist-get 'arguments (cdr record))))
               (should (equal '("Updated" . t)
                              (alist-get 'sort (cdr record))))
               (should (equal '(row . "1003")
                              (alist-get 'target (cdr record))))
               (should (equal "GitLab Pipelines gitlab-pipeline-list"
                              (car record))))))
       (kill-buffer buffer)))))

(ert-deftest gitlab-bookmark-group-list-record ()
  "A group list record keeps the scope, the group and the row."
  (gitlab-test-with-environment
   (let ((buffer nil))
     (unwind-protect
         (progn
           (cl-letf (((symbol-function 'completing-read)
                      (lambda (&rest _arguments) "my-group")))
             (gitlab-list-group-merge-requests)
             (setq buffer (current-buffer)))
           (should (gitlab-test-wait
                    (lambda ()
                      (with-current-buffer buffer
                        (= 2 (length tabulated-list-entries))))))
           (with-current-buffer buffer
             (should (eq 'group gitlab--scope))
             (should (equal "my-group" gitlab--context))
             (should (equal "my-group" list-buffers-directory))
             (should (equal "Project" (car (aref tabulated-list-format 0))))
             (should (gitlab-list--goto-id
                      "group/project@gitlab.example!13"))
             (let ((record (gitlab-bookmark-tests--record)))
               (should (equal "GitLab Group Merge Requests gitlab-mr-list:my-group"
                              (car record)))
               (should (eq 'group (alist-get 'scope (cdr record))))
               (should (equal "my-group" (alist-get 'repository (cdr record))))
               (should (equal '(row . "group/project@gitlab.example!13")
                              (alist-get 'target (cdr record)))))))
       (when (buffer-live-p buffer)
         (kill-buffer buffer))))))

(ert-deftest gitlab-bookmark-job-log-record ()
  "A job log record adds the job name and the pipeline."
  (gitlab-test-with-environment
   (let ((buffer (generate-new-buffer "*GitLab Job bookmark test*")))
     (unwind-protect
         (with-current-buffer buffer
           (gitlab-job-log-mode)
           (setq-local gitlab--id "5001")
           (setq-local gitlab-job-log--name "unit-tests")
           (setq-local gitlab-job-log--pipeline-id "1001")
           (let ((record (gitlab-bookmark-tests--record)))
             (should (eq 'job (alist-get 'kind (cdr record))))
             (should (equal "5001" (alist-get 'id (cdr record))))
             (should (equal "unit-tests" (alist-get 'name (cdr record))))
             (should (equal "1001" (alist-get 'pipeline (cdr record))))
             (should (equal "gitlab-job:5001"
                            (alist-get 'location (cdr record))))))
       (kill-buffer buffer)))))

(ert-deftest gitlab-bookmark-jump-passes-pipeline ()
  "A job log jump passes the stored pipeline to the display command."
  (let (pipeline)
    (cl-letf (((symbol-function 'gitlab-display-job-log)
               (lambda (_id _name pipeline-id)
                 (setq pipeline pipeline-id))))
      (gitlab-bookmark-jump
       (list "GitLab Job gitlab-job:5001"
             (list (cons 'kind 'job)
                   (cons 'id "5001")
                   (cons 'name "unit-tests")
                   (cons 'pipeline "1001")
                   (cons 'handler 'gitlab-bookmark-jump)))))
    (should (equal "1001" pipeline))))

;;; Targets

(ert-deftest gitlab-bookmark-apply-target-field ()
  "A field target moves point to the field line and clears the target."
  (with-temp-buffer
    (insert "Header\n"
            (propertize "Status: success" 'gitlab-field 'status) "\n"
            (propertize "Ref: main" 'gitlab-field 'ref) "\n")
    (setq-local gitlab--target '(field . ref))
    (gitlab--apply-target)
    (should (equal 'ref (gitlab--field-at-point)))
    (should (null gitlab--target))))

(ert-deftest gitlab-bookmark-apply-target-missing-field ()
  "A missing field leaves point where the renderer put it."
  (with-temp-buffer
    (insert "Header\n")
    (setq-local gitlab--target '(field . title))
    (gitlab--apply-target)
    (should (equal (point-min) (point)))
    (should (null gitlab--target))))

(ert-deftest gitlab-bookmark-jump-targets-job-row ()
  "A pending job target lands point on that job row after the fetch."
  (gitlab-test-with-environment
   (let ((buffer (generate-new-buffer "*GitLab pipeline bookmark test*"))
         (gitlab--pending-target '(job . "5002")))
     (unwind-protect
         (progn
           (with-current-buffer buffer
             (gitlab-pipeline-mode)
             (setq-local gitlab--id "1001")
             (gitlab--refresh))
           (should (gitlab-test-wait
                    (lambda ()
                      (with-current-buffer buffer
                        (string-match-p "lint:linux"
                                        (buffer-string))))))
           (with-current-buffer buffer
             (should (equal "5002"
                            (gitlab-pipeline-job-id-at-point)))
             (should (null gitlab--target))))
       (kill-buffer buffer)))))

(ert-deftest gitlab-bookmark-apply-target-job-list-row ()
  "A job-row target expands the pipeline and lands on the job row.
The row waits for the jobs fetch, so the target stays until the
render that shows the job row arrives."
  (gitlab-test-with-environment
   (let ((process-environment
          (cons "GITLAB_TEST_PIPELINE_JOBS=pipeline-list-jobs.json"
                process-environment))
         (buffer (generate-new-buffer "*GitLab pipeline list target test*"))
         (gitlab--pending-target '(job-row "6002" "1003")))
     (unwind-protect
         (progn
           (with-current-buffer buffer
             (gitlab-pipeline-list-mode)
             (gitlab-list--refresh))
           (should (gitlab-test-wait
                    (lambda ()
                      (with-current-buffer buffer
                        (equal "6002"
                               (get-text-property (point)
                                                  'gitlab-job-id))))))
           (with-current-buffer buffer
             (should (equal "6002" (get-text-property (point) 'gitlab-job-id)))
             (should (gitlab-list--expanded-p "1003"))
             (should (null gitlab--target))))
       (kill-buffer buffer)))))

(ert-deftest gitlab-bookmark-list-record-job-row ()
  "A record made on a child row names the job and its pipeline."
  (gitlab-test-with-environment
   (let ((process-environment
          (cons "GITLAB_TEST_PIPELINE_JOBS=pipeline-list-jobs.json"
                process-environment))
         (buffer (generate-new-buffer "*GitLab pipeline list job record*")))
     (unwind-protect
         (progn
           (with-current-buffer buffer
             (gitlab-pipeline-list-mode)
             (gitlab-list--refresh))
           (should (gitlab-test-wait
                    (lambda ()
                      (with-current-buffer buffer
                        (= 2 (length tabulated-list-entries))))))
           (with-current-buffer buffer
             (gitlab-list-toggle-expansion "1003"))
           (should (gitlab-test-wait
                    (lambda ()
                      (with-current-buffer buffer
                        (plist-get (gitlab-pipeline--jobs-state "1003")
                                   :loaded)))))
           (with-current-buffer buffer
             (should (gitlab--goto-property 'gitlab-job-id "6001"))
             (let ((record (gitlab-bookmark-tests--record)))
               (should (eq 'pipeline-list (alist-get 'kind (cdr record))))
               (should (equal '(job-row "6001" "1003")
                              (alist-get 'target (cdr record)))))))
       (kill-buffer buffer)))))

;;; Jump handler
(ert-deftest gitlab-bookmark-jump-restores-project ()
  "A jump restores the project, the directory and the target."
  (let (opened repository directory target)
    (cl-letf (((symbol-function 'gitlab-display-merge-request)
               (lambda (iid)
                 (setq opened iid
                       repository gitlab-repository
                       directory gitlab-cli-directory
                       target gitlab--pending-target))))
      (gitlab-bookmark-jump
       (list "GitLab MR group/project!12"
             (list (cons 'kind 'merge-request)
                   (cons 'id "12")
                   (cons 'repository "group/project")
                   (cons 'directory "/tmp/project/")
                   (cons 'target '(field . title))
                   (cons 'handler 'gitlab-bookmark-jump)))))
    (should (equal "12" opened))
    (should (equal "group/project" repository))
    (should (equal "/tmp/project/" directory))
    (should (equal '(field . title) target))))

(ert-deftest gitlab-bookmark-jump-list-setup ()
  "A list jump passes a setup function that restores the view."
  (let (setup)
    (cl-letf (((symbol-function 'gitlab-list--show)
               (lambda (_buffer _mode function)
                 (setq setup function))))
      (gitlab-bookmark-jump
       (list "GitLab Pipelines gitlab-pipeline-list"
             (list (cons 'kind 'pipeline-list)
                   (cons 'arguments '("--all"))
                   (cons 'sort '("Status" . nil))
                   (cons 'handler 'gitlab-bookmark-jump)))))
    (should (functionp setup))
    (with-temp-buffer
      (gitlab-pipeline-list-mode)
      (funcall setup)
      (should (equal '("--all") gitlab-list--arguments))
      (should (equal '("Status" . nil) tabulated-list-sort-key)))))

(ert-deftest gitlab-bookmark-jump-through-bookmark ()
  "The bookmark system reaches the handler with the whole record."
  (let ((buffer (generate-new-buffer "*GitLab MR bookmark jump test*"))
        (bookmark-alist nil)
        opened)
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (gitlab-merge-request-mode)
            (setq-local gitlab--id "12")
            (setq bookmark-alist
                  (list (cons "mr" (cdr (gitlab-bookmark-tests--record))))))
          (cl-letf (((symbol-function 'gitlab-display-merge-request)
                     (lambda (iid) (setq opened iid))))
            (bookmark-jump "mr"))
          (should (equal "12" opened)))
      (kill-buffer buffer))))

(ert-deftest gitlab-bookmark-jump-keeps-project ()
  "A jumped display buffer keeps the project of the record.
The jump binds `gitlab-repository' around the display command, so
the buffer must capture it and not fall back to the global value on
a later refresh."
  (gitlab-test-with-environment
   (let ((record (list "GitLab Pipeline gitlab-pipeline:group/project#1001"
                       (list (cons 'kind 'pipeline)
                             (cons 'id "1001")
                             (cons 'repository "group/project")
                             (cons 'directory
                                   (expand-file-name default-directory))
                             (cons 'handler 'gitlab-bookmark-jump))))
         buffer)
     (unwind-protect
         (progn
           (gitlab-bookmark-jump record)
           (setq buffer (get-buffer
                         "*GitLab Pipeline group/project#1001*"))
           (should (buffer-live-p buffer))
           (should (equal "group/project"
                          (buffer-local-value 'gitlab-repository buffer)))
           (should (gitlab-test-wait
                    (lambda ()
                      (buffer-local-value 'gitlab--rendered buffer))))
           (should (equal "group/project"
                          (buffer-local-value 'gitlab-repository buffer))))
       (when (buffer-live-p buffer)
         (kill-buffer buffer))))))

(ert-deftest gitlab-bookmark-jump-unknown-kind ()
  "An unknown kind signals a `user-error'."
  (should-error (gitlab-bookmark-jump
                 (list "gitlab" (list (cons 'kind 'epic))))
                :type 'user-error))

(provide 'gitlab-bookmark-tests)

;;; gitlab-bookmark-test.el ends here
