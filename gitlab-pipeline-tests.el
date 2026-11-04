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

;;; Expanded job rows

(defconst gitlab-pipeline-tests--job-fixture
  "GITLAB_TEST_PIPELINE_JOBS=pipeline-list-jobs.json"
  "Process environment entry that selects the expanded jobs fixture.")

(defun gitlab-pipeline-tests--jobs-list-buffer ()
  "Return a rendered pipeline list buffer, or signal a test failure.
The caller kills the buffer."
  (let ((buffer (generate-new-buffer "*GitLab pipeline jobs test*")))
    (with-current-buffer buffer
      (gitlab-pipeline-list-mode)
      (gitlab-list--refresh))
    (should (gitlab-test-wait
             (lambda ()
               (with-current-buffer buffer
                 (= 2 (length tabulated-list-entries))))))
    buffer))

(defun gitlab-pipeline-tests--expand (buffer pipeline-id)
  "Expand PIPELINE-ID in BUFFER and wait for the job rows."
  (with-current-buffer buffer
    (gitlab-list-toggle-expansion pipeline-id))
  (should (gitlab-test-wait
           (lambda ()
             (with-current-buffer buffer
               (plist-get (gitlab-pipeline--jobs-state pipeline-id)
                          :loaded)))))
  buffer)

(defun gitlab-pipeline-tests--row-ids (buffer)
  "Return the row IDs of the rendered rows of BUFFER."
  (with-current-buffer buffer
    (mapcar #'car tabulated-list-entries)))

(ert-deftest gitlab-pipeline-list-expands-jobs ()
  "TAB expands a pipeline row into five column job rows."
  (gitlab-test-with-environment
   (let ((process-environment
          (cons gitlab-pipeline-tests--job-fixture process-environment))
         (buffer nil))
     (unwind-protect
         (progn
           (setq buffer (gitlab-pipeline-tests--jobs-list-buffer))
           (gitlab-pipeline-tests--expand buffer "1003")
           (with-current-buffer buffer
             (should (equal '("1004" "1003"
                              ("1003" . "6001")
                              ("1003" . "6002")
                              ("1003" . "6003"))
                            (gitlab-pipeline-tests--row-ids buffer)))
             (should (string-match-p "unit-tests" (buffer-string)))
             (let* ((entry (nth 2 tabulated-list-entries))
                    (cells (gitlab-list--entry-cells entry)))
               (should (equal "6001"
                              (string-trim (substring-no-properties
                                            (aref cells 0)))))
               (should (equal "success" (aref cells 1)))
               (should (equal "unit-tests" (aref cells 2)))
               (should (equal "test" (aref cells 3)))
               (should (string-match-p "2026-11-04 09:57:40"
                                       (aref cells 4)))
               (should (equal "1003"
                              (get-text-property
                               0 'gitlab-list-parent-id (aref cells 0))))
               (should (equal "6001"
                              (get-text-property 0 'gitlab-job-id
                                                 (aref cells 0)))))))
       (kill-buffer buffer)))))

(ert-deftest gitlab-pipeline-list-collapses-jobs ()
  "A second TAB hides the job rows of the pipeline again."
  (gitlab-test-with-environment
   (let ((process-environment
          (cons gitlab-pipeline-tests--job-fixture process-environment))
         (buffer nil))
     (unwind-protect
         (progn
           (setq buffer (gitlab-pipeline-tests--jobs-list-buffer))
           (gitlab-pipeline-tests--expand buffer "1003")
           (with-current-buffer buffer
             (gitlab-list-toggle-expansion "1003")
             (should (equal '("1004" "1003")
                            (gitlab-pipeline-tests--row-ids buffer)))))
       (kill-buffer buffer)))))

(ert-deftest gitlab-pipeline-list-job-row-commands ()
  "A job row copies its own ID and names the row of its pipeline."
  (gitlab-test-with-environment
   (let ((process-environment
          (cons gitlab-pipeline-tests--job-fixture process-environment))
         (buffer nil))
     (unwind-protect
         (progn
           (setq buffer (gitlab-pipeline-tests--jobs-list-buffer))
           (gitlab-pipeline-tests--expand buffer "1003")
           (with-current-buffer buffer
             (should (gitlab--goto-property 'gitlab-job-id "6002"))
             (should (equal '(job . "6002") (gitlab--line-identity)))
             (should (equal "https://gitlab.example/group/project/-/jobs/6002"
                            (gitlab-list--thing-at-point-url)))
             (should (equal '(job-row "6002" "1003")
                            (gitlab--bookmark-target)))
             (let ((kill-ring nil))
               (gitlab-list-copy-id)
               (should (equal "6002" (car kill-ring))))
             (should (equal '("1004" "1003")
                            (mapcar #'car (gitlab-list--children))))
             ;; TAB on a child row collapses the row of the parent.
             (gitlab-list-toggle-expansion)
             (should (equal '("1004" "1003")
                            (gitlab-pipeline-tests--row-ids buffer)))))
       (kill-buffer buffer)))))

(ert-deftest gitlab-pipeline-list-sort-keeps-jobs ()
  "A sort keeps the job rows behind the row of their pipeline.
The descending direction reverses the predicate that
`tabulated-list-print' sorts with, so the list layer sorts the
parent rows alone and adds the child rows after the sort."
  (gitlab-test-with-environment
   (let ((process-environment
          (cons gitlab-pipeline-tests--job-fixture process-environment))
         (buffer nil))
     (unwind-protect
         (progn
           (setq buffer (gitlab-pipeline-tests--jobs-list-buffer))
           (gitlab-pipeline-tests--expand buffer "1003")
           (gitlab-pipeline-tests--expand buffer "1004")
           (with-current-buffer buffer
             (gitlab-list-sort 0)
             (should (equal '("1003"
                              ("1003" . "6001")
                              ("1003" . "6002")
                              ("1003" . "6003")
                              "1004"
                              ("1004" . "6001")
                              ("1004" . "6002")
                              ("1004" . "6003"))
                            (gitlab-pipeline-tests--row-ids buffer)))
             (gitlab-list-sort 0)
             (should (equal '("1004"
                              ("1004" . "6001")
                              ("1004" . "6002")
                              ("1004" . "6003")
                              "1003"
                              ("1003" . "6001")
                              ("1003" . "6002")
                              ("1003" . "6003"))
                            (gitlab-pipeline-tests--row-ids buffer)))))
       (kill-buffer buffer)))))

(ert-deftest gitlab-pipeline-list-jobs-error-row ()
  "A failed jobs fetch reports the condition in a child row."
  (gitlab-test-with-environment
   (let ((buffer nil))
     (unwind-protect
         (progn
           (setq buffer (gitlab-pipeline-tests--jobs-list-buffer))
           (with-current-buffer buffer
             (gitlab-list--set-expanded "1003" t)
             (gitlab-pipeline--jobs-set "1003"
                                        :error '(error "boom"))
             (gitlab--render)
             (should (equal '("1004" "1003" (note . "1003"))
                            (gitlab-pipeline-tests--row-ids buffer)))
             (should (string-match-p "Jobs: boom" (buffer-string)))))
       (kill-buffer buffer)))))

(ert-deftest gitlab-pipeline-list-job-row-opens-log ()
  "RET on a job row opens the log of that job.
The row names its pipeline, so the log walks up without a request."
  (gitlab-test-with-environment
   (let ((process-environment
          (cons gitlab-pipeline-tests--job-fixture process-environment))
         (buffer nil)
         (log nil))
     (unwind-protect
         (progn
           (setq buffer (gitlab-pipeline-tests--jobs-list-buffer))
           (gitlab-pipeline-tests--expand buffer "1003")
           (with-current-buffer buffer
             (should (gitlab--goto-property 'gitlab-job-id "6002"))
             (gitlab-list-open))
           (setq log (get-buffer "*GitLab Job 6002*"))
           (should log)
           (with-current-buffer log
             (should (equal "6002" gitlab--id))
             (should (equal "1003" gitlab-job-log--pipeline-id))))
       (when (buffer-live-p log) (kill-buffer log))
       (kill-buffer buffer)))))

(ert-deftest gitlab-pipeline-list-refetches-live-jobs ()
  "A running pipeline takes one jobs answer per list refresh.
A final pipeline keeps its answer, because nothing changes its
jobs without a user action."
  (gitlab-test-with-environment
   (let ((process-environment
          (cons gitlab-pipeline-tests--job-fixture process-environment))
         (buffer nil))
     (unwind-protect
         (progn
           (setq buffer (gitlab-pipeline-tests--jobs-list-buffer))
           (gitlab-pipeline-tests--expand buffer "1003")
           (gitlab-pipeline-tests--expand buffer "1004")
           (with-current-buffer buffer
             (should (= 1 (plist-get (gitlab-pipeline--jobs-state "1004")
                                     :tick)))
             (gitlab-list--refresh))
           (should (gitlab-test-wait
                    (lambda ()
                      (with-current-buffer buffer
                        (let ((state (gitlab-pipeline--jobs-state "1004")))
                          (and (= 2 (plist-get state :tick))
                               (plist-get state :loaded)))))))
           (with-current-buffer buffer
             (should (= 1 (plist-get (gitlab-pipeline--jobs-state "1003")
                                     :tick)))
             (should (plist-get (gitlab-pipeline--jobs-state "1003")
                                :loaded))
             (should (= 8 (length tabulated-list-entries)))))
       (kill-buffer buffer)))))

(ert-deftest gitlab-pipeline-job-time-cell ()
  "A finished job shows its end, a running job the time it runs."
  (let ((finished '((status . "success")
                    (started_at . "2026-11-04T09:56:00.000Z")
                    (finished_at . "2026-11-04T09:57:40.000Z")))
        (running '((status . "running")
                   (started_at . "2020-01-01T00:00:00.000Z")))
        (queued '((status . "created"))))
    (should (equal "2026-11-04 09:57:40"
                   (substring-no-properties
                    (gitlab-pipeline--job-time-cell finished))))
    (should (string-match-p "\\`running [0-9]+h"
                            (gitlab-pipeline--job-time-cell running)))
    (should (equal "-" (gitlab-pipeline--job-time-cell queued)))))

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

(ert-deftest gitlab-pipeline-detail-mouse-face-covers-one-job ()
  "Every mouse face run of the jobs table names one job.
Emacs lights each contiguous character that carries the same
`mouse-face' value, so a run that covers a whole row joins the
runs of the neighbour rows into one block."
  (gitlab-test-with-environment
   (let ((buffer (generate-new-buffer "*GitLab pipeline mouse test*")))
     (unwind-protect
         (progn
           (with-current-buffer buffer
             (gitlab-pipeline-mode)
             (setq-local gitlab--id "1001")
             (gitlab--refresh))
           (should (gitlab-pipeline-tests--wait-for
                    buffer "lint:linux"))
           (with-current-buffer buffer
             (let ((position (point-min))
                   runs)
               (while (< position (point-max))
                 (let ((end (or (next-single-property-change
                                 position 'mouse-face)
                                (point-max))))
                   (when (get-text-property position 'mouse-face)
                     (push (cons position end) runs))
                   (setq position end)))
               (setq runs (cl-remove-if-not
                           (lambda (run)
                             (get-text-property (car run) 'gitlab-job-id))
                           (nreverse runs)))
               (should (= 3 (length runs)))
               (dolist (run runs)
                 (let ((id (get-text-property (car run) 'gitlab-job-id))
                       (position (car run)))
                   (while (< position (cdr run))
                     (should (equal id (get-text-property
                                        position 'gitlab-job-id)))
                     (setq position (1+ position))))))))
       (kill-buffer buffer)))))

(ert-deftest gitlab-pipeline-list-numeric-column-right-aligns ()
  "The identifier column of the pipeline list aligns to the right."
  (should (eq t (plist-get (nthcdr 3 (aref gitlab-pipeline-list-format 0))
                           :right-align)))
  (should (eq 'gitlab-list--number-sort
              (nth 2 (aref gitlab-pipeline-list-format 0)))))

(ert-deftest gitlab-pipeline-detail-table-right-aligns-numbers ()
  "The duration column of the jobs table ends on one edge.
The header and every value take the same width and align to the
right, so a reader compares two durations by their last digit."
  (with-temp-buffer
    (gitlab-pipeline--insert-jobs
     (list (cons 'jobs
                 (list '((id . 5001) (status . "success") (stage . "test")
                         (name . "unit-tests") (duration . 100))
                       '((id . 5002) (status . "failed") (stage . "build")
                         (name . "package") (duration . 3))))))
    (goto-char (point-min))
    (should (search-forward "Duration" nil t))
    (let ((edge (current-column)))
      (goto-char (point-min))
      (should (search-forward "1m 40s" nil t))
      (should (= edge (current-column)))
      (goto-char (point-min))
      (should (search-forward "3s" nil t))
      (should (= edge (current-column))))))

(ert-deftest gitlab-pipeline-detail-job-row-is-a-button ()
  "A job row is one text button of the type `gitlab-object'.
The button carries the mouse face and the tooltip, and the row
carries the navigation properties."
  (with-temp-buffer
    (gitlab-pipeline--insert-job
     '((id . 5001) (status . "success") (stage . "test")
       (name . "unit-tests") (duration . 100))
     36)
    (goto-char (point-min))
    (let ((button (button-at (point))))
      (should button)
      (should (eq 'gitlab-object (button-type button))))
    (should (eq 'highlight (get-char-property (point) 'mouse-face)))
    (should (equal "Job unit-tests (5001)"
                   (get-char-property (point) 'help-echo)))
    (should (equal "5001" (get-text-property (point) 'gitlab-job-id)))
    (should (equal "unit-tests"
                   (get-text-property (point) 'gitlab-job-name)))))

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

(ert-deftest gitlab-pipeline-detail-keeps-column ()
  "A re-render keeps the column of point in a field line."
  (gitlab-test-with-environment
   (let ((buffer (generate-new-buffer "*GitLab pipeline column test*")))
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
             (forward-char 12)
             (gitlab--force-render)
             (should (eq 'status (gitlab--field-at-point)))
             (should (= 12 (- (point) (line-beginning-position))))))
       (kill-buffer buffer)))))

(ert-deftest gitlab-pipeline-detail-keeps-heading-point ()
  "A re-render keeps point on a line without an identity property."
  (gitlab-test-with-environment
   (let ((buffer (generate-new-buffer "*GitLab pipeline heading point test*")))
     (unwind-protect
         (progn
           (with-current-buffer buffer
             (gitlab-pipeline-mode)
             (setq-local gitlab--id "1001")
             (gitlab--refresh))
           (should (gitlab-pipeline-tests--wait-for
                    buffer "lint:linux"))
           (with-current-buffer buffer
             (goto-char (point-min))
             (should (search-forward "Jobs" nil t))
             (beginning-of-line)
             (gitlab--force-render)
             (should (equal "Jobs" (gitlab--line-text)))))
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

(ert-deftest gitlab-pipeline-job-log-point-stays-at-start ()
  "A job log opens at its first line and keeps point there."
  (gitlab-test-with-environment
   (let ((buffer (gitlab-pipeline--prepare-job-log
                  "5001" "unit-tests")))
     (unwind-protect
         (progn
           (with-current-buffer buffer
             (should (= (point) (point-min))))
           (should
            (gitlab-test-wait
             (lambda ()
               (with-current-buffer buffer gitlab-job-log--finished))))
           (with-current-buffer buffer
             (should (> (point-max) (point-min)))
             (should (= (point) (point-min)))))
       (kill-buffer buffer)))))

(ert-deftest gitlab-pipeline-job-log-point-follows-tail ()
  "A log follows output only when point sits at its end."
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
             ;; Point below the last line keeps its place.
             (goto-char (point-min))
             (gitlab-job-log--write "added line\n")
             (should (= (point) (point-min)))
             (should (string-match-p "added line" (buffer-string)))
             ;; Point on the last line follows the new output.
             (goto-char (point-max))
             (gitlab-job-log--write "tail line\n")
             (should (eobp))
             (should (string-suffix-p "tail line\n" (buffer-string)))))
       (kill-buffer buffer)))))

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
             (should-not (get-text-property (point-min) 'invisible))
             (call-interactively #'gitlab-job-log-toggle-timestamps)
             (should-not gitlab-job-log-show-timestamps)
             (should (eq gitlab-job-log--hidden-prefix
                         (get-text-property (point-min) 'invisible)))
             (should (invisible-p (point-min)))
             (should (string-match-p "step 1"
                                     (gitlab-test-buffer-string buffer)))
             (gitlab-job-log-toggle-timestamps)
             (should gitlab-job-log-show-timestamps)
             (should-not (get-text-property (point-min) 'invisible))))
       (kill-buffer buffer)))))

(ert-deftest gitlab-pipeline-job-log-hidden-prefix-invisible ()
  "A hidden prefix hides with `invisible' and not with `display'.
Emacs draws the cursor at the end of the previous line when point
sits in a `display' range with an empty string at the start of a
line, so `move-beginning-of-line' looks like a motion to the line
above.  The `invisible' property keeps the cursor on its line."
  (let ((buffer (gitlab-pipeline-tests--job-log-with-trace
                 (concat "2026-10-30T20:59:37.000Z 00O one\n"
                         "2026-10-30T20:59:38.000Z 01E two\n"))))
    (unwind-protect
        (with-current-buffer buffer
          (call-interactively #'gitlab-job-log-toggle-timestamps)
          (should (memq gitlab-job-log--hidden-prefix
                        buffer-invisibility-spec))
          (goto-char (point-min))
          (while (not (eobp))
            (should (eq gitlab-job-log--hidden-prefix
                        (get-text-property (point) 'invisible)))
            (should (invisible-p (point)))
            (should-not (get-text-property (point) 'display))
            (forward-line 1)))
      (kill-buffer buffer))))

(defun gitlab-pipeline-tests--visible-line-text ()
  "Return the text of the current line after a hidden prefix."
  (let ((end (line-end-position))
        (start (point)))
    (while (and (< start end)
                (get-text-property start 'invisible))
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
          (should (eq 'gitlab-date (get-text-property (point-min) 'face)))
          ;; The stream identifier and its separator keep no timestamp face.
          (should-not (get-text-property (+ (point-min) 25) 'face))
          (gitlab-job-log-toggle-timestamps)
          (should-not (get-text-property (point-min) 'invisible))
          (should (equal shown (gitlab-test-buffer-string buffer))))
      (kill-buffer buffer))))


(ert-deftest gitlab-pipeline-job-log-duration-string ()
  "A duration keeps at most three decimals and no trailing zeroes."
  (should (equal "1.234s" (gitlab-job-log--duration-string 1.234)))
  (should (equal "2m 3.456s" (gitlab-job-log--duration-string 123.456)))
  (should (equal "1h 2m 3.456s" (gitlab-job-log--duration-string 3723.456)))
  (should (equal "1m 0s" (gitlab-job-log--duration-string 59.9996)))
  (should (equal "55s" (gitlab-job-log--duration-string 55)))
  (should (equal "3.7s" (gitlab-job-log--duration-string 3.7)))
  (should (equal "0.05s" (gitlab-job-log--duration-string 0.05)))
  (should (equal "1h 2m 3s" (gitlab-job-log--duration-string 3723))))

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
          (should (equal " [3 in region, 3.75s]"
                         gitlab-job-log--mode-line-cache))
          (should (eq 'mode-line-format-right-align
                      (nth (- (length mode-line-format) 2)
                           mode-line-format)))
          (should (equal gitlab-job-log--mode-line-cache
                         (car (last mode-line-format)))))
      (kill-buffer buffer))))

(ert-deftest gitlab-pipeline-job-log-mode-line-region-downward ()
  "A region that starts at the top and ends lower down is measured.
Point sits below and the mark above, so the helper reads both bounds
before it moves point."
  (let ((buffer
         (gitlab-pipeline-tests--job-log-with-trace
          (concat "2026-10-30T20:59:37.000Z 00O one\n"
                  "2026-10-30T20:59:38.250Z 00O two\n"
                  "2026-10-30T20:59:40.750Z 00O three\n"))))
    (unwind-protect
        (with-current-buffer buffer
          (goto-char (point-max))
          (set-mark (point-min))
          (activate-mark)
          (gitlab-job-log--update-mode-line)
          (should (equal " [3 in region, 3.75s]"
                         gitlab-job-log--mode-line-cache)))
      (kill-buffer buffer))))

(ert-deftest gitlab-pipeline-job-log-mode-line-right-align ()
  "The region section sits at the right edge of the mode line.
The base drops the construct that fills the mode line, because a
filled line leaves no room for the section."
  (let ((buffer
         (gitlab-pipeline-tests--job-log-with-trace
          (concat "2026-10-30T20:59:37.000Z 00O one\n"
                  "2026-10-30T20:59:38.250Z 00O two\n"))))
    (unwind-protect
        (with-current-buffer buffer
          (should (equal (butlast (default-value 'mode-line-format))
                         gitlab-job-log--mode-line-base))
          (gitlab-job-log--update-mode-line)
          (should (eq 'mode-line-format-right-align
                      (nth (- (length mode-line-format) 2)
                           mode-line-format))))
      (kill-buffer buffer))))

(ert-deftest gitlab-pipeline-job-log-mode-line-shared-right-align ()
  "A base that right-aligns receives no second symbol.
A user format already holds a right block behind
`mode-line-format-right-align', so the section joins that block and
the mode line keeps one alignment."
  (let ((original (default-value 'mode-line-format))
        (base '("%e" "LEFT" mode-line-format-right-align "RIGHT"))
        (buffer nil))
    (unwind-protect
        (progn
          (set-default 'mode-line-format base)
          (setq buffer
                (gitlab-pipeline-tests--job-log-with-trace
                 (concat "2026-10-30T20:59:37.000Z 00O one\n"
                         "2026-10-30T20:59:38.250Z 00O two\n")))
          (with-current-buffer buffer
            (gitlab-job-log--update-mode-line)
            (should (equal base (butlast mode-line-format)))
            (should (= 1 (seq-count (lambda (item)
                                      (eq item 'mode-line-format-right-align))
                                    mode-line-format)))
            (should (equal gitlab-job-log--mode-line-cache
                           (car (last mode-line-format))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (set-default 'mode-line-format original))))

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
          (should (equal " [2 in region, 1.5s]"
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
    (should (equal "main" (substring-no-properties (aref row 2))))
    (should (eq 'gitlab-branch (get-text-property 0 'face (aref row 2))))
    (should (equal "push" (aref row 3)))
    (should (equal "2026-10-31 20:57:30" (aref row 4)))
    (should (eq 'gitlab-date (get-text-property 0 'face (aref row 4))))))

(ert-deftest gitlab-pipeline-entries-tag-ref ()
  "A pipeline that runs on a tag marks its ref a tag."
  (let* ((data '(((id . 9) (status . "success")
                  (ref . "v1.0") (tag . t))))
         (row (cadr (car (gitlab-pipeline--entries data)))))
    (should (equal "v1.0" (substring-no-properties (aref row 2))))
    (should (eq 'gitlab-tag (get-text-property 0 'face (aref row 2)))))
  (let* ((data '(((id . 10) (status . "success")
                  (ref . "main") (tag . :false))))
         (row (cadr (car (gitlab-pipeline--entries data)))))
    (should (eq 'gitlab-branch (get-text-property 0 'face (aref row 2))))))

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

(defun gitlab-pipeline-tests--detail-buffer (pipeline-id)
  "Return a rendered pipeline detail buffer for PIPELINE-ID."
  (let ((buffer (generate-new-buffer "*GitLab pipeline sibling test*")))
    (with-current-buffer buffer
      (gitlab-pipeline-mode)
      (gitlab--use-project-directory)
      (setq-local gitlab--id pipeline-id)
      (setq-local gitlab--identity
                  (list #'gitlab-pipeline-mode pipeline-id gitlab--context))
      (gitlab--refresh))
    (gitlab-test-wait
     (lambda () (with-current-buffer buffer gitlab--rendered)))
    buffer))

(defun gitlab-pipeline-tests--list-buffer ()
  "Return a rendered pipeline list buffer."
  (let ((buffer (generate-new-buffer "*GitLab pipeline list sibling test*")))
    (with-current-buffer buffer
      (gitlab-pipeline-list-mode)
      (gitlab--use-project-directory)
      (setq-local gitlab--identity
                  (list #'gitlab-pipeline-list-mode nil gitlab--context))
      (gitlab-list--refresh))
    (gitlab-test-wait
     (lambda () (with-current-buffer buffer
                  (not (null tabulated-list-entries)))))
    buffer))

(defun gitlab-pipeline-tests--plain-job-log-buffer (job-id name pipeline-id)
  "Return a job log buffer of JOB-ID without a trace process."
  (let ((buffer (generate-new-buffer "*GitLab job log sibling test*")))
    (with-current-buffer buffer
      (gitlab-job-log-mode)
      (gitlab--use-project-directory)
      (setq-local gitlab--id job-id)
      (setq-local gitlab--identity
                  (list #'gitlab-job-log-mode job-id gitlab--context))
      (setq-local gitlab-job-log--name name)
      (setq-local gitlab-job-log--pipeline-id pipeline-id))
    buffer))

(ert-deftest gitlab-pipeline-detail-children ()
  "The children of a pipeline buffer are its job rows."
  (gitlab-test-with-environment
   (let ((buffer (gitlab-pipeline-tests--detail-buffer "1001")))
     (unwind-protect
         (with-current-buffer buffer
           (should (equal '(("5001" . "unit-tests")
                            ("5002" . "lint:linux")
                            ("5003" . "package:android"))
                          (gitlab--children))))
       (kill-buffer buffer)))))

(ert-deftest gitlab-pipeline-detail-jobs-ascending ()
  "The job table lists the oldest job first.
The fixture answers the jobs newest first, as glab does."
  (gitlab-test-with-environment
   (let ((buffer (gitlab-pipeline-tests--detail-buffer "1001")))
     (unwind-protect
         (with-current-buffer buffer
           (should (equal '(("5001" . "unit-tests")
                            ("5002" . "lint:linux")
                            ("5003" . "package:android"))
                          (gitlab-pipeline--children))))
       (kill-buffer buffer)))))

(ert-deftest gitlab-pipeline-sort-jobs ()
  "The job sort reads a numeric ID and keeps the answered array."
  (let* ((jobs '(((id . 3) (name . "c"))
                 ((id . "20") (name . "b"))
                 ((id . 1) (name . "a"))))
         (sorted (gitlab-pipeline--sort-jobs jobs)))
    (should (equal '("a" "c" "b") (mapcar (lambda (job)
                                               (gitlab-data-field-string
                                                "name" job))
                                             sorted)))
    (should (equal 3 (gitlab-data-field "id" (car jobs))))))

(ert-deftest gitlab-pipeline-job-log-next-sibling ()
  "The next sibling of a job log is the next job of its pipeline."
  (gitlab-test-with-environment
   (let ((pipeline (gitlab-pipeline-tests--detail-buffer "1001"))
         (log (gitlab-pipeline-tests--plain-job-log-buffer
               "5002" "lint:linux" "1001"))
         opened)
     (unwind-protect
         (with-current-buffer log
           (cl-letf (((symbol-function 'gitlab-display-job-log)
                      (lambda (id name pipeline-id)
                        (setq opened (list id name pipeline-id)))))
             (call-interactively #'gitlab-next-sibling))
           (should (equal '("5003" "package:android" "1001") opened)))
       (kill-buffer log)
       (kill-buffer pipeline)))))

(ert-deftest gitlab-pipeline-job-log-previous-sibling ()
  "The previous sibling of a job log is the earlier job of the pipeline."
  (gitlab-test-with-environment
   (let ((pipeline (gitlab-pipeline-tests--detail-buffer "1001"))
         (log (gitlab-pipeline-tests--plain-job-log-buffer
               "5002" "lint:linux" "1001"))
         opened)
     (unwind-protect
         (with-current-buffer log
           (cl-letf (((symbol-function 'gitlab-display-job-log)
                      (lambda (id name pipeline-id)
                        (setq opened (list id name pipeline-id)))))
             (call-interactively #'gitlab-previous-sibling))
           (should (equal '("5001" "unit-tests" "1001") opened)))
       (kill-buffer log)
       (kill-buffer pipeline)))))

(ert-deftest gitlab-pipeline-job-log-sibling-prefix ()
  "A numeric argument walks several siblings at once."
  (gitlab-test-with-environment
   (let ((pipeline (gitlab-pipeline-tests--detail-buffer "1001"))
         (log (gitlab-pipeline-tests--plain-job-log-buffer
               "5001" "unit-tests" "1001"))
         opened)
     (unwind-protect
         (with-current-buffer log
           (cl-letf (((symbol-function 'gitlab-display-job-log)
                      (lambda (id _name _pipeline-id)
                        (setq opened id))))
             (gitlab-next-sibling 2)
             (should (equal "5003" opened))
             (setq opened nil)
             (gitlab-previous-sibling -2)
             (should (equal "5003" opened))))
       (kill-buffer log)
       (kill-buffer pipeline)))))

(ert-deftest gitlab-pipeline-job-log-sibling-edges ()
  "A walk that leaves the collection signals a `user-error'."
  (gitlab-test-with-environment
   (let ((pipeline (gitlab-pipeline-tests--detail-buffer "1001"))
         (last-log (gitlab-pipeline-tests--plain-job-log-buffer
                    "5003" "package:android" "1001"))
         (first-log (gitlab-pipeline-tests--plain-job-log-buffer
                     "5001" "unit-tests" "1001")))
     (unwind-protect
         (progn
           (with-current-buffer last-log
             (should-error (gitlab-next-sibling) :type 'user-error))
           (with-current-buffer first-log
             (should-error (gitlab-previous-sibling) :type 'user-error)))
       (kill-buffer last-log)
       (kill-buffer first-log)
       (kill-buffer pipeline)))))

(ert-deftest gitlab-pipeline-job-log-sibling-needs-pipeline ()
  "A job log without an open pipeline view signals a `user-error'."
  (gitlab-test-with-environment
   (let ((log (gitlab-pipeline-tests--plain-job-log-buffer
               "5001" "unit-tests" "1001")))
     (unwind-protect
         (with-current-buffer log
           (should-error (gitlab-next-sibling) :type 'user-error))
       (kill-buffer log)))))

(ert-deftest gitlab-pipeline-job-log-sibling-not-in-pipeline ()
  "A job that the pipeline view does not hold signals a `user-error'."
  (gitlab-test-with-environment
   (let ((pipeline (gitlab-pipeline-tests--detail-buffer "1001"))
         (log (gitlab-pipeline-tests--plain-job-log-buffer
               "5099" "gone" "1001")))
     (unwind-protect
         (with-current-buffer log
           (should-error (gitlab-next-sibling) :type 'user-error))
       (kill-buffer log)
       (kill-buffer pipeline)))))

(ert-deftest gitlab-pipeline-detail-next-sibling ()
  "The next sibling of a pipeline is the next row of its pipeline list."
  (gitlab-test-with-environment
   (let ((list (gitlab-pipeline-tests--list-buffer))
         (detail (gitlab-pipeline-tests--detail-buffer "1004"))
         opened)
     (unwind-protect
         (with-current-buffer detail
           (cl-letf (((symbol-function 'gitlab-display-pipeline)
                      (lambda (id) (setq opened id))))
             (call-interactively #'gitlab-next-sibling))
           (should (equal "1003" opened)))
       (kill-buffer detail)
       (kill-buffer list)))))

(ert-deftest gitlab-pipeline-detail-previous-sibling ()
  "The previous sibling of a pipeline is the earlier row of the list."
  (gitlab-test-with-environment
   (let ((list (gitlab-pipeline-tests--list-buffer))
         (detail (gitlab-pipeline-tests--detail-buffer "1003"))
         opened)
     (unwind-protect
         (with-current-buffer detail
           (cl-letf (((symbol-function 'gitlab-display-pipeline)
                      (lambda (id) (setq opened id))))
             (call-interactively #'gitlab-previous-sibling))
           (should (equal "1004" opened)))
       (kill-buffer detail)
       (kill-buffer list)))))

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

(defconst gitlab-pipeline-tests--nested-trace
  (concat
   "2026-11-02T12:00:00.000Z 00O section_start:1761857977:prepare_executor"
   "\r\e[0KPreparing the docker executor...\r\e[0K\n"
   "2026-11-02T12:00:00.300Z 00O section_start:1761857978:prepare_script"
   "\r\e[0KPreparing the \"docker\" executor...\r\e[0K\n"
   "2026-11-02T12:00:00.700Z 00O section_end:1761857979:prepare_script\r\e[0K\n"
   "2026-11-02T12:00:00.800Z 00O section_end:1761857980:prepare_executor\r\e[0K\n"
   "2026-11-02T12:00:01.000Z 00O section_start:1761857981:get_sources"
   "\r\e[0KGetting source from Git repository\r\e[0K\n"
   "2026-11-02T12:00:09.600Z 00O section_end:1761857989:get_sources\r\e[0K\n")
  "Trace text with nested sections and a message after every start marker.
The message follows a carriage return, so the name of the marker
ends at the carriage return and not at the message.")

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

(defun gitlab-pipeline-tests--section-folded-p (regexp)
  "Return non-nil when the section that starts in REGEXP hides its body."
  (save-excursion
    (goto-char (gitlab-pipeline-tests--line-start-of regexp))
    (outline-invisible-p (line-end-position))))

(defun gitlab-pipeline-tests--own-row-p (regexp)
  "Return non-nil when the line that matches REGEXP starts a screen row.
A hidden newline makes Emacs draw the next line on the row before it."
  (let ((position (gitlab-pipeline-tests--line-start-of regexp)))
    (save-excursion
      (goto-char position)
      (vertical-motion 0)
      (= position (point)))))

(ert-deftest gitlab-pipeline-job-log-section-header ()
  "A section marker shows a header with the name and the duration."
  (let ((buffer (gitlab-pipeline-tests--job-log-buffer
                 gitlab-pipeline-tests--section-trace)))
    (unwind-protect
        (with-current-buffer buffer
          (let* ((position (gitlab-pipeline-tests--position-of
                            "section_start:1761857977"))
                 (display (get-text-property position 'display)))
            (should (equal "── get_sources (9s, 1 line) ── "
                           (substring-no-properties display)))
            (should (eq 'gitlab-title (get-text-property 0 'face display))))
          ;; The open section shows no duration yet.
          (should (equal "── step_script ── "
                         (substring-no-properties
                          (get-text-property
                           (gitlab-pipeline-tests--position-of
                            "section_start:1761857987")
                           'display))))
          ;; The end marker text stays in the buffer and disappears.
          (let ((position (gitlab-pipeline-tests--position-of
                           "section_end:1761857986")))
            (should (eq t (get-text-property position
                                             'gitlab-job-log-section-end)))
            (should (equal "" (get-text-property position 'display)))
            ;; The marker joins the line above, so no newline of the
            ;; buffer carries a `display' property.  Emacs draws the
            ;; next header on the line of a folded section when a
            ;; hidden newline sits inside the fold.
            (should-not (eq ?\n (char-before position)))
            (save-excursion
              (goto-char (point-min))
              (while (search-forward "\n" nil t)
                (should-not (stringp (get-text-property (1- (point))
                                                        'display))))))
          ;; The anchor text of the start marker stays on its line.
          (should (string-match-p "Getting source from Git repository"
                                  (gitlab-test-buffer-string buffer))))
      (kill-buffer buffer))))

(ert-deftest gitlab-pipeline-job-log-section-name-before-message ()
  "The message after a start marker stays out of the section name."
  (let ((buffer (gitlab-pipeline-tests--job-log-buffer
                 gitlab-pipeline-tests--nested-trace)))
    (unwind-protect
        (with-current-buffer buffer
          (should (equal '("prepare_executor (3s, 1 line)"
                           "prepare_script (1s, 0 lines)"
                           "get_sources (8s, 0 lines)")
                         (mapcar #'car (gitlab-job-log--imenu-index))))
          (should (equal "── prepare_executor (3s, 1 line) ── "
                         (substring-no-properties
                          (get-text-property
                           (gitlab-pipeline-tests--position-of
                            "section_start:1761857977")
                           'display))))
          ;; A nested header indents under its parent.
          (should (equal "  ── prepare_script (1s, 0 lines) ── "
                         (substring-no-properties
                          (get-text-property
                           (gitlab-pipeline-tests--position-of
                            "section_start:1761857978")
                           'display)))))
      (kill-buffer buffer))))

(ert-deftest gitlab-pipeline-job-log-section-indent-by-depth ()
  "A header indents two spaces per nesting level."
  (let ((buffer (gitlab-pipeline-tests--job-log-buffer
                 (concat "section_start:100:outer\n"
                         "outer line\n"
                         "section_start:101:middle\n"
                         "middle line\n"
                         "section_start:102:inner\n"
                         "inner line\n"
                         "section_end:103:inner\n"
                         "section_end:104:middle\n"
                         "section_end:105:outer\n"))))
    (unwind-protect
        (with-current-buffer buffer
          (should
           (equal "── outer (5s, 5 lines) ── "
                  (substring-no-properties
                   (get-text-property
                    (gitlab-pipeline-tests--position-of "section_start:100")
                    'display))))
          (should
           (equal "  ── middle (3s, 3 lines) ── "
                  (substring-no-properties
                   (get-text-property
                    (gitlab-pipeline-tests--position-of "section_start:101")
                    'display))))
          (should
           (equal "    ── inner (1s, 1 line) ── "
                  (substring-no-properties
                   (get-text-property
                    (gitlab-pipeline-tests--position-of "section_start:102")
                    'display)))))
      (kill-buffer buffer))))

(ert-deftest gitlab-pipeline-job-log-section-end-joins-line ()
  "An end marker joins the line above and keeps no line of its own."
  (let ((buffer (gitlab-pipeline-tests--job-log-buffer
                 gitlab-pipeline-tests--nested-trace)))
    (unwind-protect
        (with-current-buffer buffer
          (let ((first (gitlab-pipeline-tests--position-of
                        "section_end:1761857979"))
                (second (gitlab-pipeline-tests--position-of
                         "section_end:1761857980")))
            ;; The marker text stays in the buffer, behind the message
            ;; of the section that it closes.
            (should (eq t (get-text-property first
                                             'gitlab-job-log-section-end)))
            (should-not (eq ?\n (char-before first)))
            ;; Two markers of two closing sections share one line.
            (should-not (string-search
                         "\n" (buffer-substring-no-properties first second)))))
      (kill-buffer buffer))))

(ert-deftest gitlab-pipeline-job-log-section-fold-keeps-headers-apart ()
  "Every folded section keeps its header on a line of its own."
  (let ((buffer (gitlab-pipeline-tests--job-log-buffer
                 gitlab-pipeline-tests--section-trace)))
    (unwind-protect
        (with-current-buffer buffer
          (dolist (regexp '("section_start:1761857977"
                            "section_start:1761857987"))
            (goto-char (gitlab-pipeline-tests--line-start-of regexp))
            (call-interactively #'gitlab-job-log-toggle-section))
          (should (gitlab-pipeline-tests--section-folded-p
                   "section_start:1761857977"))
          (should (gitlab-pipeline-tests--section-folded-p
                   "section_start:1761857987"))
          ;; Two headers, one row each.
          (should (gitlab-pipeline-tests--own-row-p
                   "section_start:1761857977"))
          (should (gitlab-pipeline-tests--own-row-p
                   "section_start:1761857987")))
      (kill-buffer buffer))))

(ert-deftest gitlab-pipeline-job-log-section-fold-during-stream ()
  "A fold of a close keeps the next header on a row of its own.
The close folds its section while that section ends the buffer, so
the fold must not hide the newline above the next trace line."
  (let ((buffer (generate-new-buffer "*GitLab job log stream fold*")))
    (unwind-protect
        (with-current-buffer buffer
          (gitlab-job-log-mode)
          (setq-local gitlab-job-log--collapsed '("get_sources"))
          (gitlab-job-log--write gitlab-pipeline-tests--section-trace)
          (should (gitlab-pipeline-tests--section-folded-p
                   "section_start:1761857977"))
          (should (gitlab-pipeline-tests--own-row-p
                   "section_start:1761857977"))
          (should (gitlab-pipeline-tests--own-row-p
                   "section_start:1761857987")))
      (kill-buffer buffer))))

(ert-deftest gitlab-pipeline-job-log-section-fold-before-new-output ()
  "A fold of the last section keeps later output on its own row."
  (let ((buffer (generate-new-buffer "*GitLab job log fold tail*")))
    (unwind-protect
        (with-current-buffer buffer
          (gitlab-job-log-mode)
          (gitlab-job-log--write
           (concat "2026-10-30T20:59:37.000Z 00O "
                   "section_start:1761857977:first\n"
                   "2026-10-30T20:59:38.000Z 00O body\n"
                   "2026-10-30T20:59:46.000Z 00O "
                   "section_end:1761857986:first\n"))
          (goto-char (gitlab-pipeline-tests--line-start-of
                      "section_start:1761857977"))
          (call-interactively #'gitlab-job-log-toggle-section)
          (should (gitlab-pipeline-tests--section-folded-p
                   "section_start:1761857977"))
          (gitlab-job-log--write
           (concat "2026-10-30T20:59:47.000Z 00O "
                   "section_start:1761857987:second\n"
                   "2026-10-30T20:59:48.000Z 00O body\n"))
          (should (gitlab-pipeline-tests--own-row-p
                   "section_start:1761857977"))
          (should (gitlab-pipeline-tests--own-row-p
                   "section_start:1761857987")))
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
  "Imenu lists every section with its duration and line count."
  (let ((buffer (gitlab-pipeline-tests--job-log-buffer
                 gitlab-pipeline-tests--section-trace)))
    (unwind-protect
        (with-current-buffer buffer
          (should (eq imenu-create-index-function
                      #'gitlab-job-log--imenu-index))
          (let ((index (gitlab-job-log--imenu-index)))
            (should (equal '("get_sources (9s, 1 line)" "step_script")
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
          (should (gitlab-pipeline-tests--section-folded-p
                   "section_start:1761857977"))
          (call-interactively #'gitlab-job-log-toggle-section)
          (should-not (gitlab-pipeline-tests--section-folded-p
                       "section_start:1761857977")))
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
          (should (gitlab-pipeline-tests--section-folded-p
                   "section_start:1761857987"))
          (gitlab-job-log--write "2026-10-30T20:59:53.000Z 00O more\n")
          (should-not (gitlab-pipeline-tests--section-folded-p
                       "section_start:1761857987")))
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
          (should (gitlab-pipeline-tests--section-folded-p
                   "section_start:1761857977"))
          (should-not (gitlab-pipeline-tests--section-folded-p
                       "section_start:1761857987")))
      (kill-buffer buffer))))

(ert-deftest gitlab-pipeline-job-log-section-timestamps ()
  "The timestamp toggle keeps the headers and the hidden end marker."
  (let ((buffer (gitlab-pipeline-tests--job-log-buffer
                 gitlab-pipeline-tests--section-trace)))
    (unwind-protect
        (with-current-buffer buffer
          (let* ((marker (gitlab-pipeline-tests--position-of
                          "section_start:1761857977"))
                 (end (gitlab-pipeline-tests--position-of
                       "section_end:1761857986"))
                 (header (get-text-property marker 'display)))
            (gitlab-job-log-toggle-timestamps)
            (should (equal (substring-no-properties header)
                           (substring-no-properties
                            (get-text-property marker 'display))))
            (should (equal "" (get-text-property end 'display)))
            (gitlab-job-log-toggle-timestamps)
            (should (equal (substring-no-properties header)
                           (substring-no-properties
                            (get-text-property marker 'display))))
            (should (equal "" (get-text-property end 'display)))))
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
               (should (equal '("get_sources (9s, 1 line)" "step_script")
                              (mapcar #'car (gitlab-job-log--imenu-index))))
               (should (equal "── get_sources (9s, 1 line) ── "
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

(ert-deftest gitlab-pipeline-command-modes ()
  "The pipeline commands name the modes in which they work."
  (should (equal '(gitlab-pipeline-mode)
                 (command-modes #'gitlab-pipeline-open-job-at-point)))
  (should (equal '(gitlab-job-log-mode)
                 (command-modes #'gitlab-job-log-toggle-section)))
  (should (equal '(gitlab-job-log-mode)
                 (command-modes #'gitlab-job-log-toggle-timestamps)))
  (should (equal '(gitlab-job-log-mode)
                 (command-modes #'gitlab-job-log-go-to-parent)))
  (should (equal '(gitlab-job-log-mode)
                 (command-modes #'gitlab-job-log-restart)))
  (should-not (command-modes #'gitlab-list-pipelines))
  (should-not (command-modes #'gitlab-display-pipeline))
  (should-not (command-modes #'gitlab-display-job-log)))

(provide 'gitlab-pipeline-tests)

;;; gitlab-pipeline-tests.el ends here
