(define correlated->annotation
  (case-lambda
   [(v serializable?)
    (let-values ([(e stripped-e) (correlated->annotation* v serializable?)])
      e)]
   [(v) (correlated->annotation v #f)]))

(define (correlated->annotation* v serializable?)
  (cond
   [(pair? v) (let-values ([(a stripped-a) (correlated->annotation* (car v) serializable?)]
                           [(d stripped-d) (correlated->annotation* (cdr v) serializable?)])
                (cond
                 [(and (eq? a (car v))
                       (eq? d (cdr v)))
                  (values v v)]
                 [else (values (cons a d)
                               (cons stripped-a stripped-d))]))]
   [(correlated? v) (let-values ([(e stripped-e) (correlated->annotation* (correlated-e v) serializable?)])
                      (let ([name (correlated-property v 'inferred-name)]
                            [method-arity-error (correlated-property v 'method-arity-error)])
                        (define (add-name e)
                          (if (and name (not (void? name)))
                              `(|#%name| ,name ,e)
                              e))
                        (define (add-method-arity-error e)
                          (if method-arity-error
                              `(|#%method-arity| ,e)
                              e))
                        (values (add-method-arity-error
                                 (add-name (transfer-srcloc v e stripped-e serializable?)))
                                (add-method-arity-error
                                 (add-name stripped-e)))))]
   ;; correlated will be nested only in pairs with current expander
   [else (values v v)]))

(define (extract-inferred-name expr default-name)
  (let ([name (and (correlated? expr)
                   (correlated-property expr 'inferred-name))])
    (cond
     [(void? name) #f]
     [(correlated? name) (correlated-e name)]
     [(symbol? name) name]
     [else default-name])))

(define (transfer-srcloc v e stripped-e serializable?)
  (let ([src (correlated-source v)]
        [pos (correlated-position v)]
        [line (correlated-line v)]
        [column (correlated-column v)]
        [span (correlated-span v)])
    (if (and pos span (or (path? src) (string? src)))
        (let ([pos (sub1 pos)]) ; Racket positions are 1-based; host Scheme positions are 0-based
          (make-annotation e
                           (if (and line column)
                               ;; Racket columns are 0-based; host-Scheme columns are 1-based
                               (make-source-object (source->sfd src serializable?) pos (+ pos span) line (add1 column))
                               (make-source-object (source->sfd src serializable?) pos (+ pos span)))
                           stripped-e))
        e)))

(define sfd-cache-box/ser (unsafe-make-place-local #f))
(define sfd-cache-box/unser (unsafe-make-place-local #f))

(define (source->sfd src serializable?)
  (let* ([sfd-cache-box (if serializable? sfd-cache-box/ser sfd-cache-box/unser)]
         [sfd-cache (unsafe-place-local-ref sfd-cache-box)])
    (cond
     [sfd-cache
      (or (hash-ref sfd-cache src #f)
          (let ([str (cond
                      [serializable?
                       ;; Making paths to record for procedure obey
                       ;; `current-write-relative-directory`, etc., is
                       ;; difficult --- a lot of work for something that
                       ;; shows up only in stack traces. So, just keep a
                       ;; couple of path elements
                       (let-values ([(base name dir?) (split-path src)])
                         (cond
                          [(or (not (path? name))
                               (not base))
                           "..."]
                          [(path? base)
                           (let-values ([(base name2 dir?) (split-path base)])
                             (cond
                              [(and (path? name2)
                                    base)
                               (string-append ".../" (path-element->string name2)
                                              "/" (path-element->string name))]
                              [else
                               (string-append ".../" (path-element->string name))]))]
                          [else
                           (string-append ".../" (path-element->string name))]))]
                      [(path? src) (path->string src)]
                      [else src])])
            ;; We'll use a file-position object in source objects, so
            ;; the sfd checksum doesn't matter
            (let ([sfd (source-file-descriptor str 0)])
              (hash-set! sfd-cache src sfd)
              sfd)))]
     [else
      ;; There's a race here at the level of Racket threads,
      ;; but that seems ok for setting up a cache
      (unsafe-place-local-set! sfd-cache-box (make-weak-hash))
      (source->sfd src serializable?)])))

;; --------------------------------------------------

(define (strip-nested-annotations s)
  (cond
   [(annotation? s) (annotation-stripped s)]
   [(pair? s)
    (let ([a (strip-nested-annotations (car s))]
          [d (strip-nested-annotations (cdr s))])
      (if (and (eq? a (car s)) (eq? d (cdr s)))
          s
          (cons a d)))]
   [else s]))
