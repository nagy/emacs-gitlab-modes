;;; gitlab-modes.el --- GitLab merge request and pipeline modes -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Daniel Nagy

;; Author: Daniel Nagy
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
;; Keywords: tools, convenience
;; URL: https://github.com/nagy/emacs-gitlab-modes

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Affero General Public License for more details.

;; You should have received a copy of the GNU Affero General Public
;; License along with this program.  If not, see
;; <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Entry library of the package.  Requiring `gitlab-modes' loads the
;; data layer, the display layer and both resource families:
;;
;;   M-x gitlab-list-merge-requests
;;   M-x gitlab-display-merge-request
;;   M-x gitlab-list-pipelines
;;   M-x gitlab-display-pipeline
;;   M-x gitlab-display-job-log
;;   M-x gitlab-export-json
;;
;; The optional layers keep their own libraries and stay out of this
;; one: `gitlab-evil' adds evil bindings, `ol-gitlab' adds Org link
;; types and `gitlab-xref' adds the xref backend.  The autoloaded form
;; below loads the evil layer when evil loads and enables the bindings
;; unless the option `gitlab-evil-auto-enable' is nil.  The plain form
;; covers the other load order, when evil is already loaded.  A user
;; without evil loads nothing extra.
;;
;; All reads go through glab.  Set `gitlab-program' to another binary
;; path, or `gitlab-repository' to OWNER/REPO when the current
;; directory is not a Git checkout of the wanted project.
;;
;; A display buffer carries a bookmark record, so `C-x r m' saves the
;; object, its project and the point in the buffer, and a jump rebuilds
;; the buffer from the record.

;;; Code:

(require 'gitlab-error)
(require 'gitlab-cli)
(require 'gitlab-data)
(require 'gitlab-mode)
(require 'gitlab-read)
(require 'gitlab-merge-request)
(require 'gitlab-pipeline)
(require 'gitlab-export)

(declare-function gitlab-evil-auto-setup "gitlab-evil" ())

;;;###autoload
(add-hook 'evil-after-load-hook #'gitlab-evil-auto-setup)

(when (featurep 'evil)
  (gitlab-evil-auto-setup))

(provide 'gitlab-modes)

;;; gitlab-modes.el ends here
