/* The C side of every struct whose layout zal-net's Nim code declares
   itself instead of importing it from a system header. One definition
   each, shared by the C files and by tests/tabi.nim, which checks that both
   sides agree on sizes and field offsets. Change a type here and its Nim
   twin (sys/types.nim, or the module named) together. */
#ifndef NN_TYPES_H
#define NN_TYPES_H
#include <stdint.h>
#include <stddef.h>


/* A received datagram's metadata (sys/types.nim NnDinfo). */
typedef struct {
  unsigned char dst[16];   /* destination address: IPv4 in the first 4 bytes */
  int dst_family;          /* 0 unknown, AF_INET or AF_INET6 */
  unsigned int ifindex;    /* 0 unknown */
  int ttl;                 /* -1 unknown */
  int tos;                 /* -1 unknown */
  int truncated;
} nn_dinfo;

#if defined(_WIN32)
/* Windows has no iovec, pollfd, msghdr or mmsghdr. The Nim side uses the
   Linux layouts (net/sockaddr.nim IoVec, sys/sock.nim PollFd,
   net/mmsg.nim MsgHdr and MmsgHdr) and nn_win.c converts. */
typedef struct { void *base; size_t len; } nn_iovec;
typedef struct { int32_t fd; int16_t events, revents; } nn_pollfd;
typedef struct {
  void *msg_name;
  unsigned msg_namelen;
  nn_iovec *msg_iov;
  size_t msg_iovlen;
  void *msg_control;
  size_t msg_controllen;
  int msg_flags;
} nn_msghdr;
typedef struct { nn_msghdr msg_hdr; unsigned msg_len; } nn_mmsghdr;

/* nn_if_list's records (sys/types.nim NnIfAddr, NnIfInfo). */
typedef struct {
  unsigned char ip[16];
  int family;              /* AF_INET or AF_INET6 */
  int prefix;
} nn_ifaddr;

#define NN_IF_ADDRS 32

typedef struct {
  unsigned index;
  char name[256];          /* the friendly name, UTF-8 */
  int mtu;
  unsigned flags;          /* bit per InterfaceFlag: up, broadcast, loopback, p2p, running, multicast */
  int naddrs;
  nn_ifaddr addrs[NN_IF_ADDRS];
} nn_ifinfo;

#elif defined(__APPLE__)
/* Darwin has no mmsghdr (net/mmsg.nim MmsgHdr). */
#include <sys/socket.h>
struct nn_mmsghdr {
  struct msghdr msg_hdr;
  unsigned int msg_len;
};
#endif

#endif
