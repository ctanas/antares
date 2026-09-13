;;; antares.el --- Distraction-free writing mode  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Claudiu

;; Author: Claudiu
;; Version: 0.4.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: convenience, writing, wp
;; URL: https://github.com/ctanas/antares

;;; Commentary:

;; Antares is a distraction-free minor mode for focused writing.
;;
;; It centers the buffer body at ~80 characters (configurable), removes
;; fringes, enables soft word-wrap via `visual-line-mode', and adds a
;; small top margin so text doesn't start at the very top of the window.
;;
;; Typewriter scrolling keeps the current line vertically centered at all
;; times — as you write and lines accumulate, text scrolls upward, just
;; like paper feeding through a typewriter.
;;
;; Dimming fades every paragraph except the one point is in, keeping your
;; eye on exactly what you are writing.  Paragraphs are separated by
;; blank lines.
;;
;; Usage:
;;   M-x antares-mode         toggle in current buffer
;;   M-x global-antares-mode  toggle globally
;;
;; Customization:
;;   antares-body-width    - target text column width (default 80)
;;   antares-top-lines     - blank lines added above text (default 2)
;;   antares-typewriter    - keep current line vertically centered (default t)
;;   antares-dim-others    - fade all paragraphs except current (default t)

;;; Code:

;; Defined in face-remap.el, which is loaded whenever `text-scale-mode' is on.
(defvar text-scale-mode-step)
(defvar text-scale-mode-amount)

(defgroup antares nil
  "Distraction-free writing mode."
  :group 'convenience
  :prefix "antares-")

