;;; magit-auto-detach-test.el --- ERT tests for magit-auto-detach -*- lexical-binding: t; -*-

(require 'ert)
(require 'json)

;; Load the package under test
(load (expand-file-name "../magit-auto-detach.el"
                        (file-name-directory (or load-file-name buffer-file-name))))

(defvar mad-test--bin-dir
  (expand-file-name "../bin/magit-auto-detach"
                    (file-name-directory (or load-file-name buffer-file-name))))

(defun mad-test--create-repo (dir)
  "Create test repo in DIR with branches and worktrees.
Returns the repo path."
  (let ((repo (expand-file-name "repo" dir)))
    (make-directory repo t)
    (mad-test--git repo "init" "-b" "main")
    (mad-test--git repo "config" "user.email" "test@test.com")
    (mad-test--git repo "config" "user.name" "Test")
    ;; A -- main stays here
    (with-temp-file (expand-file-name "a.txt" repo) (insert "a"))
    (mad-test--git repo "add" "a.txt")
    (mad-test--git repo "commit" "-m" "A")
    ;; Detach so further commits don't advance main
    (mad-test--git repo "checkout" "--detach")
    ;; B
    (with-temp-file (expand-file-name "b.txt" repo) (insert "b"))
    (mad-test--git repo "add" "b.txt")
    (mad-test--git repo "commit" "-m" "B")
    ;; C -> feat-a
    (with-temp-file (expand-file-name "c.txt" repo) (insert "c"))
    (mad-test--git repo "add" "c.txt")
    (mad-test--git repo "commit" "-m" "C")
    (mad-test--git repo "branch" "feat-a")
    ;; D -> feat-b
    (with-temp-file (expand-file-name "d.txt" repo) (insert "d"))
    (mad-test--git repo "add" "d.txt")
    (mad-test--git repo "commit" "-m" "D")
    (mad-test--git repo "branch" "feat-b")
    ;; E -> feat-c
    (with-temp-file (expand-file-name "e.txt" repo) (insert "e"))
    (mad-test--git repo "add" "e.txt")
    (mad-test--git repo "commit" "-m" "E")
    (mad-test--git repo "branch" "feat-c")
    ;; Worktrees
    (mad-test--git repo "worktree" "add" (expand-file-name "wt-feat-a" dir) "feat-a")
    (mad-test--git repo "worktree" "add" (expand-file-name "wt-feat-b" dir) "feat-b")
    (mad-test--git repo "worktree" "add" (expand-file-name "wt-feat-c" dir) "feat-c")
    repo))

(defun mad-test--git (repo &rest args)
  "Run git in REPO with ARGS."
  (with-temp-buffer
    (let ((exit-code (apply #'call-process "git" nil t nil "-C" repo args)))
      (unless (= exit-code 0)
        (error "git %s failed: %s" (car args) (buffer-string)))
      (string-trim (buffer-string)))))

(defun mad-test--run-script (name dir &rest args)
  "Run mad script NAME with --repo DIR and extra ARGS.
Returns (exit-code stdout stderr)."
  (with-temp-buffer
    (let* ((err-file (make-temp-file "mad-test-stderr"))
           (cmd (expand-file-name name mad-test--bin-dir))
           (full-args (append args (list "--repo" dir)))
           (exit-code (apply #'call-process "ruby" nil
                             (list (current-buffer) err-file) nil
                             cmd full-args))
           (stdout (buffer-string))
           (stderr (with-temp-buffer
                     (insert-file-contents err-file)
                     (prog1 (buffer-string)
                       (delete-file err-file)))))
      (list exit-code stdout stderr))))

(defun mad-test--worktree-branch (wt-path)
  "Return branch name checked out in WT-PATH, or nil if detached."
  (with-temp-buffer
    (let ((exit-code (call-process "git" nil t nil "-C" wt-path
                                   "symbolic-ref" "--short" "HEAD")))
      (when (= exit-code 0)
        (string-trim (buffer-string))))))

;; --- Tests ---

(ert-deftest mad-test-script-detach-and-restore ()
  "Full round-trip: detach all, verify detached, restore all, verify restored."
  (let ((dir (file-truename (make-temp-file "mad-ert-" t))))
    (unwind-protect
        (let ((repo (mad-test--create-repo dir)))
          ;; Detach
          (pcase-let ((`(,code ,stdout ,_stderr)
                       (mad-test--run-script "mad-detach" repo "main" "feat-c")))
            (should (= 0 code))
            (let ((result (json-parse-string stdout :object-type 'alist)))
              (should (= 3 (length (alist-get 'detached result))))))
          ;; Verify detached
          (dolist (wt '("wt-feat-a" "wt-feat-b" "wt-feat-c"))
            (should-not (mad-test--worktree-branch (expand-file-name wt dir))))
          ;; Restore
          (pcase-let ((`(,code ,stdout ,_stderr)
                       (mad-test--run-script "mad-restore" repo)))
            (should (= 0 code))
            (let ((result (json-parse-string stdout :object-type 'alist)))
              (should (= 3 (length (alist-get 'restored result))))))
          ;; Verify restored
          (should (equal "feat-a" (mad-test--worktree-branch (expand-file-name "wt-feat-a" dir))))
          (should (equal "feat-b" (mad-test--worktree-branch (expand-file-name "wt-feat-b" dir))))
          (should (equal "feat-c" (mad-test--worktree-branch (expand-file-name "wt-feat-c" dir)))))
      (delete-directory dir t))))

(ert-deftest mad-test-detach-refuses-with-existing-state ()
  "Second detach should fail when state file exists."
  (let ((dir (file-truename (make-temp-file "mad-ert-" t))))
    (unwind-protect
        (let ((repo (mad-test--create-repo dir)))
          (mad-test--run-script "mad-detach" repo "main" "feat-c")
          (pcase-let ((`(,code ,_stdout ,stderr)
                       (mad-test--run-script "mad-detach" repo "main" "feat-c")))
            (should-not (= 0 code))
            (should (string-match-p "previous\\|already" (downcase stderr)))))
      (delete-directory dir t))))

(ert-deftest mad-test-restore-no-state ()
  "Restore with no state file should succeed with message."
  (let ((dir (file-truename (make-temp-file "mad-ert-" t))))
    (unwind-protect
        (let ((repo (mad-test--create-repo dir)))
          (pcase-let ((`(,code ,stdout ,_stderr)
                       (mad-test--run-script "mad-restore" repo)))
            (should (= 0 code))
            (should (string-match-p "nothing" (downcase stdout)))))
      (delete-directory dir t))))

(ert-deftest mad-test-elisp-run-parses-output ()
  "Verify `magit-auto-detach--run' returns structured data."
  (let ((dir (file-truename (make-temp-file "mad-ert-" t))))
    (unwind-protect
        (let* ((repo (mad-test--create-repo dir))
               (default-directory repo)
               (magit-auto-detach-bin-directory mad-test--bin-dir))
          ;; Mock magit-toplevel
          (cl-letf (((symbol-function 'magit-toplevel) (lambda () repo)))
            (pcase-let ((`(,code ,stdout ,stderr)
                         (magit-auto-detach--run "mad-detach" "main" "feat-c")))
              (should (= 0 code))
              (should (magit-auto-detach--parse-json stdout))
              (should (stringp stderr)))))
      (delete-directory dir t))))

(provide 'magit-auto-detach-test)
;;; magit-auto-detach-test.el ends here
