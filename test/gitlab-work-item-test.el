;;; gitlab-work-item-test.el --- Tests of the work item views -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Daniel Nagy

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;;; Commentary:

;; Offline tests of the work item list and detail buffers.  GitLab
;; renamed the issue object to work item, so the fixtures hold issue
;; JSON and the web URLs use /-/work_items/.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'bookmark)
(require 'gitlab-test-helper)
(require 'gitlab-work-item)

(defun gitlab-work-item-tests--wait-for (buffer text)
  "Wait until BUFFER contains TEXT."
  (gitlab-test-wait
   (lambda ()
     (and (buffer-live-p buffer)
          (with-current-buffer buffer
            (string-match-p (regexp-quote text) (buffer-string)))))))

(ert-deftest gitlab-work-item-identifier ()
  "A work item identifier uses the % sigil."
  (should (equal "group/project%12"
                 (gitlab-data-identifier 'work-item "12" "group/project")))
  (should (equal '("group/project" . "12")
                 (gitlab-data-identifier-split 'work-item
                                               "group/project%12")))
  (should (equal '(nil . "12")
                 (gitlab-data-identifier-split 'work-item "%12"))))

(ert-deftest gitlab-work-item-web-url ()
  "The web URL of a work item names the work_items path."
  (let ((gitlab-repository "group/project"))
    (should (equal "https://gitlab.example/group/project/-/work_items/21"
                   (gitlab-web-url 'work-item 21
                                   "group/project@gitlab.example")))))

(ert-deftest gitlab-work-item-data-entry-points ()
  "The data layer reads an issue as a work item."
  (gitlab-test-with-environment
   (let ((items (gitlab-work-item-list)))
     (should (= 2 (length items)))
     (should (equal "Add the setup guide"
                    (gitlab-data-field "title" (car items)))))
   (let ((item (gitlab-work-item-show "21")))
     (should (equal 21 (gitlab-data-field "iid" item)))
     (should (equal "issue" (gitlab-data-field "issue_type" item))))))

(ert-deftest gitlab-work-item-list-entries ()
  "The list renders every work item."
  (gitlab-test-with-environment
   (let ((buffer (generate-new-buffer "*GitLab work item list test*")))
     (unwind-protect
         (with-current-buffer buffer
           (gitlab-work-item-list-mode)
           (gitlab-list--refresh)
           (should (gitlab-test-wait
                    (lambda () (= 2 (length tabulated-list-entries)))))
           (should (= 2 (length gitlab-list--rows)))
           (should (string-match-p "%21" (buffer-string)))
           (should (string-match-p "Add the setup guide" (buffer-string)))
           (should (string-match-p "incident" (buffer-string)))
           (should (string-match-p "closed" (buffer-string)))
           (should (string-match-p "good first issue" (buffer-string))))
       (with-current-buffer buffer
         (set-buffer-modified-p nil))
       (kill-buffer buffer)))))

(ert-deftest gitlab-work-item-list-numeric-column-right-aligns ()
  "The IID column aligns its cells to the right."
  (should (eq t (plist-get (nthcdr 3 (aref gitlab-work-item-list-format 0))
                           :right-align)))
  (should (eq 'gitlab-list--number-sort
              (nth 2 (aref gitlab-work-item-list-format 0)))))

(ert-deftest gitlab-work-item-list-thing-at-point-url ()
  "The url thing at point is the web URL of the row."
  (gitlab-test-with-environment
   (let ((buffer (generate-new-buffer "*GitLab work item list url test*")))
     (unwind-protect
         (with-current-buffer buffer
           (gitlab-work-item-list-mode)
           (gitlab-list--refresh)
           (should (gitlab-test-wait
                    (lambda () (= 2 (length tabulated-list-entries)))))
           (goto-char (point-min))
           (while (and (not (string-match-p "Add the setup guide"
                                            (thing-at-point 'line)))
                       (not (eobp)))
             (forward-line 1))
           (should (equal "https://gitlab.example/group/project/-/work_items/21"
                          (thing-at-point 'url))))
       (with-current-buffer buffer
         (set-buffer-modified-p nil))
       (kill-buffer buffer)))))

(ert-deftest gitlab-work-item-group-entries ()
  "A group row keeps its project in the row ID and the leftmost cell."
  (with-temp-buffer
    (setq-local gitlab--scope 'group)
    (setq-local gitlab--context "group")
    (let* ((gitlab-show-author-username t)
           (item '((iid . 12)
                   (title . "Group item")
                   (state . "opened")
                   (issue_type . "issue")
                   (author . ((username . "alice") (name . "Alice")))
                   (labels . ("docs"))
                   (updated_at . "2026-11-01T09:30:00.000Z")
                   (web_url . "https://gitlab.example.com/group/project/-/work_items/12")))
           (entries (gitlab-work-item--entries (list item)))
           (cells (cadr (car entries))))
      (should (equal '("group/project@gitlab.example.com%12"
                       "group/project@gitlab.example.com"
                       "%12"
                       "issue"
                       "Group item"
                       "opened"
                       "Alice (@alice)"
                       "docs"
                       "2026-11-01 09:30:00")
                     (cons (car (car entries)) (append cells nil))))
      (should (equal "group/project@gitlab.example.com%12"
                     (get-text-property 0 'gitlab-work-item-iid
                                        (aref cells 1))))
      (should (= 8 (length cells))))))

(ert-deftest gitlab-work-item-detail-buffer ()
  "The detail buffer renders the fields of the work item."
  (gitlab-test-with-environment
   (let ((gitlab-repository "group/project"))
     (let ((buffer (gitlab--prepare-detail
                    #'gitlab-work-item--buffer-name
                    #'gitlab-work-item-mode "21")))
       (unwind-protect
           (progn
             (should (gitlab-work-item-tests--wait-for
                      buffer "Add the setup guide"))
             (with-current-buffer buffer
               (should (derived-mode-p 'gitlab-work-item-mode))
               (should (equal "group/project%21" list-buffers-directory))
               (should (equal "*GitLab Work Item group/project%21*"
                              (buffer-name)))
               (should (string-match-p "%21 Add the setup guide"
                                       (buffer-string)))
               (should (string-match-p "Description:" (buffer-string)))
               (should (string-match-p "good first issue" (buffer-string)))
               (goto-char (point-min))
               (should (re-search-forward
                        "https://gitlab.example/group/project/-/work_items/21"
                        nil t))
               (should (equal "https://gitlab.example/group/project/-/work_items/21"
                              (get-text-property (1- (point)) 'gitlab-url)))))
         (with-current-buffer buffer
           (set-buffer-modified-p nil))
         (kill-buffer buffer))))))

(ert-deftest gitlab-work-item-display-command-parses-identifier ()
  "The display command takes an IID from a full identifier."
  (let (arguments)
    (cl-letf (((symbol-function 'gitlab--show-detail)
               (lambda (&rest value)
                 (setq arguments value)
                 (current-buffer))))
      (gitlab-display-work-item "group/project%21")
      (should (equal "21" (nth 2 arguments)))
      (should (equal "group/project" (nth 3 arguments)))
      (gitlab-display-work-item "%22")
      (should (equal "22" (nth 2 arguments))))))

(ert-deftest gitlab-work-item-read-prompt ()
  "The prompt completes with the % sigil and annotates the title."
  (gitlab-test-with-environment
   (let (collection category annotation)
     (cl-letf (((symbol-function 'gitlab-work-item-list-cached)
                (lambda ()
                  '(((iid . 7) (title . "Seven") (state . "opened"))
                    ((iid . 10) (title . "Ten") (state . "closed")))))
               ((symbol-function 'completing-read)
                (lambda (_prompt completions &rest _arguments)
                  (setq collection (append completions nil)
                        category (plist-get completion-extra-properties
                                            :category)
                        annotation
                        (funcall (plist-get completion-extra-properties
                                            :annotation-function)
                                 "%7"))
                  "%7")))
       (should (equal "7" (gitlab-read-work-item-iid))))
     (should (equal '("%7" "%10") collection))
     (should (eq 'gitlab-work-item category))
     (should (equal "  Seven  [opened]" annotation)))))

(ert-deftest gitlab-work-item-bookmark-record ()
  "A work item buffer stores its identifier as the bookmark location."
  (gitlab-test-with-environment
   (let ((gitlab-repository "group/project"))
     (let ((buffer (gitlab--prepare-detail
                    #'gitlab-work-item--buffer-name
                    #'gitlab-work-item-mode "21")))
       (unwind-protect
           (progn
             (should (gitlab-work-item-tests--wait-for
                      buffer "Add the setup guide"))
             (with-current-buffer buffer
               (let ((record (funcall bookmark-make-record-function)))
                 (should (eq 'work-item (alist-get 'kind record)))
                 (should (equal "gitlab-work-item:group/project%21"
                                (alist-get 'location record)))
                 (should (equal "GitLab Work Item gitlab-work-item:group/project%21"
                                (car record))))))
         (with-current-buffer buffer
           (set-buffer-modified-p nil))
         (kill-buffer buffer))))))

(provide 'gitlab-work-item-tests)

;;; gitlab-work-item-test.el ends here
