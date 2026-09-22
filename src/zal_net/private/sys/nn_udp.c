/* UDP segmentation offload (GSO) and receive coalescing (GRO) on Linux.
   Elsewhere these report "unsupported" and callers keep per-datagram I/O.

   A kernel before 4.18 does not refuse a UDP_SEGMENT control message: it
   skips it and sends one oversized datagram. So GSO is probed once, with
   getsockopt (ENOPROTOOPT before 4.18), not inferred from a failed send.
   NN_LINUX_COMPAT=1 turns both off. */
#include <stdint.h>
#include <errno.h>
#include <string.h>

#if defined(__linux__)
#include <sys/socket.h>
#include <sys/uio.h>
#include <netinet/in.h>
#include <netinet/udp.h>
#include <unistd.h>
#include "nn_compat.h"
#ifndef SOL_UDP
#define SOL_UDP 17
#endif
#ifndef UDP_SEGMENT
#define UDP_SEGMENT 103
#endif
#ifndef UDP_GRO
#define UDP_GRO 104
#endif

int nn_udp_gro_on(int fd) {
  int one = 1;
  if (nn_compat()) return 0;
  return setsockopt(fd, SOL_UDP, UDP_GRO, &one, sizeof one) == 0;
}

/* 1 when the kernel segments UDP_SEGMENT sends (4.18 and later). */
int nn_udp_gso_ok(void) {
  static int ok = -1;
  if (ok < 0) {
    int v = 0, fd = socket(AF_INET, SOCK_DGRAM, 0);
    socklen_t len = sizeof v;
    ok = fd >= 0 && !nn_compat() && getsockopt(fd, SOL_UDP, UDP_SEGMENT, &v, &len) == 0;
    if (fd >= 0) close(fd);
  }
  return ok;
}

int nn_udp_gro_size(const void *msghdr) {
  const struct msghdr *mh = (const struct msghdr *)msghdr;
  struct cmsghdr *c;
  if (mh->msg_control == NULL || mh->msg_controllen == 0) return 0;
  for (c = CMSG_FIRSTHDR((struct msghdr *)mh); c != NULL; c = CMSG_NXTHDR((struct msghdr *)mh, c)) {
    if (c->cmsg_level == SOL_UDP && c->cmsg_type == UDP_GRO) {
      int seg = 0;
      memcpy(&seg, CMSG_DATA(c), sizeof seg);
      return seg;
    }
  }
  return 0;
}

long nn_udp_send_gso(int fd, const void *buf, unsigned long len, int seg,
                       const void *dest, unsigned dest_len) {
  char ctrl[CMSG_SPACE(sizeof(uint16_t))];
  struct iovec iov;
  struct msghdr mh;
  struct cmsghdr *c;
  uint16_t s = (uint16_t)seg;
  ssize_t n;
  if (!nn_udp_gso_ok()) return -(long)EOPNOTSUPP;   /* would go out as one datagram */
  memset(ctrl, 0, sizeof ctrl);
  memset(&mh, 0, sizeof mh);
  iov.iov_base = (void *)buf;
  iov.iov_len = len;
  mh.msg_name = (void *)dest;
  mh.msg_namelen = dest_len;
  mh.msg_iov = &iov;
  mh.msg_iovlen = 1;
  mh.msg_control = ctrl;
  mh.msg_controllen = sizeof ctrl;
  c = CMSG_FIRSTHDR(&mh);
  c->cmsg_level = SOL_UDP;
  c->cmsg_type = UDP_SEGMENT;
  c->cmsg_len = CMSG_LEN(sizeof s);
  memcpy(CMSG_DATA(c), &s, sizeof s);
  do n = sendmsg(fd, &mh, 0); while (n < 0 && errno == EINTR);
  return n < 0 ? -(long)errno : (long)n;
}

#else

int nn_udp_gro_on(int fd) { (void)fd; return 0; }
int nn_udp_gso_ok(void) { return 0; }
int nn_udp_gro_size(const void *msghdr) { (void)msghdr; return 0; }
long nn_udp_send_gso(int fd, const void *buf, unsigned long len, int seg,
                       const void *dest, unsigned dest_len) {
  (void)fd; (void)buf; (void)len; (void)seg; (void)dest; (void)dest_len;
#if defined(_WIN32)
  return -95L;             /* EOPNOTSUPP in the numbering zal-net uses there */
#else
  return -(long)EOPNOTSUPP;
#endif
}

#endif
