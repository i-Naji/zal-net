/* splice(2) for zal-net's socket relay (Linux). */
#define _GNU_SOURCE
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

int nn_pipe_nb(int fds[2]);   /* nn_linux.c: pipe2, or pipe on old kernels */

/* A non-blocking pipe, grown to `size` bytes where allowed (2.6.35). 0 or -1. */
int nn_pipe(int fds[2], int size) {
  if (nn_pipe_nb(fds) != 0) return -1;
#ifdef F_SETPIPE_SZ
  if (size > 0) (void)fcntl(fds[0], F_SETPIPE_SZ, size);
#endif
  return 0;
}

/* Move up to len bytes between a socket and a pipe without copying
   through user space. >0 moved, 0 end of stream, -1 with errno. */
long nn_splice(int in, int out, long len) {
  long n;
  do n = splice(in, NULL, out, NULL, (size_t)len, SPLICE_F_MOVE | SPLICE_F_NONBLOCK);
  while (n < 0 && errno == EINTR);
  return n;
}

#ifdef NN_STREAM_FAULT_TEST
static int reject_output;
void nn_test_reject_splice_output(void) { __atomic_store_n(&reject_output, 1, __ATOMIC_SEQ_CST); }
int nn_test_splice_rejection_pending(void) { return __atomic_load_n(&reject_output, __ATOMIC_SEQ_CST); }
#endif

/* Separate egress boundary so the regression fixture can refuse an output
 * descriptor after input has already transferred bytes into the pipe. */
long nn_splice_output(int in, int out, long len) {
#ifdef NN_STREAM_FAULT_TEST
  if (__atomic_exchange_n(&reject_output, 0, __ATOMIC_SEQ_CST)) {
    errno = EINVAL;
    return -1;
  }
#endif
  return nn_splice(in, out, len);
}
