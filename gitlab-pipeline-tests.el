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

(ert-deftest gitlab-pipeline-job-log-list-buffers-directory-project ()
  "A job log names its project and its job in `list-buffers-directory'."
  (gitlab-test-with-environment
   (let ((buffer (let ((gitlab-repository "group/project"))
                   (gitlab-pipeline--prepare-job-log "5001" "unit-tests"))))
     (unwind-protect
         (progn
           (gitlab-test-wait
            (lambda ()
              (with-current-buffer buffer gitlab-job-log--finished)))
           (with-current-buffer buffer
             (should (equal "group/project&5001" list-buffers-directory))))
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
  "A pipeline detail buffer opens the pipeline list.
The list belongs to the project of the pipeline."
  (gitlab-test-with-environment
   (let ((buffer (generate-new-buffer "*GitLab pipeline parent test*")))
     (unwind-protect
         (let ((gitlab-repository "group/project"))
           (with-current-buffer buffer
             (gitlab-pipeline-mode)
             (setq-local gitlab--id "1001")
             (gitlab-go-to-parent)
             (should (derived-mode-p 'gitlab-pipeline-list-mode))
             (should (equal "group/project"
                            (buffer-local-value
                             'gitlab--context (current-buffer))))))
       (kill-buffer buffer)
       (when-let* ((list (get-buffer
                          (gitlab--contextual-name
                           gitlab-pipeline-list-buffer-name
                           "group/project"))))
         (kill-buffer list))))))

(defconst gitlab-pipeline-tests--section-trace
  (concat
   "2026-10-30T20:59:37.000Z 00O "
   "section_start:1761857977:get_sources[collapsed=true]\r\e[0K"
   "Getting source from Git repository\r\e[0K\n"
   "2026-10-30T20:59:38.500Z 00O fetch\r\e[0K\n"
   "2026-10-30T20:59:46.600Z 00O section_end:1761857986:get_sources\r\e[0K\n"
   "2026-10-30T20:59:47.000Z 00O section_start:1761857987:step_script\r\e[0K\n"
   "2026-10-30T20:59:52.000Z 00O $ make test\r\e[0K\n")
  "Trace text with two sections, the last one still open.
A trace line ends with the carriage return and the erase sequence
of GitLab, so the log must strip the carriage return from a
section marker line.")

(defun gitlab-pipeline-tests--job-log-buffer (trace)
  "Return a job log buffer that holds TRACE."
  (let ((buffer (generate-new-buffer "*GitLab job log section test*")))
    (with-current-buffer buffer
      (gitlab-job-log-mode)
      (gitlab-job-log--write trace))
    buffer))

(defun gitlab-pipeline-tests--position-of (regexp)
  "Return the start of the first match of REGEXP in the buffer."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward regexp nil t)
      (match-beginning 0))))

(defun gitlab-pipeline-tests--line-start-of (regexp)
  "Return the start of the first line that matches REGEXP."
  (save-excursion
    (goto-char (gitlab-pipeline-tests--position-of regexp))
    (line-beginning-position)))

(defun gitlab-pipeline-tests--section-folded-p (line)
  "Return non-nil when the heading on line number LINE hides its body."
  (save-excursion
    (goto-char (point-min))
    (forward-line line)
    (outline-invisible-p (line-end-position))))

(ert-deftest gitlab-pipeline-job-log-section-header ()
  "A section marker shows a header with the name and the duration."
  (let ((buffer (gitlab-pipeline-tests--job-log-buffer
                 gitlab-pipeline-tests--section-trace)))
    (unwind-protect
        (with-current-buffer buffer
          (let* ((position (gitlab-pipeline-tests--position-of
                            "section_start:1761857977"))
                 (display (get-text-property position 'display)))
            (should (equal "── get_sources (9.000s) ── "
                           (substring-no-properties display)))
            (should (eq 'gitlab-title (get-text-property 0 'face display))))
          ;; The open section shows no duration yet.
          (should (equal "── step_script ── "
                         (substring-no-properties
                          (get-text-property
                           (gitlab-pipeline-tests--position-of
                            "section_start:1761857987")
                           'display))))
          ;; The end marker line disappears, its carriage return too.
          (let ((line (gitlab-pipeline-tests--line-start-of
                       "section_end:1761857986")))
            (should (equal "" (get-text-property line 'display)))
            (should (eq t (get-text-property line
                                             'gitlab-job-log-section-end)))
            (should (equal "" (get-text-property
                                (save-excursion (goto-char line)
                                                (line-end-position))
                                'display))))
          ;; The anchor text of the start marker stays on its line.
          (should (string-match-p "Getting source from Git repository"
                                  (gitlab-test-buffer-string buffer))))
      (kill-buffer buffer))))

(ert-deftest gitlab-pipeline-job-log-section-carriage-returns ()
  "A section marker line keeps no carriage return of its redraw."
  (let ((buffer (gitlab-pipeline-tests--job-log-buffer
                 gitlab-pipeline-tests--section-trace)))
    (unwind-protect
        (with-current-buffer buffer
          (should-not (string-match-p "\r" (buffer-string)))
          (let ((line (gitlab-pipeline-tests--line-start-of
                       "section_start:1761857977")))
            (should (equal (save-excursion (goto-char line)
                                           (line-end-position))
                           (save-excursion
                             (goto-char line)
                             (search-forward "repository")
                             (point))))))
      (kill-buffer buffer))))

(ert-deftest gitlab-pipeline-job-log-section-imenu ()
  "Imenu lists every section with its duration."
  (let ((buffer (gitlab-pipeline-tests--job-log-buffer
                 gitlab-pipeline-tests--section-trace)))
    (unwind-protect
        (with-current-buffer buffer
          (should (eq imenu-create-index-function
                      #'gitlab-job-log--imenu-index))
          (let ((index (gitlab-job-log--imenu-index)))
            (should (equal '("get_sources (9.000s)" "step_script")
                           (mapcar #'car index)))
            (should (equal (gitlab-pipeline-tests--line-start-of
                            "section_start:1761857977")
                           (cdr (car index))))
            (should (equal (gitlab-pipeline-tests--line-start-of
                            "section_start:1761857987")
                           (cdr (cadr index))))))
      (kill-buffer buffer))))

(ert-deftest gitlab-pipeline-job-log-section-fold-from-body ()
  "TAB inside a section folds it, a second TAB opens it again."
  (let ((buffer (gitlab-pipeline-tests--job-log-buffer
                 gitlab-pipeline-tests--section-trace)))
    (unwind-protect
        (with-current-buffer buffer
          (goto-char (point-min))
          (forward-line 1)
          (call-interactively #'gitlab-job-log-toggle-section)
          (should (gitlab-pipeline-tests--section-folded-p 0))
          (call-interactively #'gitlab-job-log-toggle-section)
          (should-not (gitlab-pipeline-tests--section-folded-p 0)))
      (kill-buffer buffer))))

(ert-deftest gitlab-pipeline-job-log-section-fold-needs-heading ()
  "TAB above the first section signals a user error."
  (let ((buffer (generate-new-buffer "*GitLab job log no section test*")))
    (unwind-protect
        (with-current-buffer buffer
          (gitlab-job-log-mode)
          (let ((inhibit-read-only t))
            (insert "2026-10-30T20:59:37.000Z 00O prologue\n"))
          (goto-char (point-min))
          (should-error (call-interactively #'gitlab-job-log-toggle-section)
                        :type 'user-error))
      (kill-buffer buffer))))

(ert-deftest gitlab-pipeline-job-log-section-new-output-opens ()
  "New output reopens the section that a fold closed."
  (let ((buffer (gitlab-pipeline-tests--job-log-buffer
                 gitlab-pipeline-tests--section-trace)))
    (unwind-protect
        (with-current-buffer buffer
          (goto-char (point-max))
          (call-interactively #'gitlab-job-log-toggle-section)
          (should (gitlab-pipeline-tests--section-folded-p 3))
          (gitlab-job-log--write "2026-10-30T20:59:53.000Z 00O more\n")
          (should-not (gitlab-pipeline-tests--section-folded-p 3)))
      (kill-buffer buffer))))

(ert-deftest gitlab-pipeline-job-log-section-restart-keeps-folds ()
  "A restart folds the sections that the old trace folded."
  (let ((buffer (gitlab-pipeline-tests--job-log-buffer
                 gitlab-pipeline-tests--section-trace)))
    (unwind-protect
        (with-current-buffer buffer
          (goto-char (point-min))
          (forward-line 1)
          (call-interactively #'gitlab-job-log-toggle-section)
          (should (equal '("get_sources") (gitlab-job-log--collapsed-names)))
          ;; The steps of `gitlab-job-log--start', without a process.
          (setq-local gitlab-job-log--collapsed
                      (gitlab-job-log--collapsed-names))
          (setq-local gitlab-job-log--sections nil)
          (let ((inhibit-read-only t))
            (erase-buffer))
          (gitlab-job-log--write gitlab-pipeline-tests--section-trace)
          (should (gitlab-pipeline-tests--section-folded-p 0))
          (should-not (gitlab-pipeline-tests--section-folded-p 3)))
      (kill-buffer buffer))))

(ert-deftest gitlab-pipeline-job-log-section-timestamps ()
  "The timestamp toggle keeps the headers and the hidden end marker."
  (let ((buffer (gitlab-pipeline-tests--job-log-buffer
                 gitlab-pipeline-tests--section-trace)))
    (unwind-protect
        (with-current-buffer buffer
          (let* ((marker (gitlab-pipeline-tests--position-of
                          "section_start:1761857977"))
                 (end-line (gitlab-pipeline-tests--line-start-of
                            "section_end:1761857986"))
                 (header (get-text-property marker 'display)))
            (gitlab-job-log-toggle-timestamps)
            (should (equal (substring-no-properties header)
                           (substring-no-properties
                            (get-text-property marker 'display))))
            (should (equal "" (get-text-property end-line 'display)))
            (gitlab-job-log-toggle-timestamps)
            (should (equal (substring-no-properties header)
                           (substring-no-properties
                            (get-text-property marker 'display))))
            (should (equal "" (get-text-property end-line 'display)))))
      (kill-buffer buffer))))

(ert-deftest gitlab-pipeline-job-log-section-stream ()
  "A streamed trace with sections shows a header per section."
  (gitlab-test-with-environment
   (let ((process-environment
          (cons "GITLAB_TEST_TRACE=job-trace-sections.txt"
                process-environment)))
     (let ((buffer (gitlab-pipeline--prepare-job-log "5001" "unit-tests")))
       (unwind-protect
           (progn
             (should
              (gitlab-test-wait
               (lambda ()
                 (with-current-buffer buffer gitlab-job-log--finished))))
             (with-current-buffer buffer
               (should (equal '("get_sources (9.000s)" "step_script")
                              (mapcar #'car (gitlab-job-log--imenu-index))))
               (should (equal "── get_sources (9.000s) ── "
                              (substring-no-properties
                               (get-text-property
                                (point-min) 'display))))
               (should-not (string-match-p "Getting job trace"
                                           (gitlab-test-buffer-string buffer)))
               (should-not (string-match-p "\r"
                                           (gitlab-test-buffer-string buffer)))))
         (kill-buffer buffer))))))

(defun gitlab-pipeline-tests--copy-region (beg end)
  "Return the kill ring text of the region between BEG and END."
  (let ((kill-ring nil)
        (interprogram-cut-function nil))
    (kill-ring-save beg end)
    (substring-no-properties (current-kill 0 t))))

(ert-deftest gitlab-pipeline-job-log-copy-follows-timestamps ()
  "A copy drops the prefix only while the buffer hides it."
  (let* ((shown (concat "2026-10-30T20:59:37.000Z 00O one\n"
                        "2026-10-30T20:59:38.000Z 01E two\n"))
         (buffer (gitlab-pipeline-tests--job-log-with-trace shown)))
    (unwind-protect
        (with-current-buffer buffer
          (gitlab-job-log--apply-timestamps (point-min) (point-max))
          (should (equal shown
                         (gitlab-pipeline-tests--copy-region
                          (point-min) (point-max))))
          (call-interactively #'gitlab-job-log-toggle-timestamps)
          (should (equal "one\ntwo\n"
                         (gitlab-pipeline-tests--copy-region
                          (point-min) (point-max))))
          (should (equal shown (gitlab-test-buffer-string buffer))))
      (kill-buffer buffer))))

(ert-deftest gitlab-pipeline-job-log-copy-reaches-clipboard ()
  "The clipboard receives the filtered text and not the buffer text."
  (let ((buffer (gitlab-pipeline-tests--job-log-with-trace
                 "2026-10-30T20:59:37.000Z 00O one\n"))
        (clip nil))
    (unwind-protect
        (with-current-buffer buffer
          (gitlab-job-log--apply-timestamps (point-min) (point-max))
          (call-interactively #'gitlab-job-log-toggle-timestamps)
          (let ((kill-ring nil)
                (interprogram-cut-function (lambda (string)
                                             (setq clip string))))
            (kill-ring-save (point-min) (point-max)))
          (should (equal "one\n" (substring-no-properties clip))))
      (kill-buffer buffer))))

(ert-deftest gitlab-pipeline-job-log-copy-drops-section-markers ()
  "A copy keeps the message after a marker and drops the marker lines."
  (let ((buffer (gitlab-pipeline-tests--job-log-buffer
                 gitlab-pipeline-tests--section-trace)))
    (unwind-protect
        (with-current-buffer buffer
          (should (equal (concat "Getting source from Git repository\n"
                                 "2026-10-30T20:59:38.500Z 00O fetch\n"
                                 "2026-10-30T20:59:52.000Z 00O $ make test\n")
                         (gitlab-pipeline-tests--copy-region
                          (point-min) (point-max))))
          (call-interactively #'gitlab-job-log-toggle-timestamps)
          (should (equal (concat "Getting source from Git repository\n"
                                 "fetch\n"
                                 "$ make test\n")
                         (gitlab-pipeline-tests--copy-region
                          (point-min) (point-max)))))
      (kill-buffer buffer))))

(ert-deftest gitlab-pipeline-job-log-copy-keeps-read-only-buffer ()
  "A kill command copies and leaves the trace text in place."
  (let ((buffer (gitlab-pipeline-tests--job-log-buffer
                 gitlab-pipeline-tests--section-trace)))
    (unwind-protect
        (with-current-buffer buffer
          (let ((before (buffer-string))
                (kill-ring nil)
                (interprogram-cut-function nil)
                (kill-read-only-ok t))
            (should-not (kill-region (point-min) (point-max)))
            (should (equal before (buffer-string)))
            (should (string-prefix-p "Getting source from Git repository"
                                     (substring-no-properties
                                      (current-kill 0 t))))))
      (kill-buffer buffer))))

(provide 'gitlab-pipeline-tests)

;;; gitlab-pipeline-tests.el ends here
