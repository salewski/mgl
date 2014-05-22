(in-package :mgl-example-util)

(defun call-repeatably (seed fn)
  (with-cuda (:random-seed seed)
    (let ((*random-state*
            #+sbcl (sb-ext:seed-random-state seed)
            #+allegro (make-random-state t seed)
            #-(or sbcl allegro) *random-state))
      (funcall fn))))

(defmacro repeatably ((seed) &body body)
  `(call-repeatably ,seed (lambda () ,@body)))

(defvar *experiment-random-seed* 1234)

(defun run-experiment (fn)
  (repeatably (*experiment-random-seed*)
    (funcall fn)))

(defmacro with-experiment (() &body body)
  `(repeatably (*experiment-random-seed*)
     ,@body))


(defun time->string (&optional (time (get-universal-time)))
  (destructuring-bind (second minute hour date month year)
      (subseq (multiple-value-list (decode-universal-time time)) 0 6)
    (format nil "~4,'0D-~2,'0D-~2,'0D ~2,'0D:~2,'0D:~2,'0D"
            year month date hour minute second)))

(defparameter *example-dir*
  (merge-pathnames (make-pathname :directory '(:relative "example"))
                   (make-pathname :name nil :type nil
                                  :defaults (asdf:component-pathname
                                             (asdf:find-system :mgl-example)))))

(defparameter *log-file*
  (merge-pathnames "mgl-example.log" *example-dir*))

(defun log-msg (format &rest args)
  (pprint-logical-block (*trace-output* nil)
    (format *trace-output* "~A: " (time->string))
    (pprint-logical-block (*trace-output* nil)
      (apply #'format *trace-output* format args)))
  (with-open-file (s *log-file* :direction :output
                   :if-exists :append :if-does-not-exist :create)
    (pprint-logical-block (s nil)
      (format s "~A: " (time->string))
      (pprint-logical-block (s nil)
        (apply #'format s format args)))))

(defmacro with-logging-entry ((stream) &body body)
  `(log-msg "~A"
    (with-output-to-string (,stream)
      ,@body)))


;;;; Logging trainer

(defgeneric log-training-error (trainer learner))
(defgeneric log-test-error (trainer learner))
(defgeneric log-training-period (trainer learner))
(defgeneric log-test-period (trainer learner))

(defclass logging-trainer ()
  ((log-training-fn :initform (make-instance 'periodic-fn
                                             :period 'log-training-period
                                             :fn 'log-training-error)
                    :reader log-training-fn)
   (log-test-fn :initform (make-instance 'periodic-fn
                                         :period 'log-test-period
                                         :fn 'log-test-error)
                :reader log-test-fn)))

(defmethod train-batch :around (samples (trainer logging-trainer) learner)
  (multiple-value-prog1 (call-next-method)
    (call-periodic-fn (n-inputs trainer) (log-training-fn trainer)
                      trainer learner)
    (call-periodic-fn (n-inputs trainer) (log-test-fn trainer)
                      trainer learner)))

(defmethod train :before (sampler (trainer logging-trainer) learner)
  (setf (last-eval (log-training-fn trainer))
        (n-inputs trainer))
  (call-periodic-fn! (n-inputs trainer) (log-test-fn trainer)
                     trainer learner))

(defmethod train :after (sampler (trainer logging-trainer) learner)
  (call-periodic-fn! (n-inputs trainer) (log-training-fn trainer)
                     trainer learner)
  (call-periodic-fn! (n-inputs trainer) (log-test-fn trainer)
                     trainer learner))


;;;; BASE-TRAINER

(defclass base-trainer (logging-trainer)
  ((training-counters-and-measurers :reader training-counters-and-measurers)))

(defun log-cuda ()
  (when (use-cuda-p)
    (log-msg "cuda mats: ~S, copies: h->d: ~S, d->h: ~S~%"
             (mgl-cube:count-barred-facets 'cuda-array :type 'mat)
             *n-memcpy-host-to-device*
             *n-memcpy-device-to-host*)))

(defmethod log-test-error ((trainer base-trainer) learner)
  (let ((*print-level* nil))
    (when (zerop (n-inputs trainer))
      (with-logging-entry (stream)
        (format stream "Describing learner:~%")
        (describe learner stream))
      (with-logging-entry (stream)
        (format stream "Describing trainer:~%")
        (describe trainer stream))))
  (log-msg "n-inputs: ~S~%" (n-inputs trainer))
  (log-cuda))

(defmethod log-training-error ((trainer base-trainer) learner)
  (log-msg "n-inputs: ~S~%"  (n-inputs trainer))
  (log-cuda)
  (dolist (counter-and-measurer (training-counters-and-measurers trainer))
    (let ((counter (car counter-and-measurer)))
      (log-msg "~A~%" counter)
      (reset-counter counter))))

(defmethod negative-phase :around (batch (learner rbm-cd-learner)
                                   (sink base-trainer) multiplier)
  (call-next-method)
  (when *accumulating-interesting-gradients*
    (apply-counters-and-measurers (training-counters-and-measurers sink)
                                  batch (bm learner))))

(defmethod positive-phase :around (batch (learner bm-pcd-learner)
                                   (sink base-trainer) multiplier)
  (call-next-method)
  (when *accumulating-interesting-gradients*
    (let ((bm (bm learner)))
      (set-visible-mean bm)
      (apply-counters-and-measurers (training-counters-and-measurers sink)
                                    batch bm))))

(defmethod compute-derivatives :around (batch (trainer base-trainer)
                                        (learner bp-learner))
  (multiple-value-prog1 (call-next-method)
    ;; FIXME: this is broken if DO-EXECUTORS is non-trivial.
    (when *accumulating-interesting-gradients*
      (apply-counters-and-measurers (training-counters-and-measurers trainer)
                                    batch (bpn learner)))))

(defmethod train-batch (batch (trainer base-trainer) (learner bp-learner))
  (if (typep trainer 'mgl-cg:cg-trainer)
      (let ((result (multiple-value-list (call-next-method))))
        (when (= (length result) 5)
          (destructuring-bind (best-w best-f n-line-searches
                               n-succesful-line-searches n-evaluations)
              result
            (declare (ignore best-w))
            (log-msg "best-f: ~,5E, ~:_n-evaluations: ~S~%"
                     best-f n-evaluations)
            (log-msg "n-line-searches: ~S (succesful ~S)~%"
                     n-line-searches n-succesful-line-searches)))
        result)
      (call-next-method)))

(defun prepend-name-to-counters (name counters-and-measurers)
  (dolist (counter-and-measurer counters-and-measurers counters-and-measurers)
    (setf (slot-value (car counter-and-measurer) 'name)
          (cons name
                (alexandria:ensure-list
                 (slot-value (car counter-and-measurer) 'name))))))


;;;; Simple cross entropy softmax classification (CESC) support

(defclass softmax-label-chunk* (softmax-label-chunk) ())

(defclass cesc-trainer (base-trainer) ())

(defun maximally-likely-node (striped stripe &key (nodes (nodes striped)))
  (with-facets ((nodes (nodes 'backing-array :direction :input
                              :type flt-vector)))
    (with-stripes ((stripe striped start end))
      (- (max-position nodes start end)
         start))))

;;; Samplers don't return examples, but a list of (SAMPLE &KEY
;;; DISCARD-LABEL-P SAMPLE-VISIBLE-P). Work around it.
(defmethod maybe-make-misclassification-measurer ((chunk softmax-label-chunk*))
  (let ((measurer (call-next-method)))
    (when measurer
      (lambda (examples learner)
        (funcall measurer (mapcar #'first examples) learner)))))

(defmethod mgl-train::maybe-make-cross-entropy-measurer
    ((chunk softmax-label-chunk*))
  (let ((measurer (call-next-method)))
    (when measurer
      (lambda (examples learner)
        (funcall measurer (mapcar #'first examples) learner)))))

(defmethod mgl-train::maybe-make-classification-confidence-collector
    ((chunk softmax-label-chunk*))
  (let ((measurer (call-next-method)))
    (when measurer
      (lambda (examples learner)
        (funcall measurer (mapcar #'first examples) learner)))))


;;;; RBM/DBN support for CESC-TRAINER

(defmethod initialize-gradient-sink ((trainer cesc-trainer) learner (rbm rbm))
  (call-next-method)
  (setf (slot-value trainer 'training-counters-and-measurers)
        (prepend-name-to-counters
         "rbm: training"
         (append
          (make-bm-reconstruction-rmse-counters-and-measurers rbm)
          (make-bm-reconstruction-misclassification-counters-and-measurers rbm)
          (make-bm-reconstruction-cross-entropy-counters-and-measurers rbm)))))

(defun log-dbn-cesc-accuracy (rbm sampler name)
  (if (dbn rbm)
      (let ((counters (collect-dbn-mean-field-errors/labeled sampler (dbn rbm)
                                                             :rbm rbm)))
        (map nil (lambda (counter)
                   (log-msg "dbn: ~:_~A ~:_~A~%" name counter))
             counters))
      (let ((counters (collect-bm-mean-field-errors/labeled sampler rbm)))
        (map nil (lambda (counter)
                   (log-msg "rbm: ~:_~A ~:_~A~%" name counter))
             counters))))


;;;; DBM support for CESC-TRAINER

(defmethod initialize-gradient-sink ((trainer cesc-trainer) learner (dbm dbm))
  (call-next-method)
  (setf (slot-value trainer 'training-counters-and-measurers)
        (prepend-name-to-counters
         "dbm train: training"
         (append
          (make-dbm-reconstruction-rmse-counters-and-measurers dbm)
          (make-bm-reconstruction-misclassification-counters-and-measurers
           dbm)
          (make-bm-reconstruction-cross-entropy-counters-and-measurers
           dbm)))))

(defun log-dbm-cesc-accuracy (dbm sampler name)
  (let ((counters (collect-bm-mean-field-errors/labeled sampler dbm)))
    (when counters
      (map nil (lambda (counter)
                 (log-msg "dbm test: ~:_~A ~:_~A~%" name counter))
           counters))))


;;;; BPN support for CESC-TRAINER

(defun maximally-likely-in-cross-entropy-softmax-lump (lump stripe)
  (values (maximally-likely-node lump stripe :nodes (softmax lump))
          (maximally-likely-node (target lump) stripe)))

(defun cesc-max-likelihood-classification-error (lump)
  "A measurer that return the number of misclassifications."
  (values (loop for stripe below (n-stripes lump)
                count (multiple-value-bind (prediction target)
                          (maximally-likely-in-cross-entropy-softmax-lump
                           lump stripe)
                        (/= prediction target)))
          (n-stripes lump)))

(defun cesc-classification-error (bpn)
  (cesc-max-likelihood-classification-error
   (find-if (lambda (lump)
              (typep lump '->cross-entropy-softmax))
            (lumps bpn))))

(defun make-bpn-cesc-counters-and-measurers ()
  (list (cons (make-instance 'misclassification-counter)
              (lambda (samples bpn)
                (declare (ignore samples))
                (cesc-classification-error bpn)))
        (cons (make-instance 'cross-entropy-counter)
              (lambda (samples bpn)
                (mgl-train::measure-cross-entropy
                 samples
                 (find-if (lambda (lump)
                            (typep lump '->cross-entropy-softmax))
                          (lumps bpn)))))))

(defmethod initialize-gradient-sink ((trainer cesc-trainer) learner (bpn bpn))
  (call-next-method)
  (setf (slot-value trainer 'training-counters-and-measurers)
        (prepend-name-to-counters "bpn train: training"
                                  (make-bpn-cesc-counters-and-measurers))))

(defun bpn-cesc-error (sampler bpn)
  (collect-bpn-errors sampler bpn
                      :counters-and-measurers
                      (make-bpn-cesc-counters-and-measurers)))


;;;; Utilities

(defun load-weights (filename obj)
  (with-open-file (stream filename :element-type 'unsigned-byte)
    (read-weights obj stream)))

(defun save-weights (filename obj)
  (ensure-directories-exist filename)
  (with-open-file (stream filename :direction :output
                   :if-does-not-exist :create :if-exists :supersede
                   :element-type 'unsigned-byte)
    (write-weights obj stream)))
