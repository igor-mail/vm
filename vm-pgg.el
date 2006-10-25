;;; vm-pgg.el --- PGP/MIME support for VM by pgg.el
;; 
;; Copyright (C) 2006 Robert Widhopf-Fenk
;;
;; Author:      Robert Widhopf-Fenk
;; Status:      Tested with XEmacs 21.4.19 & VM 7.19
;; Keywords:    VM helpers
;; X-URL:       http://www.robf.de/Hacking/elisp
;; Version:     $Id$

;;
;; This code is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 1, or (at your option)
;; any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program; if not, write to the Free Software
;; Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.

;;; Commentary:
;;
;; This is a replacement for mailcrypt adding PGP/MIME support to VM. 
;;
;; It requires PGG which is a standard package for XEmacs and is a part 
;; of Gnus for GNU Emacs.  On Debian "apt-get install gnus" should do the 
;; trick.
;;
;; It is still in BETA state thus you must explicitly load it by
;; 
;;      (and (locate-library "vm-pgg") (require 'vm-pgg))
;;
;; If you set `vm-auto-displayed-mime-content-types' or
;; `vm-auto-displayed-mime-content-types' make sure that
;; they contain "application/pgp-keys" or set them before
;; loading vm-pgg.  Otherwise public keys are not detected
;; automatically .
;;
;; To customize vm-pgg use: M-x customize-group RET vm-pgg RET 
;;
;; Displaying of messages in the PGP/MIME format will automatically trigger:
;;  * decrypted of encrypted MIME parts
;;  * verification of signed MIME parts 
;;  * snarfing of public keys
;;
;; The status of the current message will also be displayed in the modeline.
;;
;; To create messages according to PGP/MIME you should use:
;;  * M-x vm-pgg-encrypt       for encrypting
;;  * M-x vm-pgg-sign          for signing  
;;  * C-u M-x vm-pgg-encrypt   for encrypting + signing 
;;
;; All these commands are also available in the menu PGP/MIME which is
;; activated by the minor mode `vm-pgg-compose-mode'.  There are also
;; commands for the old style clear text format as MC had them.
;;
;; If you get annoyed by answering password prompts you might want to set the
;; variable `pgg-cache-passphrase' to t and `pgg-passphrase-cache-expiry' to a
;; higher value or nil! 
;;

;;; References:
;;
;; Code partially stems from the sources:
;; * mml2015.el (Gnus)
;; * mc-toplev.el (Mailcrypt) 
;;
;; For PGP/MIME see:
;; * http://www.faqs.org/rfcs/rfc2015.html
;; * http://www.faqs.org/rfcs/rfc3156.html
;;

;;; TODO:
;;
;; * remove ARMOR for clear text signatues 
;; * add header with verification status, or glyph to the modeline, or annotation see
;;   display-time of GNU Emacs ...    
;; * attaching of other keys from key-ring
;;

;;; Code:

;; handle missing pgg.el gracefully 
(eval-and-compile
  (if (and (boundp 'byte-compile-current-file) byte-compile-current-file)
      (condition-case nil
          (require 'pgg)
        (error (message "WARNING: Cannot load pgg.el, related functions may not work!")))
    (require 'pgg)))

(require 'easymenu)
(require 'vm-misc)

(eval-when-compile
  (require 'cl)
  (require 'vm-version)
  (require 'vm-vars)
  (require 'vm-mime)
  (require 'vm-reply)
  ;; avoid warnings 
  (defvar vm-mode-line-format)
  (defvar vm-message-pointer)
  (defvar vm-presentation-buffer)
  (defvar vm-summary-buffer))

(defgroup vm nil
  "VM"
  :group 'mail)

(defgroup vm-pgg nil
  "PGP and PGP/MIME support for VM by PGG."
  :group  'vm)

(defface vm-pgg-bad-signature
  '((((type tty) (class color))
     (:foreground "red" :bold t))
    (((type tty))
     (:bold t))
    (((background light))
     (:foreground "red" :bold t))
    (((background dark))
     (:foreground "red" :bold t:)))
  "The face used to highlight bad signature messages."
  :group 'vm-pgg
  :group 'faces)

(defface vm-pgg-good-signature
  '((((type tty) (class color))
     (:foreground "green" :bold t))
    (((type tty))
     (:bold t))
    (((background light))
     (:foreground "green4"))
    (((background dark))
     (:foreground "green")))
  "The face used to highlight good signature messages."
  :group 'vm-pgg
  :group 'faces)

(defface vm-pgg-error
  '((((type tty) (class color))
     (:foreground "red" :bold t))
    (((type tty))
     (:bold t))
    (((background light))
     (:foreground "red" :bold t))
    (((background dark))
     (:foreground "red" :bold t:)))
  "The face used to highlight error messages."
  :group 'vm-pgg
  :group 'faces)

(defcustom vm-pgg-always-replace 'never
  "*If t, decrypt mail messages in place without prompting.

If 'never, always use a viewer instead of replacing."
  :group 'vm-pgg
  :type '(choice (const never)
                 (const :tag "always" t)
                 (const :tag "ask" nil)))

(defvar vm-pgg-compose-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "\C-c#e" 'vm-pgg-encrypt-and-sign)
    (define-key map "\C-c#E" 'vm-pgg-encrypt)
    (define-key map "\C-c#s" 'vm-pgg-sign)
    (define-key map "\C-c#k" 'vm-pgg-attach-public-key)
    map))

(defvar vm-pgg-compose-mode-menu nil
  "The composition menu of vm-pgg.")

(easy-menu-define
 vm-pgg-compose-mode-menu (if (featurep 'xemacs) nil (list vm-pgg-compose-mode-map))
 "PGP/MIME compose mode menu."
 '("PGP/MIME"
   ["Encrypt"           vm-pgg-encrypt t]
   ["Sign"              vm-pgg-sign t]
   ["Encrypt+Sign"      vm-pgg-encrypt-and-sign t]
   ["Attach Public Key" vm-pgg-attach-public-key t]))

(defvar vm-pgg-compose-mode nil
  "None-nil means PGP/MIME composition mode key bindings and menu are available.")

(make-variable-buffer-local 'vm-pgg-compose-mode)

(defun vm-pgg-compose-mode (&optional arg)
  "\nMinor mode for interfacing with cryptographic functions.
\\<vm-pgg-compose-mode-map>"
  (interactive)
  (setq vm-pgg-compose-mode
	(if (null arg) (not vm-pgg-compose-mode)
	  (> (prefix-numeric-value arg) 0)))
  (if vm-pgg-compose-mode
      (easy-menu-add vm-pgg-compose-mode-menu)
    (easy-menu-remove vm-pgg-compose-mode-menu)))

(defvar vm-pgg-compose-mode-string " vm-pgg"
  "*String to put in mode line when `vm-pgg-compose-mode' is active.")


(if (not (assq 'vm-pgg-compose-mode minor-mode-map-alist))
    (setq minor-mode-map-alist
	  (cons (cons 'vm-pgg-compose-mode vm-pgg-compose-mode-map)
		minor-mode-map-alist)))

(if (not (assq 'vm-pgg-compose-mode minor-mode-alist))
    (setq minor-mode-alist
	  (cons '(vm-pgg-compose-mode vm-pgg-compose-mode-string) minor-mode-alist)))

(defun vm-pgg-compose-mode-activate ()
  "Activate `vm-pgg-compose-mode'."
  (vm-pgg-compose-mode 1))

(add-hook 'vm-mail-mode-hook 'vm-pgg-compose-mode-activate t)

(defun vm-pgg-get-emails (headers)
  "Return email addresses found in the given HEADERS."
  (let (content recipients)
    (while headers
      (setq content (vm-mail-mode-get-header-contents (car headers)))
      (when content
        (setq recipients (append (rfc822-addresses content) recipients)))
      (setq headers (cdr headers)))
    recipients))

(defvar vm-pgg-get-recipients-headers '("To:" "CC:" "BCC:")
  "The list of headers to get recipients from.")
  
(defun vm-pgg-get-recipients ()
  "Return a list of recipients."
  (vm-pgg-get-emails vm-pgg-get-recipients-headers))

(defvar vm-pgg-get-author-headers '("From:" "Sender:")
  "The list of headers to get the author from.")

(defun vm-pgg-get-author ()
  "Return the author of the message."
  (car (vm-pgg-get-emails vm-pgg-get-author-headers)))

(defun vm-pgp-prepare-composition ()
  "Prepare the composition for encrypting or signing."
  ;; encode message
  (unless (vm-mail-mode-get-header-contents "MIME-Version:")
    (vm-mime-encode-composition))
  ;; ensure newline at the end
  (goto-char (point-max))
  (skip-chars-backward " \t\r\n\f")
  (delete-region (point) (point-max))
  (insert "\n")
  ;; skip headers
  (goto-char (point-min))
  (search-forward (concat "\n" mail-header-separator "\n"))
  (goto-char (match-end 0))
  ;; guess the author 
  (make-local-variable 'pgg-default-user-id)
  (setq pgg-default-user-id (or (vm-pgg-get-author) pgg-default-user-id)))

;;; ###autoload
(defun vm-pgg-cleartext-encrypt (sign)
  "*Encrypt the composition as cleartext and with a prefix also SIGN it."
  (interactive "P")
  (save-excursion 
    (vm-pgp-prepare-composition)
    (let ((start (point)) (end   (point-max)))
      (unless (pgg-encrypt-region start end (vm-pgg-get-recipients) sign)
        (pop-to-buffer pgg-errors-buffer)
        (error "Encrypt error"))
      (delete-region start end)
      (insert-buffer-substring pgg-output-buffer))))

(defvar vm-pgg-state nil
  "State of the currently viewed message.")

(make-variable-buffer-local 'vm-pgg-state)

(defvar vm-pgg-state-message nil
  "The message for `vm-pgg-state'.")

(make-variable-buffer-local 'vm-pgg-state-message)

(defvar vm-pgg-mode-line-items
  (let ((items '((error " ERROR" vm-pgg-error)
                 (verified " verified" vm-pgg-good-signature)))
        mode-line-items
        x i s f)
    (while (and (featurep 'xemacs) items)
      (setq x (car items)
            i (car x)
            s (cadr x)
            f (caddr x)
            x (vm-make-extent 0 (length s) s))
      (vm-set-extent-property x 'face f)
      (setq items (cdr items))
      (setq mode-line-items (append mode-line-items (list (list i x s)))))
    mode-line-items)
  "An alist mapping states to modeline strings.")

(if (not (member'vm-pgg-state vm-mode-line-format))
    (setq vm-mode-line-format (append '("" vm-pgg-state) vm-mode-line-format)))

(defun vm-pgg-state-set (&rest states)
  ;; clear state for a new message
  (save-excursion
    (vm-select-folder-buffer-if-possible)
    (when (not (equal (car vm-message-pointer) vm-pgg-state-message))
      (setq vm-pgg-state-message (car vm-message-pointer))
      (setq vm-pgg-state nil)
      (when vm-presentation-buffer
        (save-excursion
          (set-buffer vm-presentation-buffer)
          (setq vm-pgg-state nil)))
      (when vm-summary-buffer
        (save-excursion
          (set-buffer vm-summary-buffer)
          (setq vm-pgg-state nil))))
    ;; add prefix
    (if (and states (not vm-pgg-state))
        (setq vm-pgg-state '("PGP:")))
    ;; add new states
    (let (s)
      (while states
        (setq s (car states)
              vm-pgg-state (append vm-pgg-state
                                   (list (or (cdr (assoc s vm-pgg-mode-line-items))
                                             (format " %s" s))))
              states (cdr states))))
    ;; propagate state
    (setq states vm-pgg-state)
    (when vm-presentation-buffer
      (save-excursion
        (set-buffer vm-presentation-buffer)
        (setq vm-pgg-state states)))
    (when vm-summary-buffer
      (save-excursion
        (set-buffer vm-summary-buffer)
        (setq vm-pgg-state states)))))
                         
(defun vm-pgg-cleartext-automode ()
  (let ((current-window (selected-window)))
    (select-window (minibuffer-window))
    (enlarge-window (- 1 (window-height (minibuffer-window))))
    (select-window current-window))
  (save-excursion 
    (vm-select-folder-buffer)
    (if vm-presentation-buffer
	(set-buffer vm-presentation-buffer))
    (goto-char (point-min))
    (search-forward "\n\n")
    (if (looking-at "^-----BEGIN PGP \\(SIGNED \\)?MESSAGE-----$")
	(condition-case e
	    (cond ((string= (match-string 1) "SIGNED ")
		   (vm-pgg-cleartext-verify))
		  (t
		   (vm-pgg-cleartext-decrypt)))
	  (error (message "%S" e)))
      (let ((window (get-buffer-window pgg-output-buffer)))
	(when window
	  (delete-window window))))))

(defadvice vm-preview-current-message (after vm-pgg-cleartext-automode activate)
  "Decode or check signature on clear text messages."
  (when (not (eq vm-system-state 'previewing))
    (vm-pgg-state-set)
    (vm-pgg-cleartext-automode)))

(defadvice vm-scroll-forward (around vm-pgg-cleartext-automode activate)
  "Decode or check signature on clear text messages."
  (let ((vm-system-state-was vm-system-state))
    ad-do-it
    (when (eq vm-system-state-was 'previewing)
      (vm-pgg-state-set)
      (vm-pgg-cleartext-automode))))

;;; ###autoload
(defun vm-pgg-cleartext-sign ()
  "*Sign the message."
  (interactive)
  (save-excursion 
    (vm-pgp-prepare-composition)
    (let ((start (point)) (end (point-max)))
      (unless (pgg-sign-region start end t)
        (pop-to-buffer pgg-errors-buffer)
        (error "Signing error"))
      (delete-region start end)
      (insert-buffer-substring pgg-output-buffer))))

;;; ###autoload
(defun vm-pgg-cleartext-verify ()
  "*Verify the signature in the current message."
  (interactive)
  (let ((current-window (selected-window)))
    (select-window (minibuffer-window))
    (enlarge-window (- 1 (window-height (minibuffer-window))))
    (select-window current-window))
  (let ((status))
    (if (interactive-p)
        (vm-follow-summary-cursor))
    (vm-select-folder-buffer)
    (vm-check-for-killed-summary)
    (vm-error-if-folder-empty)
    ;; ensure we are in the right buffer
    (if vm-presentation-buffer
        (set-buffer vm-presentation-buffer))
    ;; skip headers 
    (goto-char (point-min))
    (search-forward "\n\n")
    (goto-char (match-end 0))
    ;; verify 
    (unless (pgg-verify-region (point) (point-max))
      (save-excursion
        (set-buffer pgg-errors-buffer)
        (if (re-search-forward "\\(BADSIG\\|NO_PUBKEY\\)[^\n\r]+" (point-max) t)
            (progn
              (setq status (downcase (match-string 0)))
              (vm-pgg-state-set (intern status))
              (message status))
          (vm-pgg-state-set 'error)
          (pop-to-buffer pgg-errors-buffer)
          (error "Verification failed"))))
    (vm-pgg-state-set 'signed)
    (let (lines height)
      (save-excursion
        (set-buffer pgg-output-buffer)
        (skip-chars-backward " \t\t\n\f")
        (beginning-of-line)
        (message (buffer-substring (point-min) (point-max)))
        (setq lines (count-lines (point-min) (point-max))))
      (setq height (window-height (minibuffer-window)))
      (if (< height lines)
	  (let ((current-window (selected-window)))
	    (select-window (minibuffer-window))
	    (enlarge-window (- lines height))
	    (select-window current-window))))
    (vm-pgg-state-set 'verified)))

;;; ###autoload
(defun vm-pgg-cleartext-decrypt ()
  "*Decrypt the contents of the current message."
  (interactive)
  (let ((vm-frame-per-edit nil))
    (if (interactive-p)
	(vm-follow-summary-cursor))
    (vm-select-folder-buffer)
    (vm-check-for-killed-summary)
    (vm-error-if-folder-read-only)
    (vm-error-if-folder-empty)
    
    ;; skip headers 
    (goto-char (point-min))
    (search-forward "\n\n")
    (goto-char (match-end 0))
    
    ;; decrypt 
    (unless (pgg-decrypt-region (point) (point-max))
      (vm-pgg-state-set 'error)
      (pop-to-buffer pgg-errors-buffer)
      (error "Decryption failed"))

    (vm-pgg-state-set 'encrypted)
    
    ;; make a presentation copy 
    (vm-make-presentation-copy (car vm-message-pointer))
    (vm-save-buffer-excursion
     (vm-replace-buffer-in-windows (current-buffer)
                                   vm-presentation-buffer))
    (set-buffer vm-presentation-buffer)

    (let ((buffer-read-only nil))
      ;; remove From line 
      (goto-char (point-min))
      (forward-line 1)
      (delete-region (point-min) (point))
      ;; insert decrypted message 
      (search-forward "\n\n")
      (goto-char (match-end 0))
      (delete-region (point) (point-max))
      (insert-buffer-substring pgg-output-buffer)
      ;; do cleanup 
      (vm-pgg-crlf-cleanup (point-min) (point-max))
      (goto-char (point-min))
      (vm-reorder-message-headers nil vm-visible-headers
                                  vm-invisible-header-regexp)
      (vm-decode-mime-message-headers (car vm-message-pointer))
      (vm-energize-urls-in-message-region)
      (vm-highlight-headers-maybe)
      (vm-energize-headers-and-xfaces)
      ;; care for a signature 
      (goto-char (point-min))
      (search-forward "\n\n")
      (goto-char (match-end 0))
      (if (looking-at "^-----BEGIN PGP \\(SIGNED \\)?MESSAGE-----$")
          (vm-pgg-cleartext-verify))
      ;; replace the message?
      (when (and (not (eq vm-pgg-always-replace 'never))
                 (or vm-pgg-always-replace
                     (y-or-n-p "Replace encrypted message with decrypted? ")))
        (vm-edit-message)
        (delete-region (point-min) (point-max))
        (insert-buffer-substring vm-presentation-buffer)
        (let ((this-command 'vm-edit-message-end))
          (vm-edit-message-end))))))

(defun vm-pgg-crlf-cleanup (start end)
  "Convert CRLF to LF in region from START to END."
  (save-excursion
    (goto-char start)
    (while (search-forward "\r\n" end t)
      (replace-match "\n" t t))))

(defun vm-pgg-make-crlf (start end)
  "Convert CRLF to LF in region from START to END."
  (save-excursion
    (goto-char start)
    (while (search-forward "\n" end t)
      (replace-match "\r\n" t t))))

;;; ###autoload
(defun vm-mime-display-internal-multipart/encrypted (layout)
  "Display multipart/encrypted LAYOUT."
  (vm-pgg-state-set 'encrypted)
  (let* ((part-list (vm-mm-layout-parts layout))
         (header (car part-list))
         (message (car (cdr part-list)))
         status)
    (if (not (and (= (length part-list) 2)
                  (vm-mime-types-match (car (vm-mm-layout-type header))
                                       "application/pgp-encrypted")
                  ;; TODO: check version and protocol here?
                  (vm-mime-types-match (car (vm-mm-layout-type message))
                                       "application/octet-stream")))
        (insert "Unknown multipart/encrypted format.")
      ;; decode the message now
      (save-excursion
        (set-buffer (vm-buffer-of (vm-mm-layout-message message)))
        (save-restriction
          (widen)
          (setq status (pgg-decrypt-region (vm-mm-layout-body-start message)
                                           (vm-mm-layout-body-end message)))))
      (if (not status)
          (let ((start (point)))
            (vm-pgg-state-set 'error)
            (insert-buffer-substring pgg-errors-buffer)
            (put-text-property start (point) 'face 'vm-pgg-error))
        (save-excursion
          (set-buffer pgg-output-buffer)
          (vm-pgg-crlf-cleanup (point-min) (point-max))
          (setq message (vm-mime-parse-entity-safe nil nil nil t)))
        (if message
          (vm-decode-mime-layout message)
          (insert-buffer-substring pgg-output-buffer))
        (setq status (save-excursion
                       (set-buffer pgg-errors-buffer)
                       (goto-char (point-min))
                       ;; TODO: care for BADSIG
                       (when (re-search-forward "GOODSIG [^\n\r]+" (point-max) t)
                         (vm-pgg-state-set 'signed 'verified)
                         (buffer-substring (match-beginning 0) (match-end 0)))))
        (if status
            (let ((start (point)))
              (insert "\n" status "\n")
              (put-text-property start (point) 'face 'vm-pgg-good-signature))))
      t)))

;;; ###autoload
(defun vm-mime-display-internal-multipart/signed (layout)
  "Display multipart/signed LAYOUT."
  (vm-pgg-state-set 'signed)
  (let* ((part-list (vm-mm-layout-parts layout))
         (message (car part-list))
         (signature (car (cdr part-list)))
         status signature-file start end)
    (if (not (and (= (length part-list) 2)
                  ;; TODO: check version and protocol here?
                  (vm-mime-types-match (car (vm-mm-layout-type signature))
                                       "application/pgp-signature")))
        (insert "Unknown multipart/signed format.")
      ;; insert the message 
      (vm-decode-mime-layout message)
      ;; write signature to a temp file
      (setq start (point))
      (vm-mime-insert-mime-body signature)
      (setq end (point))
      (write-region start end
                    (setq signature-file (make-temp-file "vm-pgg-signature")))
      (delete-region start end)
      (setq start (point))
      (vm-insert-region-from-buffer (marker-buffer (vm-mm-layout-header-start message))
                                    (vm-mm-layout-header-start message)
                                    (vm-mm-layout-body-end message))
      ;; according to the RFC 3156 we need to skip trailing white space and
      ;; end with a  CRLF!
      (skip-chars-backward " \t\r\n\f" start)
      (insert "\n")
      (setq end (point-marker))
      (vm-pgg-make-crlf start end)
      (setq status (pgg-verify-region start end signature-file))
      (delete-file signature-file)
      (delete-region start end)
      ;; now insert the content
      (insert "\n")
      (let ((start (point)) end)
        (if (not status)
            (progn
              (vm-pgg-state-set 'error)
              (insert-buffer-substring pgg-errors-buffer))
          (vm-pgg-state-set 'verified)
          (insert-buffer-substring pgg-output-buffer)
          (vm-pgg-crlf-cleanup start (point)))
        (setq end (point))
        (put-text-property start end 'face
                           (if status 'vm-pgg-good-signature 'vm-pgg-bad-signature)))
      t)))

;; we must add these in order to force VM to call our handler
(if (listp vm-auto-displayed-mime-content-types)
    (add-to-list 'vm-auto-displayed-mime-content-types "application/pgp-keys"))

(if (listp vm-mime-internal-content-types)
    (add-to-list 'vm-mime-internal-content-types "application/pgp-keys"))

;;; ###autoload
(defun vm-mime-display-internal-application/pgp-keys (layout)
  "Snarf keys in LAYOUT and display result of snarfing."
  (vm-pgg-state-set 'public-key)
  ;; insert the keys
  (let ((start (point)) end status)
    (vm-mime-insert-mime-body layout)
    (setq end (point-marker))
    (vm-mime-transfer-decode-region layout start end)
    (save-excursion
      (setq status (pgg-snarf-keys-region start end)))
    (delete-region start end)
    ;; now insert the result of snafing 
    (if status
        (insert-buffer-substring pgg-output-buffer)
      (insert-buffer-substring pgg-errors-buffer))
    t))

;;; ###autoload
(defun vm-pgg-snarf-keys ()
  "*Snarf keys from the current message."
  (interactive)
  (if (interactive-p)
      (vm-follow-summary-cursor))
  (vm-select-folder-buffer)
  (vm-check-for-killed-summary)
  (vm-error-if-folder-empty)
  (save-restriction
    ;; ensure we are in the right buffer
    (if vm-presentation-buffer
        (set-buffer vm-presentation-buffer))
    ;; skip headers 
    (goto-char (point-min))
    (search-forward "\n\n")
    (goto-char (match-end 0))
    ;; verify 
    (unless (pgg-snarf-keys)
      (error "Snarfing failed"))
    (save-excursion
      (set-buffer pgg-output-buffer)
      (message (buffer-substring (point-min) (point-max))))))

;;; ###autoload
(defun vm-pgg-attach-public-key ()
  "Attach your public key to a composition."
  (interactive)
  (let* ((pgg-default-user-id (or (vm-pgg-get-author) pgg-default-user-id))
         (description (concat "public key of " pgg-default-user-id))
         (buffer (get-buffer-create (concat " *" description "*")))
         start)
    (save-excursion
      (set-buffer buffer)
      (erase-buffer)
      (setq start (point))
      (pgg-insert-key)
      (if (= start (point))
          (error "%s has no public key!" pgg-default-user-id)))
    (save-excursion
      (goto-char (point-max))
      (insert "\n")
      (setq start (point))
      (vm-mime-attach-object buffer
                             "application/pgp-keys"
                             (list (concat "name=\"" pgg-default-user-id ".asc\""))
                             description
                             nil)
      ;; a crude hack to set the disposition
      (let ((disposition (list "attachment"
                               (concat "filename=\"" pgg-default-user-id ".asc\"")))
            (end (point)))
        (if (featurep 'xemacs)
            (set-extent-property (extent-at start nil 'vm-mime-disposition)
                                 'vm-mime-disposition disposition)
          (put-text-property start end 'vm-mime-disposition disposition))))))

(defun vm-pgg-make-multipart-boundary (word)
  "Creates a mime part boundery. 

We cannot use `vm-mime-make-multipart-boundary' as it uses the current time as
seed and thus creates the same boundery when called twice in a short period."
  (if word (setq word (concat word "+")))
  (let ((boundary (concat word (make-string 15 ?a)))
	(i (length word)))
    (random)
    (while (< i (length boundary))
      (aset boundary i (aref vm-mime-base64-alphabet
			     (% (vm-abs (lsh (random) -8))
				(length vm-mime-base64-alphabet))))
      (vm-increment i))
    boundary))

;;; ###autoload
(defun vm-pgg-sign ()
  "Sign the composition with PGP/MIME."
  (interactive)
  (unless (vm-mail-mode-get-header-contents "MIME-Version:")
    (vm-mime-encode-composition))
  (let ((content-type (vm-mail-mode-get-header-contents "Content-Type:"))
        (encoding (vm-mail-mode-get-header-contents "Content-Transfer-Encoding:"))
        (boundary (vm-pgg-make-multipart-boundary "pgp+signed"))
        (micalg "sha1")
        entry
        body-start)
    ;; fix the body
    (goto-char (point-min))
    (search-forward (concat "\n" mail-header-separator "\n"))
    (goto-char (match-end 0))
    (setq body-start (point-marker))
    (insert "Content-Type:" (or content-type "text/plain") "\n")
    (insert "Content-Transfer-Encoding:" (or encoding "7bit") "\n")
    (if (not (looking-at "\n"))
        (insert "\n"))
    ;; now create the signature
    (save-excursion 
      (vm-pgp-prepare-composition)
      (unless (pgg-sign-region (point) (point-max) nil)
        (pop-to-buffer pgg-errors-buffer)
        (error "Signing error"))
      (and (setq entry (assq 2 (pgg-parse-armor
                                (with-current-buffer pgg-output-buffer
                                  (buffer-string)))))
           (setq entry (assq 'hash-algorithm (cdr entry)))
           (if (cdr entry)
               (setq micalg (downcase (format "%s" (cdr entry)))))))
    ;; insert mime part bounderies
    (goto-char body-start)
    (insert "--" boundary "\n")
    (goto-char (point-max))
    (insert "--" boundary "\n")
    ;; insert the signature
    (insert "Content-Type: application/pgp-signature\n\n")
    (goto-char (point-max))
    (insert-buffer-substring pgg-output-buffer)
    (insert "--" boundary "--\n")
    ;; fix the headers 
    (vm-mail-mode-remove-header "MIME-Version:")
    (vm-mail-mode-remove-header "Content-Type:")
    (vm-mail-mode-remove-header "Content-Transfer-Encoding:")
    (mail-position-on-field "MIME-Version")
    (insert "1.0")
    (mail-position-on-field "Content-Type")
    (insert "multipart/signed;\n"
            "\tboundary=\"" boundary "\";\n"
            "\tmicalg=pgg-\"" micalg "\";\n"
            "\tprotocol=\"application/pgp-signature\"")))
    
;;; ###autoload
(defun vm-pgg-encrypt (sign)
  "Encrypt the composition as PGP/MIME. With a prefix arg SIGN also sign it."
  (interactive "P")
  (unless (vm-mail-mode-get-header-contents "MIME-Version:")
    (vm-mime-encode-composition))
  (let ((content-type (vm-mail-mode-get-header-contents "Content-Type:"))
        (encoding (vm-mail-mode-get-header-contents "Content-Transfer-Encoding:"))
        (boundary (vm-pgg-make-multipart-boundary "pgp+encrypted"))
        body-start)
    ;; fix the body
    (goto-char (point-min))
    (search-forward (concat "\n" mail-header-separator "\n"))
    (goto-char (match-end 0))
    (setq body-start (point-marker))
    (insert "Content-Type: " (or content-type "text/plain") "\n")
    (insert "Content-Transfer-Encoding: " (or encoding "7bit") "\n")
    (insert "\n")
    (goto-char (point-max))
    (insert "\n")
    (vm-pgg-cleartext-encrypt sign)
    (goto-char body-start)
    (insert "--" boundary "\n")
    (insert "Content-Type: application/pgp-encrypted\n\n")
    (insert "Version: 1\n\n")
    (insert "--" boundary "\n")
    (insert "Content-Type: application/octet-stream\n\n")
    (goto-char (point-max))
    (insert "--" boundary "--\n")
    ;; fix the headers 
    (vm-mail-mode-remove-header "MIME-Version:")
    (vm-mail-mode-remove-header "Content-Type:")
    (vm-mail-mode-remove-header "Content-Transfer-Encoding:")
    (mail-position-on-field "MIME-Version")
    (insert "1.0")
    (mail-position-on-field "Content-Type")
    (insert "multipart/encrypted; boundary=\"" boundary "\";\n"
            "\tprotocol=\"application/pgp-encrypted\"")))

(defun vm-pgg-encrypt-and-sign ()
  "*Encrypt and sign the composition as PGP/MIME."
  (interactive)
  (vm-pgg-encrypt t))

(provide 'vm-pgg)

;;; vm-pgg.el ends here
