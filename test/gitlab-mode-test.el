;;; gitlab-mode-test.el --- Tests of the GitLab display layer -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Daniel Nagy

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;;; Commentary:

;; Unit tests of the renderers, the stale check and the two base modes.
;; The tests never start glab and never open a network connection.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'outline)
(require 'subr-x)
(require 'gitlab-test-helper)
(require 'gitlab-mode)

(declare-function gitlab-display-job-log "gitlab-pipeline"
                  (job-id &optional name pipeline-id repository))
(declare-function gitlab-display-merge-request "gitlab-merge-request"
                  (iid &optional repository))
(declare-function gitlab-display-pipeline "gitlab-pipeline"
                  (pipeline-id &optional repository))

(ert-deftest gitlab-mode-format-value ()
  "Values render as readable text."
  (should (equal "-" (gitlab--format-value nil)))
  (should (equal "no" (gitlab--format-value :false)))
  (should (equal "yes" (gitlab--format-value t)))
  (should (equal "UX, CLI" (gitlab--format-value '("UX" "CLI"))))
  (should (equal "Alice"
                 (gitlab--format-value
                  '((username . "alice") (name . "Alice")))))
  (let ((gitlab-show-author-username t))
    (should (equal "Alice (@alice)"
                   (gitlab--format-value
                    '((username . "alice") (name . "Alice")))))))

(ert-deftest gitlab-mode-format-object-pipeline ()
  "A nested pipeline becomes text with a navigation property."
  (let* ((value (gitlab--format-value
                 '((id . 100) (status . "success") (ref . "main"))))
         (id (get-text-property 0 'gitlab-pipeline-id value)))
    (should (equal "#100 success" value))
    (should (equal "100" id))))

(ert-deftest gitlab-mode-format-date-and-duration ()
  "Timestamps and durations have compact forms."
  (should (equal "2026-10-31 20:57:30"
                 (gitlab--format-date "2026-10-31T20:57:30.763Z")))
  (should (equal "8m 42s" (gitlab--format-duration 522)))
  (should (equal "1m 40s" (gitlab--format-duration 100.234765)))
  (should (equal "1h 0m 5s" (gitlab--format-duration 3605))))

(ert-deftest gitlab-mode-date-field-face ()
  "Timestamp fields carry `gitlab-date' and a compact form."
  (dolist (key '(created_at updated_at latest_build_started_at
                 latest_build_finished_at authored_date))
    (let ((text (gitlab--format-field-value
                 key "2026-10-31T20:57:30.763Z")))
      (should (equal "2026-10-31 20:57:30" text))
      (should (eq 'gitlab-date (get-text-property 0 'face text))))))

(ert-deftest gitlab-mode-id-field-face ()
  "Identifier fields carry `gitlab-id'."
  (dolist (key '(id iid project_id sha before_sha merge_commit_sha))
    (should (eq 'gitlab-id
                (get-text-property
                 0 'face (gitlab--format-field-value key "42")))))
  (should (eq 'gitlab-branch
              (get-text-property
               0 'face (gitlab--format-field-value 'ref "main")))))

(ert-deftest gitlab-mode-author-face ()
  "An author field and a branch field carry their own face."
  (should (equal "Alice" (gitlab--format-author
                           '((name . "Alice") (username . "alice")))))
  (let ((author (let ((gitlab-show-author-username t))
                  (gitlab--format-author
                   '((name . "Alice") (username . "alice"))))))
    (should (equal "Alice (@alice)" author))
    (should (eq 'gitlab-author (get-text-property 0 'face author)))
    (should (eq 'gitlab-id (get-text-property 7 'face author))))
  (should (equal "@alice" (gitlab--format-author '((username . "alice")))))
  (should (eq 'gitlab-author
              (get-text-property 0 'face (gitlab--format-author "Bob"))))
  (should (equal "-" (gitlab--format-author nil)))
  (should-not (get-text-property 0 'face (gitlab--format-author nil)))
  (should (eq 'gitlab-branch
              (get-text-property 0 'face (gitlab--format-branch "main"))))
  (should (eq 'gitlab-tag
              (get-text-property
               0 'face (gitlab--format-branch "v1.0" t))))
  (should (equal "-" (gitlab--format-branch nil)))
  (dolist (key '(source_branch target_branch ref))
    (should (eq 'gitlab-branch
                (get-text-property
                 0 'face (gitlab--format-field-value key "main")))))
  (should (eq 'gitlab-author
              (get-text-property
               0 'face (gitlab--format-field-value
                        'author '((name . "Alice"))))))
  (dolist (key '(merge_user merged_by))
    (let ((text (let ((gitlab-show-author-username t))
                  (gitlab--format-field-value
                   key '((name . "Alice") (username . "alice"))))))
      (should (equal "Alice (@alice)" text))
      (should (eq 'gitlab-author (get-text-property 0 'face text)))
      (should (eq 'gitlab-id (get-text-property 7 'face text))))
    (should (equal "Alice"
                   (gitlab--format-field-value
                    key '((name . "Alice") (username . "alice")))))))

(ert-deftest gitlab-mode-tag-field-face ()
  "A ref that the tag flag marks a tag takes `gitlab-tag'."
  (let ((data '((ref . "v1.0") (tag . t))))
    (should (eq 'gitlab-tag
                (get-text-property
                 0 'face (gitlab--format-field-value
                          'ref (gitlab-data-field "ref" data) data))))
    (should (eq 'gitlab-branch
                (get-text-property
                 0 'face (gitlab--format-field-value
                          'ref "v1.0" '((ref . "v1.0") (tag . :false))))))
    (should-not (get-text-property
                 0 'face (gitlab--format-field-value 'tag t data)))))

(ert-deftest gitlab-mode-author-list-face ()
  "A field that holds users takes the faces of every user."
  (let ((reviewers
           (let ((gitlab-show-author-username t))
             (gitlab--format-field-value
              'reviewers
              '(((name . "Bob") (username . "bob"))
                ((name . "Carol") (username . "carol")))))))
    (should (equal "Bob (@bob), Carol (@carol)" reviewers))
    (should (eq 'gitlab-author (get-text-property 0 'face reviewers)))
    (should (eq 'gitlab-id (get-text-property 5 'face reviewers))))
  (should (equal "Bob, Carol"
                 (gitlab--format-field-value
                  'reviewers
                  '(((name . "Bob") (username . "bob"))
                    ((name . "Carol") (username . "carol"))))))
  (dolist (key '(author assignee assignees reviewers user))
    (let ((text (let ((gitlab-show-author-username t))
                  (gitlab--format-field-value
                   key '((name . "Alice") (username . "alice"))))))
      (should (eq 'gitlab-author (get-text-property 0 'face text)))
      (should (eq 'gitlab-id (get-text-property 7 'face text)))))
  (should (equal "-"
                 (gitlab--format-field-value 'assignees nil))))

(ert-deftest gitlab-mode-list-id-cell-face ()
  "A list identifier cell carries `gitlab-id' and its property."
  (let ((cell (gitlab-list--id-cell "!12" 'gitlab-merge-request-iid)))
    (should (equal "!12" cell))
    (should (eq 'gitlab-id (get-text-property 0 'face cell)))
    (should (equal "!12" (get-text-property 0 'gitlab-merge-request-iid cell)))))

(ert-deftest gitlab-mode-render-fields ()
  "A field table has labels, values and a field property."
  (gitlab-test-with-environment
   (with-temp-buffer
     (gitlab--render-fields
      "Merge request !12"
      '((iid . 12)
        (title . "Fix")
        (author (username . "alice") (name . "Alice"))))
     (should (string-match-p "Merge request !12" (buffer-string)))
     (should (string-match-p "Alice" (buffer-string)))
     (gitlab--goto-field 'title)
     (should (eq 'title (gitlab--field-at-point)))
     (should (string-match-p "Title:" (buffer-substring
                                        (line-beginning-position)
                                        (line-end-position)))))))

(ert-deftest gitlab-mode-render-fields-author-username ()
  "The author option adds the account name to a rendered field."
  (gitlab-test-with-environment
   (let ((gitlab-show-author-username t))
     (with-temp-buffer
       (gitlab--render-fields
        "Merge request !12"
        '((iid . 12)
          (author (username . "alice") (name . "Alice"))))
       (should (string-match-p "Alice (@alice)" (buffer-string)))))))

(ert-deftest gitlab-mode-point-record-text ()
  "A plain line records its text and its ordinal among equal lines."
  (with-temp-buffer
    (insert "Header\nsame\nother\nsame\n")
    (goto-char (point-min))
    (forward-line 3)
    (let ((record (gitlab--point-record)))
      (should (equal '(text "same" . 1) (plist-get record :identity)))
      (should (= 0 (plist-get record :offset)))
      (should (= 0 (plist-get record :column))))))

(ert-deftest gitlab-mode-point-record-blank-line ()
  "A blank line leans on the nearest line above that has an identity."
  (with-temp-buffer
    (insert "Header\nNote\n\nFooter\n")
    (goto-char (point-min))
    (forward-line 2)
    (let ((record (gitlab--point-record)))
      (should (equal '(text "Note" . 0) (plist-get record :identity)))
      (should (= 1 (plist-get record :offset))))))

(ert-deftest gitlab-mode-point-record-property ()
  "A line with a text property records that property."
  (with-temp-buffer
    (insert "Header\n"
            (propertize "Status: success" 'gitlab-field 'status)
            "\n")
    (goto-char (point-max))
    (forward-line -1)
    (forward-char 10)
    (let ((record (gitlab--point-record)))
      (should (equal '(field . status) (plist-get record :identity)))
      (should (= 10 (plist-get record :column))))))

(ert-deftest gitlab-mode-point-restore-shifted ()
  "A restore finds the same line after the lines above changed."
  (with-temp-buffer
    (insert "Header\nNote one\nNote two\n")
    (goto-char (point-min))
    (forward-line 2)
    (forward-char 5)
    (let ((record (gitlab--point-record)))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "A much longer header\nAnother line\n\n\nNote one\nNote two   \n"))
      (gitlab--restore-point record)
      (should (equal "Note two" (gitlab--line-text)))
      (should (= 5 (- (point) (line-beginning-position)))))))

(ert-deftest gitlab-mode-point-restore-clips-column ()
  "A shorter line clips the column of point to its end."
  (with-temp-buffer
    (insert "Header\nNote      \n")
    (goto-char (point-min))
    (forward-line 1)
    (forward-char 8)
    (let ((record (gitlab--point-record)))
      (should (= 8 (plist-get record :column)))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Header\nNote\n"))
      (gitlab--restore-point record)
      (should (equal "Note" (gitlab--line-text)))
      (should (= (line-end-position) (point))))))

(ert-deftest gitlab-mode-point-restore-without-record ()
  "A nil record moves point to the start of the buffer."
  (with-temp-buffer
    (insert "Header\n\n")
    (goto-char (point-max))
    (gitlab--restore-point nil)
    (should (= (point-min) (point)))))

(ert-deftest gitlab-mode-render-keeps-point ()
  "A render keeps the line and the column of point."
  (gitlab-test-with-environment
   (with-temp-buffer
     (gitlab-detail-mode)
     (setq-local gitlab--render-function
                 (lambda (_id _data)
                   (let ((inhibit-read-only t))
                     (erase-buffer)
                     (insert "Title\n\nStatus: failed\n\nJobs\n\njob row\n"))))
     (gitlab--render)
     (goto-char (point-min))
     (search-forward "job row")
     (backward-char 3)
     (let ((column (- (point) (line-beginning-position))))
       (gitlab--render)
       (should (equal "job row" (gitlab--line-text)))
       (should (= column (- (point) (line-beginning-position))))))))

(ert-deftest gitlab-mode-render-keeps-other-window-point ()
  "A render keeps the point of a window that shows the buffer."
  (gitlab-test-with-environment
   (let ((buffer (generate-new-buffer "*GitLab other window point test*"))
         (configuration (current-window-configuration)))
     (unwind-protect
         (progn
           (with-current-buffer buffer
             (gitlab-detail-mode)
             (setq-local gitlab--render-function
                         (lambda (_id _data)
                           (let ((inhibit-read-only t))
                             (erase-buffer)
                             (insert "Title\n\nrow one\nrow two\nrow three\n"))))
             (gitlab--render))
           (switch-to-buffer buffer)
           (let ((window (display-buffer buffer
                                         '(display-buffer-below-selected))))
             (set-window-point window
                               (with-current-buffer buffer
                                 (goto-char (point-min))
                                 (search-forward "row two")
                                 (point)))
             (select-window (next-window window))
             (with-current-buffer buffer
               (gitlab--render))
             (with-selected-window window
               (should (equal "row two" (gitlab--line-text))))))
       (set-window-configuration configuration)
       (kill-buffer buffer)))))

(ert-deftest gitlab-mode-stale-check ()
  "The stale check honours the refresh interval and pending state."
  (let ((gitlab-refresh-visible-only nil)
        (gitlab-refresh-interval 30)
        (gitlab-refresh-fast-interval 5))
    (with-temp-buffer
      (setq-local gitlab--last-fetch-time nil)
      (should (gitlab--buffer-stale-p))
      (setq-local gitlab--last-fetch-time (float-time))
      (should-not (gitlab--buffer-stale-p))
      (setq-local gitlab--last-fetch-time (- (float-time) 40))
      (should (gitlab--buffer-stale-p))
      (setq-local gitlab--pending t)
      (should-not (gitlab--buffer-stale-p)))))

(ert-deftest gitlab-mode-stale-check-finished-pipeline ()
  "A finished pipeline buffer does not poll."
  (gitlab-test-with-environment
   (let ((gitlab-refresh-visible-only nil)
         (gitlab-refresh-interval 30)
         (gitlab-refresh-fast-interval 5))
     (with-temp-buffer
       (gitlab-detail-mode)
       (setq-local gitlab--kind 'pipeline)
       (setq-local gitlab--last-fetch-time (- (float-time) 400))
       (setq-local gitlab--last-data
                   '((status . "success")
                     (jobs . (((status . "success"))
                              ((status . "failed"))
                              ((status . "manual"))))))
       (should-not (gitlab--buffer-stale-p))
       (let ((gitlab-refresh-finished-pipelines nil))
         (should (gitlab--buffer-stale-p)))
       (setq-local gitlab--last-data
                   '((status . "running")
                     (jobs . (((status . "running"))))))
       (should (gitlab--buffer-stale-p))
       (setq-local gitlab--last-data
                   '((status . "success")
                     (jobs . (((status . "success"))
                              ((status . "running"))))))
       (should (gitlab--buffer-stale-p))
       (setq-local gitlab--kind 'merge-request)
       (setq-local gitlab--last-data '((status . "merged")))
       (should (gitlab--buffer-stale-p))))))

(ert-deftest gitlab-mode-detail-refresh ()
  "A synchronous fetch renders the detail buffer."
  (gitlab-test-with-environment
   (with-temp-buffer
     (gitlab-detail-mode)
     (setq-local gitlab--id "12")
     (setq-local gitlab--fetch-function
                 (lambda (_id success _error)
                   (funcall success '((iid . 12) (title . "Fix")))))
     (gitlab--refresh)
     (should (string-match-p "Fix" (buffer-string)))
     (should-not gitlab--pending)
     (should-not (buffer-modified-p)))))

(ert-deftest gitlab-mode-detail-error-keeps-data ()
  "A failed refresh keeps the last good content."
  (gitlab-test-with-environment
   (with-temp-buffer
     (gitlab-detail-mode)
     (setq-local gitlab--id "12")
     (setq-local gitlab--fetch-function
                 (lambda (_id success _error)
                   (funcall success '((iid . 12) (title . "Good")))))
     (gitlab--refresh)
     (setq-local gitlab--fetch-function
                 (lambda (_id _success error)
                   (funcall error '(gitlab-cli-error "Boom"))))
     (gitlab--refresh)
     (should (string-match-p "Good" (buffer-string)))
     (should (string-match-p "Boom" (or header-line-format ""))))))

(ert-deftest gitlab-mode-refresh-after-write ()
  "A write drops the cache of its kind and fetches the buffer again."
  (gitlab-test-with-environment
   (with-temp-buffer
     (gitlab-detail-mode)
     (setq-local gitlab--id "12")
     (setq-local gitlab--kind 'merge-request)
     (let ((invalidated nil)
           (reverted nil))
       (cl-letf (((symbol-function 'gitlab-cache-invalidate)
                  (lambda (&optional kind) (setq invalidated kind)))
                 ((symbol-function 'gitlab--revert-buffer)
                  (lambda (&rest _arguments) (setq reverted t))))
         (gitlab--refresh-after-write (current-buffer)))
       (should (eq 'merge-request invalidated))
       (should reverted)))))

(ert-deftest gitlab-mode-refresh-after-write-dead-buffer ()
  "A write that outlives its buffer drops every cached list."
  (gitlab-test-with-environment
   (let ((buffer (generate-new-buffer "*GitLab write test*"))
         (invalidated 'unset)
         (reverted nil))
     (kill-buffer buffer)
     (cl-letf (((symbol-function 'gitlab-cache-invalidate)
                (lambda (&optional kind) (setq invalidated kind)))
               ((symbol-function 'gitlab--revert-buffer)
                (lambda (&rest _arguments) (setq reverted t))))
       (gitlab--refresh-after-write buffer))
     (should-not invalidated)
     (should-not reverted))))

(ert-deftest gitlab-mode-list-refresh ()
  "A synchronous list fetch fills `tabulated-list-entries'."
  (gitlab-test-with-environment
   (with-temp-buffer
     (gitlab-list-mode)
     (setq-local tabulated-list-format [("ID" 8 t) ("Title" 20 t)])
     (setq-local gitlab-list--fetch-function
                 (lambda (success _error)
                   (funcall success '(((id . 1) (title . "One"))
                                      ((id . 2) (title . "Two"))))))
     (setq-local gitlab-list--entries-function
                 (lambda (data)
                   (mapcar (lambda (row)
                             (list (gitlab-data-id-string
                                    (gitlab-data-field "id" row))
                                   (vector (gitlab-data-id-string
                                            (gitlab-data-field "id" row))
                                           (gitlab-data-field "title" row))))
                           data)))
     (setq-local gitlab-list--rows-function
                 (lambda (data)
                   (mapcar (lambda (row)
                             (cons (gitlab-data-id-string
                                    (gitlab-data-field "id" row))
                                   row))
                           data)))
     (setq-local gitlab-list--open-function #'ignore)
     (gitlab-list--refresh)
     (should (= 2 (length tabulated-list-entries)))
     (should (= 2 (length gitlab-list--rows)))
     (should (string-match-p "One" (buffer-string))))))

(ert-deftest gitlab-mode-list-header-line ()
  "A list buffer shows the column names in its header line."
  (gitlab-test-with-environment
   (with-temp-buffer
     (gitlab-list-mode)
     (setq-local tabulated-list-format [("ID" 8 t) ("Title" 12 t)])
     (setq-local tabulated-list-sort-key '("ID" . t))
     (setq-local tabulated-list-entries
                 '(("1" ["one" "alpha"]) ("2" ["two" "beta"])))
     (gitlab-list--render nil nil)
     ;; The header line holds strings and the `header-line-indent'
     ;; symbol, so keep the strings only.
     (let ((text (apply #'concat
                        (delq nil (mapcar (lambda (item)
                                            (and (stringp item) item))
                                          (flatten-list header-line-format))))))
       (should (string-match-p "ID" text))
       (should (string-match-p "Title" text)))
     (should (equal header-line-format gitlab--header-line-format))
     (gitlab--set-error '(gitlab-cli-error "Offline"))
     (should (string-match-p "Offline" (format "%s" mode-line-process)))
     (gitlab--clear-error)
     (should (equal header-line-format gitlab--header-line-format)))))

(defvar gitlab-mode-test--header-format
  [("ID" 8 t) ("Title" 12 t)]
  "Table format of `gitlab-mode-test-list-mode'.")

(define-derived-mode gitlab-mode-test-list-mode gitlab-list-mode
  "GitLab Test List"
  "List mode that declares a table format.
The test suite runs the mode of an open buffer again through
`gitlab-list--show', so the mode body sets the format itself."
  :group 'gitlab
  (setq-local tabulated-list-format gitlab-mode-test--header-format)
  (setq-local tabulated-list-sort-key '("ID" . t)))

(ert-deftest gitlab-mode-list-second-display-keeps-header ()
  "A second display of an open list buffer keeps its header line.
`define-derived-mode' runs `kill-all-local-variables', which drops
`header-line-format' while the rows of the last render stay in the
buffer."
  (gitlab-test-with-environment
   (cl-letf (((symbol-function 'pop-to-buffer)
              (lambda (buffer &rest _arguments) (set-buffer buffer)))
             ((symbol-function 'gitlab-list--refresh) #'ignore))
     (gitlab-list--show "*GitLab Test List*" #'gitlab-mode-test-list-mode)
     (setq tabulated-list-entries '(("1" ["one" "alpha"])))
     (gitlab-list--render nil nil)
     (should header-line-format)
     (gitlab-list--show "*GitLab Test List*" #'gitlab-mode-test-list-mode)
     (should header-line-format)
     (should (equal header-line-format gitlab--header-line-format))
     (let ((text (apply #'concat
                        (delq nil (mapcar (lambda (item)
                                            (and (stringp item) item))
                                          (flatten-list header-line-format))))))
       (should (string-match-p "Title" text)))
     (kill-buffer (current-buffer)))))

(ert-deftest gitlab-mode-list-error ()
  "A list error goes to the mode line."
  (gitlab-test-with-environment
   (with-temp-buffer
     (gitlab-list-mode)
     (setq-local tabulated-list-format [("ID" 8 t)])
     (setq-local gitlab-list--fetch-function
                 (lambda (_success error)
                   (funcall error '(gitlab-cli-error "Offline"))))
     (gitlab-list--refresh)
     (should (string-match-p "Offline" (format "%s" mode-line-process))))))

(ert-deftest gitlab-mode-navigation-property ()
  "RET opens the object that the text property names."
  (with-temp-buffer
    (insert (gitlab--nav-string "#100 success" 'gitlab-pipeline-id "100"))
    (goto-char (point-min))
    (let (opened)
      (cl-letf (((symbol-function 'gitlab-display-pipeline)
                 (lambda (id) (setq opened id))))
        (gitlab-open-at-point))
      (should (equal "100" opened)))))

(ert-deftest gitlab-mode-navigation-string-is-a-button ()
  "A navigation string is a text button of the type `gitlab-object'.
`button.el' supplies the mouse face, the tooltip and the action, so
the renderer names none of them."
  (let* ((string (gitlab--nav-string "#100" 'gitlab-pipeline-id "100"))
         (category (get-text-property 0 'category string)))
    (should (equal "#100" string))
    (should (eq 'gitlab-object (get category 'type)))
    (should (equal "100" (get-text-property 0 'gitlab-pipeline-id string)))
    (should (eq 'highlight (get-text-property 0 'mouse-face string)))
    (should (equal "100" (get-text-property 0 'help-echo string)))
    (should-not (get-text-property 0 'keymap string))))

(ert-deftest gitlab-mode-button-push-opens-object ()
  "`push-button' runs the action of a GitLab object button."
  (with-temp-buffer
    (insert (gitlab--nav-string "#100" 'gitlab-pipeline-id "100") "\n")
    (gitlab-detail-mode)
    (let (opened)
      (cl-letf (((symbol-function 'gitlab-display-pipeline)
                 (lambda (id) (setq opened id))))
        (should (push-button (point-min))))
      (should (equal "100" opened)))))

(ert-deftest gitlab-mode-button-opens-commit ()
  "A commit line opens the commit at point."
  (with-temp-buffer
    (insert (gitlab--button-string "abc123d Fix" "Open the commit"))
    (add-text-properties (point-min) (point-max)
                         '(gitlab-commit-sha "abc123def"))
    (gitlab-detail-mode)
    (let (opened)
      (cl-letf (((symbol-function 'gitlab-git-show-commit)
                 (lambda (sha) (setq opened sha))))
        (goto-char (point-min))
        (gitlab-open-at-point))
      (should (equal "abc123def" opened)))))

(ert-deftest gitlab-mode-button-follows-one-click ()
  "One click follows a button in a detail buffer alone.
A list buffer keeps the click for the selection of a row."
  (with-temp-buffer
    (gitlab-detail-mode)
    (should (gitlab--button-follow-mouse-1-p (point-min)))
    (gitlab-list-mode)
    (should-not (gitlab--button-follow-mouse-1-p (point-min)))))

(ert-deftest gitlab-mode-list-id-cell-is-a-button ()
  "A list identifier cell is a button that opens its row."
  (let* ((cell (gitlab-list--id-cell "!12" 'gitlab-merge-request-iid))
         (category (get-text-property 0 'category cell)))
    (should (eq 'gitlab-object (get category 'type)))
    (should (eq 'highlight (get-text-property 0 'mouse-face cell)))
    (should-not (get-text-property 0 'keymap cell))))

(defun gitlab-mode-test--reference-url (text)
  "Return the web URL of the first reference of TEXT."
  (with-temp-buffer
    (setq-local gitlab--context "group/project@gitlab.example.com")
    (insert text)
    (goto-char (point-min))
    (should (re-search-forward (gitlab--bug-reference-regexp) nil t))
    (gitlab--bug-reference-url)))

(ert-deftest gitlab-mode-bug-reference-regexp ()
  "The reference regexp marks the sigil, the number and the project."
  (with-temp-buffer
    (insert "Fix !12 and other/proj#34 and a/b/c!7 and plain")
    (goto-char (point-min))
    (let ((regexp (gitlab--bug-reference-regexp)))
      (should (re-search-forward regexp nil t))
      (should (equal "!12" (match-string-no-properties 0)))
      (should-not (match-string-no-properties 2))
      (should (equal "!" (match-string-no-properties 3)))
      (should (equal "12" (match-string-no-properties 4)))
      (should (re-search-forward regexp nil t))
      (should (equal "other/proj#34" (match-string-no-properties 0)))
      (should (equal "other/proj" (match-string-no-properties 2)))
      (should (equal "#" (match-string-no-properties 3)))
      (should (re-search-forward regexp nil t))
      (should (equal "a/b/c!7" (match-string-no-properties 0)))
      (should-not (re-search-forward regexp nil t)))))

(ert-deftest gitlab-mode-bug-reference-url ()
  "A reference becomes the web URL of its object on the buffer instance."
  (should (equal
           "https://gitlab.example.com/group/project/-/merge_requests/12"
           (gitlab-mode-test--reference-url "Fix !12")))
  (should (equal
           "https://gitlab.example.com/other/proj/-/pipelines/34"
           (gitlab-mode-test--reference-url "See other/proj#34")))
  (should (equal
           "https://gitlab.example.com/group/project/-/jobs/56"
           (gitlab-mode-test--reference-url "Job &56")))
  (should (equal
           "https://gitlab.example.com/group/project/-/work_items/21"
           (gitlab-mode-test--reference-url "Work item %21"))))

(ert-deftest gitlab-mode-detail-links-text ()
  "A detail buffer links its text through two built-in modes."
  (let ((gitlab-bug-reference t)
        (gitlab-goto-address t))
    (with-temp-buffer
      (gitlab-detail-mode)
      (should bug-reference-mode)
      (should goto-address-mode)
      (should (equal (gitlab--bug-reference-regexp)
                     bug-reference-bug-regexp))
      (should (eq #'gitlab--bug-reference-url bug-reference-url-format))))
  (let ((gitlab-bug-reference nil)
        (gitlab-goto-address nil))
    (with-temp-buffer
      (gitlab-detail-mode)
      (should-not bug-reference-mode)
      (should-not goto-address-mode))))

(ert-deftest gitlab-mode-detail-reference-overlay ()
  "The overlay of a reference carries its web URL."
  (gitlab-test-with-environment
   (with-temp-buffer
     (insert "Fix !12\n")
     (gitlab-detail-mode)
     (setq-local gitlab--context "group/project@gitlab.example.com")
     (bug-reference-fontify (point-min) (point-max))
     (let ((overlay (seq-find (lambda (overlay)
                                (overlay-get overlay 'bug-reference-url))
                              (overlays-in (point-min) (point-max)))))
       (should overlay)
       (should (equal
                "https://gitlab.example.com/group/project/-/merge_requests/12"
                (overlay-get overlay 'bug-reference-url)))))))

(ert-deftest gitlab-mode-json-remap ()
  "Both JSON major modes remap the export command of each base mode.
Emacs 30 ships `json-ts-mode' beside `js-json-mode', so a buffer that
visits JSON with tree-sitter keeps the export key."
  (should (fboundp 'json-ts-mode))
  (dolist (map (list gitlab-detail-mode-map gitlab-list-mode-map))
    (dolist (mode '(js-json-mode json-ts-mode))
      (should (eq 'gitlab-export-json
                  (lookup-key map (vector 'remap mode)))))))

(defun gitlab-mode-test--render-sections (_id _data)
  "Render two sections into the current buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (gitlab--insert-section-title "First")
    (insert "\nfirst body\n")
    (gitlab--insert-section-title "Second")
    (insert "\nsecond body\n")))

(defun gitlab-mode-test--invisible-p (heading)
  "Return non-nil when the body of the section of HEADING is folded."
  (save-excursion
    (goto-char heading)
    (outline-invisible-p (line-end-position))))

(ert-deftest gitlab-mode-detail-sections ()
  "A detail buffer folds its sections through `outline-minor-mode'.
A title line carries `gitlab-section', so no heading needs a special
character, and every section sits at the same level."
  (gitlab-test-with-environment
   (with-temp-buffer
     (gitlab-detail-mode)
     (should outline-minor-mode)
     (should (eq outline-search-function #'gitlab--outline-search))
     (gitlab--render-fields "Merge request !12" '((iid . 12) (title . "Fix")))
     (should (equal '(1) (gitlab--section-headings)))
     (should (equal "Merge request !12"
                    (get-text-property (point-min) 'gitlab-section)))
     (should (eq 'gitlab-title (get-text-property (point-min) 'face)))
     (goto-char (point-min))
     (should (outline-on-heading-p))
     ;; The outline machinery calls the variable, not the function of
     ;; the same name.
     (should (= 1 (funcall outline-level))))))

(ert-deftest gitlab-mode-detail-fold-section ()
  "TAB folds the section around point and TAB folds it open again."
  (gitlab-test-with-environment
   (with-temp-buffer
     (gitlab-detail-mode)
     (gitlab-mode-test--render-sections nil nil)
     (let ((first (nth 0 (gitlab--section-headings)))
           (second (nth 1 (gitlab--section-headings))))
       (goto-char second)
       (forward-line 1)
       (gitlab-detail-toggle-section)
       (should (equal '("Second") (gitlab--collapsed-sections)))
       (should (gitlab-mode-test--invisible-p second))
       (should-not (gitlab-mode-test--invisible-p first))
       (gitlab-detail-toggle-section)
       (should-not (gitlab--collapsed-sections))))))

(ert-deftest gitlab-mode-detail-fold-survives-render ()
  "A render keeps the folded sections of a detail buffer."
  (gitlab-test-with-environment
   (with-temp-buffer
     (gitlab-detail-mode)
     (setq-local gitlab--render-function #'gitlab-mode-test--render-sections
                 gitlab--rendered t)
     (gitlab--render)
     (goto-char (point-min))
     (gitlab-detail-toggle-section)
     (should (equal '("First") (gitlab--collapsed-sections)))
     (gitlab--render)
     (should (equal '("First") (gitlab--collapsed-sections)))
     (should (gitlab-mode-test--invisible-p (point-min))))))

(ert-deftest gitlab-mode-detail-toggle-section-without-section ()
  "A buffer without a section at point signals a `user-error'."
  (gitlab-test-with-environment
   (with-temp-buffer
     (gitlab-detail-mode)
     (let ((inhibit-read-only t))
       (insert "plain text\n"))
     (goto-char (point-min))
     (should-error (gitlab-detail-toggle-section) :type 'user-error))))

(ert-deftest gitlab-mode-imenu-index-with-sections ()
  "The imenu index names the sections and the field lines."
  (gitlab-test-with-environment
   (with-temp-buffer
     (gitlab-detail-mode)
     (gitlab--render-fields "Merge request !12" '((iid . 12) (title . "Fix")))
     (let ((index (gitlab--imenu-index)))
       (should (equal "Merge request !12" (car (car index))))
       (should (member "Title" (mapcar #'car index)))))))

(ert-deftest gitlab-mode-list-revert ()
  "`revert-buffer' fetches the collection again."
  (gitlab-test-with-environment
   (with-temp-buffer
     (let ((calls 0))
       (gitlab-list-mode)
       (setq-local tabulated-list-format [("ID" 8 t)])
       (setq-local gitlab-list--fetch-function
                   (lambda (success _error)
                     (setq calls (1+ calls))
                     (funcall success nil)))
       (setq-local gitlab-list--entries-function #'ignore)
       (setq-local gitlab-list--rows-function #'ignore)
       (setq-local gitlab-list--open-function #'ignore)
       (gitlab-list--refresh)
       (should (= 1 calls))
       (revert-buffer nil t)
       (should (= 2 calls))))))

(ert-deftest gitlab-mode-detail-directory ()
  "A detail buffer keeps the project root for glab."
  (gitlab-test-with-environment
   (let ((default-directory (file-name-as-directory "/some/project/sub")))
     (with-temp-buffer
       (cl-letf (((symbol-function 'project-current)
                  (lambda (&rest _arguments) 'stub-project))
                 ((symbol-function 'project-root)
                  (lambda (_project) "/some/project/")))
         (let ((buffer (gitlab--prepare-detail
                        (lambda (_id _context) "*GitLab directory test*")
                        #'gitlab-detail-mode "1")))
           (unwind-protect
               (with-current-buffer buffer
                 (should (equal "/some/project/" default-directory))
                 (should (equal "/some/project/" gitlab-cli-directory))
                 (should-not (buffer-modified-p)))
             (kill-buffer buffer))))))))

(ert-deftest gitlab-mode-detail-directory-outside-project ()
  "A detail buffer keeps the directory when it belongs to no project."
  (gitlab-test-with-environment
   (let ((default-directory (file-name-as-directory "/no/project")))
     (with-temp-buffer
       (cl-letf (((symbol-function 'project-current)
                  (lambda (&rest _arguments) nil)))
         (let ((buffer (gitlab--prepare-detail
                        (lambda (_id _context)
                          "*GitLab directory fallback test*")
                        #'gitlab-detail-mode "1")))
           (unwind-protect
               (with-current-buffer buffer
                 (should (equal (file-name-as-directory "/no/project")
                                default-directory))
                 (should (equal (file-name-as-directory "/no/project")
                                gitlab-cli-directory)))
             (kill-buffer buffer))))))))

(defun gitlab-mode-test--column-widths ()
  "Return the width of every column of the current list buffer."
  (mapcar (lambda (column) (nth 1 column))
          (append tabulated-list-format nil)))

(ert-deftest gitlab-mode-list-fit-columns ()
  "A list render sizes every column to its content."
  (gitlab-test-with-environment
   (with-temp-buffer
     (gitlab-list-mode)
     (setq-local tabulated-list-format [("ID" 7 t) ("Title" 42 t)])
     (setq-local tabulated-list-sort-key nil)
     (setq-local tabulated-list-entries
                 '(("1" ["!1" "short"])
                   ("2" ["!22" "a much longer title"])))
     (cl-letf (((symbol-function 'gitlab-list--available-width)
                (lambda (&optional _window) 200)))
       (gitlab-list--render nil nil))
     (should (equal '(3 19) (gitlab-mode-test--column-widths)))
     (should (equal "ID" (car (aref tabulated-list-format 0))))
     (should (equal 't (nth 2 (aref tabulated-list-format 0)))))))

(ert-deftest gitlab-mode-list-fit-columns-clip ()
  "Fitted columns shrink together and keep their header width."
  (gitlab-test-with-environment
   (with-temp-buffer
     (gitlab-list-mode)
     (setq-local tabulated-list-format [("ID" 7 t) ("Title" 42 t)])
     (setq-local tabulated-list-sort-key '("ID" . t))
     (setq-local tabulated-list-entries
                 '(("1" ["!1" "a much longer title"])))
     (cl-letf (((symbol-function 'gitlab-list--available-width)
                (lambda (&optional _window) 12)))
       (gitlab-list--render nil nil))
     ;; The ID header takes "ID", one pad and the sort indicator, so
     ;; it keeps five columns and the title takes the rest.
     (should (equal '(5 7) (gitlab-mode-test--column-widths)))
     (should (= 12 (apply #'+ (gitlab-mode-test--column-widths)))))))

(ert-deftest gitlab-mode-list-fit-columns-off ()
  "A nil `gitlab-list-fit-columns' keeps the widths of the format."
  (gitlab-test-with-environment
   (let ((gitlab-list-fit-columns nil))
     (with-temp-buffer
       (gitlab-list-mode)
       (setq-local tabulated-list-format [("ID" 7 t) ("Title" 42 t)])
       (setq-local tabulated-list-sort-key nil)
       (setq-local tabulated-list-entries '(("1" ["!1" "short"])))
       (gitlab-list--render nil nil)
       (should (equal '(7 42) (gitlab-mode-test--column-widths)))))))

(ert-deftest gitlab-mode-list-fit-keeps-column-properties ()
  "A fitted column keeps its own properties.
The fitting replaces the width alone, so a right-aligned numeric
column stays right-aligned."
  (gitlab-test-with-environment
   (with-temp-buffer
     (gitlab-list-mode)
     (setq-local tabulated-list-format
                 [("ID" 7 t :right-align t) ("Title" 42 t)])
     (setq-local tabulated-list-sort-key nil)
     (setq-local tabulated-list-entries '(("1" ["!1" "short"])))
     (cl-letf (((symbol-function 'gitlab-list--available-width)
                (lambda (&optional _window) 200)))
       (gitlab-list--render nil nil))
     (should (eq t (plist-get (nthcdr 3 (aref tabulated-list-format 0))
                              :right-align)))
     (should (equal '(3 6) (gitlab-mode-test--column-widths))))))

(ert-deftest gitlab-mode-list-refit-resize ()
  "A narrower window refits the columns and keeps the rows."
  (gitlab-test-with-environment
   (with-temp-buffer
     (gitlab-list-mode)
     (setq-local tabulated-list-format [("ID" 7 t) ("Title" 42 t)])
     (setq-local tabulated-list-sort-key nil)
     (setq-local tabulated-list-entries
                 '(("1" ["!1" "a much longer title"])))
     (cl-letf (((symbol-function 'gitlab-list--available-width)
                (lambda (&optional _window) 200)))
       (gitlab-list--render nil nil))
     (should (equal '(3 19) (gitlab-mode-test--column-widths)))
     (cl-letf (((symbol-function 'gitlab-list--available-width)
                (lambda (&optional _window) 12)))
       (gitlab-list--schedule-refit)
       (gitlab-list--run-refits))
     (should (equal '(3 9) (gitlab-mode-test--column-widths)))
     (should (string-match-p "a much" (buffer-string))))))

(ert-deftest gitlab-mode-list-number-sort ()
  "A numeric column sorts entries and ignores the IID sigil."
  (gitlab-test-with-environment
   (with-temp-buffer
     (gitlab-list-mode)
     (setq-local tabulated-list-format
                 [("IID" 7 gitlab-list--number-sort)
                  ("Title" 20 t)])
     (setq-local tabulated-list-entries
                 '(("13" ["!13" "b"])
                   ("12" ["!12" "a"])))
     (setq-local tabulated-list-sort-key '("IID" . nil))
     (tabulated-list-print t)
     (should (equal '("12" "13")
                    (mapcar #'car tabulated-list-entries))))))

(ert-deftest gitlab-mode-list-change-hook-kind ()
  "A list refresh passes its collection kind to the change hook."
  (gitlab-test-with-environment
   (with-temp-buffer
     (gitlab-list-mode)
     (setq-local tabulated-list-format [("ID" 8 t)])
     (setq-local gitlab-list--kind 'merge-request)
     (setq-local gitlab-list--fetch-function
                 (lambda (success _error) (funcall success nil)))
     (setq-local gitlab-list--entries-function #'ignore)
     (setq-local gitlab-list--rows-function #'ignore)
     (let* (seen
            (gitlab-change-functions
             (list (lambda (kind id _data) (setq seen (list kind id))))))
       (gitlab-list--refresh)
       (should (equal '(merge-request nil) seen))))))

(ert-deftest gitlab-mode-list-buffers-directory ()
  "A list buffer names its project in `list-buffers-directory'."
  (gitlab-test-with-environment
   (let ((gitlab-repository "group/project"))
     (with-temp-buffer
       (gitlab-list-mode)
       (setq-local gitlab-list--kind 'merge-request)
       (gitlab--update-list-buffers-directory)
       (should (equal "group/project" list-buffers-directory))))))

(ert-deftest gitlab-mode-format-object-job ()
  "A nested job gets no pipeline property."
  (let* ((value (gitlab--format-value
                 '((id . 5) (status . "failed") (stage . "test")
                   (name . "lint"))))
         (pipeline (get-text-property 0 'gitlab-pipeline-id value)))
    (should (equal "#5 failed" value))
    (should-not pipeline)))

(ert-deftest gitlab-mode-go-to-parent-without-parent ()
  "A buffer without a parent function signals a `user-error'."
  (gitlab-test-with-environment
   (with-temp-buffer
     (gitlab-detail-mode)
     (should-error (gitlab-go-to-parent) :type 'user-error))))

(ert-deftest gitlab-mode-go-to-parent-keys ()
  "The detail and job log modes remap `dired-jump'."
  (dolist (mode '(gitlab-detail-mode gitlab-job-log-mode))
    (with-temp-buffer
      (funcall mode)
      (should (eq #'gitlab-go-to-parent
                  (key-binding (kbd "C-x C-j"))))
      (dolist (command '(dired-jump dired-up-directory))
        (should (eq #'gitlab-go-to-parent
                    (command-remapping command)))))))

(ert-deftest gitlab-mode-go-to-parent-list-keys ()
  "A list buffer keeps the Dired meaning of `dired-jump'."
  (with-temp-buffer
    (gitlab-list-mode)
    (should (eq #'dired-jump (key-binding (kbd "C-x C-j"))))))

(ert-deftest gitlab-mode-sibling-keys ()
  "The detail and job log modes bind both sibling commands."
  (dolist (mode '(gitlab-detail-mode gitlab-job-log-mode))
    (with-temp-buffer
      (funcall mode)
      (should (eq #'gitlab-next-sibling
                  (key-binding (kbd "C-c C-n"))))
      (should (eq #'gitlab-previous-sibling
                  (key-binding (kbd "C-c C-p"))))
      (should (eq #'gitlab-next-sibling (key-binding [mouse-9])))
      (should (eq #'gitlab-previous-sibling (key-binding [mouse-8]))))))

(ert-deftest gitlab-mode-sibling-without-parent ()
  "A buffer without a parent signals a `user-error'."
  (gitlab-test-with-environment
   (with-temp-buffer
     (gitlab-detail-mode)
     (should-error (gitlab-next-sibling) :type 'user-error)
     (should-error (gitlab-previous-sibling) :type 'user-error))))

(ert-deftest gitlab-mode-sibling-list-is-top-level ()
  "A list buffer has no siblings, because it has no parent."
  (gitlab-test-with-environment
   (with-temp-buffer
     (gitlab-list-mode)
     (should-error (gitlab-next-sibling) :type 'user-error))))

(ert-deftest gitlab-mode-list-children ()
  "The children of a list buffer are its rows in display order.
The fake header line and the empty rows contribute nothing."
  (gitlab-test-with-environment
   (with-temp-buffer
     (gitlab-list-mode)
     (setq-local tabulated-list-format [("ID" 8 t)])
     (setq-local tabulated-list-entries
                 '(("1" ["one"]) ("2" ["two"]) ("3" ["three"])))
     (tabulated-list-print t)
     (should (equal '(("1" . nil) ("2" . nil) ("3" . nil))
                    (gitlab--children))))))

(ert-deftest gitlab-mode-children-by-function ()
  "A parent buffer with a children function answers with it."
  (with-temp-buffer
    (gitlab-detail-mode)
    (setq-local gitlab--children-function
                (lambda () '(("5001" . "build") ("5002" . "test"))))
    (should (equal '(("5001" . "build") ("5002" . "test"))
                   (gitlab--children)))))

(ert-deftest gitlab-mode-command-modes ()
  "Every display command names the modes in which it works."
  (should (equal '(gitlab-detail-mode)
                 (command-modes #'gitlab-open-at-point)))
  (should (equal '(gitlab-detail-mode)
                 (command-modes #'gitlab-mouse-open-at-point)))
  (should (equal '(gitlab-detail-mode) (command-modes #'gitlab-open-web)))
  (should (equal '(gitlab-detail-mode) (command-modes #'gitlab-pop)))
  (should-not (command-modes #'gitlab-copy-id))
  (should (equal '(gitlab-detail-mode)
                 (command-modes #'gitlab-detail-toggle-section)))
  (should (equal '(gitlab-detail-mode gitlab-job-log-mode)
                 (command-modes #'gitlab-go-to-parent)))
  (should (equal '(gitlab-detail-mode gitlab-job-log-mode)
                 (command-modes #'gitlab-next-sibling)))
  (should (equal '(gitlab-detail-mode gitlab-job-log-mode)
                 (command-modes #'gitlab-previous-sibling)))
  (should (equal '(gitlab-list-mode) (command-modes #'gitlab-list-open)))
  (should (equal '(gitlab-list-mode)
                 (command-modes #'gitlab-list-mouse-open)))
  (should (equal '(gitlab-list-mode)
                 (command-modes #'gitlab-list-copy-id)))
  (should (equal '(gitlab-list-mode)
                 (command-modes #'gitlab-list-open-web))))

(ert-deftest gitlab-mode-command-modes-filter-mx ()
  "A mode-tagged command hides outside its mode in command completion."
  (with-temp-buffer
    (should-not (command-completion-default-include-p
                 #'gitlab-open-web (current-buffer)))
    (gitlab-detail-mode)
    (should (command-completion-default-include-p
             #'gitlab-open-web (current-buffer)))
    (gitlab-list-mode)
    (should-not (command-completion-default-include-p
                 #'gitlab-open-web (current-buffer)))))

(ert-deftest gitlab-mode-remaps-the-json-major-mode ()
  "The display layer remaps `js-json-mode' to the export command.
The binding lives in this layer and not in `gitlab-export', because
an autoloaded display command loads `gitlab-mode' alone.  The
target stays a symbol, so the export layer loads on the first key
that reaches it."
  (dolist (mode '(gitlab-detail-mode gitlab-list-mode))
    (with-temp-buffer
      (funcall mode)
      (should (eq (command-remapping 'js-json-mode)
                  'gitlab-export-json))))
  (should (eq (lookup-key gitlab-detail-mode-map [remap js-json-mode])
              'gitlab-export-json))
  (should (eq (lookup-key gitlab-list-mode-map [remap js-json-mode])
              'gitlab-export-json)))

(ert-deftest gitlab-mode-list-expands-a-row ()
  "A rendered list shows the child row of an expanded row.
The child row answers its parent as the identity of its line, so a
render that replaces it keeps the place through the parent."
  (gitlab-test-with-environment
   (with-temp-buffer
     (gitlab-list-mode)
     (setq-local tabulated-list-format [("ID" 12 t) ("Title" 20 t)])
     (setq-local tabulated-list-sort-key '("ID" . nil))
     (setq-local gitlab--last-data '((id . 1)))
     (setq-local gitlab-list--entries-function
                 (lambda (_data)
                   (list (list "10" (vector "10" "ten"))
                         (list "20" (vector "20" "twenty")))))
     (setq-local gitlab-list--child-function
                 (lambda (id)
                   (list (cons (concat id ".child")
                               (vector "   child" id)))))
     (should (eq t (gitlab-list--set-expanded "10" t)))
     (gitlab-list--render nil nil)
     (should (equal '("10" "10.child" "20")
                    (mapcar #'car tabulated-list-entries)))
     (should (string-match-p "child" (buffer-string)))
     (should (gitlab--goto-property 'tabulated-list-id "10.child"))
     (should (equal "10" (gitlab-list--parent-id-at-point)))
     (should (equal '(row . "10") (gitlab--line-identity)))
     (should (equal '("10" "20")
                    (mapcar #'car (gitlab-list--children))))
     ;; TAB on the child row collapses the row of the parent.
     (gitlab-list-toggle-expansion)
     (should (equal '("10" "20")
                    (mapcar #'car tabulated-list-entries))))))

(ert-deftest gitlab-mode-list-order-keeps-children ()
  "The sort keeps a child row behind its parent in both directions.
`tabulated-list-print' reverses the sort of a descending key by
swapping the arguments, and that swap would turn a child in front
of its parent.  The list layer therefore sorts the parent rows
alone and adds the child rows after the sort."
  (gitlab-test-with-environment
   (with-temp-buffer
     (gitlab-list-mode)
     (setq-local tabulated-list-format [("ID" 8 t)])
     (setq-local gitlab-list--child-function
                 (lambda (id)
                   (list (cons (concat id ".child")
                               (vector "  child")))))
     (gitlab-list--set-expanded "10" t)
     (gitlab-list--set-expanded "20" t)
     (let ((entries '(("20" ["20"]) ("10" ["10"]))))
       (setq tabulated-list-sort-key '("ID" . nil))
       (should (equal '("10" "10.child" "20" "20.child")
                      (mapcar #'car
                              (gitlab-list--ordered-entries entries))))
       (setq tabulated-list-sort-key '("ID" . t))
       (should (equal '("20" "20.child" "10" "10.child")
                      (mapcar #'car
                              (gitlab-list--ordered-entries entries))))))))

(ert-deftest gitlab-mode-list-sort-command ()
  "`gitlab-list-sort' sets the key, flips it and returns the order."
  (gitlab-test-with-environment
   (with-temp-buffer
     (gitlab-list-mode)
     (setq-local tabulated-list-format [("ID" 8 t) ("Title" 20 t)])
     (setq-local tabulated-list-sort-key nil)
     (setq-local gitlab--last-data '((id . 1)))
     (setq-local gitlab-list--entries-function
                 (lambda (_data)
                   (list (list "2" (vector "2" "two"))
                         (list "1" (vector "1" "one")))))
     (gitlab-list-sort 0)
     (should (equal '("ID" . nil) tabulated-list-sort-key))
     (should (equal '("1" "2") (mapcar #'car tabulated-list-entries)))
     (gitlab-list-sort 0)
     (should (equal '("ID" . t) tabulated-list-sort-key))
     (should (equal '("2" "1") (mapcar #'car tabulated-list-entries)))
     (gitlab-list-sort -1)
     (should-not tabulated-list-sort-key)
     (should (equal '("2" "1") (mapcar #'car tabulated-list-entries))))))

(ert-deftest gitlab-mode-browse-url ()
  "A GitLab web URL opens the object of its own project."
  (let (calls)
    (cl-letf (((symbol-function 'gitlab-display-merge-request)
               (lambda (id &optional repository)
                 (push (list 'merge-request id repository) calls)))
              ((symbol-function 'gitlab-display-work-item)
               (lambda (id &optional repository)
                 (push (list 'work-item id repository) calls)))
              ((symbol-function 'gitlab-display-pipeline)
               (lambda (id &optional repository)
                 (push (list 'pipeline id repository) calls)))
              ((symbol-function 'gitlab-display-job-log)
               (lambda (id &optional name pipeline-id repository)
                 (push (list 'job id name pipeline-id repository) calls))))
      (should (gitlab-browse-url
               "https://gitlab.com/group/project/-/merge_requests/12/diffs"))
      (should (gitlab-browse-url
               "https://gitlab.example.com/a/b/-/pipelines/1001?ref=main"))
      (should (gitlab-browse-url
               "https://gitlab.example.com/a/b/-/jobs/5001#L10"))
      (should (gitlab-browse-url
               "https://gitlab.example.com/a/b/-/work_items/7"))
      (should (gitlab-browse-url
               "https://gitlab.example.com/a/b/-/issues/8"))
      (should-not (gitlab-browse-url "https://gitlab.com/group/project")))
    (should (equal '((merge-request "12" "group/project")
                     (pipeline "1001" "a/b@gitlab.example.com")
                     (job "5001" nil nil "a/b@gitlab.example.com")
                     (work-item "7" "a/b@gitlab.example.com")
                     (work-item "8" "a/b@gitlab.example.com"))
                   (nreverse calls)))))

(ert-deftest gitlab-mode-browse-url-handler-option ()
  "The option adds and removes the `browse-url' entry."
  (let ((browse-url-default-handlers (copy-sequence
                                      browse-url-default-handlers)))
    (customize-set-variable 'gitlab-browse-url-handler nil)
    (should-not (assoc gitlab--browse-url-regexp browse-url-default-handlers))
    (customize-set-variable 'gitlab-browse-url-handler t)
    (should (eq #'gitlab-browse-url
                (cdr (assoc gitlab--browse-url-regexp
                            browse-url-default-handlers))))
    (customize-set-variable 'gitlab-browse-url-handler nil)))

(ert-deftest gitlab-mode-display-commands-take-repository ()
  "A display command passes its project to the display helper."
  (let (arguments)
    (cl-letf (((symbol-function 'gitlab--show-detail)
               (lambda (&rest value)
                 (prog1 (current-buffer) (setq arguments value)))))
      (gitlab-display-merge-request "!12" "group/project@host")
      (should (equal '("12" "group/project@host") (cddr arguments)))
      (gitlab-display-pipeline "1001" "group/project@host")
      (should (equal '("1001" "group/project@host") (cddr arguments))))
    (cl-letf (((symbol-function 'gitlab-pipeline--prepare-job-log)
               (lambda (&rest value)
                 (prog1 (current-buffer) (setq arguments value)))))
      (gitlab-display-job-log "5001" nil nil "group/project@host")
      (should (equal '("5001" nil nil "group/project@host") arguments)))))

(ert-deftest gitlab-mode-object-at-point ()
  "The object at point comes from the property, the buffer or the URL."
  (with-temp-buffer
    (insert "https://gitlab.example.com/a/b/-/pipelines/1001")
    (goto-char (point-min))
    (should (equal '(pipeline "1001" "a/b@gitlab.example.com" url)
                   (gitlab--object-at-point))))
  (with-temp-buffer
    (insert "no GitLab object here")
    (should-not (gitlab--object-at-point)))
  (with-temp-buffer
    (insert (propertize "!12" 'gitlab-merge-request-iid "12"))
    (setq-local gitlab--context "group/project")
    (goto-char (point-min))
    (should (equal '(merge-request "12" "group/project" property)
                   (gitlab--object-at-point)))
    (should-error (gitlab--object-at-point 'pipeline) :type 'user-error))
  (with-temp-buffer
    (gitlab-detail-mode)
    (setq-local gitlab--kind 'pipeline)
    (setq-local gitlab--id "7")
    (setq-local gitlab--context "group/project")
    (should (equal '(pipeline "7" "group/project" buffer)
                   (gitlab--object-at-point)))))

(ert-deftest gitlab-mode-copy-id-at-point ()
  "Copy-id reads the object at point."
  (let ((kill-ring nil))
    (with-temp-buffer
      (insert "See https://gitlab.com/group/project/-/merge_requests/12 now")
      (goto-char (point-min))
      (search-forward "merge_requests")
      (gitlab-copy-id)
      (should (equal "12" (car kill-ring))))
    (with-temp-buffer
      (insert "no object")
      (should-error (gitlab-copy-id) :type 'user-error))))

(ert-deftest gitlab-mode-object-at-point-group-row ()
  "A group row ID names its own project, not the group."
  (with-temp-buffer
    (insert (propertize "!12" 'gitlab-merge-request-iid
                        "other/project!12"))
    (setq-local gitlab--scope 'group)
    (setq-local gitlab--context "group")
    (goto-char (point-min))
    (should (equal '(merge-request "12" "other/project" property)
                   (gitlab--object-at-point)))))

(provide 'gitlab-mode-tests)

;;; gitlab-mode-test.el ends here
