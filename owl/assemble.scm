;;;
;;; Bytecode assembly
;;;

(define-library (owl assemble)

   (export
      assemble-code)

   (import
      (owl defmac)
      (owl ff)
      (owl list)
      (owl math)
      (owl list-extra)
      (only (owl syscall) error interact)
      (only (owl register) allocate-registers n-registers)
      (owl primop))

   (begin

      ;; primops = (#(name opcode in-args|#f out-args|#f wrapper-fn) ...)

      ;; ff of opcode → (in|#f out|#f), #f if variable
      (define primop-arities
         (fold
            (λ (ff node)
               (lets ((name op in out wrapper node))
                  (put ff op (cons in out))))
            empty primops))

      (define (opcode-arity-ok? op in out)
         (let ((node (getf primop-arities op)))
            (if node
               (and
                  (or (eq? in  (car node)) (not (car node)))
                  (or (eq? out (cdr node)) (not (cdr node))))
               #true)))

      (define (variable-input-arity? op)
         (eq? (car (get primop-arities op '(0))) 'any))

      (define (multiple-return-variable-primop? op)
         (and
            (not (eq? op 32)) ; bind
            (lesser? 1 (cdr (get primop-arities op '(0 . 0))))))

      (define vm-instructions
         (list->ff
            `((move . 9)      ; move a, t:      Rt = Ra
              (refi . 1)      ; refi a, p, t:   Rt = Ra[p], p unsigned
              (goto . 2)      ; jmp a, nargs    call Ra with nargs args
              (clos . 132)    ; clos lp, o, nenv, e0 ... en, t:
              (cloc . 4)      ; cloc lp, o, nenv, e0 ... en, t:
              (clos1 . 196)
              (cloc1 . 68)
              (move2 . 5)     ; two moves, 4 args
              (goto-code . 18)
              (goto-proc . 19)
              (goto-clos . 21)
              (cons . 51)     ; cons a, b, t:   Rt = mkpair(a, b)
              (car  . 105)    ; car a, t:       Rt = car(a);
              (cdr  . 169)    ; cdr a, t:       Rt = cdr(a);
              (eq   . 54)     ; eq a, b, t:     Rt = (Ra == Rb) ? true : false;
              (jeq . 8)       ; jeq a b o1 o2   ip += o if Ra == Rb
              (jeqi . 16)     ; jeqi a o1 o2    ip += o if Ra == imm[i>>6]
              (ld   . 14)     ; ld a, t:        Rt = a, signed byte
              (ldz . 13)
              (ldn  . 77)     ; 13 + 1<<6
              (ldf  . 205)     ; ldf t:          Rt = false
              (ldt  . 141)     ; ldt t:          Rt = true
              (ret  . 24)     ; ret a:          call R3 (usually cont) with Ra
              (set . 25)     ; set a, p, b     Ra[Rp] = Rb
              (jbf . 26)     ; jump-binding tuple n f offset ... r1 ... rn
              )))

      (define (inst->op name)
         (or
            (get vm-instructions name #false)
            (error "inst->op: unknown instruction " name)))

      (define (reg a)
         (if (eq? (type a) type-fix+)
            (if (< a n-registers)
               a
               (error "register too high: " a))
            (error "bad register: " a)))


      ;;;
      ;;; Bytecode assembly
      ;;;

      (define (output-code op lst)
         (if (eq? op (fxband op #xff))
            (cons op lst)
            (output-code
               (>> op 8)
               (cons (band op #xff) lst))))

      ; rtl -> list of bytes
      ;; ast fail-cont → code' | (fail-cont <reason>)
      (define (assemble code fail)
         (tuple-case code
            ((ret a)
               (list (inst->op 'ret) (reg a)))
            ((move a b more)
               (lets
                  ((tl (assemble more fail))
                   (op (inst->op 'move)))
                  (if (eq? (car tl) op) ;; [move a b] + [move c d] = [move2 a b c d] to remove a common dispatch
                     (ilist (inst->op 'move2) (reg a) (reg b) (cdr tl))
                     (ilist op (reg a) (reg b) tl))))
            ((prim op args to more)
               (cond
                  ;; fixme: handle mk differently, this was supposed to be a temp hack
                  ((> op #xff)
                     (output-code op
                        (cons (reg (length (cdr args))) ; tuple size
                           (cons (reg (car args)) ; type
                              (append (map reg (cdr args))
                                 (cons (reg to)
                                    (assemble more fail)))))))
                  ((variable-input-arity? op)
                     ;; fixme: no output arity check
                     (cons op
                        (cons (length args)
                           (append (map reg args)
                              (cons (reg to)
                                 (assemble more fail))))))
                  ((fixnum? to)
                     (if (opcode-arity-ok? op (length args) 1)
                        (cons op
                           (append (map reg args)
                              (cons to
                                 (assemble more fail))))
                        (fail (list "Bad opcode arity for " op (length args) 1))))
                  ((list? to)
                     (if (opcode-arity-ok? op (length args) (length to))
                        (if (multiple-return-variable-primop? op)
                           (cons op
                              (append (map reg args)
                                 ; <- nargs implicit, FIXME check nargs opcode too
                                 (append (map reg to)
                                    (assemble more fail))))
                           (cons op
                              (append (map reg args)
                                 (cons (length to)          ; <- prefix with output arity
                                    (append (map reg to)
                                       (assemble more fail))))))
                        (fail (list "Bad opcode arity: " (list op (length args) (length to))))))
                  (else
                     (fail (list "bad case of primop in assemble: " op)))))
            ;; fixme: closures should have just one RTL node instead of separate ones for clos-proc and clos-code
            ((clos-proc lpos offset env to more)
               ;; make a 2-level closure
               (if (= lpos 1)
                  (cons (inst->op 'clos1)
                     (cons (+ 2 (length env))
                        ;; size of object (hdr code e0 ... en)
                        (cons offset
                           (append (map reg env)
                              (cons (reg to)
                                 (assemble more fail))))))
                  (cons (inst->op 'clos)
                     (cons (+ 2 (length env))
                        ;; size of object (hdr code e0 ... en)
                        (cons (reg lpos)
                           (cons offset
                              (append (map reg env)
                                 (cons (reg to)
                                    (assemble more fail)))))))))
            ((clos-code lpos offset env to more)      ;; make a 1-level closure
               (if (= lpos 1)
                  (cons (inst->op 'cloc1)
                     (cons (+ 2 (length env))
                        ;; size of object (hdr code e0 ... en)
                        (cons offset
                           (append (map reg env)
                              (cons (reg to)
                                 (assemble more fail))))))
                  (cons (inst->op 'cloc)
                     (cons (+ 2 (length env))
                        ;; size of object (hdr code e0 ... en)
                        (cons (reg lpos)
                           (cons offset
                              (append (map reg env)
                                 (cons (reg to)
                                    (assemble more fail)))))))))
            ((ld val to cont)
               (cond
                  ((eq? val 0)
                     (ilist (inst->op 'ldz) (reg to)
                        (assemble cont fail)))
                  ((eq? val null)
                     (ilist (inst->op 'ldn) (reg to)
                        (assemble cont fail)))
                  ((fixnum? val)
                     (let ((code (assemble cont fail)))
                        (if (not (< -129 val 128)) ; would be a bug
                           (fail (list "ld: big value: " val)))
                        (ilist (inst->op 'ld)
                           (if (< val 0) (+ 256 val) val)
                           (reg to) code)))
                  ((eq? val #false)
                     (ilist (inst->op 'ldf) (reg to)
                        (assemble cont fail)))
                  ((eq? val #true)
                     (ilist (inst->op 'ldt) (reg to)
                        (assemble cont fail)))
                  (else
                     (fail (list "cannot assemble a load for " val)))))
            ((refi from offset to more)
               (ilist
                  (inst->op 'refi) (reg from) offset (reg to)
                  (assemble more fail)))
            ((goto op nargs)
               (list (inst->op 'goto) (reg op) nargs))
            ((goto-code op n)
               (list (inst->op 'goto-code) (reg op) n)) ;; <- arity needed for dispatch
            ((goto-proc op n)
               (list (inst->op 'goto-proc) (reg op) n))
            ((goto-clos op n)
               (list (inst->op 'goto-clos) (reg op) n))
            ;; todo: all jumps could have parameterized lengths (0 = 1-byte, n>0 = 2-byte, being the max code length)
            ((jeqi i a then else)
               (lets
                  ((then (assemble then fail))
                   (else (assemble else fail))
                   (len (length else)))
                  (if (< len #x10000)
                     (ilist (bor (inst->op 'jeqi) i) (reg a) (band len #xff) (>> len 8) (append else then))
                     (fail (list "invalid jump offset: " len)))))
            ((jeq a b then else)
               (lets
                  ((then (assemble then fail))
                   (else (assemble else fail))
                   (len (length else)))
                  (if (< len #x10000)
                     (ilist (inst->op 'jeq) (reg a) (reg b) (band len #xff) (>> len 8) (append else then))
                     (fail (list "invalid jump offset: " len)))))
            (else
               ;(print "assemble: what is " code)
               (fail (list "Unknown opcode " code)))))

      ;; make bytecode and intern it (to improve sharing, not mandatory)
      (define (bytes->bytecode bytes)
         (interact 'intern (raw bytes type-bytecode)))

      ; code rtl object -> executable code
      ;; todo: exit via fail cont
      ;; todo: pass tail here or have case-lambda nodes be handled internally with a foldr
      (define (assemble-code obj tail)
         (tuple-case obj
            ((code arity insts)
               (assemble-code (tuple 'code-var #true arity insts) tail))
            ((code-var fixed? arity insts)
               (lets ((insts (allocate-registers insts)))
                  (if (not insts)
                     (error "failed to allocate registers" "")
                     (lets/cc ret
                        ((fail (λ (why) (error "Error in bytecode assembly: " why) #false))
                         (bytes (assemble insts fail))
                         (len (length bytes)))
                        (if (> len #xffff)
                           (error "too much bytecode: " len))
                        (bytes->bytecode
                           (if fixed?
                              (ilist 34 arity
                                 (band 255 (>> len 8))    ;; hi jump
                                 (band 255 len)           ;; low jump
                                 (append bytes
                                    (if (null? tail)
                                       (list 17)
                                       tail)))
                              (ilist 25 (if fixed? arity (- arity 1)) ;; last is the optional one
                                 (band 255 (>> len 8))    ;; hi jump
                                 (band 255 len)           ;; low jump
                                 (append bytes
                                    (if (null? tail)
                                       (list 17)        ;; force error
                                       tail)))))))))
            (else
               (error "assemble-code: unknown AST node " obj))))))
