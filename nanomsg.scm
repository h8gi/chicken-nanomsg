(use lolevel foreigners srfi-18 srfi-13 irregex)

#>
#include <nanomsg/nn.h>
#include <nanomsg/pipeline.h>
#include <nanomsg/pubsub.h>
#include <nanomsg/reqrep.h>
#include <nanomsg/survey.h>
#include <nanomsg/pair.h>
#include <nanomsg/bus.h>
<#

;; TODO: socket options NN_SUB_SUBSCRIBE NN_SUB_UNSUBSCRIBE
(define-record-type nn-socket (%nn-socket-box int)
  nn-socket?
  (int %nn-socket-unbox))

(define-foreign-type nn-socket int
  %nn-socket-unbox
  %nn-socket-box)

;; nanomsg protocol&transport enum
(define-foreign-enum-type (nn-protocol int)
  (nn-protocol->int int->nn-protocol)

  (pair NN_PAIR)
  (pub  NN_PUB)  (sub  NN_SUB)
  (pull NN_PULL) (push NN_PUSH)
  (req  NN_REQ)  (rep  NN_REP)
  (surveyor NN_SURVEYOR)  (respondent NN_RESPONDENT)
  (bus NN_BUS))

;; nanomsg domain (AF_SP)
(define-foreign-enum-type (nn-domain int)
  (nn-domain->int int->nn-domain)
  (sp AF_SP)
  (raw AF_SP_RAW))

;; ==================== socket flags
;; nn-pub
;; return name and value
(define (nn-symbol index)
  (let-location ([value int])
    (let ([str ((foreign-lambda* c-string ([int i]
					   [(c-pointer int) value])
				 "return ("
				 "nn_symbol(i, value)"
				 ");")
		index (location value))])
      (if str
	  (cons str value)
	  #f))))

(define nn-symbol-table
  (let loop ([acc '()]
	     [i 0])
    (let ([pair (nn-symbol i)])
      (if pair (loop (cons pair acc)
		     (add1 i))
	  acc))))

(define (nn-rename str)
  (string->symbol (string-downcase (irregex-replace/all "_" str "-"))))

(eval (cons 'begin (map (lambda (pair)
			  `(define ,(nn-rename (car pair))
			     ,(cdr pair)))
			nn-symbol-table)))

(define nn/dontwait (foreign-value "NN_DONTWAIT" int))

(define (nn-strerror #!optional (errno (foreign-value "errno" int)))
  ((foreign-lambda c-string "nn_strerror" int) errno))

;; let val pass unless it is negative, in which case gulp with the nn
;; error-string. on EAGAIN, return #f.
(define (nn-assert val)
  (if (< val 0)
      (if (= (foreign-value "errno" int)
             (foreign-value "EAGAIN" int))
          #f ;; signal EGAIN with #f, other errors will throw
          (error (nn-strerror) val))
      val))

;; get the pollable fd for socket.
(define (nn-recv-fd socket)
  (let-location ((fd int -1)
                 (fd_size int (foreign-value "sizeof(int)" int)))
    (nn-assert
     ((foreign-lambda* int ( (nn-socket socket)
			     ((c-pointer int) fd)
			     ((c-pointer size_t) fds))
		       "return(nn_getsockopt(socket, NN_SOL_SOCKET, NN_RCVFD, fd, fds));")
      socket (location fd) (location fd_size)))
    (if (not (= (foreign-value "sizeof(int)" int) fd_size))
	(error "invalid nn_getsockopt destination storage size" fd_size))
    fd))

(define (nn-subscribe socket prefix)
  (nn-assert
   ((foreign-lambda* int ( (nn-socket socket)
			   (nonnull-blob prefix)
			   (int len))
		     "return("
		     "nn_setsockopt(socket, NN_SUB, NN_SUB_SUBSCRIBE, prefix, len)"
		     ");")
    socket prefix (string-length prefix))))

(define (nn-setsockopt socket level option optval)
  (nn-assert
   (cond [(number? optval)
	  ((foreign-lambda* int ([nn-socket socket]
				 [int level]
				 [int option]
				 [int optval])
			    "return("
			    "nn_setsockopt(socket, level, option, &optval, sizeof(optval))"
			    ");")
	   socket level option optval)]
	 [(string? optval)
	  ((foreign-lambda* int ([nn-socket socket]
				 [int level]
				 [int option]
				 [c-string optval]
				 [int len])
			    "return("
			    "nn_setsockopt(socket, level, option, optval, len)"
			    ");")
	   socket level option optval (string-length optval))]
	 [else
	  -1])))

(define (nn-close socket)
  (nn-assert ( (foreign-lambda int "nn_close" nn-socket) socket)))

;; int nn_socket (int domain, int protocol)
;; OBS: args reversed
;; TODO: add finalizer
(define (nn-socket protocol #!optional (domain 'sp))
  (set-finalizer!
   (%nn-socket-box
    (nn-assert ((foreign-lambda int nn_socket nn-domain nn-protocol)
                domain
                protocol)))
   nn-close))

(define (nn-bind socket address)
  (nn-assert ((foreign-lambda int "nn_bind" nn-socket c-string) socket address)))

(define (nn-connect socket address)
  (nn-assert ((foreign-lambda int "nn_connect" nn-socket c-string) socket address)))

(define (nn-freemsg! pointer)
  (nn-assert ( (foreign-lambda int "nn_freemsg" (c-pointer void)) pointer)))

(define (nn-send socket data #!optional (flags 0))
  (nn-assert ( (foreign-lambda int "nn_send" nn-socket blob int int)
	       socket data (number-of-bytes data) flags)))

(define (nn-recv! socket data size flags)
  (nn-assert ( (foreign-lambda int "nn_recv" nn-socket (c-pointer void) int int)
	       socket data (or size (number-of-bytes data)) flags)))

;; plain nn-recv, will read-block other srfi-18 threads unless
;; nn/dontwait flag is specified. returns the next message as a
;; string.
(define (nn-recv* socket #!optional (flags 0))
  ;; make a pointer which nanomsg will point to its newly allocated
  ;; message
  (let-location
      ((dst (c-pointer void) #f))
    (and-let* ((size (nn-recv! socket (location dst) (foreign-value "NN_MSG" int) flags))
	       (blb (make-string size)))
      (move-memory! dst blb size)
      (nn-freemsg! dst)
      blb)))

;; wait for message on socket, return it as string. does not block
;; other srfi-18 threads.
(define (nn-recv socket)
  (let loop ()
    ;; make a non-blocking attempt first, and if we get EAGAIN (#f),
    ;; wait and retry. let's give nn a chance to error with
    ;; something other than EAGAIN before waiting for i/o. for
    ;; example, nn-recv on PUB socket would block infinitely
    (or (nn-recv* socket nn/dontwait)
        (begin
          ;; is getting the fd an expensive operation?
          (thread-wait-for-i/o! (nn-recv-fd socket) #:input)
          (loop)))))

;; TODO: support nn_sendmsg and nn_recvmsg?
