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
           (should (string-match-p "3012272453" (buffer-string)))
           (should (string-match-p "running" (buffer-string)))
           (should (string-match-p "export-dialog-fix" (buffer-string))))
       (kill-buffer buffer)))))

(ert-deftest gitlab-pipeline-detail-render ()
  "The detail buffer shows the pipeline fields and the jobs table."
  (gitlab-test-with-environment
   (let ((buffer (generate-new-buffer "*GitLab pipeline detail test*")))
     (unwind-protect
         (progn
           (with-current-buffer buffer
             (gitlab-pipeline-mode)
             (setq-local gitlab--id "3010647305")
             (gitlab--refresh))
           (should (gitlab-pipeline-tests--wait-for
                    buffer "media-check"))
           (with-current-buffer buffer
             (should (string-match-p "Pipeline #3010647305 success"
                                     (buffer-string)))
             (should (string-match-p "Tavmjong Bah (@tavmjong)"
                                     (buffer-string)))
             (should (string-match-p "Jobs" (buffer-string)))
             (should (string-match-p "clangtidy:linux" (buffer-string)))
             (should (string-match-p "1m 40s" (buffer-string)))
             (goto-char (point-min))
             (should (search-forward "media-check" nil t))
             (should (equal "17624043693"
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
             (setq-local gitlab--id "3010647305")
             (gitlab--refresh))
           (should (gitlab-pipeline-tests--wait-for
                    buffer "clangtidy:linux"))
           (with-current-buffer buffer
             (gitlab-pipeline--goto-job "17624043692")
             (gitlab--force-render)
             (should (equal "17624043692"
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
             (setq-local gitlab--id "3010647305")
             (gitlab--refresh))
           (should (gitlab-pipeline-tests--wait-for
                    buffer "clangtidy:linux"))
           (with-current-buffer buffer
             (gitlab--goto-field 'status)
             (gitlab--force-render)
             (should (eq 'status (gitlab--field-at-point)))))
       (kill-buffer buffer)))))

(ert-deftest gitlab-pipeline-open-job ()
  "RET on a job row opens the job log."
  (with-temp-buffer
    (insert (propertize "row\n" 'gitlab-job-id "17624043693"
                        'gitlab-job-name "media-check"))
    (goto-char (point-min))
    (let (opened name)
      (cl-letf (((symbol-function 'gitlab-display-job-log)
                 (lambda (id job-name)
                   (setq opened id name job-name))))
        (gitlab-pipeline-open-job-at-point))
      (should (equal "17624043693" opened))
      (should (equal "media-check" name)))))

(ert-deftest gitlab-pipeline-job-log-stream ()
  "The job log fills from the trace process and reports its end."
  (gitlab-test-with-environment
   (let ((buffer (generate-new-buffer "*GitLab job log test*")))
     (unwind-protect
         (progn
           (with-current-buffer buffer
             (gitlab-job-log-mode)
             (setq-local gitlab--id "17624043693")
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
                  "17624043693" "media-check")))
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
             (should (equal "Running job\nstep 1\nstep 2\n"
                            (gitlab-test-buffer-string buffer)))))
       (with-current-buffer buffer
         (set-buffer-modified-p nil))
       (kill-buffer buffer)))))

(ert-deftest gitlab-pipeline-job-log-open-twice ()
  "Opening a job log again replaces the old trace."
  (gitlab-test-with-environment
   (let ((first (gitlab-pipeline--prepare-job-log "17624043693" "media-check")))
     (gitlab-test-wait
      (lambda () (with-current-buffer first gitlab-job-log--finished)))
     (let ((second (gitlab-pipeline--prepare-job-log
                    "17624043693" "media-check")))
       (should (eq first second))
       (gitlab-test-wait
        (lambda () (with-current-buffer second gitlab-job-log--finished)))
       (with-current-buffer second
         (should (equal "Running job\nstep 1\nstep 2\n"
                        (gitlab-test-buffer-string second)))
         (should-not (buffer-modified-p))))
     (kill-buffer first))))

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
    (should (equal "push" (aref row 3)))))

(provide 'gitlab-pipeline-tests)

;;; gitlab-pipeline-tests.el ends here
