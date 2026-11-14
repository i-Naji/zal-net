/* Sizes and field offsets, as C sees them, of the structs whose layout
   zal-net's Nim code declares itself: for tests/tabi.nim. */
#define _GNU_SOURCE
#include <stddef.h>
#ifdef _WIN32
#include <winsock2.h>
#else
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <poll.h>
#endif
#include "../src/zal_net/private/sys/nn_types.h"

#define OFF(T, f) ((long)offsetof(T, f))

#ifdef _WIN32
typedef nn_pollfd PollFdC;
typedef nn_mmsghdr MmsgC;
#elif defined(__APPLE__)
typedef struct pollfd PollFdC;
typedef struct nn_mmsghdr MmsgC;
#else
typedef struct pollfd PollFdC;
typedef struct mmsghdr MmsgC;
#endif

long nn_abi(int q) {
  switch (q) {
  case 20: return sizeof(nn_dinfo);
  case 21: return OFF(nn_dinfo, dst);
  case 22: return OFF(nn_dinfo, dst_family);
  case 23: return OFF(nn_dinfo, ifindex);
  case 24: return OFF(nn_dinfo, ttl);
  case 25: return OFF(nn_dinfo, tos);
  case 26: return OFF(nn_dinfo, truncated);
  case 30: return sizeof(PollFdC);
  case 31: return OFF(PollFdC, fd);
  case 32: return OFF(PollFdC, events);
  case 33: return OFF(PollFdC, revents);
  case 40: return sizeof(struct linger);
  case 41: return OFF(struct linger, l_onoff);
  case 42: return OFF(struct linger, l_linger);
  case 50: return sizeof(MmsgC);
  case 51: return OFF(MmsgC, msg_hdr);
  case 52: return OFF(MmsgC, msg_len);
#ifdef _WIN32
  case 60: return sizeof(nn_iovec);
  case 61: return OFF(nn_iovec, base);
  case 62: return OFF(nn_iovec, len);
  case 70: return sizeof(nn_msghdr);
  case 71: return OFF(nn_msghdr, msg_name);
  case 72: return OFF(nn_msghdr, msg_namelen);
  case 73: return OFF(nn_msghdr, msg_iov);
  case 74: return OFF(nn_msghdr, msg_iovlen);
  case 75: return OFF(nn_msghdr, msg_control);
  case 76: return OFF(nn_msghdr, msg_controllen);
  case 77: return OFF(nn_msghdr, msg_flags);
  case 80: return sizeof(nn_ifaddr);
  case 81: return OFF(nn_ifaddr, ip);
  case 82: return OFF(nn_ifaddr, family);
  case 83: return OFF(nn_ifaddr, prefix);
  case 90: return sizeof(nn_ifinfo);
  case 91: return OFF(nn_ifinfo, index);
  case 92: return OFF(nn_ifinfo, name);
  case 93: return OFF(nn_ifinfo, mtu);
  case 94: return OFF(nn_ifinfo, flags);
  case 95: return OFF(nn_ifinfo, naddrs);
  case 96: return OFF(nn_ifinfo, addrs);
#endif
  default: return -1;
  }
}
