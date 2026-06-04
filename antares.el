;;; antares.el --- Distraction-free writing mode  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Claudiu

;; Author: Claudiu
;; Version: 0.3.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: convenience, writing, wp
;; URL: https://github.com/claudiu/antares

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
;; Dimming fades all lines except the one point is on, keeping your eye
;; on exactly what you are writing.
;;
;; Usage:
;;   M-x antares-mode         toggle in current buffer
;;   M-x global-antares-mode  toggle globally
;;
;; Customization:
;;   antares-body-width    - target text column width (default 80)
;;   antares-top-lines     - blank lines added above text (default 2)
;;   antares-typewriter    - keep current line vertically centered (default t)
;;   antares-dim-others    - fade all lines except current (default t)

;;; Code:

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
  "When non-nil, fade every line except the one point is on."
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
  '(mwheel-scroll
    pixel-scroll-precision-scroll
    scroll-up scroll-up-command
    scroll-down scroll-down-command
    scroll-left scroll-right)
  "Commands that do not trigger typewriter re-centering.
Mouse wheel and keyboard scroll commands are listed here by default so
the user can freely scroll to read earlier text; the view snaps back to
center only when editing resumes.
Commands with the `scroll-command' symbol property are also skipped
automatically, so most scroll commands are covered without listing them."
  :type '(repeat symbol)
  :group 'antares)

;;; Faces

(defface antares-dim
  '((((background dark))  :foreground "#4a4a4a")
    (((background light)) :foreground "#c0c0c0"))
  "Face applied to all text except the current line in `antares-mode'."
  :group 'antares)

;;; Internal state (all buffer-local)

