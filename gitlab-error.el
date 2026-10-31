;;; gitlab-error.el --- Conditions of the GitLab modes -*- lexical-binding: t; -*-

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

;; The package-wide parent condition `gitlab-error'.  The transport
;; layers derive their own conditions from it, so a caller can catch
;; every GitLab failure with one handler:
;;
;;   (condition-case err
;;       (gitlab-merge-request-list)
;;     (gitlab-error (message "%s" (error-message-string err))))
;;
;; `gitlab-cli-error' covers the glab command line transport and
;; `gitlab-api-error' reserves the native HTTP transport.  The
;; timeout conditions derive from their transport, so a caller can
;; retry a slow request without treating every failure as a timeout.
;;
;; This file also defines the `gitlab' customization group, because
;; every other library requires it.

;;; Code:

(defgroup gitlab nil
  "Display GitLab merge requests and pipelines in Emacs."
  :prefix "gitlab-"
  :group 'tools)

(define-error 'gitlab-error "GitLab error")

(define-error 'gitlab-cli-error "GitLab CLI error" 'gitlab-error)
(define-error 'gitlab-cli-timeout "GitLab CLI timeout" 'gitlab-cli-error)

(define-error 'gitlab-api-error "GitLab API error" 'gitlab-error)
(define-error 'gitlab-api-timeout "GitLab API timeout" 'gitlab-api-error)

(define-error 'gitlab-backend-error "Unsupported GitLab backend"
  'gitlab-error)

(provide 'gitlab-error)

;;; gitlab-error.el ends here
