/* recvmmsg/sendmmsg for Darwin, which has neither, as loops over
   recvmsg/sendmsg. Linux uses the real calls. */
#if defined(__APPLE__)
#include <sys/socket.h>
#include <sys/types.h>
#include <errno.h>
#include <time.h>

#include "nn_types.h"                  /* struct nn_mmsghdr */

int nn_recvmmsg(int fd, struct nn_mmsghdr *msgvec, unsigned int vlen,
             int flags, struct timespec *timeout) {
  unsigned i;
  int count = 0;
  (void)timeout;
  if (msgvec == NULL || vlen == 0) return 0;
  for (i = 0; i < vlen; i++) {
    int fl = flags & ~0x10000; /* Linux MSG_WAITFORONE: handled below. */
    ssize_t n;
    if (count > 0) fl |= MSG_DONTWAIT;
    n = recvmsg(fd, &msgvec[i].msg_hdr, fl);
    if (n < 0) {
      if (count > 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
      if (count == 0) return -1;
      break;
    }
    msgvec[i].msg_len = (unsigned)n;
    count++;
  }
  return count;
}

int nn_sendmmsg(int fd, struct nn_mmsghdr *msgvec, unsigned int vlen, int flags) {
  unsigned i;
  int count = 0;
  if (msgvec == NULL || vlen == 0) return 0;
  for (i = 0; i < vlen; i++) {
    ssize_t n = sendmsg(fd, &msgvec[i].msg_hdr, flags);
    if (n < 0) {
      if (count == 0) return -1;
      break;
    }
    msgvec[i].msg_len = (unsigned)n;
    count++;
  }
  return count;
}
#endif
