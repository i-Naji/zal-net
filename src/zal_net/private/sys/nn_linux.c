/* Old Linux kernels and C libraries. Each call newer than Linux 2.6.27 is
   tried first (when the headers have it) and replaced by an older one when
   the kernel does not know it (ENOSYS, or EINVAL for unknown flags):

     accept4 (2.6.28)           accept, then fcntl
     pipe2 (2.6.27)             pipe, then fcntl
     eventfd with flags (2.6.27) -1: the caller uses a pipe
     recvmmsg (2.6.33)          recvmsg in a loop
     sendmmsg (3.0)             sendmsg in a loop

   epoll_create1 (2.6.27) is in nn_poll.c and nn_poller.c. NN_LINUX_COMPAT=1
   in the environment forces every fallback, so the test suite can run them
   on a new kernel. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <sys/types.h>
#include <sys/socket.h>
#include "nn_compat.h"

#if NN_GLIBC_MIN(2, 8)
#include <sys/eventfd.h>
#endif

static void nb_cloexec(int fd) {
  int fl = fcntl(fd, F_GETFL);
  if (fl >= 0) (void)fcntl(fd, F_SETFL, fl | O_NONBLOCK);
  (void)fcntl(fd, F_SETFD, FD_CLOEXEC);
}

int nn_compat_linux(void) { return nn_compat(); }

/* ------------------------------------------------------------- accept */

static int g_no_accept4;

/* One accepted connection, non-blocking and close-on-exec; -1 with errno. */
int nn_accept_nb(int fd) {
  int c;
#if NN_GLIBC_MIN(2, 10) && defined(SOCK_NONBLOCK)
  if (!g_no_accept4 && !nn_compat()) {
    c = accept4(fd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
    if (c >= 0) return c;
    if (errno != ENOSYS && errno != EINVAL) return -1;
    /* EINVAL: flags this kernel does not know, or a listener that is gone;
       plain accept tells them apart below. */
    c = accept(fd, NULL, NULL);
    if (c < 0) return -1;
    g_no_accept4 = 1;
    nb_cloexec(c);
    return c;
  }
#endif
  c = accept(fd, NULL, NULL);
  if (c >= 0) nb_cloexec(c);
  return c;
}

/* --------------------------------------------------------------- pipe */

/* A non-blocking, close-on-exec pipe. 0 or -1. */
int nn_pipe_nb(int fds[2]) {
#if NN_GLIBC_MIN(2, 9) && defined(O_CLOEXEC)
  if (!nn_compat()) {
    if (pipe2(fds, O_NONBLOCK | O_CLOEXEC) == 0) return 0;
    if (errno != ENOSYS && errno != EINVAL) return -1;
  }
#endif
  if (pipe(fds) != 0) return -1;
  nb_cloexec(fds[0]);
  nb_cloexec(fds[1]);
  return 0;
}

/* ------------------------------------------------------------ eventfd */

/* A non-blocking eventfd, or -1: the caller falls back to a pipe. */
int nn_eventfd_nb(void) {
#if NN_GLIBC_MIN(2, 8) && defined(EFD_NONBLOCK)
  if (!nn_compat()) return eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
#endif
  errno = ENOSYS;
  return -1;
}

/* ----------------------------------------------------- mmsg batches */

/* struct mmsghdr, which old headers lack; the kernel's layout. */
struct nn_mmsghdr {
  struct msghdr msg_hdr;
  unsigned int msg_len;
};

#define NN_MSG_WAITFORONE 0x10000

static int g_no_recvmmsg, g_no_sendmmsg;

static int recv_loop(int fd, struct nn_mmsghdr *v, unsigned vlen, int flags) {
  unsigned i;
  int count = 0;
  for (i = 0; i < vlen; i++) {
    int fl = flags & ~NN_MSG_WAITFORONE;
    ssize_t n;
    if (count > 0) fl |= MSG_DONTWAIT;
    n = recvmsg(fd, &v[i].msg_hdr, fl);
    if (n < 0) {
      if (count == 0) return -1;
      break;
    }
    v[i].msg_len = (unsigned)n;
    count++;
  }
  return count;
}

static int send_loop(int fd, struct nn_mmsghdr *v, unsigned vlen, int flags) {
  unsigned i;
  int count = 0;
  for (i = 0; i < vlen; i++) {
    ssize_t n = sendmsg(fd, &v[i].msg_hdr, flags);
    if (n < 0) {
      if (count == 0) return -1;
      break;
    }
    v[i].msg_len = (unsigned)n;
    count++;
  }
  return count;
}

int nn_recvmmsg(int fd, void *vec, unsigned vlen, int flags, void *timeout) {
  (void)timeout;
#if NN_GLIBC_MIN(2, 12)
  if (!g_no_recvmmsg && !nn_compat()) {
    int n = recvmmsg(fd, (struct mmsghdr *)vec, vlen, flags, NULL);
    if (n >= 0 || errno != ENOSYS) return n;
    g_no_recvmmsg = 1;
  }
#endif
  return recv_loop(fd, (struct nn_mmsghdr *)vec, vlen, flags);
}

int nn_sendmmsg(int fd, void *vec, unsigned vlen, int flags) {
#if NN_GLIBC_MIN(2, 14)
  if (!g_no_sendmmsg && !nn_compat()) {
    int n = sendmmsg(fd, (struct mmsghdr *)vec, vlen, flags);
    if (n >= 0 || errno != ENOSYS) return n;
    g_no_sendmmsg = 1;
  }
#endif
  return send_loop(fd, (struct nn_mmsghdr *)vec, vlen, flags);
}
