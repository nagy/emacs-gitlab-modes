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
    (insert (propertize "!8285" 'gitlab-merge-request-iid "!8285"))
    (goto-char (point-min))
    (should (equal "mr:8285" (gitlab-xref--property-identifier)))))

(ert-deftest gitlab-xref-merge-request-definition-strips-sigil ()
  "A typed mr:!8285 identifier reaches glab without the sigil."
  (let ((buffer (generate-new-buffer "*GitLab xref sigil test*"))
        prepared)
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'gitlab--prepare-detail)
                     (lambda (_buffer _mode id)
                       (setq prepared id)
                       buffer)))
            (xref-backend-definitions 'gitlab "mr:!8285"))
          (should (equal "8285" prepared)))
      (kill-buffer buffer))))

(ert-deftest gitlab-xref-text-identifier ()
  "The backend finds a prefixed ID under point."
  (with-temp-buffer
    (insert "see mr:8285 now")
    (search-backward "mr:")
    (goto-char (+ (point) 3))
    (should (equal "mr:8285" (gitlab-xref--text-identifier)))
    (should (equal "mr:8285"
                   (xref-backend-identifier-at-point 'gitlab)))))

(ert-deftest gitlab-xref-definitions ()
  "A merge request identifier yields one xref item."
  (let ((buffer (generate-new-buffer "*GitLab xref test*")))
    (unwind-protect
        (cl-letf (((symbol-function 'gitlab--prepare-detail)
                   (lambda (_buffer _mode _id) buffer)))
          (let ((items (xref-backend-definitions
                        'gitlab "mr:8285")))
            (should (= 1 (length items)))
            (should (string-match-p "Merge request !8285"
                                    (xref-item-summary (car items))))))
      (kill-buffer buffer))))

(ert-deftest gitlab-xref-completion-table ()
  "Completion lists merge requests and pipelines from the cache."
  (gitlab-test-with-environment
   (let ((ids (xref-backend-identifier-completion-table 'gitlab)))
     (should (member "mr:8285" ids))
     (should (member "pipeline:3012272453" ids)))))

(provide 'gitlab-xref-tests)

;;; gitlab-xref-tests.el ends here
