;;; gitlab-merge-request-tests.el --- Tests of the merge request views -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Daniel Nagy

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;;; Commentary:

;; Offline tests of the merge request list and detail buffers.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'gitlab-test-helpers)
(require 'gitlab-merge-request)

(defun gitlab-merge-request-tests--wait-for (buffer text)
  "Wait until BUFFER contains TEXT."
  (gitlab-test-wait
   (lambda ()
     (and (buffer-live-p buffer)
          (with-current-buffer buffer
            (string-match-p (regexp-quote text) (buffer-string)))))))

(ert-deftest gitlab-merge-request-detail-list-buffers-directory ()
  "A detail buffer names its object in `list-buffers-directory'."
  (gitlab-test-with-environment
   (let* ((gitlab-repository "group/project")
          (buffer (gitlab--prepare-detail
                   (lambda (_id _context) "*GitLab list-buffers test*")
                   #'gitlab-merge-request-mode "12")))
     (unwind-protect
         (with-current-buffer buffer
           (should (equal "group/project!12" list-buffers-directory)))
       (with-current-buffer buffer
         (set-buffer-modified-p nil))
       (kill-buffer buffer)))))

(ert-deftest gitlab-merge-request-list-entries ()
  "The list renders both merge requests."
  (gitlab-test-with-environment
   (let ((buffer (generate-new-buffer "*GitLab MR list test*")))
     (unwind-protect
         (with-current-buffer buffer
           (gitlab-merge-request-list-mode)
           (gitlab-list--refresh)
           (should (gitlab-test-wait
                    (lambda () (= 2 (length tabulated-list-entries)))))
           (should (= 2 (length gitlab-list--rows)))
           (should (string-match-p "!12" (buffer-string)))
           (should (string-match-p "Add the export dialog" (buffer-string)))
           (should (string-match-p "closed" (buffer-string))))
       (kill-buffer buffer)))))

(ert-deftest gitlab-merge-request-list-numeric-column-right-aligns ()
  "The IID column aligns its cells to the right."
  (should (eq t (plist-get (nthcdr 3 (aref gitlab-merge-request-list-format 0))
                           :right-align)))
  (should (eq 'gitlab-list--number-sort
              (nth 2 (aref gitlab-merge-request-list-format 0)))))

(ert-deftest gitlab-merge-request-list-thing-at-point-url ()
  "The url thing at point is the web URL of the row."
  (gitlab-test-with-environment
   (let ((buffer (generate-new-buffer "*GitLab MR list url test*")))
     (unwind-protect
         (with-current-buffer buffer
           (gitlab-merge-request-list-mode)
           (gitlab-list--refresh)
           (should (gitlab-test-wait
                    (lambda () (= 2 (length tabulated-list-entries)))))
           (goto-char (point-min))
           (forward-line 1)
           (forward-char 3)
           (should (equal "https://gitlab.example/group/project/-/merge_requests/13"
                          (thing-at-point 'url)))
           (should (equal (gitlab-data-field
                           "web_url" (gitlab-list--row-at-point))
                          (thing-at-point 'url))))
       (with-current-buffer buffer
         (set-buffer-modified-p nil))
       (kill-buffer buffer)))))

(ert-deftest gitlab-merge-request-approve-data ()
  "The approve entry point returns the text answer of glab."
  (gitlab-test-with-environment
   (let ((gitlab-repository "group/project"))
     (should (string-match-p "Approved merge request !12"
                             (gitlab-merge-request-approve "12"))))))

(ert-deftest gitlab-merge-request-approve-command ()
  "The approve command sends the IID, reports and refreshes."
  (gitlab-test-with-environment
   (let ((buffer (generate-new-buffer "*GitLab MR approve test*"))
         (iid nil)
         (success nil)
         (refreshed nil)
         (messages nil))
     (unwind-protect
         (progn
           (with-current-buffer buffer
             (gitlab-merge-request-mode)
             (setq-local gitlab--id "12")
             (setq-local gitlab--context "group/project"))
           (cl-letf (((symbol-function 'gitlab-merge-request-approve-async)
                      (lambda (argument callback _error)
                        (setq iid argument
                              success callback))))
             (with-current-buffer buffer
               (call-interactively #'gitlab-approve-merge-request)))
           (should (equal "12" iid))
           (should (functionp success))
           (cl-letf (((symbol-function 'message)
                      (lambda (format-string &rest arguments)
                        (push (apply #'format format-string arguments)
                              messages)))
                     ((symbol-function 'gitlab--refresh-after-write)
                      (lambda (argument) (setq refreshed argument))))
             (funcall success "✓ Approved merge request !12"))
           (should (equal '("Approved group/project!12") messages))
           (should (eq buffer refreshed)))
       (with-current-buffer buffer
         (set-buffer-modified-p nil))
       (kill-buffer buffer)))))

(ert-deftest gitlab-merge-request-approve-command-elsewhere ()
  "The approve command needs a merge request at point."
  (with-temp-buffer
    (should-error (gitlab-approve-merge-request) :type 'user-error)))

(ert-deftest gitlab-merge-request-approve-from-url ()
  "A web URL at point names the merge request, and the write confirms."
  (gitlab-test-with-environment
   (let ((prompt nil)
         (iid nil)
         (repository nil))
     (with-temp-buffer
       (insert
        "https://gitlab.example.com/group/project/-/merge_requests/12")
       (goto-char (point-min))
       (cl-letf (((symbol-function 'yes-or-no-p)
                  (lambda (format-string &rest arguments)
                    (setq prompt (apply #'format format-string arguments))
                    t))
                 ((symbol-function 'gitlab-merge-request-approve-async)
                  (lambda (argument &rest _)
                    (setq iid argument
                          repository gitlab-repository))))
         (gitlab-approve-merge-request))
       (should (equal "12" iid))
       (should (equal "group/project@gitlab.example.com" repository))
       (should (equal "Approve group/project@gitlab.example.com!12? "
                      prompt))))))

(ert-deftest gitlab-merge-request-approve-detail-no-prompt ()
  "A merge request buffer needs no confirmation."
  (gitlab-test-with-environment
   (let ((buffer (generate-new-buffer "*GitLab MR approve prompt test*"))
         (iid nil))
     (unwind-protect
         (progn
           (with-current-buffer buffer
             (gitlab-merge-request-mode)
             (setq-local gitlab--id "12")
             (setq-local gitlab--context "group/project"))
           (cl-letf (((symbol-function 'yes-or-no-p)
                      (lambda (&rest _) (error "Asked for confirmation")))
                     ((symbol-function 'gitlab-merge-request-approve-async)
                      (lambda (argument &rest _) (setq iid argument))))
             (with-current-buffer buffer
               (gitlab-approve-merge-request)))
           (should (equal "12" iid)))
       (with-current-buffer buffer
         (set-buffer-modified-p nil))
       (kill-buffer buffer)))))

(ert-deftest gitlab-merge-request-approve-from-list-row ()
  "A list row names its merge request through the url at point."
  (gitlab-test-with-environment
   (let ((buffer (generate-new-buffer "*GitLab MR approve row test*"))
         (prompt nil)
         (iid nil)
         (repository nil))
     (unwind-protect
         (let ((gitlab-repository "group/project"))
           (with-current-buffer buffer
             (gitlab-merge-request-list-mode)
             (gitlab-list--refresh)
             (should (gitlab-test-wait
                      (lambda () (= 2 (length tabulated-list-entries)))))
             (goto-char (point-min))
             (forward-line 1)
             (forward-char 3))
           (cl-letf (((symbol-function 'yes-or-no-p)
                      (lambda (format-string &rest arguments)
                        (setq prompt (apply #'format format-string arguments))
                        t))
                     ((symbol-function 'gitlab-merge-request-approve-async)
                      (lambda (argument &rest _)
                        (setq iid argument
                              repository gitlab-repository))))
             (with-current-buffer buffer
               (gitlab-approve-merge-request)))
           (should (equal "13" iid))
           (should (equal "group/project" repository))
           (should (equal "Approve group/project!13? " prompt)))
       (with-current-buffer buffer
         (set-buffer-modified-p nil))
       (kill-buffer buffer)))))

(ert-deftest gitlab-merge-request-target-data-at-row ()
  "The commit range reads the data of the row at point."
  (gitlab-test-with-environment
   (let ((buffer (generate-new-buffer "*GitLab MR row data test*")))
     (unwind-protect
         (with-current-buffer buffer
           (gitlab-merge-request-list-mode)
           (gitlab-list--refresh)
           (should (gitlab-test-wait
                    (lambda () (= 2 (length tabulated-list-entries)))))
           (goto-char (point-min))
           (forward-line 1)
           (should (equal "13" (gitlab-data-id-string
                                 (gitlab-data-field
                                  "iid"
                                  (gitlab-merge-request--target-data
                                   "13" nil)))))
           (should-not (gitlab-merge-request--target-data "99" nil)))
       (with-current-buffer buffer
         (set-buffer-modified-p nil))
       (kill-buffer buffer)))))

(ert-deftest gitlab-merge-request-merge-data ()
  "The merge entry point returns the text answer of glab."
  (gitlab-test-with-environment
   (let ((gitlab-repository "group/project"))
     (should (string-match-p "Merged merge request !12"
                             (gitlab-merge-request-merge "12"))))))

(ert-deftest gitlab-merge-request-merge-command ()
  "The merge command asks, sends the IID, reports and refreshes."
  (gitlab-test-with-environment
   (let ((buffer (generate-new-buffer "*GitLab MR merge test*"))
         (iid nil)
         (success nil)
         (prompt nil)
         (refreshed nil)
         (messages nil))
     (unwind-protect
         (progn
           (with-current-buffer buffer
             (gitlab-merge-request-mode)
             (setq-local gitlab--id "12")
             (setq-local gitlab--context "group/project"))
           (cl-letf (((symbol-function 'yes-or-no-p)
                      (lambda (format-string &rest arguments)
                        (setq prompt (apply #'format format-string arguments))
                        t))
                     ((symbol-function 'gitlab-merge-request-merge-async)
                      (lambda (argument callback _error)
                        (setq iid argument
                              success callback))))
             (with-current-buffer buffer
               (call-interactively #'gitlab-merge-merge-request)))
           (should (equal "Merge group/project!12? " prompt))
           (should (equal "12" iid))
           (should (functionp success))
           (cl-letf (((symbol-function 'message)
                      (lambda (format-string &rest arguments)
                        (push (apply #'format format-string arguments)
                              messages)))
                     ((symbol-function 'gitlab--refresh-after-write)
                      (lambda (argument) (setq refreshed argument))))
             (funcall success "✓ Merged merge request !12"))
           (should (equal '("Merged group/project!12") messages))
           (should (eq buffer refreshed)))
       (with-current-buffer buffer
         (set-buffer-modified-p nil))
       (kill-buffer buffer)))))

(ert-deftest gitlab-merge-request-merge-declined ()
  "A declined confirmation sends no merge request."
  (gitlab-test-with-environment
   (let ((buffer (generate-new-buffer "*GitLab MR merge decline test*"))
         (called nil))
     (unwind-protect
         (progn
           (with-current-buffer buffer
             (gitlab-merge-request-mode)
             (setq-local gitlab--id "12")
             (setq-local gitlab--context "group/project"))
           (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil))
                     ((symbol-function 'gitlab-merge-request-merge-async)
                      (lambda (&rest _) (setq called t))))
             (with-current-buffer buffer
               (call-interactively #'gitlab-merge-merge-request)))
           (should-not called))
       (with-current-buffer buffer
         (set-buffer-modified-p nil))
       (kill-buffer buffer)))))

(ert-deftest gitlab-merge-request-merge-command-elsewhere ()
  "The merge command needs a merge request at point."
  (with-temp-buffer
    (should-error (gitlab-merge-merge-request) :type 'user-error)))

(ert-deftest gitlab-merge-request-detail-render ()
  "The detail buffer shows fields and nested objects."
  (gitlab-test-with-environment
   (let ((gitlab-show-author-username t)
         (buffer (generate-new-buffer "*GitLab MR detail test*")))
     (unwind-protect
         (progn
           (with-current-buffer buffer
             (gitlab-merge-request-mode)
             (setq-local gitlab--id "12")
             (gitlab--refresh))
           (should (gitlab-merge-request-tests--wait-for
                    buffer "Add the export dialog"))
           (with-current-buffer buffer
             (should (string-match-p "Alice (@alice)"
                                     (buffer-string)))
             (should (string-match-p "Milestone One (!16)" (buffer-string)))
             (should (string-match-p "#1001 success" (buffer-string)))
             (should (string-match-p "Fix for #1" (buffer-string)))))
       (kill-buffer buffer)))))

(ert-deftest gitlab-merge-request-notes-command ()
  "The notes command adds the notes below the fields."
  (gitlab-test-with-environment
   (let ((buffer (generate-new-buffer "*GitLab MR notes test*")))
     (unwind-protect
         (progn
           (with-current-buffer buffer
             (gitlab-merge-request-mode)
             (setq-local gitlab--id "12")
             (gitlab--refresh))
           (should (gitlab-merge-request-tests--wait-for
                    buffer "Add the export dialog"))
           (with-current-buffer buffer
             (gitlab-merge-request-show-notes))
           (should (gitlab-merge-request-tests--wait-for
                    buffer "Looks good to me."))
           (with-current-buffer buffer
             (should (string-match-p "Changed the target branch."
                                     (buffer-string)))
             (should (string-match-p "(system)" (buffer-string)))))
       (kill-buffer buffer)))))

(ert-deftest gitlab-merge-request-notes-keep-point ()
  "A re-render keeps point inside the notes and not at the end."
  (gitlab-test-with-environment
   (let ((buffer (generate-new-buffer "*GitLab MR notes point test*")))
     (unwind-protect
         (progn
           (with-current-buffer buffer
             (gitlab-merge-request-mode)
             (setq-local gitlab--id "12")
             (gitlab--refresh))
           (should (gitlab-merge-request-tests--wait-for
                    buffer "Add the export dialog"))
           (with-current-buffer buffer
             (gitlab-merge-request-show-notes))
           (should (gitlab-merge-request-tests--wait-for
                    buffer "Looks good to me."))
           (with-current-buffer buffer
             (goto-char (point-min))
             (should (search-forward "Looks good to me." nil t))
             (gitlab--force-render)
             (should (equal "Looks good to me." (gitlab--line-text)))))
       (kill-buffer buffer)))))

(ert-deftest gitlab-merge-request-entries-fields ()
  "A list row carries the IID, state and branch columns."
  (let* ((gitlab-show-author-username t)
         (data '(((iid . 7)
                  (title . "Seven")
                  (state . "opened")
                  (author (name . "Alice") (username . "alice"))
                  (source_branch . "feature")
                  (target_branch . "main")
                  (labels . ("UX"))
                  (updated_at . "2026-10-31T20:57:30.763Z"))))
         (entries (gitlab-merge-request--entries data))
         (row (cadr (car entries))))
    (should (equal "7" (car (car entries))))
    (should (equal "!7" (aref row 0)))
    (should (equal "Seven" (aref row 1)))
    (should (equal "Alice (@alice)" (substring-no-properties (aref row 3))))
    (should (eq 'gitlab-author (get-text-property 0 'face (aref row 3))))
    (should (eq 'gitlab-id (get-text-property 7 'face (aref row 3))))
    (should (equal "feature -> main" (substring-no-properties (aref row 4))))
    (should (eq 'gitlab-branch (get-text-property 0 'face (aref row 4))))
    (should (eq 'gitlab-branch (get-text-property 11 'face (aref row 4))))
    (should (equal "UX" (aref row 5)))
    (should (equal "2026-10-31 20:57:30" (aref row 6)))
    (should (eq 'gitlab-date (get-text-property 0 'face (aref row 6))))
    (let ((gitlab-show-author-username nil))
      (should (equal "Alice"
                     (substring-no-properties
                      (aref (cadr (car (gitlab-merge-request--entries data)))
                            3)))))))

(ert-deftest gitlab-merge-request-commit-rows-faces ()
  "A commit row marks its SHA, its author and its date."
  (gitlab-test-with-environment
   (with-temp-buffer
     (setq-local gitlab--id "12")
     (cl-letf (((symbol-function 'gitlab-git-merge-request-commits)
                (lambda (&rest _)
                  (list :commits
                        (list '((sha . "abc123def")
                                (short . "abc123d")
                                (subject . "Fix")
                                (author . "Bob")
                                (date . "2026-10-31T20:57:30Z")))
                        :total 1))))
       (gitlab-merge-request--insert-commits nil))
     (goto-char (point-min))
     (re-search-forward "abc123d")
     (should (eq 'gitlab-id (get-text-property (match-beginning 0) 'face)))
     (should (equal "abc123def"
                    (get-text-property (match-beginning 0)
                                       'gitlab-commit-sha)))
     (re-search-forward "Bob")
     (should (eq 'gitlab-author (get-text-property (match-beginning 0) 'face)))
     (should (string-match-p "2026-10-31 20:57:30" (buffer-string))))))

(ert-deftest gitlab-merge-request-commit-mouse-face-covers-one-row ()
  "Every mouse face run of the commit list names one commit.
Emacs lights each contiguous character that carries the same
`mouse-face' value, so a run that covers a whole row joins the
runs of the neighbour rows into one block."
  (gitlab-test-with-environment
   (with-temp-buffer
     (setq-local gitlab--id "12")
     (cl-letf (((symbol-function 'gitlab-git-merge-request-commits)
                (lambda (&rest _)
                  (list :commits
                        (list '((sha . "abc123def")
                                (short . "abc123d")
                                (subject . "Fix")
                                (author . "Bob")
                                (date . "2026-10-31T20:57:30Z"))
                              '((sha . "def456abc")
                                (short . "def456a")
                                (subject . "Add")
                                (author . "Ann")
                                (date . "2026-10-31T21:57:30Z")))
                        :total 2))))
       (gitlab-merge-request--insert-commits nil))
     (let ((position (point-min))
           runs)
       (while (< position (point-max))
         (let ((end (or (next-single-property-change position 'mouse-face)
                        (point-max))))
           (when (get-text-property position 'mouse-face)
             (push (cons position end) runs))
           (setq position end)))
       (setq runs (cl-remove-if-not
                   (lambda (run)
                     (get-text-property (car run) 'gitlab-commit-sha))
                   (nreverse runs)))
       (should (= 2 (length runs)))
       (dolist (run runs)
         (let ((sha (get-text-property (car run) 'gitlab-commit-sha))
               (position (car run)))
           (while (< position (cdr run))
             (should (equal sha (get-text-property position
                                                   'gitlab-commit-sha)))
             (setq position (1+ position)))))))))

(ert-deftest gitlab-merge-request-commits-section ()
  "The commit list starts a foldable section of the detail buffer."
  (gitlab-test-with-environment
   (with-temp-buffer
     (gitlab-detail-mode)
     (setq-local gitlab--id "12")
     (cl-letf (((symbol-function 'gitlab-git-merge-request-commits)
                (lambda (&rest _)
                  (list :commits
                        (list '((sha . "abc123def") (short . "abc123d")
                                (subject . "Fix") (author . "Bob")
                                (date . "2026-10-31T20:57:30Z")))
                        :total 1))))
       (gitlab-merge-request--insert-commits nil))
     (goto-char (point-min))
     (should (search-forward "Commits (1)" nil t))
     (should (equal "Commits (1)"
                    (get-text-property (line-beginning-position)
                                       'gitlab-section))))))

(ert-deftest gitlab-merge-request-notes-section ()
  "The notes start a foldable section of the detail buffer."
  (gitlab-test-with-environment
   (with-temp-buffer
     (gitlab-detail-mode)
     (setq-local gitlab-merge-request--notes
                 (list '((author (name . "Alice") (username . "alice"))
                         (created_at . "2026-10-31T20:57:30Z")
                         (body . "Looks good"))))
     (setq-local gitlab-merge-request--notes-loaded t)
     (gitlab-merge-request--insert-notes)
     (goto-char (point-min))
     (should (search-forward "Notes" nil t))
     (should (equal "Notes"
                    (get-text-property (line-beginning-position)
                                       'gitlab-section))))))

(ert-deftest gitlab-merge-request-notes-author-face ()
  "The notes header marks the author and the account name."
  (gitlab-test-with-environment
   (let ((gitlab-show-author-username t))
     (with-temp-buffer
       (setq-local gitlab-merge-request--notes
                   (list '((author (name . "Alice") (username . "alice"))
                           (created_at . "2026-10-31T20:57:30.763Z")
                           (body . "Fine."))))
       (setq-local gitlab-merge-request--notes-loaded t)
       (gitlab-merge-request--insert-notes)
       (goto-char (point-min))
       (re-search-forward "Alice")
       (should (eq 'gitlab-author (get-text-property (match-beginning 0) 'face)))
       (re-search-forward "@alice")
       (should (eq 'gitlab-id (get-text-property (match-beginning 0) 'face)))
       (should (string-match-p "Fine." (buffer-string)))))))

(ert-deftest gitlab-merge-request-detail-parent ()
  "A merge request detail buffer opens the merge request list.
The list belongs to the project of the merge request, so a merge
request of another project opens the list of that project."
  (gitlab-test-with-environment
   (let ((buffer (generate-new-buffer "*GitLab MR parent test*")))
     (unwind-protect
         (let ((gitlab-repository "group/project"))
           (with-current-buffer buffer
             (gitlab-merge-request-mode)
             (setq-local gitlab--id "12")
             (gitlab-go-to-parent)
             (should (derived-mode-p 'gitlab-merge-request-list-mode))
             (should (equal "group/project"
                            (buffer-local-value
                             'gitlab--context (current-buffer))))))
       (kill-buffer buffer)
       (when-let* ((list (get-buffer
                          (gitlab--contextual-name
                           gitlab-merge-request-list-buffer-name
                           "group/project"))))
         (kill-buffer list))))))

(defun gitlab-merge-request-tests--detail-buffer (iid)
  "Return a merge request detail buffer for IID without a fetch."
  (let ((buffer (generate-new-buffer "*GitLab MR sibling test*")))
    (with-current-buffer buffer
      (gitlab-merge-request-mode)
      (gitlab--use-project-directory)
      (setq-local gitlab--id iid)
      (setq-local gitlab--identity
                  (list #'gitlab-merge-request-mode iid gitlab--context)))
    buffer))

(defun gitlab-merge-request-tests--list-buffer ()
  "Return a rendered merge request list buffer."
  (let ((buffer (generate-new-buffer "*GitLab MR list sibling test*")))
    (with-current-buffer buffer
      (gitlab-merge-request-list-mode)
      (gitlab--use-project-directory)
      (setq-local gitlab--identity
                  (list #'gitlab-merge-request-list-mode nil gitlab--context))
      (gitlab-list--refresh))
    (gitlab-test-wait
     (lambda () (with-current-buffer buffer
                  (not (null tabulated-list-entries)))))
    buffer))

(ert-deftest gitlab-merge-request-detail-next-sibling ()
  "The next sibling of a merge request is the next row of its list."
  (gitlab-test-with-environment
   (let ((list (gitlab-merge-request-tests--list-buffer))
         (detail (gitlab-merge-request-tests--detail-buffer "12"))
         opened)
     (unwind-protect
         (with-current-buffer detail
           (cl-letf (((symbol-function 'gitlab-display-merge-request)
                      (lambda (iid) (setq opened iid))))
             (call-interactively #'gitlab-next-sibling))
           (should (equal "13" opened)))
       (kill-buffer detail)
       (kill-buffer list)))))

(ert-deftest gitlab-merge-request-detail-previous-sibling ()
  "The previous sibling of a merge request is the earlier row."
  (gitlab-test-with-environment
   (let ((list (gitlab-merge-request-tests--list-buffer))
         (detail (gitlab-merge-request-tests--detail-buffer "13"))
         opened)
     (unwind-protect
         (with-current-buffer detail
           (cl-letf (((symbol-function 'gitlab-display-merge-request)
                      (lambda (iid) (setq opened iid))))
             (call-interactively #'gitlab-previous-sibling))
           (should (equal "12" opened)))
       (kill-buffer detail)
       (kill-buffer list)))))

(ert-deftest gitlab-merge-request-detail-sibling-needs-list ()
  "A merge request detail without its list signals a `user-error'."
  (gitlab-test-with-environment
   (let ((detail (gitlab-merge-request-tests--detail-buffer "12")))
     (unwind-protect
         (with-current-buffer detail
           (should-error (gitlab-next-sibling) :type 'user-error))
       (kill-buffer detail)))))

(ert-deftest gitlab-merge-request-group-entries ()
  "A group row keeps its project in the row ID and the leftmost cell."
  (gitlab-test-with-environment
   (let ((data
          '(((iid . 12) (title . "Fix") (state . "opened")
             (author (name . "Alice") (username . "alice"))
             (source_branch . "feature") (target_branch . "main")
             (labels) (updated_at . "2026-10-31T20:57:30Z")
             (web_url . "https://gitlab.example.com/group/project/-/merge_requests/12"))
            ((iid . 12) (title . "Other") (state . "opened")
             (author (name . "Bob") (username . "bob"))
             (source_branch . "fix") (target_branch . "main")
             (labels) (updated_at . "2026-10-31T20:57:30Z")
             (web_url . "https://gitlab.example.com/other/project/-/merge_requests/12")))))
     (with-temp-buffer
       (setq-local gitlab--scope 'group)
       (setq-local gitlab--context "group")
       (let* ((entries (gitlab-merge-request--entries data))
              (first (cadr (car entries)))
              (second (cadr (cadr entries))))
         (should (equal '("group/project@gitlab.example.com!12"
                          "other/project@gitlab.example.com!12")
                        (mapcar #'car entries)))
         (should (equal '("group/project@gitlab.example.com!12"
                          "other/project@gitlab.example.com!12")
                        (mapcar #'car (gitlab-merge-request--rows data))))
         (should (equal "group/project@gitlab.example.com" (aref first 0)))
         (should (equal "other/project@gitlab.example.com" (aref second 0)))
         (should (equal "!12" (aref first 1)))
         (should (equal "group/project@gitlab.example.com!12"
                        (get-text-property 0 'gitlab-merge-request-iid
                                           (aref first 1))))
         (should (= 8 (length first))))))))

(ert-deftest gitlab-merge-request-group-entries-project-list ()
  "A project row keeps the bare IID and no project cell."
  (gitlab-test-with-environment
   (let ((data '(((iid . 12) (title . "Fix") (state . "opened")
                  (author (name . "Alice") (username . "alice"))
                  (source_branch . "feature") (target_branch . "main")
                  (labels) (updated_at . "2026-10-31T20:57:30Z")))))
     (with-temp-buffer
       (setq-local gitlab--scope nil)
       (let* ((entries (gitlab-merge-request--entries data))
              (row (cadr (car entries))))
         (should (equal "12" (car (car entries))))
         (should (equal "!12" (aref row 0)))
         (should (= 7 (length row))))))))

(ert-deftest gitlab-merge-request-group-web-url ()
  "A group row reads its own project from the `web_url' field."
  (should (equal "group/project@gitlab.example.com"
                 (gitlab-merge-request--row-context
                  '((web_url . "https://gitlab.example.com/group/project/-/merge_requests/12")))))
  (should-not (gitlab-merge-request--row-context '((iid . 12)))))

(ert-deftest gitlab-merge-request-command-modes ()
  "The merge request commands name their mode, the display commands do not."
  (should (equal '(gitlab-merge-request-mode)
                 (command-modes #'gitlab-merge-request-show-notes)))
  (should-not (command-modes #'gitlab-merge-request-show-changes))
  (should-not (command-modes #'gitlab-merge-request-show-log))
  (should-not (command-modes #'gitlab-approve-merge-request))
  (should-not (command-modes #'gitlab-merge-merge-request))
  (should-not (command-modes #'gitlab-list-merge-requests))
  (should-not (command-modes #'gitlab-display-merge-request)))

(provide 'gitlab-merge-request-tests)

;;; gitlab-merge-request-tests.el ends here
