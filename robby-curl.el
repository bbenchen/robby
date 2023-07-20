;;; robby-curl.el  --- Make robby requests via curl  -*- lexical-binding:t -*-

;;; Commentary:

(require 'cl-macs)
(require 'json)
(require 'seq)

(require 'robby-apis)
(require 'robby-logging)

;;; API key 
(defun robby-get-api-key-from-auth-source ()
  "Get api key from auth source."
  (if-let ((secret (plist-get (car (auth-source-search
                                    :host "api.openai.com"
                                    :user "apikey"
                                    :require '(:secret)))
                              :secret)))
      (if (functionp secret)
          (encode-coding-string (funcall secret) 'utf-8)
        secret)
    (user-error "No `robby-api-key' found in auth source")))

(defun robby--get-api-key ()
  "Get api key from `robby-api-key'."
  (cond
   ((stringp robby-openai-api-key) robby-openai-api-key)
   ((functionp robby-openai-api-key) (funcall robby-openai-api-key))
   (t (error "`robby-openai-api-key` not set"))))

;;; curl
(defvar robby--curl-options
  '("--compressed"
    "--disable"
    "--silent"
    "-m 600"
    "-H" "Content-Type: application/json"))

(defun robby--parse-chunk (remaining data)
  "Parse json documents in current buffer from DATA string.

Prepend REMAINING text incomplete JSON in last chunk Return
remaining incomplete text in this document.

Ignores `\"[DONE]\".

Returns a plist with remaining un-parsed text (if any) and a list
of parsed JSON objects: `(:remaining \"text\" :parsed '())'
"
  (with-temp-buffer
    (let ((new-remaining "")
          (parsed '())
          (done)
          (pos (point-min)))
      (insert remaining)
      (insert data)
      (goto-char pos)
      (while (and (not done) (not (looking-at " *\\[DONE\\]")))
        (condition-case err
            (progn
              (setq pos (point))
              (let* ((json-object-type 'alist)
                     (obj (json-read)))
                (setq parsed (cons obj parsed))))
          (error
           (setq done t)
           (setq new-remaining (buffer-substring pos (point-max))))))
      `(:remaining ,new-remaining :parsed ,(nreverse parsed)))))

(defconst robby--curl-unknown-error "Unexpected error making OpenAI request via curl" )

(defun robby--curl-parse-error (string)
  (condition-case _err
      (cdr (assoc 'message (assoc 'error (json-read-from-string string))))
    (error nil)))

(defun robby--curl-parse-response (api string remaining streamp)
  (let ((error-msg (robby--curl-parse-error string)))
    (if error-msg
        `(:error ,error-msg)
      (let* ((data (replace-regexp-in-string (rx bol "data:") "" string))
             (json (robby--parse-chunk remaining data))
             (parsed (plist-get json :parsed))
             (text (string-join (seq-filter #'stringp (seq-map (lambda (chunk) (robby--chunk-content api chunk streamp)) parsed)))))
        (setq remaining (plist-get json :remaining))
        `(:text ,text :remaining ,(plist-get json :remaining))))))

(cl-defun robby--curl (&key api payload on-text on-error streamp)
  (let* ((input-json (json-encode payload))
         (url (robby--request-url api))
         (curl-options (append robby--curl-options
                               `("-H" ,(format "Authorization: Bearer %s" (robby-get-api-key-from-auth-source))
                                 "-d" ,input-json)))
         (proc-buffer (if streamp nil (generate-new-buffer (format "*robby-curl-%s*" (buffer-name)))))
         (proc (condition-case err
                   (apply #'start-process
                          "curl"
                          proc-buffer
                          "curl"
                          url
                          curl-options)
                 (error (funcall on-error err)))))
    (let ((remaining "")
          (text ""))
      (when streamp
        (set-process-filter
         proc
         (lambda (_proc string)
           (let ((error-msg (robby--curl-parse-error string)))
             (if error-msg
                 (funcall on-error error-msg)
               (let ((resp (robby--curl-parse-response api string remaining streamp)))
                 (setq remaining (plist-get resp :remaining))
                 (funcall on-text :text (plist-get resp :text) :completep nil)))))))
      (set-process-sentinel
       proc
       (lambda (_proc _status)
         (if streamp
             (funcall on-text :text text :completep t)
           (with-current-buffer proc-buffer
             (let* ((string (buffer-string))
                    (error-msg (robby--curl-parse-error string)))
               (if error-msg
                   (funcall on-error error-msg)
                 (let ((resp (robby--curl-parse-response api string "" nil)))
                   (funcall on-text :text (plist-get resp :text) :completep t)))))))))
    proc))

(provide 'robby-curl)

;; robby-curl.el ends here
