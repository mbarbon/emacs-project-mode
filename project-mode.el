;;; project-mode.el
;;
;; Author: Benjamin Cluff
;; Created: 02-Feb-2010
;;
;; Synopsis:
;;   * Finding files is greatly simplified (see key bindings)
;;   * TAGS files for project files.
;;

(require 'cl)
(require 'levenshtein)

(defgroup project-mode nil
  "Project mode allows users to do fuzzy and regex searches on
   file names and text within a defined set of directories and
   files that make up the project.  Multiple projects can be
   loaded at the same time and the user can switch back and forth
   between them."
  :prefix "project-"
  :group 'programming)

(defcustom project-search-exclusion-regexes-default '("\\.svn" "\\.jar$" "\\.class$" "\\.exe$" "\\.png$"
                                                      "\\.gif$" "\\.jpg$" "\\.jpeg$" "\\.ico$" "\\.log$"
                                                      "\\.rtf$" "\\.bin$" "\\.tar$" "\\.tgz$" "\\.gz$"
                                                      "\\.bz2$" "\\.zip$" "\\.rar$" "\\.cab$" "\\.msi$"
                                                      "\\.o$" "\\.a$" "\\.dll$" "\\.pdf$" "\\.tmp$"
                                                      "\\bTAGS\\b")
  "File paths that match these regexes will be excluded from any type of search"
  :group 'project)

(defcustom project-fuzzy-match-tolerance-default 50
  "Precentage. The higher the more tolerant fuzzy matches will be."
  :group 'project)

;; TODO: This feature isn't fully tested, but does seem to work currently.
(defcustom project-tags-form-default nil
  "Used to create tags. Useful for when extending project mode.
The form must be like the following:
'(\".groovy\"
  ('elisp \"regex1\"
          \"regex2\") ; generate tags using elisp
  \".clj\"
  ('etags \"-r 'etags regex argument'\"
          \"-R 'etags regex exclusion'\") ; generate tags using etags
  \".c\"
  ('etags)) ; generate using etags language auto-detect
"
  :group 'project)

(defcustom project-extension-for-saving ".proj"
  "Appended to the file name of saved projects."
  :group 'project)

(defcustom project-proj-files-dir "~/.emacs.d"
  "Where project files are saved."
  :group 'project)

(define-minor-mode project-mode
  "Toggle project mode.
   With no argument, this command toggles the mode.
   Non-null prefix argument turns on the mode.
   Null prefix argument turns off the mode."
  ;; The initial value.
  :init-value nil
  ;; The indicator for the mode line.
  :lighter " Project"
  ;; This mode is best as a global minor mode
  :global t
  ;; The minor mode bindings.
  ;; NOTE: C-c[<control-char>  and C-c[[ are reserved for modes that extend project-mode.
  :keymap
  '(;; Commands on projects start with:............. 'p'
    ("\C-c[pn" . project-new)
    ("\C-c[pc" . project-choose)
    ("\C-c[pa" . project-show-current-name)
    ("\C-c[ppcv" . project-view-path-cache)
    ("\C-c[pspv" . project-view-search-paths)
    ("\C-c[pspa" . project-add-search-path)
    ;; Commands for saving start with:.............. 's'
    ("\C-c[ss" . project-save)
    ("\C-c[sa" . project-save-all)
    ;; Commands for loading start with:............. 'l'
    ("\C-c[ll" . project-load-and-select)
    ("\C-c[la" . project-load-all)
    ;; Commands for refreshing start with:.......... 'r'
    ("\C-c[rr" . project-refresh)
    ("\C-c[rp" . project-path-cache-refresh)
    ("\C-c[rt" . project-tags-refresh)
    ;; Commands for searching/finding start with:... 'f'
    ("\C-c[fs" . project-search-filesystem-interactive)
    ("\C-c[ff" . project-search-fuzzy-interactive)
    ("\C-c[fr" . project-search-regex-interactive)
    ("\C-c[ft" . project-search-text)
    ("\C-c[fn" . project-search-text-next)
    ("\C-c[fp" . project-search-text-previous)
    ("\C-c[flf" . project-im-feeling-lucky-fuzzy)
    ("\C-c[flr" . project-im-feeling-lucky-regex)
    ;; Commands for doing something at point:....... 't'
    ("\C-c[tm" . project-open-match-on-line)
    ("\C-c[to" . project-open-file-on-line))
  :group 'project)

;;;###autoload

(defvar *project-current* nil
  "For project-mode. The project name string of the currently active project.
   You should almost always use the `PROJECT-CURRENT' function instead if this.")

(defvar *project-list* nil
  "For project-mode. List of projects. Projects are symbols that are uninterned and their plists contain project specific data.")

(defvar project-windows-or-msdos-p (or (string-match "^windows.*" (symbol-name system-type))
                                       (string-match "^ms-dos.*" (symbol-name system-type)))
  "Predicate indicating if this `SYSTEM-TYPE' is windows for the purpose of using the correct directory separator.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Interactive commands

(defun project-new (project-name search-path)
  (interactive "MNew Project Name: 
DAdd a search directory to project: ")
  (when (project-find project-name)
    (error "A project by that name already exists. Project not created."))
  (let ((project (project-create project-name)))
    (project-select project)
    (project-search-paths-add project search-path)
    (project-refresh)))

(defun project-choose (&optional project-name)
  (interactive)
  (if (not project-name)
      (let ((listified-project-list (mapcar (lambda (x) (list x)) *project-list*)))
        (let ((choice (completing-read "Select project: " listified-project-list nil nil nil)))
          (project-select choice)))
    (project-select project-name)))

(defun project-load-and-select (project-name)
  (interactive "MLoad project by name: ")
  (project-load project-name)
  (project-choose project-name))

(defun project-load-all nil
  (interactive)
  (dolist (file (directory-files project-proj-files-dir))
    (when (string-match (concat project-extension-for-saving "$") file)
      (project-load-file (project-append-to-path project-proj-files-dir file))))
  (message "Done loading all projects"))

(defun project-show-current-name nil
  (interactive)
  (if (project-current)
      (message (concat "Current project: " (project-current-name)))
    (message "No project is currently selected.")))

(defun project-save nil
  (interactive)
  (project-ensure-current)
  (message (concat "Saving project '" (project-current-name) "'"))
  (project-write (project-current)))

(defun project-save-all nil
  (interactive)
  (dolist (project *project-list*)
    (project-write project))
  (message "Done saving all projects."))

(defun project-view-search-paths nil
  (interactive)
  (project-ensure-current)
  (let ((buf (generate-new-buffer (concat "*" (project-current-name) "-search-paths-dump*"))))
    (pop-to-buffer buf)
    (pp (project-search-paths-get (project-current)))
    (dolist (file (project-search-paths-get (project-current)))
      (insert file "\n"))))

(defun project-search-paths-clear nil
  (interactive)
  (project-ensure-current)
  (project-search-paths-set (project-current) nil))

(defun project-add-search-path (dir)
  (interactive "DAdd a search directory to project: ")
  (project-ensure-current)
  (project-search-paths-add (project-current) dir))

(defun project-im-feeling-lucky-fuzzy (file-name)
  (interactive "MI'm-feeling-lucky FUZZY search: ")
  (project-ensure-current)
  (let ((best-match (car (project-search-fuzzy (project-current) file-name))))
    (when best-match
      (find-file best-match))))

(defun project-im-feeling-lucky-regex (regex)
  (interactive "MI'm-feeling-lucky REGEX search: ")
  (project-ensure-current)
  (let ((best-match (car (project-search-regex (project-current) regex))))
    (when best-match
      (find-file best-match))))

(defun project-search-filesystem-interactive (file-name-regex)
  (interactive "MFile system REGEX search: ")
  (project-ensure-current)
  (let ((matches (project-search-filesystem (project-current) file-name-regex)))
    (when matches
      (let ((choice (completing-read "Choose: " matches nil nil nil)))
        (when choice
          (find-file choice))))))

(defun project-search-fuzzy-interactive (name)
  (interactive "MFind file FUZZY: ")
  (project-ensure-current)
  (let ((matches (project-search-fuzzy (project-current) name)))
    (if matches
        (if (= 1 (length matches))
            (find-file (car matches))
          (progn
            (setq matches (mapcar (lambda (x) (list x)) matches))
            (let ((choice (completing-read "Choose: " matches nil nil nil)))
              (when choice
                (find-file choice)))))
      (message "No reasonable matches found."))))

(defun project-search-regex-interactive (regex)
  (interactive "MFind file REGEX: ")
  (project-ensure-current)
  (let ((matches (project-search-regex (project-current) regex)))
    (when matches
      (if (> (length matches) 1)
          (progn
            (setq matches (mapcar (lambda (x) (list x)) matches))
            (let ((choice (completing-read "Choose: " matches nil nil nil)))
              (when choice
                (find-file choice))))
        (find-file (car matches))))))

(defun project-search-text (regex)
  (interactive "MFull-text REGEX: ")
  (project-ensure-current)
  (let ((matches nil))
    (dolist (path (project-path-cache-get (project-current)))
      (project-run-regex-on-file path regex
                                 (lambda (p)
                                   (setq matches
                                         (append matches (list (list path p)))))))
    (when matches
      (let ((buf (generate-new-buffer (concat "*" (project-current-name) "-regex-full-text-search-results*"))))
        (project-full-text-search-results-buffer-set (project-current) buf)
        (pop-to-buffer buf)
        (dolist (match matches)
          (insert (concat "\n" (first match)
                          ":" (number-to-string (second match)))))
        (beginning-of-buffer)))))

(defun project-search-text-next nil
  (interactive)
  (project-ensure-current)
  (let ((buf (project-full-text-search-results-buffer-get (project-current))))
    (when buf
      (set-buffer buf)
      (forward-line)
      (push-mark (point) t t)
      (end-of-line)
      (project-open-file-for-match-selection)))
  nil)

(defun project-search-text-previous nil
  (interactive)
  (project-ensure-current)
  (let ((buf (project-full-text-search-results-buffer-get (project-current))))
    (when buf
      (set-buffer buf)
      (forward-line -1)
      (push-mark (point) t t)
      (end-of-line)
      (project-open-file-for-match-selection)))
  nil)

(defun project-open-file-for-match-selection nil
  (interactive)
  (let ((match-line (buffer-substring-no-properties (region-beginning) (region-end))))
    (when (string-match ":[0-9]+$" match-line)
      (let ((file (substring match-line 0 (string-match ":[0-9]+$" match-line)))
            (p (substring match-line (string-match "[0-9]+$" match-line))))
        (when file
          (find-file file)
          (when p
            (goto-char (string-to-number p))))))))

(defun project-open-match-on-line nil
  (interactive)
  (beginning-of-line)
  (push-mark (point) t t)
  (end-of-line)
  (project-open-file-for-match-selection))

(defun project-open-file-on-line nil
  (interactive)
  (beginning-of-line)
  (push-mark (point) t t)
  (end-of-line)
  (let ((file-path (buffer-substring-no-properties (region-beginning) (region-end))))
    (when file-path
      (find-file file-path))))    

(defun project-view-path-cache nil
  (interactive)
  (project-ensure-current)
  (let ((cache (project-path-cache-get (project-current)))
        (buf (generate-new-buffer (concat "*" (project-current-name)
                                          "-path-cache-dump*"))))
    (pop-to-buffer buf)
    (dolist (item cache)
      (goto-char (point-max))
      (insert (concat "\n" item)))))

(defun project-path-cache-refresh nil
  (interactive)
  (project-ensure-current)
  (project-path-cache-create (project-current)))

(defun project-tags-refresh nil
  (interactive)
  (project-ensure-current)
  (message "Refreshing tags...")
  (project-write-tags (project-path-cache-get (project-current))
                      (project-tags-file (project-current))
                      nil
                      (project-tags-form-get (project-current)))
  (when (file-exists-p (project-tags-file (project-current)))
    (visit-tags-table (project-tags-file (project-current))))
  (message "Done refreshing tags."))

(defun project-refresh nil
  (interactive)
  (project-ensure-current)
  (project-path-cache-refresh)
  (when (not (project-disable-auto-tags-get (project-current)))
    (project-tags-refresh))
  (message (concat "Done refreshing project '" (project-current-name) "'")))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Non-interactive functions

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Projects non-interactive functions (for managing multiple projects)

;;; Tags
(defun project-write-tags (path-cache tags-file append-p tags-form)
  (when (not (evenp (length tags-form)))
    (error "Invalid `TAGS-FORM' parameter"))
  (when (and (not append-p)
             (file-exists-p tags-file))
    (with-temp-buffer
      (write-file tags-file)))
  (dolist (file path-cache)
    (let ((tags-form tags-form))
      (while (and (stringp file)
                  (first tags-form)
                  (second tags-form))
        (let ((path-regex (first tags-form))
              (regexes (second tags-form)))
          (setq tags-form (cddr tags-form)) ;; move ahead 2
          (when (string-match path-regex file)
            (let ((tag-gen-method (car regexes))
                  (regexes (if (stringp (car regexes))
                               regexes
                             (cdr regexes))))
              (if (equal 'etags tag-gen-method)
                  (project-write-tags-for-file-with-etags file tags-file t regexes)
                (project-write-tags-for-file-with-elisp file tags-file t regexes)))))))))

(defun project-write-tags-for-file-with-elisp (input-file tags-file append-p regexes)
  (let ((tags (project-generate-tags-for-file-with-elisp input-file regexes)))
    (when tags
      (let ((data (mapconcat (lambda (x) x) tags "\n")))
        (with-temp-buffer
          (insert "\n"
                  input-file "," (number-to-string (length data)) "\n"
                  data "\n")
          (write-region (point-min) (point-max) tags-file append-p))))))

(defun project-generate-tags-for-file-with-elisp (file regexes)
  "Generates a list of tag file entry lines for one file for the given regexes."
  (let (ret-val)
    (with-temp-buffer
      (insert-file-contents file)
      (let (entries)
        (dolist (regex regexes)
          (goto-char (point-min))
          (while (re-search-forward regex nil t)
            (let (byte-offset line match)
              (setq match (match-string 0))
              (setq byte-offset (- (point) (length match)))
              (setq line (line-number-at-pos))
              (setq entries (append entries (list (concat match ""
                                                          (number-to-string line) ","
                                                          (number-to-string byte-offset))))))))
        entries))))

(defun project-write-tags-for-file-with-etags (input-file tags-file append-p &optional regex-args)
  (let ((cmd-string (combine-and-quote-strings (list ("etags" (when append-p "-a")
                                                      "-o" tags-file
                                                      regex-args)))))
    (call-process-shell-command cmd-string)))

(defun project-tags-file (project)
  (project-append-to-path (project-search-paths-get-default project) "TAGS"))

(defun project-tags-form-get (project)
  (or (get project 'tags-form)
      project-tags-form-default))

(defun project-tags-form-set (project value)
  (put project 'tags-form value))

(defun project-disable-auto-tags-get (project)
  (get project 'disable-auto-tags))

(defun project-disable-auto-tags-set (project value)
  "Project-mode can automatically handle the generation of tags
   files from the files listed in the path-cache if
   `TAGS-FORM' is populated correctly."
  (put project 'disable-auto-tags value))

(defun project-enable-auto-tags-for-other-file-types-get (project)
  (get project 'enable-auto-tags-for-other-file-types))

(defun project-enable-auto-tags-for-other-file-types-set (project value)
  "Generate tags for file types found in path-cache and that have
   not already been processed using `TAGS-FORM'."
  (put project 'enable-auto-tags-for-other-file-types value))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Other

(defun project-load (project-name)
  (message (concat "Loading project from file: " (project-file project-name)))
  (project-load-file (project-file project-name))
  (message (concat "Done loading project from file: " (project-file project-name))))

(defun project-load-file (project-file)
  (with-temp-buffer
    (insert-file-contents project-file)
    (goto-char (point-min))
    (eval (read (current-buffer)))))

(defun project-file (project)
  (let ((project (if (symbolp project)
                     (project-name project)
                   project)))
    (project-append-to-path project-proj-files-dir
                            (concat project project-extension-for-saving))))

(defun project-write (project)
  (let ((data (project-as-data project)))
    (when data
      (with-temp-buffer
        (insert (pp-to-string data))
        (write-file (project-file project))))))

(defun project-as-data (project)
  `(progn
     (let ((project (project-create ,(project-name project))))
       (project-search-paths-set              project  ',(project-search-paths-get              project))
       (project-tags-form-set                 project  ',(project-tags-form-get                 project))
       (project-search-exclusion-regexes-set  project  ',(project-search-exclusion-regexes-get  project))
       (project-fuzzy-match-tolerance-set     project  ,(project-fuzzy-match-tolerance-get      project)))))

(defun project-search-exclusion-regexes-get (project)
  (or (get project 'search-exclusion-regexes)
      project-search-exclusion-regexes-default))

(defun project-search-exclusion-regexes-set (project value)
  (put project 'search-exclusion-regexes value))

(defun project-fuzzy-match-tolerance-get (project)
  (or (get project 'fuzzy-match-tolerance)
      project-fuzzy-match-tolerance-default))

(defun project-fuzzy-match-tolerance-set (project value)
  (put project 'fuzzy-match-tolerance value))

(defun project-ensure-current nil
  (when (not (project-current))
    (error "No project selected.")))

(defun project-ensure-path-cache (project)
  (let ((paths (project-path-cache-get project)))
    (when (not paths)
      (project-path-cache-create project))))

(defun project-run-regex-on-file (file regex match-handler)
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (let ((p nil))
      (while (condition-case nil
                 (setq p (re-search-forward regex))
               (error nil))
        (funcall match-handler p)))))

(defun project-find (project)
  "If project found return it, else nil.
  `PROJECT' can be a string or symbol."
  (when (stringp project)
    (setq project (make-symbol project)))
  (let ((projects *project-list*))
    (while (and (car projects)
                (not (project-equal (car projects) project)))
      (setq projects (cdr projects)))
    (when (project-equal (car projects) project)
      (car projects))))

(defun project-select (project)
  (let ((project (project-find project)))
    (if project
        (progn
          (setq *project-current* project)
          (let ((new-default-path (project-search-paths-get-default project)))
            (when new-default-path
              (cd new-default-path)
              (when (and (project-search-paths-get project)
                         (not (project-path-cache-get project)))
                (project-path-cache-create project))
              (let ((tags-file (project-tags-file project)))
                (when (file-exists-p tags-file)
                  (visit-tags-table tags-file))))))
      (message "That project doesn't exist."))))

(defun project-current nil
  (project-find *project-current*))

(defun project-current-name nil
  (let ((p (project-find (project-current))))
    (when p
      (project-name p))))

(defun project-name (project)
  (symbol-name project))

(defun project-create (project-name)
  "Creates a new project and adds it to the list"
  (let ((project (project-find (make-symbol project-name))))
    (when (not project)
      (setq project (make-symbol project-name))
      (setq *project-list* (append *project-list* (list project))))
    project))

(defun project-equal (project-sym1 project-sym2)
  (equal (project-name project-sym1) (project-name project-sym2)))

(defun project-properties-set (project new-plist)
  (setplist project new-plist))

(defun project-properties-get (project)
  (symbol-plist project))

(defun project-path-cache-create (project)
  (let ((matches nil))
    (message "Creating project path-cache...")
    (dolist (path (project-search-paths-get project))
      (project-filesystem-traverse :query nil
                                   :looking-at path
                                   :test (lambda (a b) t) ; always return t
                                   :match-handler
                                   (lambda (test-result file-path)
                                     (let ((regexes (append (project-search-exclusion-regexes-get project)))
                                           (add-p t))
                                       (while (and (car regexes)
                                                   add-p)
                                         (when (string-match (car regexes) file-path)
                                           (setq add-p nil))
                                         (setq regexes (cdr regexes)))
                                       (if add-p
                                           (setq matches (append matches (list file-path)))
                                         (setq add-p nil))))))
    (message (concat "Done creating project path-cache. Cached "
                     (number-to-string (length matches)) " file paths."))
    (project-path-cache-set project matches)))

(defun project-path-cache-set (project paths-list)
  (put project 'path-cache paths-list))

(defun project-path-cache-get (project)
  (get project 'path-cache))

(defun project-search-paths-set (project paths-list)
  (when (not (listp paths-list))
    (error "`PROJECT-SEARCH-PATHS-SET' accepts only a LIST."))
  (put project 'search-paths paths-list))

(defun project-search-paths-get (project)
  (get project 'search-paths))

(defun project-search-paths-get-default (project)
  (car (get project 'search-paths)))

(defun project-search-paths-add (project &rest new-paths)
  (when (stringp new-paths)
    (setq new-paths (list (project-fix-dir-separators-in-path-if-windows new-paths))))
  (put project 'search-paths (append (get project 'search-paths) new-paths)))

(defun* project-path-cache-traverse (&key (project nil)
                                          (name nil)
                                          (test nil)
                                          (match-handler nil))
  (project-ensure-path-cache project)
  (dolist (path (project-path-cache-get project))
    (let* ((file-path (project-path-file-name path))
           (test-results (funcall test name file-path)))
      (when test-results
        (funcall match-handler test-results path)))))

(defun project-search-filesystem (project file-name-regex)
  (let (matches)
    (dolist (dir (project-search-paths-get project))
      (project-filesystem-traverse :query file-name-regex
                                   :looking-at dir
                                   :test (lambda (query x) (string-match query x))
                                   :match-handler
                                   (lambda (test-result file-path)
                                     (setq matches (append matches (list file-path))))))
    matches))

(defun project-search-fuzzy (project file-name &optional tolerance)
  (when (not tolerance)
    (setq tolerance (project-fuzzy-match-tolerance-get project)))
  (let ((matches nil))
    (project-path-cache-traverse :project project
                                 :name file-name
                                 :test 'project-fuzzy-distance-pct-for-files
                                 :match-handler
                                 (lambda (test-result file-path)
                                   (when (<= test-result tolerance)
                                     (setq matches (append matches (list file-path))))))
    (sort matches (lambda (a b)
                    (when (< (project-fuzzy-distance-pct-for-files a file-name)
                             (project-fuzzy-distance-pct-for-files b file-name))
                      t)))))

(defun* project-search-regex (project regex)
  (let ((matches nil))
    (project-path-cache-traverse :project project
                                 :name regex
                                 :test (lambda (regex x) (string-match regex x))
                                 :match-handler
                                 (lambda (test-result file-path)
                                   (setq matches (append matches (list file-path)))))
    (sort matches (lambda (a b)
                    (let ((a-pos (string-match regex a))
                          (b-pos (string-match regex b)))
                      (if (and a-pos
                               b-pos)
                          (if (= a-pos b-pos) ; when earliest match is a tie take the shortest string
                              (<= (length a)
                                  (length b))
                            (<= a-pos
                                b-pos))
                        (if a
                            t
                          nil)))))))

(defun project-full-text-search-results-buffer-get (project)
  (get (project-current) 'project-full-text-search-results-buffer))


(defun project-full-text-search-results-buffer-set (project buf)
  (put (project-current) 'project-full-text-search-results-buffer buf))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Functions that have no knowledge of the concept of projects

(defun* project-fuzzy-distance-pct-for-files (file1 file2 &optional (ignore-ext t))
  (if ignore-ext
      (project-fuzzy-distance-pct (project-file-strip-extension file1)
                                  (project-file-strip-extension file2))
    (project-fuzzy-distance-pct file1 file2)))

(defun project-strip-assumed-file-extensions (file)
  (project-strip-file-extensions file project-assumed-file-extensions))

(defun* project-filesystem-traverse (&key (query nil)
                                          (looking-at nil)
                                          (parent-dir nil)
                                          (test nil)
                                          (match-handler nil))
  (when  (and looking-at
              (> (length looking-at) 0)
              (not (string-equal "." looking-at))
              (not (string-equal ".." looking-at)))
    (let ((file-path (project-append-to-path parent-dir looking-at)))
      (if (file-directory-p file-path)
          ;; Handle directory
          (dolist (file (directory-files file-path))
            (project-filesystem-traverse :query query :looking-at file :parent-dir file-path
                                         :test test :match-handler match-handler))
        ;; Handle file
        (when (and test match-handler)
          (let ((test-results (funcall test query looking-at)))
            (when test-results
              (funcall match-handler test-results file-path))))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Utility functions. Function independently.

(defun project-remove-trailing-dirsep (dir-path)
  (when dir-path
    (substring dir-path 0 (string-match "[\\\\/]*$" dir-path))))

(defun project-path-file-name (path)
  (replace-regexp-in-string ".*[\\\\/]+" "" path))

(defun project-append-to-path (dir-path str-or-list)
  (if (stringp str-or-list)
      (if (and dir-path str-or-list)
          (concat (project-remove-trailing-dirsep dir-path) "/" str-or-list)
        (if dir-path
            (project-remove-trailing-dirsep dir-path)
          (if str-or-list
              (project-remove-trailing-dirsep str-or-list))))
    (when (listp str-or-list)
      (let ((retVal dir-path))
        (dolist (x str-or-list)
          (setq retVal (project-append-to-path retVal x)))
        retVal))))

(defun project-fix-dir-separators-in-path-if-windows (path)
  (when project-windows-or-msdos-p
    (replace-regexp-in-string "\\\\" "/" path)))

(defun project-fuzzy-distance-pct (str1 str2)
  (let ((distance (levenshtein-distance str1 str2)))
    (/ (* distance 100)
       (length (if (< (length str1) (length str2))
                   str1
                 str2)))))

(defun project-strip-file-extensions (file-path extensions-regex-list)
  (let ((new-file-path file-path))
    (while (and (car extensions-regex-list)
                (string-equal file-path new-file-path))
      (setq new-file-path (replace-regexp-in-string (car extensions-regex-list)
                                                    "" file-path))
      (setq extensions-regex-list (cdr extensions-regex-list)))
    new-file-path))


(defun project-file-strip-extension (file-path)
  (if (string-match "[^^]\\.[^.]+$" file-path)
      (substring file-path 0 (string-match "\\.[^.]+$" file-path))
    file-path))


(defun project-file-get-extension (file-path)
  (when (string-match "[^^]\\.[^.]+$" file-path)
    (substring file-path (string-match "\\.[^.]+$" file-path))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Menu

(defun project-display-menu nil
  (define-key-after
    global-map
    [menu-bar projmenu]
    (cons "Project" (make-sparse-keymap))
    'tools)

  ;; Searching
  (define-key
    global-map
    [menu-bar projmenu projsrch]
    (cons "Search" (make-sparse-keymap)))

  (define-key
    global-map
    [menu-bar projmenu projsrch lckyreg]
    '("I'm feeling lucky regex" . project-im-feeling-lucky-regex))

  (define-key
    global-map
    [menu-bar projmenu projsrch lckyfuz]
    '("I'm feeling lucky fuzzy" . project-im-feeling-lucky-fuzzy))

  (define-key
    global-map
    [menu-bar projmenu projsrch mtchonl]
    '("Open match at point" . project-open-match-on-line))

  (define-key
    global-map
    [menu-bar projmenu projsrch srchtpm]
    '("Full-Text Prev Match" . project-search-text-previous))

  (define-key
    global-map
    [menu-bar projmenu projsrch srchtnm]
    '("Full-Text Next Match" . project-search-text-next))

  (define-key
    global-map
    [menu-bar projmenu projsrch srchregexft]
    '("Regex Full-Text" . project-search-text))

  (define-key
    global-map
    [menu-bar projmenu projsrch srchregexfn]
    '("Regex File Name" . project-search-regex-interactive))

  (define-key
    global-map
    [menu-bar projmenu projsrch srchfuz]
    '("Fuzzy File Name" . project-search-fuzzy-interactive))
 
  (define-key
    global-map
    [menu-bar projmenu projsrch srchfs]
    '("Regex File Name (filesystem)" . project-search-filesystem-interactive))
  ;; Refresh
  (define-key
    global-map
    [menu-bar projmenu projref]
    (cons "Refresh" (make-sparse-keymap)))

  (define-key
    global-map
    [menu-bar projmenu projref projtref]
    '("Refresh Tags" . project-tags-refresh))
  
  (define-key
    global-map
    [menu-bar projmenu projref projpcref]
    '("Refresh Path Cache" . project-path-cache-refresh))

  (define-key
    global-map
    [menu-bar projmenu projref projrefall]
    '("Refresh All" . project-refresh))

  ;; Save & Load
  (define-key
    global-map
    [menu-bar projmenu projsvld]
    (cons "Save or Load" (make-sparse-keymap)))

  (define-key
    global-map
    [menu-bar projmenu projsvld projloadall]
    '("Load All" . project-load-all))
  
  (define-key
    global-map
    [menu-bar projmenu  projsvld projload]
    '("Load" . project-load-and-select))

  (define-key
    global-map
    [menu-bar projmenu  projsvld projsaveall]
    '("Save All" . project-save-all))

  (define-key
    global-map
    [menu-bar projmenu projsvld projsave]
    '("Save" . project-save))
  
  ;; Project info
  (define-key
    global-map
    [menu-bar projmenu curproj]
    (cons "Current" (make-sparse-keymap)))

  (define-key
    global-map
    [menu-bar projmenu curproj pvcp]
    '("View Path Cache" . project-view-path-cache))

  (define-key
    global-map
    [menu-bar projmenu curproj pasp]
    '("Add Search Path" . project-add-search-path))

  (define-key
    global-map
    [menu-bar projmenu curproj pvsp]
    '("View Search Paths" . project-view-search-paths))

  (define-key
    global-map
    [menu-bar projmenu curproj pscn]
    '("View Name" . project-show-current-name))

  ;; Top
  (define-key
    global-map
    [menu-bar projmenu pc]
    '("Choose" . project-choose))
  (define-key
    global-map
    [menu-bar projmenu pn]
    '("New" . project-new))
  nil)

(defun project-remove-menu nil
  (global-unset-key [menu-bar projmenu]))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(provide 'project-mode)