(defvar-local antares--saved-margins nil
  "Window margins before `antares-mode' was enabled, per window.
Alist of (WINDOW . (LEFT . RIGHT)).")

(defvar-local antares--saved-fringes nil
  "Fringe widths before `antares-mode' was enabled, per window.
Alist of (WINDOW . FRINGE-LIST) where FRINGE-LIST is from `window-fringes'.")

(defvar-local antares--enabled-visual-line nil
  "Non-nil if `antares-mode' turned on `visual-line-mode' in this buffer.")

(defvar-local antares--saved-word-wrap nil
  "Saved state of `word-wrap' before `antares-mode' was enabled.
nil      — no save (mode is off);
`global' — variable had no buffer-local binding;
(local . VALUE) — variable was buffer-local with VALUE.")

(defvar-local antares--saved-truncate-lines nil
  "Saved state of `truncate-lines' before `antares-mode' was enabled.
Encoded the same way as `antares--saved-word-wrap'.")

(defvar-local antares--disabled-line-numbers nil
  "Non-nil if `antares-mode' turned off `display-line-numbers-mode'.")

(defvar-local antares--enabled-cursor-intangible nil
  "Non-nil if `antares-mode' turned on `cursor-intangible-mode'.")

(defvar-local antares--stats-timer nil
  "Idle timer used to defer stats recomputation off the keystroke path.")

(defvar-local antares--top-overlay nil
  "Overlay that inserts blank lines above buffer content.")

(defvar-local antares--dim-before nil
  "Overlay covering text before the current line (dimmed).")

(defvar-local antares--dim-after nil
  "Overlay covering text after the current line (dimmed).")

(defvar-local antares--stats ""
  "Mode-line string showing character and word counts.")

(defvar-local antares--target-chars nil
  "Character count goal set by `antares-target-chars', or nil for no goal.")

(defvar-local antares--target-words nil
  "Word count goal set by `antares-target-words', or nil for no goal.")

;;; Horizontal centering

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
  "Compute the left/right margin to center text in WIN."
  (max 0 (/ (- (window-total-width win) (antares--scaled-body-width)) 2)))

(defun antares--apply-to-window (win)
  "Apply centering and fringe settings to WIN.
Lazily saves the window's original margins and fringes the first time
WIN is seen, so windows that start showing the buffer after
`antares--enable' are still restored correctly on disable."
  (unless (assq win antares--saved-margins)
    (push (cons win (window-margins win)) antares--saved-margins))
  (unless (assq win antares--saved-fringes)
    (push (cons win (window-fringes win)) antares--saved-fringes))
  (let ((m (antares--margin-for-window win)))
    (set-window-margins win m m))
  (set-window-fringes win 0 0))

(defun antares--reapply ()
  "Reapply antares settings to all windows showing the current buffer."
  (when (bound-and-true-p antares-mode)
    (dolist (win (get-buffer-window-list (current-buffer) nil t))
      (antares--apply-to-window win))))

(defun antares--on-size-change (_frame)
  "Reapply margins when a frame is resized."
  (antares--reapply))

;;; Top padding overlay

(defun antares--make-top-overlay ()
  "Create the top-padding overlay anchored to the real buffer start.
Widens temporarily so that toggling the mode while the buffer is
narrowed does not strand the padding in the middle of the buffer."
  (let ((ov (save-restriction
              (widen)
              (make-overlay (point-min) (point-min)))))
    (overlay-put ov 'before-string
                 (propertize (make-string antares-top-lines ?\n)
                             'cursor-intangible t))
    (overlay-put ov 'antares t)
    (setq antares--top-overlay ov)))

(defun antares--remove-top-overlay ()
  "Delete the top-padding overlay."
  (when antares--top-overlay
    (delete-overlay antares--top-overlay)
    (setq antares--top-overlay nil)))

;;; Typewriter scrolling

(defun antares--typewriter-scroll ()
  "Center the current line in the selected window.
Does nothing when the current buffer is not the one shown in the
selected window (e.g. when toggled from a hook against an off-screen
buffer), since `recenter' would error in that case."
  (when (eq (current-buffer) (window-buffer (selected-window)))
    (recenter)))

;;; Dimming

(defun antares--make-dim-overlay (beg end)
  "Create a dim overlay from BEG to END."
  (let ((ov (make-overlay beg end nil t nil)))
    (overlay-put ov 'face 'antares-dim)
    (overlay-put ov 'priority 50)
    (overlay-put ov 'antares-dim t)
    ov))

(defun antares--paragraph-bounds ()
  "Return (START . END) of the paragraph around point.
A paragraph is a contiguous run of non-blank lines.  When point is on
a blank line, returns (point . point) so nothing is highlighted."
  (save-excursion
    (beginning-of-line)
    (if (looking-at "[[:space:]]*$")
        ;; On a blank line — no paragraph to highlight
        (let ((p (point))) (cons p p))
      ;; Walk up until we hit a blank line or the top of the buffer
      (while (and (not (bobp))
                  (not (looking-at "[[:space:]]*$")))
        (forward-line -1))
      (let ((lo (if (looking-at "[[:space:]]*$")
                    (progn (forward-line 1) (point))
                  (point))))
        ;; Walk down from lo until we hit a blank line or the bottom
        (goto-char lo)
        (while (and (not (eobp))
                    (not (looking-at "[[:space:]]*$")))
          (forward-line 1))
        (cons lo (point))))))

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
    ;; Region before current paragraph
    (if (<= lo (point-min))
        (when antares--dim-before
          (delete-overlay antares--dim-before)
          (setq antares--dim-before nil))
      (if antares--dim-before
          (move-overlay antares--dim-before (point-min) lo)
        (setq antares--dim-before (antares--make-dim-overlay (point-min) lo))))
    ;; Region after current paragraph
    (if (>= hi (point-max))
        (when antares--dim-after
          (delete-overlay antares--dim-after)
          (setq antares--dim-after nil))
      (if antares--dim-after
          (move-overlay antares--dim-after hi (point-max))
        (setq antares--dim-after (antares--make-dim-overlay hi (point-max)))))))

(defun antares--remove-dim-overlays ()
  "Delete both dim overlays."
  (when antares--dim-before
    (delete-overlay antares--dim-before)
    (setq antares--dim-before nil))
  (when antares--dim-after
    (delete-overlay antares--dim-after)
    (setq antares--dim-after nil)))

;;; Stats (character and word count)

(defun antares--update-stats ()
  "Recompute character and word counts and refresh the mode-line string.
The mode line is only forced to redraw when the formatted string has
actually changed, to avoid extra redisplay work on every command."
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
  "Schedule a stats recompute when Emacs next becomes idle.
Cancels any previously-queued timer so a burst of keystrokes only
triggers a single recompute once the user pauses."
  (when (timerp antares--stats-timer)
    (cancel-timer antares--stats-timer))
  (setq antares--stats-timer
        (run-with-idle-timer 0.3 nil
                             #'antares--run-stats-timer
                             (current-buffer))))

(defun antares--run-stats-timer (buf)
  "Stats timer callback for BUF.
Skips the update if BUF has been killed or has left `antares-mode'."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (setq antares--stats-timer nil)
      (when (bound-and-true-p antares-mode)
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
  "Drive typewriter scrolling and dimming after each command.
Errors are caught so that a bad state never removes this function
from `post-command-hook'."
  (when (bound-and-true-p antares-mode)
    (condition-case err
        (progn
          (antares--schedule-stats)
          (if antares-dim-others
              (antares--update-dim)
            ;; Toggle handling: clear stale overlays if the user has just
            ;; turned off `antares-dim-others' from elsewhere.
            (when (or antares--dim-before antares--dim-after)
              (antares--remove-dim-overlays)))
          (when (and antares-typewriter
                     (not (use-region-p))
                     (not (memq this-command antares-typewriter-skip-commands))
                     (not (and (symbolp this-command)
                               (get this-command 'scroll-command))))
            (antares--typewriter-scroll)))
      (error (message "antares: %s" (error-message-string err))))))

;;; Enable / disable

(defun antares--save-var (var)
  "Capture the prior state of VAR so it can be restored on disable.
Returns `global' when VAR had no buffer-local binding, or
\(local . VALUE) when it did."
  (if (local-variable-p var)
      (cons 'local (symbol-value var))
    'global))

(defun antares--enable ()
  "Enable antares settings in the current buffer."
  ;; Per-window state — apply-to-window lazily saves the original
  ;; margins/fringes the first time each window is seen, so windows
  ;; that start showing this buffer later are still restored properly.
  (setq antares--saved-margins nil
        antares--saved-fringes nil)
  (dolist (win (get-buffer-window-list (current-buffer) nil t))
    (antares--apply-to-window win))

  ;; Save prior state of the buffer-locals we are about to override.
  (setq antares--saved-word-wrap     (antares--save-var 'word-wrap)
        antares--saved-truncate-lines (antares--save-var 'truncate-lines))

  (setq-local word-wrap t)
  (setq-local truncate-lines nil)

  ;; Only enable visual-line-mode if it isn't already on, so we know
  ;; whether to turn it off again on disable.
  (unless (bound-and-true-p visual-line-mode)
    (visual-line-mode 1)
    (setq antares--enabled-visual-line t))

  ;; Disable line numbers if the user had them on; remember we did so.
  (when (and (boundp 'display-line-numbers-mode)
             (bound-and-true-p display-line-numbers-mode))
    (display-line-numbers-mode -1)
    (setq antares--disabled-line-numbers t))

  ;; Top padding overlay
  (when (> antares-top-lines 0)
    (antares--make-top-overlay)
    (unless (bound-and-true-p cursor-intangible-mode)
      (cursor-intangible-mode 1)
      (setq antares--enabled-cursor-intangible t)))

  ;; React to window layout / frame size / text scale changes
  (add-hook 'window-configuration-change-hook #'antares--reapply nil t)
  (add-hook 'window-size-change-functions      #'antares--on-size-change nil t)
  (add-hook 'text-scale-mode-hook              #'antares--reapply nil t)

  ;; Typewriter + dimming
  (add-hook 'post-command-hook #'antares--post-command nil t)

  ;; Initial pass
  (antares--update-stats)
  (when antares-dim-others   (antares--update-dim))
  (when antares-typewriter   (antares--typewriter-scroll)))

(defun antares--restore-var (var saved)
  "Restore VAR from SAVED, the value previously stored by `antares--save-var'."
  (cond
   ((eq saved 'global) (kill-local-variable var))
   ((consp saved)      (set (make-local-variable var) (cdr saved)))))

(defun antares--disable ()
  "Restore all settings changed by `antares--enable'."
  (remove-hook 'window-configuration-change-hook #'antares--reapply t)
  (remove-hook 'window-size-change-functions      #'antares--on-size-change t)
  (remove-hook 'text-scale-mode-hook              #'antares--reapply t)
  (remove-hook 'post-command-hook                 #'antares--post-command t)

  ;; Cancel any pending stats refresh so it does not fire after disable.
  (when (timerp antares--stats-timer)
    (cancel-timer antares--stats-timer)
    (setq antares--stats-timer nil))

  ;; Restore per-window margins and fringes.  Iterating the saved
  ;; alists covers every window we ever applied settings to, including
  ;; ones opened after `antares--enable' ran.
  (dolist (cell antares--saved-margins)
    (let ((win (car cell))
          (m   (cdr cell)))
      (when (window-live-p win)
        (set-window-margins win (car m) (cdr m)))))
  (dolist (cell antares--saved-fringes)
    (let ((win (car cell))
          (f   (cdr cell)))
      (when (window-live-p win)
        (set-window-fringes win (car f) (cadr f)
                            (caddr f) (cadddr f)))))
  (setq antares--saved-margins nil
        antares--saved-fringes nil)

  ;; Remove overlays.
  (antares--remove-top-overlay)
  (antares--remove-dim-overlays)

  ;; Only turn off cursor-intangible-mode if we were the ones who
  ;; turned it on, and only if it's still on (so we don't undo a user
  ;; toggle made during the session).
  (when (and antares--enabled-cursor-intangible
             (bound-and-true-p cursor-intangible-mode))
    (cursor-intangible-mode -1))
  (setq antares--enabled-cursor-intangible nil)

  ;; Restore visual-line-mode using the same "only if we changed it"
  ;; convention.
  (when (and antares--enabled-visual-line
             (bound-and-true-p visual-line-mode))
    (visual-line-mode -1))
  (setq antares--enabled-visual-line nil)

  ;; Restore word-wrap and truncate-lines to their original buffer-
  ;; local-vs-global states.
  (antares--restore-var 'word-wrap      antares--saved-word-wrap)
  (antares--restore-var 'truncate-lines antares--saved-truncate-lines)
  (setq antares--saved-word-wrap     nil
        antares--saved-truncate-lines nil)

  ;; Restore line numbers only if we disabled them and the user hasn't
  ;; turned them back on themselves in the meantime.
  (when (and antares--disabled-line-numbers
             (boundp 'display-line-numbers-mode)
             (not (bound-and-true-p display-line-numbers-mode)))
    (display-line-numbers-mode 1))
  (setq antares--disabled-line-numbers nil)

  ;; Clear stats.
  (setq antares--stats "")
  (force-mode-line-update))

;;; Minor mode

;;;###autoload
(define-minor-mode antares-mode
  "Toggle distraction-free writing mode (Antares mode).

Centers the buffer at `antares-body-width' columns, hides fringes,
enables soft word-wrap, and optionally:
- keeps the current line vertically centered (typewriter scrolling)
- fades every line except the one point is on"
  :lighter " Ant"
  :group 'antares
  (if antares-mode
      (antares--enable)
    (antares--disable)))

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
