;;; gitlab-evil-tests.el --- Tests of the optional evil layer -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Daniel Nagy

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;;; Commentary:

;; Tests of gitlab-evil.el.  Evil is a build-time test dependency, not
;; a package dependency.

;;; Code:

(require 'ert)
(require 'evil)
(require 'gitlab-test-helpers)
(require 'gitlab-evil)

(ert-deftest gitlab-evil-mode-defined ()
  "The global mode and the three local modes exist."
  (should (fboundp 'gitlab-evil-mode))
  (should (fboundp 'gitlab-evil-detail-mode))
  (should (fboundp 'gitlab-evil-list-mode))
  (should (fboundp 'gitlab-evil-job-log-mode)))

(ert-deftest gitlab-evil-local-mode-detail ()
  "A merge request buffer adopts the detail bindings."
  (gitlab-test-with-environment
   (with-temp-buffer
     (gitlab-merge-request-mode)
     (gitlab-evil--maybe-enable)
     (should gitlab-evil-detail-mode))))

(ert-deftest gitlab-evil-local-mode-list ()
  "A list buffer adopts the list bindings."
  (gitlab-test-with-environment
   (with-temp-buffer
     (gitlab-merge-request-list-mode)
     (gitlab-evil--maybe-enable)
     (should gitlab-evil-list-mode))))

(ert-deftest gitlab-evil-local-mode-job-log ()
  "A job log buffer adopts the trace bindings."
  (gitlab-test-with-environment
   (with-temp-buffer
     (gitlab-job-log-mode)
     (gitlab-evil--maybe-enable)
     (should gitlab-evil-job-log-mode))))

(ert-deftest gitlab-evil-copy-ids ()
  "A visual range copies the row IDs."
  (gitlab-test-with-environment
   (with-temp-buffer
     (gitlab-list-mode)
     (setq-local tabulated-list-format [("ID" 6 t)])
     (setq-local tabulated-list-entries '(("1" ["one"])
                                          ("2" ["two"])))
     (tabulated-list-print)
     (let* ((start (point-min))
            (end (point-max))
            (ids (gitlab-evil--ids-between start end)))
       (should (equal '("1" "2") ids))))))

(provide 'gitlab-evil-tests)

;;; gitlab-evil-tests.el ends here