(defcustom antares-body-width 80
  "Target width in columns for the centered text body."
  :type 'integer
  :group 'antares)

(defcustom antares-top-lines 2
  "Number of blank lines added above the buffer content when focused."
  :type 'integer
  :group 'antares)

(defcustom antares-typewriter t
  "When non-nil, keep the current line vertically centered (typewriter scrolling).
As new lines are added the text scrolls upward, like paper through a typewriter."
  :type 'boolean
  :group 'antares)

(defcustom antares-dim-others t
  "When non-nil, fade every paragraph except the one point is in.
Paragraphs are runs of non-blank lines separated by blank lines, so in
a buffer without blank lines the whole buffer is one paragraph and
nothing is faded."
  :type 'boolean
  :group 'antares)

(defcustom antares-global-modes '(text-mode)
  "Major modes (or their derivatives) in which `global-antares-mode' activates.
Each element is checked against the current buffer with `derived-mode-p'.
Defaults to `(text-mode)' so writing-oriented buffers opt in and
special / programming buffers do not.  Set to nil to enable everywhere
except the minibuffer and internal whitespace-prefixed buffers."
  :type '(repeat symbol)
  :group 'antares)

(defcustom antares-typewriter-skip-commands
  '(scroll-left scroll-right
    recenter-top-bottom
    scroll-bar-toolkit-scroll scroll-bar-drag
    scroll-bar-scroll-up scroll-bar-scroll-down
    mouse-drag-region mouse-set-point mouse-set-region)
  "Commands that do not trigger typewriter re-centering.
Scroll bar and horizontal scroll commands are listed so the user can
scroll freely to read earlier text; mouse commands are listed so text
does not jump under the mouse while clicking; `recenter-top-bottom' is
listed so its top/middle/bottom cycling keeps working.
Commands with the `scroll-command' symbol property, such as
`mwheel-scroll', `pixel-scroll-precision' and `scroll-up-command', are
always skipped and need not be listed.
Independently of this list, re-centering only happens after commands
that move point or change the buffer text, so a scrolled view is kept
until the user resumes moving or editing."
  :type '(repeat symbol)
  :group 'antares)

;;; Faces

(defface antares-dim
  '((((class color) (min-colors 88) (background dark))  :foreground "#4a4a4a")
    (((class color) (min-colors 88) (background light)) :foreground "#c0c0c0")
    (t :inherit shadow))
  "Face applied to every paragraph except the current one in `antares-mode'."
  :group 'antares)

;;; Internal state (all buffer-local)

(defvar-local antares--active nil
  "Non-nil while the settings applied by `antares--enable' are in effect.
The body of `antares-mode' runs on every call, even when the mode is
already on (e.g. when both `text-mode-hook' and `org-mode-hook' call
it), so this flag keeps setup and teardown from running twice.")

(defvar-local antares--enabled-visual-line nil
  "Non-nil if `antares-mode' turned on `visual-line-mode' in this buffer.")

(defvar-local antares--disabled-line-numbers nil
  "Non-nil if `antares-mode' turned off `display-line-numbers-mode'.")

(defvar-local antares--stats-timer nil
  "Idle timer used to defer stats recomputation off the keystroke path.")

(defvar-local antares--stats-state nil
  "Buffer state that `antares--stats' was last computed for.
A list (CHARS-MODIFIED-TICK POINT-MIN POINT-MAX), used to skip
recounting when nothing that affects the counts has changed.")

(defvar-local antares--typewriter-state nil
  "Window, point and text state after the previous command.
A list (WINDOW POINT CHARS-MODIFIED-TICK); typewriter re-centering is
skipped after commands that leave all three unchanged.")

(defvar-local antares--dim-before nil
  "Overlay covering text before the current paragraph (dimmed).")

(defvar-local antares--dim-after nil
  "Overlay covering text after the current paragraph (dimmed).")

(defvar-local antares--stats ""
  "Mode-line string showing character and word counts.")

(defvar-local antares--target-chars nil
  "Character count goal set by `antares-target-chars', or nil for no goal.")

(defvar-local antares--target-words nil
  "Word count goal set by `antares-target-words', or nil for no goal.")

;;; Horizontal centering

(defun antares--windows ()
  "Return the live windows showing the current buffer, on all frames."
  (get-buffer-window-list (current-buffer) nil t))

(defun antares--scaled-body-width ()
  "Return `antares-body-width' adjusted for the current text scale factor.
When text is scaled up the characters are wider, so the body occupies
more frame columns; this compensates so the visible line width stays
at `antares-body-width' characters."
  (if (bound-and-true-p text-scale-mode)
      (round (* antares-body-width
                (expt text-scale-mode-step text-scale-mode-amount)))
    antares-body-width))

(defun antares--margin-for-window (win)
  "Compute the left/right margin that centers the text body in WIN.
Scroll bars and window dividers are excluded from the available width,
so the text area itself comes out `antares-body-width' columns wide."
  (let* ((char-width (frame-char-width (window-frame win)))
         (decorations (ceiling (+ (window-scroll-bar-width win)
                                  (window-right-divider-width win))
                               char-width))
         (available (- (window-total-width win) decorations)))
    (max 0 (/ (- available (antares--scaled-body-width)) 2))))

(defun antares--apply-to-window (win)
  "Center the text body in WIN and hide its fringes."
  (let ((m (antares--margin-for-window win)))
    (set-window-margins win m m))
  (set-window-fringes win 0 0))

(defun antares--restore-window (win)
  "Reset WIN's margins and fringes to the current buffer's defaults.
These are the values `set-window-buffer' installs, so this undoes
`antares--apply-to-window' without having to remember prior state."
  (set-window-margins win left-margin-width right-margin-width)
  (set-window-fringes win left-fringe-width right-fringe-width
                      fringes-outside-margins))

(defun antares--reapply ()
  "Reapply antares settings to all windows showing the current buffer."
  (when antares--active
    (dolist (win (antares--windows))
      (antares--apply-to-window win))))

(defun antares--on-size-change (win)
  "Recenter the text body in WIN after its size changed.
Buffer-local `window-size-change-functions' receive the window."
  (when antares--active
    (antares--apply-to-window win)))

;;; Top padding overlay

(defun antares--make-top-overlay ()
  "Create the top-padding overlay anchored to the real buffer start.
Widens temporarily so that toggling the mode while the buffer is
narrowed does not strand the padding in the middle of the buffer."
  (let ((ov (save-restriction
              (widen)
              (make-overlay (point-min) (point-min)))))
    (overlay-put ov 'before-string (make-string antares-top-lines ?\n))
    (overlay-put ov 'antares t)))

;;; Typewriter scrolling

(defun antares--typewriter-scroll ()
  "Center the current line in the selected window.
Does nothing when the current buffer is not the one shown in the
selected window (e.g. when toggled from a hook against an off-screen
buffer), since `recenter' would error in that case."
  (when (eq (current-buffer) (window-buffer (selected-window)))
    (recenter)))

(defun antares--maybe-typewriter-scroll ()
  "Recenter if the last command moved point or changed the text.
Commands that leave the window, point and text as they were, such as
saving or quitting, do not re-center, so a view the user scrolled to
is kept until they resume moving or editing."
  (let ((state (list (selected-window) (point) (buffer-chars-modified-tick))))
    (unless (or (equal state antares--typewriter-state)
                (use-region-p)
                (memq this-command antares-typewriter-skip-commands)
                (and (symbolp this-command)
                     (get this-command 'scroll-command)))
      (antares--typewriter-scroll))
    (setq antares--typewriter-state state)))

;;; Dimming

(defconst antares--blank-line-regexp "^[ \t\f\r]*$"
  "Regexp matching a blank line, which separates paragraphs.")

(defun antares--make-dim-overlay (beg end)
  "Create a dim overlay from BEG to END."
  (let ((ov (make-overlay beg end nil t nil)))
    (overlay-put ov 'face 'antares-dim)
    (overlay-put ov 'priority 50)
    (overlay-put ov 'antares t)
    ov))

(defun antares--place-dim-overlay (ov beg end)
  "Make dim overlay OV cover BEG to END and return it.
Creates the overlay when OV is nil.  When the range is empty, deletes
OV and returns nil.  The overlay is only moved when its bounds change,
since moving an overlay makes redisplay reconsider the text it covers."
  (cond
   ((>= beg end)
    (when ov
      (delete-overlay ov))
    nil)
   ((not ov)
    (antares--make-dim-overlay beg end))
   (t
    (unless (and (eq (overlay-buffer ov) (current-buffer))
                 (= (overlay-start ov) beg)
                 (= (overlay-end ov) end))
      (move-overlay ov beg end (current-buffer)))
    ov)))

(defun antares--paragraph-bounds ()
  "Return (START . END) of the paragraph around point.
A paragraph is a contiguous run of non-blank lines.  When point is on
a blank line, the range is empty so nothing is highlighted."
  (save-excursion
    (beginning-of-line)
    (if (looking-at-p antares--blank-line-regexp)
        (cons (point) (point))
      (let ((bol (point)))
        (cons (if (re-search-backward antares--blank-line-regexp nil t)
                  (line-beginning-position 2)
                (point-min))
              (progn
                (goto-char bol)
                (if (re-search-forward antares--blank-line-regexp nil t)
                    (match-beginning 0)
                  (point-max))))))))

(defun antares--update-dim ()
  "Reposition dim overlays around the current paragraph.
When a region is active the unshaded zone is expanded to include the
selection so that selected text is never hidden by the dim overlay."
  (let* ((bounds (antares--paragraph-bounds))
         (lo (car bounds))
         (hi (cdr bounds)))
    ;; Expand the clear zone to cover the active selection so selected
    ;; text is always readable regardless of the dim face.
    (when (use-region-p)
      (setq lo (min lo (region-beginning))
            hi (max hi (region-end))))
    (setq antares--dim-before
          (antares--place-dim-overlay antares--dim-before (point-min) lo)
          antares--dim-after
          (antares--place-dim-overlay antares--dim-after hi (point-max)))))

(defun antares--remove-dim-overlays ()
  "Delete both dim overlays."
  (when antares--dim-before
    (delete-overlay antares--dim-before)
    (setq antares--dim-before nil))
  (when antares--dim-after
    (delete-overlay antares--dim-after)
    (setq antares--dim-after nil)))

;;; Stats (character and word count)

(defun antares--stats-inputs ()
  "Return the buffer state that the character and word counts depend on."
  (list (buffer-chars-modified-tick) (point-min) (point-max)))

(defun antares--update-stats ()
  "Recompute character and word counts and refresh the mode-line string.
The mode line is only forced to redraw when the formatted string has
actually changed, to avoid extra redisplay work on every command."
  (setq antares--stats-state (antares--stats-inputs))
  (let* ((chars (- (point-max) (point-min)))
         (words (count-words (point-min) (point-max)))
         (pct   (cond
                 ((and antares--target-chars (> antares--target-chars 0))
                  (format " %d%%" (/ (* chars 100) antares--target-chars)))
                 ((and antares--target-words (> antares--target-words 0))
                  (format " %d%%" (/ (* words 100) antares--target-words)))
                 (t "")))
         (new (format "C:%d W:%d%s" chars words pct)))
    (unless (string= new antares--stats)
      (setq antares--stats new)
      (force-mode-line-update))))

(defun antares--schedule-stats ()
  "Schedule a stats recompute for when Emacs next becomes idle.
Nothing is scheduled when the counts are already up to date or a
recompute is already pending.  A pending timer need not be restarted
on each keystroke: idle time starts over with every input event, so a
burst of typing still triggers a single recompute once the user pauses."
  (unless (or (timerp antares--stats-timer)
              (equal antares--stats-state (antares--stats-inputs)))
    (setq antares--stats-timer
          (run-with-idle-timer 0.3 nil
                               #'antares--run-stats-timer
                               (current-buffer)))))

(defun antares--run-stats-timer (buf)
  "Stats timer callback for BUF.
Skips the update if BUF has been killed or has left `antares-mode'."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (setq antares--stats-timer nil)
      (when antares--active
        (condition-case err
            (antares--update-stats)
          (error (message "antares stats: %s"
                          (error-message-string err))))))))

;;;###autoload
(defun antares-target-chars (n)
  "Set a character count goal of N.
Progress toward the goal is shown as a percentage in the mode line.
Setting N to 0 clears the goal."
  (interactive "nCharacter goal (0 to clear): ")
  (setq antares--target-chars (if (> n 0) n nil)
        antares--target-words nil)
  (antares--update-stats))

;;;###autoload
(defun antares-target-words (n)
  "Set a word count goal of N.
Progress toward the goal is shown as a percentage in the mode line.
Setting N to 0 clears the goal."
  (interactive "nWord goal (0 to clear): ")
  (setq antares--target-words (if (> n 0) n nil)
        antares--target-chars nil)
  (antares--update-stats))

;;; Post-command hook (runs after every command)

(defun antares--post-command ()
  "Drive stats, dimming and typewriter scrolling after each command.
Errors are caught so that a bad state never removes this function
from `post-command-hook'."
  (when antares--active
    (condition-case err
        (progn
          (antares--schedule-stats)
          (if antares-dim-others
              (antares--update-dim)
            ;; Clear stale overlays if `antares-dim-others' was just
            ;; turned off from elsewhere.
            (antares--remove-dim-overlays))
          (when antares-typewriter
            (antares--maybe-typewriter-scroll)))
      (error (message "antares: %s" (error-message-string err))))))

;;; Enable / disable

(defun antares--turn-off ()
  "Turn off `antares-mode' in the current buffer."
  (antares-mode -1))

(defun antares--enable ()
  "Enable antares settings in the current buffer."
  (setq antares--active t)
  (dolist (win (antares--windows))
    (antares--apply-to-window win))

  ;; `visual-line-mode' sets `word-wrap' and `truncate-lines' itself and
  ;; restores them when turned off, so only the mode needs tracking.
  (unless visual-line-mode
    (visual-line-mode 1)
    (setq antares--enabled-visual-line t))

  ;; Disable line numbers if the user had them on; remember we did so.
  (when (bound-and-true-p display-line-numbers-mode)
    (display-line-numbers-mode -1)
    (setq antares--disabled-line-numbers t))

  (when (> antares-top-lines 0)
    (antares--make-top-overlay))

  ;; React to window layout / frame size / text scale changes
  (add-hook 'window-configuration-change-hook #'antares--reapply nil t)
  (add-hook 'window-size-change-functions      #'antares--on-size-change nil t)
  (add-hook 'text-scale-mode-hook              #'antares--reapply nil t)

  ;; Stats, typewriter and dimming
  (add-hook 'post-command-hook #'antares--post-command nil t)

  ;; Every major mode (and `revert-buffer') calls `kill-all-local-variables',
  ;; which resets `antares-mode' without running the mode function and
  ;; would otherwise leave the overlays and window margins behind.
  (add-hook 'change-major-mode-hook #'antares--turn-off nil t)

  ;; Initial pass
  (antares--update-stats)
  (when antares-dim-others (antares--update-dim))
  (when antares-typewriter (antares--typewriter-scroll)))

(defun antares--disable ()
  "Restore all settings changed by `antares--enable'."
  (setq antares--active nil)
  (remove-hook 'window-configuration-change-hook #'antares--reapply t)
  (remove-hook 'window-size-change-functions      #'antares--on-size-change t)
  (remove-hook 'text-scale-mode-hook              #'antares--reapply t)
  (remove-hook 'post-command-hook                 #'antares--post-command t)
  (remove-hook 'change-major-mode-hook            #'antares--turn-off t)

  ;; Cancel any pending stats refresh so it does not fire after disable.
  (when (timerp antares--stats-timer)
    (cancel-timer antares--stats-timer))
  (setq antares--stats-timer nil)

  ;; Only windows still showing this buffer need restoring; any other
  ;; window had its margins and fringes reset by `set-window-buffer'.
  (dolist (win (antares--windows))
    (antares--restore-window win))

  ;; Remove the padding and dim overlays, plus any strays left behind.
  (antares--remove-dim-overlays)
  (save-restriction
    (widen)
    (remove-overlays (point-min) (point-max) 'antares t))

  ;; Only turn off visual-line-mode if we turned it on and it is still on.
  (when (and antares--enabled-visual-line visual-line-mode)
    (visual-line-mode -1))
  (setq antares--enabled-visual-line nil)

  ;; Restore line numbers only if we disabled them and the user hasn't
  ;; turned them back on themselves in the meantime.
  (when (and antares--disabled-line-numbers
             (not (bound-and-true-p display-line-numbers-mode)))
    (display-line-numbers-mode 1))
  (setq antares--disabled-line-numbers nil)

  (setq antares--stats ""
        antares--stats-state nil
        antares--typewriter-state nil)
  (force-mode-line-update))

;;; Minor mode

;;;###autoload
(define-minor-mode antares-mode
  "Toggle distraction-free writing mode (Antares mode).

Centers the buffer at `antares-body-width' columns, hides fringes,
turns on `visual-line-mode', and optionally:
- keeps the current line vertically centered (typewriter scrolling)
- fades every paragraph except the one point is in"
  :lighter " Ant"
  :group 'antares
  ;; The body runs on every call, including (antares-mode 1) while the
  ;; mode is already on, so only act on actual state changes.
  (cond
   ((and antares-mode (not antares--active)) (antares--enable))
   ((and (not antares-mode) antares--active) (antares--disable))))

(defun antares--should-globally-enable-p ()
  "Return non-nil when `global-antares-mode' should activate in this buffer.
Skips the minibuffer and buffers whose name starts with a space (which
Emacs uses for internal/hidden buffers).  When `antares-global-modes' is
non-nil the major mode must derive from one of its entries."
  (and (not (minibufferp))
       (not (string-prefix-p " " (buffer-name)))
       (or (null antares-global-modes)
           (apply #'derived-mode-p antares-global-modes))))

;;;###autoload
(define-globalized-minor-mode global-antares-mode
  antares-mode
  (lambda ()
    (when (antares--should-globally-enable-p)
      (antares-mode 1)))
  :group 'antares)

;;; Mode-line registration

;; Register the stats entry once at load time.  The (antares-mode ...) form
;; means the entry is only displayed in buffers where antares-mode is active.
(add-to-list 'mode-line-misc-info
             '(antares-mode (" " antares--stats))
             t)  ; append so it lands after the major-mode info

(provide 'antares)
;;; antares.el ends here
