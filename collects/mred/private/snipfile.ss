(module snipfile mzscheme
  (require (lib "class.ss")
	   (lib "etc.ss")
	   (lib "port.ss")
	   (lib "moddep.ss" "syntax")
	   (prefix wx: "kernel.ss")
	   "check.ss"
	   "editor.ss")
		
  (provide readable-snip<%>
	   open-input-text-editor 
	   open-input-graphical-file
	   text-editor-load-handler)

  ;; snip-class% and editor-data-class% loaders

  (let ([load-one
	 (lambda (str id %)
	   (let ([m (with-handlers ([void (lambda (x) #f)])
		      (and (regexp-match #rx"^[(].*[)]$" str)
			   (read (open-input-string str))))])
	     (if (and (list? m)
		      (eq? 'lib (car m))
		      (andmap string? (cdr m)))
		 (let ([result (dynamic-require m id)])
		   (if (is-a? result %)
		       result
		       (error 'load-class "not a ~a% instance" id)))
		 #f)))])
    ;; install the getters:
    (wx:set-snip-class-getter 
     (lambda (name)
       (load-one name 'snip-class wx:snip-class%)))
    (wx:set-editor-data-class-getter 
     (lambda (name)
       (load-one name 'editor-data-class wx:editor-data-class%))))

  ;; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

  (define readable-snip<%>
    (interface ()
      read-special))

  (define empty-string (make-bytes 0))
  
  ;; open-input-text-editor : (instanceof text%) num num -> input-port
  ;; creates a user port whose input is taken from the text%,
  ;; starting at position `start-in'
  ;; and ending at position `end'.
  (define open-input-text-editor 
    (opt-lambda (text [start 0] [end 'end] [snip-filter values] [port-name text] [expect-to-read-all? #f])
      ;; Check arguments:
      (unless (text . is-a? . text%)
	(raise-type-error 'open-input-text-editor "text% object" text))
      (check-non-negative-integer 'open-input-text-editor start)
      (unless (or (eq? end 'end)
		  (and (integer? end) (exact? end) (not (negative? end))))
	(raise-type-error 'open-input-text-editor "non-negative exact integer or 'end" end))
      (let ([last (send text last-position)])
	(when (start . > . last)
	  (raise-mismatch-error 'open-input-text-editor
				(format "start index outside the range [0,~a]: " last)
				start))
	(unless (eq? end 'end)
	  (unless (<= start end last)
	    (raise-mismatch-error 'open-input-text-editor
				  (format "end index outside the range [~a,~a]: " start last)
				  end))))
      (let ([end (if (eq? end 'end) (send text last-position) end)]
	    [snip (send text find-snip start 'after-or-none)])
	;; If the region is small enough, and if the editor contains
	;; only string snips, then it's probably better to move
	;; all of the text into a string port:
	(if (or (not snip)
		(and (is-a? snip wx:string-snip%)
		     (let ([s (send text find-next-non-string-snip snip)])
		       (or (not s)
			   ((send text get-snip-position s) . >= . end)))))
	    (if (or expect-to-read-all?
		    ((- end start) . < . 4096))
		;; It's all text, and it's short enough: just read it into a string
		(open-input-string (send text get-text start end) port-name)
		;; It's all text, so the reading process is simple:
		(let ([start start])
		  (let-values ([(pipe-r pipe-w) (make-pipe)])
		    (make-input-port/read-to-peek
		     port-name
		     (lambda (s)
		       (let ([v (read-bytes-avail!* s pipe-r)])
			 (if (eq? v 0)
			     (let ([n (min 4096 (- end start))])
			       (if (zero? n)
				   (begin
				     (close-output-port pipe-w)
				     eof)
				   (begin
				     (write-string (send text get-text start (+ start n)) pipe-w)
				     (set! start (+ start n))
				     (read-bytes-avail!* s pipe-r))))
			     v)))
		     (lambda (s skip general-peek)
		       (let ([v (peek-bytes-avail!* s skip #f pipe-r)])
			 (if (eq? v 0)
			     (general-peek s skip)
			     v)))
		     void))))
	    ;; General case, which handles non-text context:
	    (with-method ([gsp (text get-snip-position)]
			  [grn (text get-revision-number)])
	      (let-values ([(pipe-r pipe-w) (make-pipe)])
		(let* ([get-text-generic (generic wx:snip% get-text)]
		       [get-count-generic (generic wx:snip% get-count)]
		       [next-generic (generic wx:snip% next)]
		       [revision (grn)]
		       [next? #f]
		       [update-str-to-snip
			(lambda (to-str)
			  (if snip
			      (let ([snip-start (gsp snip)])
				(cond
				 [(snip-start . >= . end)
				  (set! snip #f)
				  (set! next? #f)
				  0]
				 [(is-a? snip wx:string-snip%)
				  (set! next? #t)
				  (let ([c (min (send-generic snip get-count-generic) (- end snip-start))])
				    (write-string (send-generic snip get-text-generic 0 c) pipe-w)
				    (read-bytes-avail!* to-str pipe-r))]
				 [else
				  (set! next? #f)
				  0]))
			      (begin
				(set! next? #f)
				0)))]
		       [next-snip
			(lambda (to-str)
			  (unless (= revision (grn))
			    (raise-mismatch-error 
			     'text-input-port 
			     "editor has changed since port was opened: "
			     text))
			  (set! snip (send-generic snip next-generic))
			  (update-str-to-snip to-str))]
		       [read-chars (lambda (to-str)
				     (cond
				      [next?
				       (next-snip to-str)]
				      [snip
				       (let ([the-snip (snip-filter snip)])
					 (next-snip empty-string)
					 (lambda (file line col ppos)
					   (if (is-a? the-snip wx:snip%)
					       (if (is-a? the-snip readable-snip<%>)
						   (send the-snip read-special file line col ppos)
						   (send the-snip copy))
					       the-snip)))]
				      [else eof]))]
		       [close (lambda () (void))]
		       [port (make-input-port/read-to-peek
			      port-name
			      (lambda (s)
				(let ([v (read-bytes-avail!* s pipe-r)])
				  (if (eq? v 0)
				      (read-chars s)
				      v)))
			      (lambda (s skip general-peek)
				(let ([v (peek-bytes-avail!* s skip #f pipe-r)])
				  (if (eq? v 0)
				      (general-peek s skip)
				      v)))
			      close)])
		  (if (is-a? snip wx:string-snip%)
		      ;; Special handling for initial snip string in
		      ;; case it starts too early:
		      (let* ([snip-start (gsp snip)]
			     [skip (- start snip-start)]
			     [c (min (- (send-generic snip get-count-generic) skip)
				     (- end snip-start))])
			(set! next? #t)
			(display (send-generic snip get-text-generic skip c) pipe-w))
		      (update-str-to-snip empty-string))
		  port)))))))

  (define (text-editor-load-handler filename expected-module)
    (unless (path? filename)
      (raise-type-error 'text-editor-load-handler "path" filename))
    (let-values ([(in-port src) (build-input-port filename)])
      (dynamic-wind
	  (lambda () (void))
	  (lambda ()
	    (parameterize ([read-accept-compiled #t])
	      (if expected-module
		  (with-module-reading-parameterization 
		   (lambda ()
		     (let* ([first (read-syntax src in-port)]
			    [module-ized-exp (check-module-form first expected-module filename)]
			    [second (read in-port)])
		       (unless (eof-object? second)
			 (raise-syntax-error
			  'text-editor-load-handler
			  (format "expected only a `module' declaration for `~s', but found an extra expression"
				  expected-module)
			  second))
		       (eval module-ized-exp))))
		  (let loop ([last-time-values (list (void))])
		    (let ([exp (read-syntax src in-port)])
		      (if (eof-object? exp)
			  (apply values last-time-values)
			  (call-with-values (lambda () (eval exp))
			    (lambda x (loop x)))))))))
	  (lambda ()
	    (close-input-port in-port)))))


  ;; build-input-port : string -> (values input any)
  ;; constructs an input port for the load handler. Also
  ;; returns a value representing the source of code read from the file.
  ;; if the file's first lines begins with #!, skips the first chars of the file.
  (define (build-input-port filename)
    (let ([p (open-input-file filename)])
      (port-count-lines! p)
      (let ([p (cond
		[(regexp-match-peek #rx#"^WXME01[0-9][0-9] ## " p)
		 (let ([t (make-object text%)])
		   (send t insert-file p 'standard)
		   (close-input-port p)
		   (open-input-text-editor t))]
		[else p])])
	(port-count-lines! p) ; in case it's new
	(let loop ()
	  ;; Wrap regexp check with `with-handlers' in case the file
	  ;;  starts with non-text input
	  (when (with-handlers ([exn:fail? (lambda (x) #f)])
		  (regexp-match-peek #rx"^#!" p))
	    ;; Throw away chars/specials up to eol,
	    ;;  and continue if line ends in backslash
	    (let lloop ([prev #f])
	      (let ([c (read-char-or-special p)])
		(if (or (eof-object? c)
			(eq? c #\return)
			(eq? c #\newline))
		    (when (eq? prev #\\)
		      (loop))
		    (lloop c))))))
	(values p filename))))

  (define (open-input-graphical-file filename)
    (let-values ([(p name) (build-input-port filename)])
      p)))