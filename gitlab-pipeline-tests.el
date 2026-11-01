;;; gitlab-pipeline-tests.el --- Tests of the pipeline views -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Daniel Nagy

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;;; Commentary:

;; Offline tests of the pipeline list, the pipeline detail buffer and
;; the streaming job log.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'gitlab-test-helpers)
(require 'gitlab-pipeline)

(defvar gitlab-pipeline-tests--trace-text
  (concat "2026-10-30T20:59:37.687111Z 00O Running job\n"
          "2026-10-30T20:59:38.687139Z 00O step 1\n"
          "2026-10-30T20:59:39.687142Z 01O step 2\n"
          "2026-10-30T20:59:39.687200Z 00O+Section start\n")
  "Trace text that the fixture gives to the job log buffer.")

(defun gitlab-pipeline-tests--wait-for (buffer text)
  "Wait until BUFFER contains TEXT."
  (gitlab-test-wait
   (lambda ()
     (and (buffer-live-p buffer)
          (with-current-buffer buffer
            (string-match-p (regexp-quote text) (buffer-string)))))))

(ert-deftest gitlab-pipeline-list-entries ()
  "The pipeline list renders both pipelines."
  (gitlab-test-with-environment
   (let ((buffer (generate-new-buffer "*GitLab pipeline list test*")))
     (unwind-protect
         (with-current-buffer buffer
           (gitlab-pipeline-list-mode)
           (gitlab-list--refresh)
           (should (gitlab-test-wait
                    (lambda () (= 2 (length tabulated-list-entries)))))
           (should (string-match-p "1003" (buffer-string)))
           (should (string-match-p "running" (buffer-string)))
           (should (string-match-p "feature-branch" (buffer-string))))
       (kill-buffer buffer)))))

(ert-deftest gitlab-pipeline-list-thing-at-point-url ()
  "The url thing at point is the web URL of the pipeline row."
  (gitlab-test-with-environment
   (let ((buffer (generate-new-buffer "*GitLab pipeline list url test*")))
     (unwind-protect
         (with-current-buffer buffer
           (gitlab-pipeline-list-mode)
           (gitlab-list--refresh)
           (should (gitlab-test-wait
                    (lambda () (= 2 (length tabulated-list-entries)))))
           (goto-char (point-min))
           (forward-line 1)
           (forward-char 3)
           (should (equal "https://gitlab.example/group/project/-/pipelines/1003"
                          (thing-at-point 'url)))
           (should (equal (gitlab-data-field
                           "web_url" (gitlab-list--row-at-point))
                          (thing-at-point 'url))))
       (with-current-buffer buffer
         (set-buffer-modified-p nil))
       (kill-buffer buffer)))))

(ert-deftest gitlab-pipeline-finished-buffer-does-not-poll ()
  "A fetched finished pipeline is not stale."
  (gitlab-test-with-environment
   (let ((gitlab-refresh-visible-only nil)
         (buffer (generate-new-buffer "*GitLab pipeline poll test*")))
     (unwind-protect
         (with-current-buffer buffer
           (gitlab-pipeline-mode)
           (setq-local gitlab--id "1001")
           (gitlab--refresh)
           (should (gitlab-test-wait
                    (lambda () (not gitlab--pending))))
           (should (equal "success" (gitlab--status-state gitlab--last-data)))
           (should-not (gitlab--buffer-stale-p)))
       (with-current-buffer buffer
         (set-buffer-modified-p nil))
       (kill-buffer buffer)))))

(ert-deftest gitlab-pipeline-detail-render ()
  "The detail buffer shows the pipeline fields and the jobs table."
  (gitlab-test-with-environment
   (let ((buffer (generate-new-buffer "*GitLab pipeline detail test*")))
     (unwind-protect
         (progn
           (with-current-buffer buffer
             (gitlab-pipeline-mode)
             (setq-local gitlab--id "1001")
             (gitlab--refresh))
           (should (gitlab-pipeline-tests--wait-for
                    buffer "unit-tests"))
           (with-current-buffer buffer
             (should (string-match-p "Pipeline #1001 success"
                                     (buffer-string)))
             (should (string-match-p "Alice (@alice)"
                                     (buffer-string)))
             (should (string-match-p "Jobs" (buffer-string)))
             (should (string-match-p "lint:linux" (buffer-string)))
             (should (string-match-p "1m 40s" (buffer-string)))
             (goto-char (point-min))
             (should (search-forward "unit-tests" nil t))
             (should (equal "5001"
                            (gitlab-pipeline-job-id-at-point)))))
       (kill-buffer buffer)))))

(ert-deftest gitlab-pipeline-detail-keeps-job-point ()
  "A re-render keeps point on the same job row."
  (gitlab-test-with-environment
   (let ((buffer (generate-new-buffer "*GitLab pipeline point test*")))
     (unwind-protect
         (progn
           (with-current-buffer buffer
             (gitlab-pipeline-mode)
             (setq-local gitlab--id "1001")
             (gitlab--refresh))
           (should (gitlab-pipeline-tests--wait-for
                    buffer "lint:linux"))
           (with-current-buffer buffer
             (gitlab-pipeline--goto-job "5002")
             (gitlab--force-render)
             (should (equal "5002"
                            (gitlab-pipeline-job-id-at-point)))))
       (kill-buffer buffer)))))

(ert-deftest gitlab-pipeline-detail-keeps-field-point ()
  "A re-render keeps point on the same pipeline field."
  (gitlab-test-with-environment
   (let ((buffer (generate-new-buffer "*GitLab pipeline field point test*")))
     (unwind-protect
         (progn
           (with-current-buffer buffer
             (gitlab-pipeline-mode)
             (setq-local gitlab--id "1001")
             (gitlab--refresh))
           (should (gitlab-pipeline-tests--wait-for
                    buffer "lint:linux"))
           (with-current-buffer buffer
             (gitlab--goto-field 'status)
             (gitlab--force-render)
             (should (eq 'status (gitlab--field-at-point)))))
       (kill-buffer buffer)))))

(ert-deftest gitlab-pipeline-open-job ()
  "RET on a job row opens the job log."
  (with-temp-buffer
    (insert (propertize "row\n" 'gitlab-job-id "5001"
                        'gitlab-job-name "unit-tests"))
    (goto-char (point-min))
    (let (opened name)
      (cl-letf (((symbol-function 'gitlab-display-job-log)
                 (lambda (id job-name _pipeline-id)
                   (setq opened id name job-name))))
        (gitlab-pipeline-open-job-at-point))
      (should (equal "5001" opened))
      (should (equal "unit-tests" name)))))

(ert-deftest gitlab-pipeline-job-log-stream ()
  "The job log fills from the trace process and reports its end."
  (gitlab-test-with-environment
   (let ((buffer (generate-new-buffer "*GitLab job log test*")))
     (unwind-protect
         (progn
           (with-current-buffer buffer
             (gitlab-job-log-mode)
             (setq-local gitlab--id "5001")
             (gitlab-job-log--start))
           (should (gitlab-test-wait
                    (lambda ()
                      (and (buffer-live-p buffer)
                           (with-current-buffer buffer
                             (string-match-p "step 2" (buffer-string)))))))
           (should (gitlab-test-wait
                    (lambda ()
                      (with-current-buffer buffer
                        gitlab-job-log--finished))))
           (with-current-buffer buffer
             (should (string-match-p "finished"
                                     (format "%s" header-line-format)))))
       (kill-buffer buffer)))))

(ert-deftest gitlab-pipeline-job-log-revert ()
  "`revert-buffer' restarts the trace of a job log buffer."
  (gitlab-test-with-environment
   (let ((buffer (gitlab-pipeline--prepare-job-log
                  "5001" "unit-tests")))
     (unwind-protect
         (progn
           (should
            (gitlab-test-wait
             (lambda ()
               (with-current-buffer buffer gitlab-job-log--finished))))
           (with-current-buffer buffer
             (revert-buffer)
             (should
              (gitlab-test-wait
               (lambda ()
                 (with-current-buffer buffer
                   gitlab-job-log--finished))))
             (should (equal gitlab-pipeline-tests--trace-text
                            (gitlab-test-buffer-string buffer)))))
       (with-current-buffer buffer
         (set-buffer-modified-p nil))
       (kill-buffer buffer)))))

(ert-deftest gitlab-pipeline-job-log-open-twice ()
  "Opening a job log again replaces the old trace."
  (gitlab-test-with-environment
   (let ((first (gitlab-pipeline--prepare-job-log "5001" "unit-tests")))
     (gitlab-test-wait
      (lambda () (with-current-buffer first gitlab-job-log--finished)))
     (let ((second (gitlab-pipeline--prepare-job-log
                    "5001" "unit-tests")))
       (should (eq first second))
       (gitlab-test-wait
        (lambda () (with-current-buffer second gitlab-job-log--finished)))
       (with-current-buffer second
         (should (equal gitlab-pipeline-tests--trace-text
                        (gitlab-test-buffer-string second)))
         (should-not (buffer-modified-p))))
     (kill-buffer first))))

(ert-deftest gitlab-pipeline-job-log-drops-banner ()
  "The job log hides the banner that glab prints before the trace."
  (gitlab-test-with-environment
   (let ((buffer (gitlab-pipeline--prepare-job-log
                  "5001" "unit-tests")))
     (unwind-protect
         (progn
           (should
            (gitlab-test-wait
             (lambda ()
               (with-current-buffer buffer gitlab-job-log--finished))))
           (with-current-buffer buffer
             (should-not (string-match-p "Getting job trace"
                                         (buffer-string)))
             (should-not (string-match-p "Showing logs for"
                                         (buffer-string)))
             (should (string-prefix-p "2026-10-30T20:59:37"
                                      (gitlab-test-buffer-string buffer)))))
       (kill-buffer buffer)))))

(ert-deftest gitlab-pipeline-job-log-timestamps ()
  "The job log keeps timestamps and the toggle hides them."
  (gitlab-test-with-environment
   (let ((buffer (gitlab-pipeline--prepare-job-log
                  "5001" "unit-tests")))
     (unwind-protect
         (progn
           (should
            (gitlab-test-wait
             (lambda ()
               (with-current-buffer buffer gitlab-job-log--finished))))
           (with-current-buffer buffer
             (should gitlab-job-log-show-timestamps)
             (should (string-match-p "2026-10-30T20:59:38\\.687139Z"
                                     (gitlab-test-buffer-string buffer)))
             (should-not (get-text-property (point-min) 'display))
             (call-interactively #'gitlab-job-log-toggle-timestamps)
             (should-not gitlab-job-log-show-timestamps)
             (should (equal "" (get-text-property (point-min) 'display)))
             (should (string-match-p "step 1"
                                     (gitlab-test-buffer-string buffer)))
             (gitlab-job-log-toggle-timestamps)
             (should gitlab-job-log-show-timestamps)
             (should-not (get-text-property (point-min) 'display))))
       (kill-buffer buffer)))))

(defun gitlab-pipeline-tests--visible-line-text ()
  "Return the text of the current line after a hidden prefix."
  (let ((end (line-end-position))
        (start (point)))
    (while (and (< start end)
                (equal "" (get-text-property start 'display)))
      (setq start (1+ start)))
    (buffer-substring start end)))

(ert-deftest gitlab-pipeline-job-log-prefix-stream-identifier ()
  "The toggle hides the stream identifier and keeps text spaces."
  (let* ((shown (concat "2026-10-30T20:59:37.000Z 00O one\n"
                        "2026-10-30T20:59:38.000Z 00O+Section\n"
                        "2026-10-30T20:59:39.000Z 01E   indented\n"
                        "2026-10-30T20:59:40.000Z 01O\ttabbed\n"))
         (buffer (gitlab-pipeline-tests--job-log-with-trace shown)))
    (unwind-protect
        (with-current-buffer buffer
          (call-interactively #'gitlab-job-log-toggle-timestamps)
          (goto-char (point-min))
          (should (equal "one" (gitlab-pipeline-tests--visible-line-text)))
          (forward-line 1)
          (should (equal "Section"
                         (gitlab-pipeline-tests--visible-line-text)))
          (forward-line 1)
          (should (equal "  indented"
                         (gitlab-pipeline-tests--visible-line-text)))
          (forward-line 1)
          (should (equal "tabbed"
                         (gitlab-pipeline-tests--visible-line-text)))
          (should (eq t (get-text-property (point-min)
                                           'gitlab-job-log-timestamp)))
          (gitlab-job-log-toggle-timestamps)
          (should-not (get-text-property (point-min) 'display))
          (should (equal shown (gitlab-test-buffer-string buffer))))
      (kill-buffer buffer))))

(ert-deftest gitlab-pipeline-job-log-duration-string ()
  "A duration keeps three decimals and grows by minutes and hours."
  (should (equal "1.234s" (gitlab-job-log--duration-string 1.234)))
  (should (equal "2m 3.456s" (gitlab-job-log--duration-string 123.456)))
  (should (equal "1h 2m 3.456s" (gitlab-job-log--duration-string 3723.456)))
  (should (equal "1m 0.000s" (gitlab-job-log--duration-string 59.9996))))

(defun gitlab-pipeline-tests--job-log-with-trace (text)
  "Return a job log buffer that holds TEXT and select the whole text."
  (let ((buffer (generate-new-buffer "*GitLab job log mode line test*")))
    (with-current-buffer buffer
      (gitlab-job-log-mode)
      (let ((inhibit-read-only t))
        (insert text))
      (set-buffer-modified-p nil)
      (goto-char (point-min))
      (set-mark (point-max))
      (activate-mark))
    buffer))

(ert-deftest gitlab-pipeline-job-log-mode-line-region-duration ()
  "The mode line sums the duration of the stamped region lines."
  (let ((buffer
         (gitlab-pipeline-tests--job-log-with-trace
          (concat "2026-10-30T20:59:37.000Z 00O one\n"
                  "no timestamp here\n"
                  "2026-10-30T20:59:38.250Z 00O two\n"
                  "2026-10-30T20:59:40.750Z 00O three\n"))))
    (unwind-protect
        (with-current-buffer buffer
          (gitlab-job-log--update-mode-line)
          (should (equal " [3 in region, 3.750s]"
                         gitlab-job-log--mode-line-cache))
          (should (eq 'mode-line-format-right-align
                      (nth (- (length mode-line-format) 2)
                           mode-line-format)))
          (should (equal gitlab-job-log--mode-line-cache
                         (car (last mode-line-format)))))
      (kill-buffer buffer))))

(ert-deftest gitlab-pipeline-job-log-mode-line-without-region ()
  "The mode line drops the region section when the region is gone."
  (let ((buffer
         (gitlab-pipeline-tests--job-log-with-trace
          "2026-10-30T20:59:37.000Z 00O one\n")))
    (unwind-protect
        (with-current-buffer buffer
          (gitlab-job-log--update-mode-line)
          (should (equal "" gitlab-job-log--mode-line-cache))
          (deactivate-mark)
          (gitlab-job-log--mode-line-maybe-update)
          (should (equal "" gitlab-job-log--mode-line-cache))
          (should-not (memq 'mode-line-format-right-align
                            mode-line-format)))
      (kill-buffer buffer))))

(ert-deftest gitlab-pipeline-job-log-mode-line-option-off ()
  "The option turns the region section off."
  (let ((buffer
         (gitlab-pipeline-tests--job-log-with-trace
          (concat "2026-10-30T20:59:37.000Z 00O one\n"
                  "2026-10-30T20:59:38.000Z 00O two\n"))))
    (unwind-protect
        (with-current-buffer buffer
          (setq-local gitlab-job-log-show-region-duration nil)
          (gitlab-job-log--update-mode-line)
          (should (equal "" gitlab-job-log--mode-line-cache)))
      (kill-buffer buffer))))

(ert-deftest gitlab-pipeline-job-log-mode-line-hidden-timestamps ()
  "A hidden timestamp still measured the region."
  (let ((buffer
         (gitlab-pipeline-tests--job-log-with-trace
          (concat "2026-10-30T20:59:37.000Z 00O one\n"
                  "2026-10-30T20:59:38.500Z 00O two\n"))))
    (unwind-protect
        (with-current-buffer buffer
          (call-interactively #'gitlab-job-log-toggle-timestamps)
          (should-not gitlab-job-log-show-timestamps)
          (gitlab-job-log--update-mode-line)
          (should (equal " [2 in region, 1.500s]"
                         gitlab-job-log--mode-line-cache))
          (deactivate-mark)
          (gitlab-job-log--update-mode-line)
          (should (equal "" gitlab-job-log--mode-line-cache)))
      (kill-buffer buffer))))

(ert-deftest gitlab-pipeline-job-log-split-chunk ()
  "A chunk that cuts a line keeps the rest for the next chunk."
  (with-temp-buffer
    (gitlab-job-log-mode)
    (gitlab-job-log--write "Getting job trace...\nstep ")
    (should (equal "" (gitlab-test-buffer-string (current-buffer))))
    (gitlab-job-log--write "1\nstep 2")
    (should (equal "step 1\n"
                   (gitlab-test-buffer-string (current-buffer))))
    (gitlab-job-log--flush)
    (should (equal "step 1\nstep 2\n"
                   (gitlab-test-buffer-string (current-buffer))))))

(ert-deftest gitlab-pipeline-entries-fields ()
  "A pipeline row carries ID, status, ref and source."
  (let* ((data '(((id . 9)
                  (status . "success")
                  (ref . "main")
                  (source . "push")
                  (updated_at . "2026-10-31T20:57:30.763Z"))))
         (entries (gitlab-pipeline--entries data))
         (row (cadr (car entries))))
    (should (equal "9" (car (car entries))))
    (should (equal "9" (aref row 0)))
    (should (equal "success" (aref row 1)))
    (should (equal "main" (aref row 2)))
    (should (equal "push" (aref row 3)))
    (should (equal "2026-10-31 20:57:30" (aref row 4)))
    (should (eq 'gitlab-date (get-text-property 0 'face (aref row 4))))))

(ert-deftest gitlab-pipeline-job-log-list-buffers-directory ()
  "A job log names its job in `list-buffers-directory'."
  (gitlab-test-with-environment
   (let ((buffer (gitlab-pipeline--prepare-job-log "5001" "unit-tests")))
     (unwind-protect
         (progn
           (gitlab-test-wait
            (lambda ()
              (with-current-buffer buffer gitlab-job-log--finished)))
           (with-current-buffer buffer
             (should (equal "5001" list-buffers-directory))))
       (kill-buffer buffer)))))

(ert-deftest gitlab-pipeline-job-log-parent-stored ()
  "A job log that knows its pipeline opens the pipeline buffer."
  (gitlab-test-with-environment
   (let ((buffer (gitlab-pipeline--prepare-job-log
                  "5001" "unit-tests" "1001")))
     (unwind-protect
         (with-current-buffer buffer
           (should (equal "1001" (gitlab-job-log-pipeline-id)))
           (gitlab-go-to-parent)
           (should (derived-mode-p 'gitlab-pipeline-mode))
           (should (equal "1001" gitlab--id)))
       (kill-buffer buffer)
       (when-let* ((pipeline (get-buffer "*GitLab Pipeline #1001*")))
         (kill-buffer pipeline))))))

(ert-deftest gitlab-pipeline-job-log-parent-fetched ()
  "A job log without a stored pipeline asks GitLab for the parent."
  (gitlab-test-with-environment
   (let ((buffer (gitlab-pipeline--prepare-job-log "5001" "unit-tests")))
     (unwind-protect
         (with-current-buffer buffer
           (should (equal "1001" (gitlab-job-log-pipeline-id)))
           (should (equal "1001" gitlab-job-log--pipeline-id))
           (gitlab-go-to-parent)
           (should (derived-mode-p 'gitlab-pipeline-mode))
           (should (equal "1001" gitlab--id)))
       (kill-buffer buffer)
       (when-let* ((pipeline (get-buffer "*GitLab Pipeline #1001*")))
         (kill-buffer pipeline))))))

(ert-deftest gitlab-pipeline-job-log-job-row-passes-pipeline ()
  "RET on a job row passes the pipeline to the log buffer."
  (let (pipeline)
    (cl-letf (((symbol-function 'gitlab-display-job-log)
               (lambda (_id _name pipeline-id)
                 (setq pipeline pipeline-id))))
      (with-temp-buffer
        (gitlab-pipeline-mode)
        (setq-local gitlab--id "1001")
        (let ((inhibit-read-only t))
          (insert (propertize "unit-tests" 'gitlab-job-id "5001")))
        (goto-char (point-min))
        (gitlab-pipeline-open-job-at-point)))
    (should (equal "1001" pipeline))))

(ert-deftest gitlab-pipeline-detail-parent ()
  "A pipeline detail buffer opens the pipeline list."
  (gitlab-test-with-environment
   (let ((buffer (generate-new-buffer "*GitLab pipeline parent test*")))
     (unwind-protect
         (with-current-buffer buffer
           (gitlab-pipeline-mode)
           (setq-local gitlab--id "1001")
           (gitlab-go-to-parent)
           (should (derived-mode-p 'gitlab-pipeline-list-mode)))
       (kill-buffer buffer)
       (when-let* ((list (get-buffer gitlab-pipeline-list-buffer-name)))
         (kill-buffer list))))))

(provide 'gitlab-pipeline-tests)

;;; gitlab-pipeline-tests.el ends here
