;;;; zimuzu/accu.lisp
;;;; Collect subtitle corpus from zimuzu.tv.

(in-package #:breakds.corpus-accu)

(defvar *zimuzu-max-new-pages* 1600)

(defvar *workspace* "/home/breakds/tmp/zimuzu/")

(defvar *zimuzu-catalog* nil)

(defparameter *zimuzu-root* "http://www.zimuzu.tv/")

(defvar *zimuzu-sleep-interval* 10)

;;; ---------- Catalog ----------

(def-struct-wrapper crawl-zimuzu-url
  ("body .middle-box .subtitle-box .area-left .subtitle-con .subtitle-links h3 a"
   :url (lambda (node) (get-attribute node "href"))))

(def-struct-wrapper crawl-item
    ("dl dt strong a" 
     :name (lambda (node) 
             (get-attribute node "title")))
    ("dl dt strong a"
     :url (lambda (node)
            (let ((sub-uri (format nil "~a~a"
                                   *zimuzu-root*
                                   (get-attribute node "href"))))
              (getf (crawl-zimuzu-url (html-from-uri sub-uri))
                    :url))))
    ("dl dd span:1" 
     :language (lambda (node)
                 (handler-case 
                     (split-sequence:split-sequence 
                      #\/
                      (subseq (get-content node) 4))
                   (t () nil))))
    ("dl dd span:2" 
     :format (lambda (node)
               (handler-case
                   (split-sequence:split-sequence
                    #\/
                    (subseq (get-content node) 4))
                 (t () nil)))))

(def-list-wrapper crawl-items
    "body .middle-box .subtitle-box .area-left .subtitle-list ul li"
  (lambda (node)
    (let ((item (crawl-item node)))
      (format t "Item: ~a ~a - format ~a~%" 
              (getf item :name)
              (getf item :language)
              (getf item :format))
      item)))

(def-path zimuzu-log (&optional (workspace *workspace*))
  (merge-pathnames "log.txt" workspace))

(def-path zimuzu-catalog (&optional (workspace *workspace*))
  (merge-pathnames "catalog.lisp" workspace))

(defun load-catalog (&optional (workspace *workspace*))
  (setf *zimuzu-catalog* nil)
  (when (probe-file (zimuzu-catalog-path))
    (with-open-file (input (zimuzu-catalog-path)
                           :direction :input)
      (setf *zimuzu-catalog* (read input))))
  *zimuzu-catalog*)

(defun subtitle-page-uri (index)
  (format nil "~aesubtitle?page=~a"
	  *zimuzu-root* index))

(defun build-catalog (&optional (workspace *workspace*))
  (setf *zimuzu-catalog* nil)
  
  ;; Parsing
  (with-open-file (log (zimuzu-log-path)
                       :direction :output
                       :if-exists :supersede)
    (loop for page-index from 1 below *zimuzu-max-new-pages*
       do (let ((items (handler-case 
                           (crawl-items (html-from-uri (subtitle-page-uri page-index)))
                         (t () (format log "[WARNING] Failed to parse page ~a~%"
                                       page-index)
                            nil))))
            (loop for item in items 
               do (push item *zimuzu-catalog*))
            (format t "~a collected so far." (length *zimuzu-catalog*))
            (format t "Sleeping for ~a sec so that we are not jamming the server.~%"
                    *zimuzu-sleep-interval*)
            (sleep *zimuzu-sleep-interval*))))

  ;; Write catalog to disk
  (with-open-file (output (zimuzu-catalog-path)
                          :direction :output
                          :if-exists :supersede)
    (write *zimuzu-catalog* :stream output))
  (format t "Saved to ~a.~%" (zimuzu-catalog-path)))


;;; ---------- Download file and Parse ----------

(def-path zimuzu-url-to-file (url &optional (parent *workspace*))
  (merge-pathnames (format nil "~a.~a" (pathname-name url) (pathname-type url))
		   parent))

(def-path zimuzu-process-log (&optional (parent *workspace*))
  (merge-pathnames "process.log" parent))

(def-path zimuzu-result (&optional (parent *workspace*))
  (merge-pathnames "result/" parent))

(defun download-file (url &optional (workspace *workspace*))
  (let ((source-stream (drakma:http-request url :want-stream t)))
    (with-open-file (output (zimuzu-url-to-file-path url workspace)
			    :direction :output
			    :if-exists :supersede
			    :element-type '(unsigned-byte 8))
      (unwind-protect 
	   (loop for byte = (read-byte source-stream nil nil)
	      while byte
	      do (write-byte byte output))
	(close source-stream)))))

(defun get-signature (url)
  (let ((md5-sequence (md5:md5sum-string url)))
    (format nil "~{~x~}"
            (loop for integer across md5-sequence
               append (list (ash integer -4) (logand integer 15))))))

(defun try-correct-encoding (input-file output-file)
  ;; Prepare an empty working file.
  (with-open-file (output output-file
                          :direction :output
                          :if-exists :supersede)
    nil)
  (sb-ext:run-program 
   (format nil "~a" 
           (merge-pathnames "bin/try_correct_encoding.sh"
                            (asdf:system-source-directory 'corpus-accu)))
   (list (format nil "~a" input-file)
         (format nil "~a" output-file))
   :wait t))

(defun process-catalog-item (item &optional (log-stream t))
  (unless (getf item :url)
    (format log-stream "[ERROR] UNKNOWN: empty url.~%")
    (return-from process-catalog-item nil))
  (let* ((sig (get-signature (getf item :url)))
         (compression-type (pathname-type (getf item :url)))
         (workspace (merge-pathnames (format nil "~a/" sig) 
                                     *workspace*))
         (package-path (zimuzu-url-to-file-path (getf item :url)
                                                workspace)))
    ;; Download the package
    (handler-case
        (download-file (getf item :url) workspace)
      (t () 
        (format log-stream "[ERROR] ~a: failed to download ~a.~%"
                sig (getf item :url))
        (return-from process-catalog-item nil)))

    ;; Decompression
    (cond ((string-equal compression-type "rar")
           (sb-ext:run-program "/usr/bin/unrar" 
                               (list "x"  ;; extraction
                                     (format nil "~a" package-path)
                                     (format nil "~a" workspace))
                               :wait t))
          ((string-equal compression-type "zip")
           (sb-ext:run-program "/usr/bin/unzip" 
                               (list (format nil "~a" package-path)
                                     "-d"
                                     (format nil "~a" workspace))
                               :wait t))
          (t (format log-stream "[WARNING] ~a: no compression detected.~%"
                     sig)))
    ;; Detect usable files
    (let (success candidates secondary-candidates)
      (handler-case
          (fad:walk-directory workspace
                              (lambda (file-name)
                                (let ((name (pathname-name file-name)))
                                  (if (or (ppcre:scan "[C|c][H|h][S|s]" name)
                                          (ppcre:scan "简体" name)
                                          (and (ppcre:scan "中文" name)
                                               (not (ppcre:scan "繁体"))))
                                      (push file-name candidates)
                                      (push file-name secondary-candidates))))
                              :test #`,(member (pathname-type x1)
                                               '("srt" "ass" "ssa")
                                               :test #'string-equal))
        (t () (format log-stream "[ERROR] Failed to walk the directory.")))
      (if (and (null candidates) (null secondary-candidates))
          (format log-stream "[ERROR] ~a: no simplified chinese candidates.~%" sig)
          (loop 
             for candidate in (append candidates secondary-candidates)
             until success
             do (let ((source-file (merge-pathnames "source.txt" workspace))
                      (result-file (merge-pathnames (format nil "~a.txt" sig)
                                                    (zimuzu-result-path))))
                  (try-correct-encoding candidate source-file)
                  (when (> (cond ((string-equal (pathname-type candidate) "srt")
                                  (subtitle-parser:extract-chinese-corpus-from-srt
                                   source-file result-file log-stream))
                                 ((member (pathname-type candidate) '("ass" "ssa")
                                          :test #'string-equal)
                                  (subtitle-parser:extract-chinese-corpus-from-ass
                                   source-file result-file log-stream))
                                 (t 0))
                           0)
                    (setf success t)))))
      (unless success
        (format log-stream "[ERROR] ~a: not successful.~%" sig))
      (when success
        (sb-ext:run-program "/bin/rm"
                            (list "-rf" (format nil "~a" workspace))))
      success)))

(defun process-catalog (&key (start 1))
  (let* ((catalog (nthcdr (1- start) *zimuzu-catalog*))
         (total (length catalog)))
    (with-open-file (log (zimuzu-process-log-path)
                         :direction :output
                         :if-exists :supersede)
      (loop 
         with success-count = 0
         for item in catalog
         for count from 1
         do 
           (format t "~a/~a ~a ~a ... " count total 
                   (getf item :name) (getf item :language))
           (handler-case 
               (if (process-catalog-item item log)
                   (progn (format t "success.")
                          (incf success-count))
                   (progn (format t "FAILED!")
                          (format log "[FAIL:~a]~%" count)))
             (t () 
               (format t "FAILED!")
               (format log "[FAIL:~a]~%" count)))
           (format t " [~a/~a]~%" success-count count)
           (finish-output log)))))
