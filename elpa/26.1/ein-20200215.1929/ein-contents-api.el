;;; ein-contents-api.el --- Interface to Jupyter's Contents API

;; Copyright (C) 2015 - John Miller

;; Authors: Takafumi Arakaki <aka.tkf at gmail.com>
;;          John M. Miller <millejoh at mac.com>

;; This file is NOT part of GNU Emacs.

;; ein-contents-api.el is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; ein-contents-api.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with ein-notebooklist.el.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;;;
;;; An interface to the Jupyter Contents API as described in
;;; https://github.com/ipython/ipython/wiki/IPEP-27%3A-Contents-Service.
;;;

;;

;;; Code:

(require 'ein-core)
(require 'ein-classes)
(require 'ein-utils)
(require 'ein-log)
(require 'ein-query)
(provide 'ein-notebook) ; see manual "Named Features" regarding recursive requires
(require 'ein-notebook)

(defcustom ein:content-query-max-depth 2
  "Don't recurse the directory tree deeper than this."
  :type 'integer
  :group 'ein)

(defcustom ein:content-query-max-branch 6
  "Don't descend into more than this number of directories per depth.  The total number of parallel queries should therefore be O({max_branch}^{max_depth})"
  :type 'integer
  :group 'ein)

(defcustom ein:content-query-timeout nil ; (* 60 1000) ;1 min
  "Query timeout for getting content from Jupyter/IPython notebook.
If you cannot open large notebooks because of a timeout error try
increasing this value.  Setting this value to `nil' means to use
global setting.  For global setting and more information, see
`ein:query-timeout'."
  :type '(choice (integer :tag "Timeout [ms]" 5000)
                 (const :tag "Use global setting" nil))
  :group 'ein)

(defcustom ein:force-sync nil
  "When non-nil, force synchronous http requests."
  :type 'boolean
  :group 'ein)

(defun ein:content-query-contents (url-or-port path callback errback &optional iteration)
  "Register CALLBACK of arity 1 for the contents at PATH from the URL-OR-PORT.
ERRBACK of arity 1 for the contents."
  (unless iteration
    (setq iteration 0))
  (ein:query-singleton-ajax
   (ein:notebooklist-url url-or-port path)
   :type "GET"
   :timeout ein:content-query-timeout
   :parser #'ein:json-read
   :complete (apply-partially #'ein:content-query-contents--complete url-or-port path)
   :success (apply-partially #'ein:content-query-contents--success url-or-port path callback)
   :error (apply-partially #'ein:content-query-contents--error url-or-port path callback errback iteration)))

(cl-defun ein:content-query-contents--complete (url-or-port path
                                                &key data symbol-status response
                                                &allow-other-keys
                                                &aux (resp-string (format "STATUS: %s DATA: %s" (request-response-status-code response) data)))
  (ein:log 'debug "ein:query-contents--complete %s" resp-string))

(cl-defun ein:content-query-contents--error (url-or-port path callback errback iteration &key symbol-status response error-thrown data &allow-other-keys)
  (let ((status-code (request-response-status-code response))) ; may be nil!
    (case status-code
      (404 (ein:log 'error "ein:content-query-contents--error %s %s"
                    status-code (plist-get data :message))
           (when errback (funcall errback url-or-port status-code)))
      (t (if (< iteration (if noninteractive 6 3))
             (progn
               (ein:log 'verbose "Retry content-query-contents #%s in response to %s" iteration status-code)
               (sleep-for 0 (* (1+ iteration) 500))
               (ein:content-query-contents url-or-port path callback errback (1+ iteration)))
           (let ((notice
                  (format "ein:content-query-contents--error %s REQUEST-STATUS %s DATA %s"
                          (concat (file-name-as-directory url-or-port) path)
                          symbol-status (cdr error-thrown))))
             (if (and (eql status-code 403) noninteractive)
                 (progn
                   (ein:log 'info notice)
                   (when callback
                     (funcall callback (ein:new-content url-or-port path data))))
               (ein:log 'error notice)
               (when errback (funcall errback url-or-port status-code)))))))))

(cl-defun ein:content-query-contents--success (url-or-port path callback
                                               &key data symbol-status response
                                               &allow-other-keys)
  (let (content)
    (if (< (ein:notebook-version-numeric url-or-port) 3)
        (setq content (ein:new-content-legacy url-or-port path data))
      (setq content (ein:new-content url-or-port path data)))
    (when callback
      (funcall callback content))))

(defun ein:fix-legacy-content-data (data)
  (if (listp (car data))
      (cl-loop for item in data
            collecting
            (ein:fix-legacy-content-data item))
    (if (string= (plist-get data :path) "")
        (plist-put data :path (plist-get data :name))
      (plist-put data :path (format "%s/%s" (plist-get data :path) (plist-get data :name))))))

(defun ein:content-to-json (content)
  (let ((path (if (>= (ein:$content-notebook-version content) 3)
                  (ein:$content-path content)
                (substring (ein:$content-path content)
                           0
                           (or (cl-position ?/ (ein:$content-path content) :from-end t)
                               0)))))
    (json-encode `((:type . ,(ein:$content-type content))
                   (:name . ,(ein:$content-name content))
                   (:path . ,path)
                   (:format . ,(or (ein:$content-format content) "json"))
                   (:content ,@(ein:$content-raw-content content))))))

(defun ein:content-from-notebook (nb)
  (let ((nb-content (ein:notebook-to-json nb)))
    (make-ein:$content :name (ein:$notebook-notebook-name nb)
                       :path (ein:$notebook-notebook-path nb)
                       :url-or-port (ein:$notebook-url-or-port nb)
                       :type "notebook"
                       :notebook-version (ein:$notebook-api-version nb)
                       :raw-content nb-content)))

;;; Managing/listing the content hierarchy

(defvar *ein:content-hierarchy* (make-hash-table :test #'equal)
  "Content tree keyed by URL-OR-PORT.")

(defun ein:content-need-hierarchy (url-or-port)
  "Callers assume ein:content-query-hierarchy succeeded.  If not, nil."
  (aif (gethash url-or-port *ein:content-hierarchy*) it
    (ein:log 'warn "No recorded content hierarchy for %s" url-or-port)
    nil))

(defun ein:new-content-legacy (url-or-port path data)
  "Content API in 2.x a bit inconsistent."
  (if (plist-get data :type)
      (ein:new-content url-or-port path data)
    (let ((content (make-ein:$content
                    :url-or-port url-or-port
                    :notebook-version (ein:notebook-version-numeric url-or-port)
                    :path path)))
      (setf (ein:$content-name content) (substring path (or (cl-position ?/ path) 0))
            (ein:$content-path content) path
            (ein:$content-type content) "directory"
            ;;(ein:$content-created content) (plist-get data :created)
            ;;(ein:$content-last-modified content) (plist-get data :last_modified)
            (ein:$content-format content) nil
            (ein:$content-writable content) nil
            (ein:$content-mimetype content) nil
            (ein:$content-raw-content content) (ein:fix-legacy-content-data data))
      content)))

(defun ein:new-content (url-or-port path data)
  ;; data is like (:size 72 :content nil :writable t :path Untitled7.ipynb :name Untitled7.ipynb :type notebook)
  (let ((content (make-ein:$content
                  :url-or-port url-or-port
                  :notebook-version (ein:notebook-version-numeric url-or-port)
                  :path path)))
    (setf (ein:$content-name content) (plist-get data :name)
          (ein:$content-path content) (plist-get data :path)
          (ein:$content-type content) (plist-get data :type)
          (ein:$content-created content) (plist-get data :created)
          (ein:$content-last-modified content) (plist-get data :last_modified)
          (ein:$content-format content) (plist-get data :format)
          (ein:$content-writable content) (plist-get data :writable)
          (ein:$content-mimetype content) (plist-get data :mimetype)
          (ein:$content-raw-content content) (plist-get data :content))
    content))

(defun ein:content-query-hierarchy* (url-or-port path callback sessions depth content)
  "Returns list (tree) of content objects.  CALLBACK accepts tree."
  (lexical-let* ((url-or-port url-or-port)
                 (path path)
                 (callback callback)
                 (items (ein:$content-raw-content content))
                 (directories (if (< depth ein:content-query-max-depth)
                                  (cl-loop for item in items
                                        with result
                                        until (>= (length result) ein:content-query-max-branch)
                                        if (string= "directory" (plist-get item :type))
                                        collect (ein:new-content url-or-port path item)
                                        into result
                                        end
                                        finally return result)))
                 (others (cl-loop for item in items
                               with c0
                               if (not (string= "directory" (plist-get item :type)))
                               do (setf c0 (ein:new-content url-or-port path item))
                               (setf (ein:$content-session-p c0)
                                     (gethash (ein:$content-path c0) sessions))
                               and collect c0
                               end)))
    (deferred:$
      (apply
       #'deferred:parallel
       (cl-loop for c0 in directories
             collect
             (lexical-let
                 ((c0 c0)
                  (d0 (deferred:new #'identity)))
               (ein:content-query-contents
                url-or-port
                (ein:$content-path c0)
                (apply-partially #'ein:content-query-hierarchy*
                                 url-or-port
                                 (ein:$content-path c0)
                                 (lambda (tree)
                                   (deferred:callback-post d0 (cons c0 tree)))
                                 sessions (1+ depth))
                (lambda (&rest _args) (deferred:callback-post d0 (cons c0 nil))))
               d0)))
      (deferred:nextc it
        (lambda (tree)
          (let ((result (append others tree)))
            (when (string= path "")
              (setf (gethash url-or-port *ein:content-hierarchy*) (-flatten result)))
            (funcall callback result)))))))

(defun ein:content-query-hierarchy (url-or-port callback)
  "Send for content hierarchy of URL-OR-PORT with CALLBACK arity 1 for content hierarchy"
  (ein:content-query-sessions
   url-or-port
   (apply-partially (lambda (url-or-port* callback* sessions)
                      (ein:content-query-contents url-or-port* ""
                       (apply-partially #'ein:content-query-hierarchy*
                                        url-or-port*
                                        ""
                                        callback* sessions 0)
                       (lambda (&rest ignore)
                         (when callback* (funcall callback* nil)))))
                    url-or-port callback)
   callback))

;;; Save Content

(defsubst ein:content-url (content)
  (ein:notebooklist-url (ein:$content-url-or-port content)
                        (ein:$content-path content)))

(defun ein:content-save (content &optional callback cbargs errcb errcbargs)
  (ein:query-singleton-ajax
   (ein:content-url content)
   :type "PUT"
   :headers '(("Content-Type" . "application/json"))
   :data (encode-coding-string (ein:content-to-json content) buffer-file-coding-system)
   :success (apply-partially #'ein:content-save-success callback cbargs)
   :error (apply-partially #'ein:content-save-error
                           (ein:content-url content) errcb errcbargs)))

(cl-defun ein:content-save-success (callback cbargs &key status response &allow-other-keys)
  (when callback
    (apply callback cbargs)))

(cl-defun ein:content-save-error (url errcb errcbargs &key response data &allow-other-keys)
  (ein:log 'error
    "Content save %s failed %s %s."
    url (request-response-error-thrown response) (plist-get data :message))
  (when errcb
    (apply errcb errcbargs)))

(defun ein:content-legacy-rename (content new-path callback cbargs)
  (let ((path (substring new-path 0 (or (cl-position ?/ new-path :from-end t) 0)))
        (name (substring new-path (or (cl-position ?/ new-path :from-end t) 0))))
    (ein:query-singleton-ajax
     (ein:content-url content)
     :type "PATCH"
     :data (json-encode `((name . ,name)
                          (path . ,path)))
     :parser #'ein:json-read
     :success (apply-partially #'update-content-path-legacy content callback cbargs)
     :error (apply-partially #'ein:content-rename-error new-path))))

(cl-defun update-content-path-legacy (content callback cbargs &key data &allow-other-keys)
  (setf (ein:$content-path content) (ein:trim-left (format "%s/%s" (plist-get data :path) (plist-get data :name))
                                                   "/")
        (ein:$content-name content) (plist-get data :name)
        (ein:$content-last-modified content) (plist-get data :last_modified))
  (when callback
    (apply callback cbargs)))

(defun ein:content-rename (content new-path &optional callback cbargs)
  (if (>= (ein:$content-notebook-version content) 3)
      (ein:query-singleton-ajax
       (ein:content-url content)
       :type "PATCH"
       :data (json-encode `((path . ,new-path)))
       :parser #'ein:json-read
       :success (apply-partially #'update-content-path content callback cbargs)
       :error (apply-partially #'ein:content-rename-error (ein:$content-path content)))
    (ein:content-legacy-rename content new-path callback cbargs)))

(defun ein:session-rename (url-or-port session-id new-path)
  (ein:query-singleton-ajax
   (ein:url url-or-port "api/sessions" session-id)
   :type "PATCH"
   :data (json-encode `((path . ,new-path)))
   :complete #'ein:session-rename--complete))

(cl-defun ein:session-rename--complete (&key data response symbol-status
                                      &allow-other-keys
                                      &aux (resp-string (format "STATUS: %s DATA: %s" (request-response-status-code response) data)))
  (ein:log 'debug "ein:session-rename--complete %s" resp-string))

(cl-defun update-content-path (content callback cbargs &key data &allow-other-keys)
  (setf (ein:$content-path content) (plist-get data :path)
        (ein:$content-name content) (plist-get data :name)
        (ein:$content-last-modified content) (plist-get data :last_modified))
  (when callback
    (apply callback cbargs)))

(cl-defun ein:content-rename-error (path &key response data &allow-other-keys)
  (ein:log 'error
    "Renaming content %s failed %s %s."
    path (request-response-error-thrown response) (plist-get data :message)))

;;; Sessions

(defun ein:content-query-sessions (url-or-port callback errback &optional iteration)
  "Register CALLBACK of arity 1 to retrieve the sessions.
Call ERRBACK of arity 1 (contents) upon failure."
  (declare (indent defun))
  (unless iteration
    (setq iteration 0))
  (unless callback
    (setq callback #'ignore))
  (unless errback
    (setq errback #'ignore))
  (ein:query-singleton-ajax
   (ein:url url-or-port "api/sessions")
   :type "GET"
   :parser #'ein:json-read
   :complete (apply-partially #'ein:content-query-sessions--complete url-or-port callback)
   :success (apply-partially #'ein:content-query-sessions--success url-or-port callback)
   :error (apply-partially #'ein:content-query-sessions--error url-or-port callback errback iteration)))

(cl-defun ein:content-query-sessions--success (url-or-port callback &key data &allow-other-keys)
  (cl-flet ((read-name (nb-json)
                       (if (< (ein:notebook-version-numeric url-or-port) 3)
                           (if (string= (plist-get nb-json :path) "")
                               (plist-get nb-json :name)
                             (format "%s/%s" (plist-get nb-json :path) (plist-get nb-json :name)))
                         (plist-get nb-json :path))))
    (let ((session-hash (make-hash-table :test 'equal)))
      (dolist (s data (funcall callback session-hash))
        (setf (gethash (read-name (plist-get s :notebook)) session-hash)
              (cons (plist-get s :id) (plist-get s :kernel)))))))

(cl-defun ein:content-query-sessions--error (url-or-port callback errback iteration
                                             &key response error-thrown
                                             &allow-other-keys)
  (if (< iteration (if noninteractive 6 3))
      (progn
        (ein:log 'verbose "Retry sessions #%s in response to %s" iteration (request-response-status-code response))
        (sleep-for 0 (* (1+ iteration) 500))
        (ein:content-query-sessions url-or-port callback errback (1+ iteration)))
    (ein:log 'error "ein:content-query-sessions--error %s: ERROR %s DATA %s" url-or-port (car error-thrown) (cdr error-thrown))
    (when errback (funcall errback nil))))

(cl-defun ein:content-query-sessions--complete (url-or-port callback
                                                &key data response
                                                &allow-other-keys
                                                &aux (resp-string (format "STATUS: %s DATA: %s" (request-response-status-code response) data)))
  (ein:log 'debug "ein:query-sessions--complete %s" resp-string))

;;; Uploads


(defun ein:get-local-file (path)
  "If path exists, get contents and try to guess type of file (one of file, notebook, or directory)
and content format (one of json, text, or base64)."
  (unless (file-readable-p path)
    (error "File %s is not accessible and cannot be uploaded." path))
  (let ((name (file-name-nondirectory path))
        (type (file-name-extension path)))
    (with-temp-buffer
      (insert-file-contents path)
      (cond ((string= type "ipynb")
             (list name "notebook" "json" (buffer-string)))
            ((eql buffer-file-coding-system 'no-conversion)
             (list name "file" "base64" (buffer-string)))
            (t (list name "file" "text" (buffer-string)))))))

(provide 'ein-contents-api)
