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
          "2026-10-30T20:59:39.687142Z 01O step 2\n")
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
                 (lambda (id job-name)
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

(provide 'gitlab-pipeline-tests)

;;; gitlab-pipeline-tests.el ends here
