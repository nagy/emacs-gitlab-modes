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

(defun gitlab-evil-test--binding (mode key &optional visual)
  "Return the command that KEY runs in a buffer with MODE and evil."
  (with-temp-buffer
    (funcall mode)
    (gitlab-evil--maybe-enable)
    (evil-local-mode 1)
    (if visual (evil-visual-char) (evil-normal-state))
    (key-binding (kbd key))))

(ert-deftest gitlab-evil-list-keys-remap ()
  "The list bindings reach the GitLab commands through a remap."
  (gitlab-test-with-environment
   (should (eq (gitlab-evil-test--binding #'gitlab-list-mode "RET")
               #'gitlab-list-open))
   (should (eq (gitlab-evil-test--binding #'gitlab-list-mode "S")
               #'tabulated-list-sort))
   (should (eq (gitlab-evil-test--binding #'gitlab-list-mode "gr")
               #'revert-buffer))
   (should (eq (gitlab-evil-test--binding #'gitlab-list-mode "y" 'visual)
               #'gitlab-evil-list-copy-ids))))

(ert-deftest gitlab-evil-detail-keys-remap ()
  "The detail bindings reach the GitLab commands through a remap."
  (gitlab-test-with-environment
   (should (eq (gitlab-evil-test--binding #'gitlab-merge-request-mode "RET")
               #'gitlab-open-at-point))
   (should (eq (gitlab-evil-test--binding #'gitlab-merge-request-mode "q")
               #'quit-window))))

(ert-deftest gitlab-evil-job-log-keys-remap ()
  "The job log bindings reach the GitLab commands through a remap."
  (gitlab-test-with-environment
   (should (eq (gitlab-evil-test--binding #'gitlab-job-log-mode "q")
               #'quit-window))
   (should (eq (gitlab-evil-test--binding #'gitlab-job-log-mode "gr")
               #'gitlab-job-log-restart))))

(ert-deftest gitlab-evil-remap-follows-command ()
  "A remap keeps the GitLab command on a new key of the evil command."
  (gitlab-test-with-environment
   (keymap-set evil-normal-state-map "C-c C-r" #'evil-ret)
   (unwind-protect
       (should (eq (gitlab-evil-test--binding #'gitlab-list-mode "C-c C-r")
                   #'gitlab-list-open))
     (keymap-unset evil-normal-state-map "C-c C-r"))))

(ert-deftest gitlab-evil-remap-stays-local ()
  "A buffer without a GitLab mode keeps the plain evil command."
  (gitlab-test-with-environment
   (with-temp-buffer
     (evil-local-mode 1)
     (evil-normal-state)
     (should (eq (key-binding (kbd "RET")) #'evil-ret)))))

(ert-deftest gitlab-evil-auto-enable-default ()
  "The bindings install without an explicit call by default."
  (should (default-value 'gitlab-evil-auto-enable)))

(ert-deftest gitlab-evil-auto-setup-on ()
  "The auto setup turns the global mode on when the option allows it."
  (gitlab-test-with-environment
   (let ((gitlab-evil-auto-enable t))
     (unwind-protect
         (progn
           (gitlab-evil-auto-setup)
           (should gitlab-evil-mode))
       (gitlab-evil-mode -1)))))

(ert-deftest gitlab-evil-auto-setup-off ()
  "The auto setup leaves the global mode off when the option says no."
  (gitlab-test-with-environment
   (let ((gitlab-evil-auto-enable nil))
     (unwind-protect
         (progn
           (gitlab-evil-auto-setup)
           (should-not gitlab-evil-mode))
       (gitlab-evil-mode -1)))))

(ert-deftest gitlab-evil-auto-setup-runs-from-hook ()
  "The load hook of evil enables the global mode."
  (gitlab-test-with-environment
   (let ((gitlab-evil-auto-enable t))
     (unwind-protect
         (progn
           (add-hook 'evil-after-load-hook #'gitlab-evil-auto-setup)
           (run-hooks 'evil-after-load-hook)
           (should gitlab-evil-mode))
       (remove-hook 'evil-after-load-hook #'gitlab-evil-auto-setup)
       (gitlab-evil-mode -1)))))

(provide 'gitlab-evil-tests)

;;; gitlab-evil-tests.el ends here
