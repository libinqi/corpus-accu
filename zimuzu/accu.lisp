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

(def-path zimuzu-url-to-file (url &optional (workspace *workspace*))
  (merge-pathnames (format nil "~a.~a" (pathname-name url) (pathname-type url))
		   workspace))

(defun download-file (url &optional (workspace *workspace*))
  (let ((source-stream (drakma:http-request url :want-stream t)))
    (with-open-file (output (zimuzu-url-to-file-path url)
			    :direction :output
			    :if-exists :supersede
			    :element-type '(unsigned-byte 8))
      (unwind-protect 
	   (loop for byte = (read-byte source-stream nil nil)
	      while byte
	      do (write-byte byte output))
	(close source-stream)))))

      
			     
	  
