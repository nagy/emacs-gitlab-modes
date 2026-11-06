;;; gitlab-xref-tests.el --- Tests of the GitLab xref backend -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Daniel Nagy

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;;; Commentary:

;; Offline tests of the xref backend.  The definition tests replace the
;; display commands, so no buffer fetch starts.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'gitlab-test-helpers)
(require 'gitlab-xref)

(ert-deftest gitlab-xref-property-identifier ()
  "A text property wins over a typed identifier."
  (with-temp-buffer
    (insert (propertize "row" 'gitlab-pipeline-id "301"))
    (goto-char (point-min))
    (should (equal "pipeline:301" (gitlab-xref--property-identifier)))
    (should (equal 'gitlab (gitlab-xref-backend)))))

(ert-deftest gitlab-xref-merge-request-sigil ()
  "A list row property with a leading ! yields a plain IID."
  (with-temp-buffer
    (insert (propertize "!12" 'gitlab-merge-request-iid "!12"))
    (goto-char (point-min))
    (should (equal "mr:12" (gitlab-xref--property-identifier)))))

(ert-deftest gitlab-xref-merge-request-definition-strips-sigil ()
  "A typed mr:!12 identifier reaches glab without the sigil."
  (let ((buffer (generate-new-buffer "*GitLab xref sigil test*"))
        prepared)
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'gitlab--prepare-detail)
                     (lambda (_buffer _mode id)
                       (setq prepared id)
                       buffer)))
            (xref-backend-definitions 'gitlab "mr:!12"))
          (should (equal "12" prepared)))
      (kill-buffer buffer))))

(ert-deftest gitlab-xref-text-identifier ()
  "The backend finds a prefixed ID under point."
  (with-temp-buffer
    (insert "see mr:12 now")
    (search-backward "mr:")
    (goto-char (+ (point) 3))
    (should (equal "mr:12" (gitlab-xref--text-identifier)))
    (should (equal "mr:12"
                   (xref-backend-identifier-at-point 'gitlab)))))

(ert-deftest gitlab-xref-definitions ()
  "A merge request identifier yields one xref item."
  (let ((buffer (generate-new-buffer "*GitLab xref test*")))
    (unwind-protect
        (cl-letf (((symbol-function 'gitlab--prepare-detail)
                   (lambda (_buffer _mode _id) buffer)))
          (let ((items (xref-backend-definitions
                        'gitlab "mr:12")))
            (should (= 1 (length items)))
            (should (string-match-p "Merge request !12"
                                    (xref-item-summary (car items))))))
      (kill-buffer buffer))))

(ert-deftest gitlab-xref-text-identifier-repository ()
  "The backend finds a project-qualified identifier under point."
  (with-temp-buffer
    (insert "see mr:group/project!12 now")
    (search-backward "mr:")
    (goto-char (+ (point) 3))
    (should (equal "mr:group/project!12"
                   (gitlab-xref--text-identifier)))))

(ert-deftest gitlab-xref-definitions-repository ()
  "A project-qualified identifier binds the project for the fetch."
  (let ((buffer (generate-new-buffer "*GitLab xref repository test*"))
        prepared repository)
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'gitlab--prepare-detail)
                     (lambda (_buffer _mode id)
                       (setq prepared id
                             repository gitlab-repository)
                       buffer)))
            (xref-backend-definitions 'gitlab "mr:group/project!12"))
          (should (equal "12" prepared))
          (should (equal "group/project" repository)))
      (kill-buffer buffer))))

(ert-deftest gitlab-xref-work-item-property-identifier ()
  "A work item row carries the % sigil in its identifier."
  (with-temp-buffer
    (insert (propertize "%21" 'gitlab-work-item-iid "%21"))
    (goto-char (point-min))
    (should (equal "work-item:21" (gitlab-xref--property-identifier)))))

(ert-deftest gitlab-xref-work-item-definition ()
  "A work-item identifier yields one xref item."
  (let ((buffer (generate-new-buffer "*GitLab xref work item test*"))
        prepared)
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'gitlab--prepare-detail)
                     (lambda (_buffer _mode id)
                       (setq prepared id)
                       buffer)))
            (let ((items (xref-backend-definitions
                          'gitlab "work-item:group/project%21")))
              (should (= 1 (length items)))
              (should (string-match-p "Work item %21"
                                      (xref-item-summary (car items))))))
          (should (equal "21" prepared)))
      (kill-buffer buffer))))

(ert-deftest gitlab-xref-completion-table ()
  "Completion lists merge requests, work items and pipelines from the cache."
  (gitlab-test-with-environment
   (let ((ids (xref-backend-identifier-completion-table 'gitlab)))
     (should (member "mr:12" ids))
     (should (member "work-item:21" ids))
     (should (member "pipeline:1003" ids)))))

(ert-deftest gitlab-xref-completion-table-repository ()
  "Completion names the project when one is set."
  (gitlab-test-with-environment
   (let ((gitlab-repository "group/project"))
     (let ((ids (xref-backend-identifier-completion-table 'gitlab)))
       (should (member "mr:group/project!12" ids))
       (should (member "work-item:group/project%21" ids))
       (should (member "pipeline:group/project#1003" ids))))))

(provide 'gitlab-xref-tests)

;;; gitlab-xref-tests.el ends here
