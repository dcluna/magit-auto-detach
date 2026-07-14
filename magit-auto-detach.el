;;; magit-auto-detach.el --- Auto-detach/restore worktrees for branch stack rebases -*- lexical-binding: t; -*-

;;; Commentary:
;; Detaches git worktrees checked out on branches within a ref range
;; so you can rebase a branch stack with --update-refs, then restores them.

;;; Code:

(require 'magit)
(require 'json)

(defgroup magit-auto-detach nil
  "Auto-detach and restore git worktrees for rebasing branch stacks."
  :group 'magit)

(defcustom magit-auto-detach-bin-directory
  (expand-file-name "bin/magit-auto-detach"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Directory containing mad-* Ruby scripts."
  :type 'directory
  :group 'magit-auto-detach)

(defun magit-auto-detach--script (name)
  "Return full path to script NAME."
  (expand-file-name name magit-auto-detach-bin-directory))

(defun magit-auto-detach--run (script &rest args)
  "Run SCRIPT with ARGS, return (exit-code stdout stderr)."
  (let ((cmd (magit-auto-detach--script script))
        (repo (magit-toplevel)))
    (unless repo
      (user-error "Not in a git repository"))
    (with-temp-buffer
      (let* ((err-file (make-temp-file "mad-stderr"))
             (full-args (append (list cmd) args (list "--repo" repo)))
             (exit-code (apply #'call-process "ruby" nil
                               (list (current-buffer) err-file) nil
                               full-args))
             (stdout (buffer-string))
             (stderr (with-temp-buffer
                       (insert-file-contents err-file)
                       (prog1 (buffer-string)
                         (delete-file err-file)))))
        (list exit-code stdout stderr)))))

(defun magit-auto-detach--parse-json (str)
  "Parse JSON string STR, return nil on empty/invalid input."
  (when (and str (not (string-empty-p (string-trim str))))
    (json-parse-string str :object-type 'alist)))

;;;###autoload
(defun magit-auto-detach-detach (base-ref tip-ref)
  "Detach worktrees for branches in BASE-REF..TIP-REF range.
Uses `magit-read-branch-or-commit' for ref selection."
  (interactive
   (list (magit-read-branch-or-commit "Base ref (ancestor)")
         (magit-completing-read "Tip ref"
                              (magit-list-refnames nil t)
                              nil 'any nil 'magit-revision-history
                              (magit-get-current-branch))))
  (pcase-let ((`(,code ,stdout ,stderr) (magit-auto-detach--run "mad-detach" base-ref tip-ref)))
    (cond
     ((= code 0)
      (let* ((result (magit-auto-detach--parse-json stdout))
             (detached (alist-get 'detached result))
             (count (length detached)))
        (if (= count 0)
            (message "No worktrees to detach in %s..%s" base-ref tip-ref)
          (message "Detached %d worktree(s) in %s..%s" count base-ref tip-ref))
        (magit-refresh)))
     ((= code 1)
      (user-error "Detach failed (rollback succeeded): %s" (string-trim stderr)))
     ((= code 2)
      (user-error "Detach failed (rollback ALSO failed): %s" (string-trim stderr)))
     (t
      (user-error "mad-detach exited %d: %s" code (string-trim stderr))))))

;;;###autoload
(defun magit-auto-detach-restore ()
  "Restore previously detached worktrees to their original branches."
  (interactive)
  (pcase-let ((`(,code ,stdout ,stderr) (magit-auto-detach--run "mad-restore")))
    (cond
     ((= code 0)
      (let* ((result (magit-auto-detach--parse-json stdout))
             (msg (alist-get 'message result))
             (restored (alist-get 'restored result)))
        (if msg
            (message "%s" msg)
          (message "Restored %d worktree(s)" (length restored)))
        (magit-refresh)))
     ((= code 1)
      (let* ((result (magit-auto-detach--parse-json stdout))
             (restored (length (alist-get 'restored result)))
             (failures (length (alist-get 'failures result))))
        (user-error "Partial restore: %d restored, %d failed. See mad-restore output. %s"
                    restored failures (string-trim stderr))))
     (t
      (user-error "mad-restore exited %d: %s" code (string-trim stderr))))))

;;;###autoload
(defun magit-auto-detach-status ()
  "Show status of currently detached worktrees."
  (interactive)
  (let* ((repo (or (magit-toplevel)
                   (user-error "Not in a git repository")))
         (common-dir (string-trim
                      (shell-command-to-string
                       (format "git -C %s rev-parse --git-common-dir"
                               (shell-quote-argument repo)))))
         (state-file (expand-file-name "magit-auto-detach.json" common-dir)))
    (if (not (file-exists-p state-file))
        (message "No active detach session")
      (let* ((data (json-parse-string
                    (with-temp-buffer
                      (insert-file-contents state-file)
                      (buffer-string))
                    :object-type 'alist))
             (entries (alist-get 'entries data))
             (base (alist-get 'base_ref data))
             (tip (alist-get 'tip_ref data)))
        (message "Detach session: %s..%s (%d worktree(s))\n%s"
                 base tip (length entries)
                 (mapconcat (lambda (e)
                              (format "  %s → %s"
                                      (alist-get 'worktree e)
                                      (alist-get 'branch e)))
                            entries "\n"))))))

;; Magit transient integration
(with-eval-after-load 'magit
  (ignore-errors
    (transient-append-suffix 'magit-worktree "m"
      '("d" "Detach for rebase" magit-auto-detach-detach))
    (transient-append-suffix 'magit-worktree "d"
      '("r" "Restore detached" magit-auto-detach-restore))
    (transient-append-suffix 'magit-worktree "r"
      '("s" "Detach status" magit-auto-detach-status))))

(provide 'magit-auto-detach)
;;; magit-auto-detach.el ends here
