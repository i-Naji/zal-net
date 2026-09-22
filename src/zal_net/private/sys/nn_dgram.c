/* Datagram metadata and multicast for zal-net's UdpSocket.
   Control-message parsing (CMSG_*) and struct group_req differ per
   platform (group_req is packed to 4 bytes on macOS), so they live here. */
#ifdef _WIN32
/* Windows: WSARecvMsg for the metadata (the function pointer comes from
   WSAIoctl), WSASendMsg for a chosen source, Winsock's multicast options.
   Failures report POSIX errno values through SetLastError, like nn_win.c. */
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <mswsock.h>
#include <windows.h>
#include <stdint.h>
#include <string.h>

#ifndef IP_RECVTTL
#define IP_RECVTTL 21
#endif
#ifndef IP_RECVTOS
#define IP_RECVTOS 40
#endif
#ifndef IPV6_RECVTCLASS
#define IPV6_RECVTCLASS 40
#endif
#ifndef IPV6_TCLASS
#define IPV6_TCLASS 39
#endif

#include "nn_types.h"

static SOCKET D(int fd) { return (SOCKET)(uintptr_t)(uint32_t)fd; }
static int dfail(void) {
  int e = WSAGetLastError();
  SetLastError(e == WSAEWOULDBLOCK ? 11 : e == WSAEINTR ? 4 : e == WSAENOTSOCK ? 88 :
               e == WSAEINVAL ? 22 : e == WSAENOPROTOOPT ? 92 : e == WSAEADDRNOTAVAIL ? 99 : 5);
  return -1;
}

static LPFN_WSARECVMSG g_recvmsg;

static LPFN_WSARECVMSG recvmsg_fn(SOCKET s) {
  GUID id = WSAID_WSARECVMSG;
  DWORD got = 0;
  LPFN_WSARECVMSG fn = __atomic_load_n(&g_recvmsg, __ATOMIC_ACQUIRE);
  if (fn) return fn;
  if (WSAIoctl(s, SIO_GET_EXTENSION_FUNCTION_POINTER, &id, sizeof id, &fn, sizeof fn,
               &got, NULL, NULL) != 0) return NULL;
  __atomic_store_n(&g_recvmsg, fn, __ATOMIC_RELEASE);
  return fn;
}

static int opt(int fd, int level, int name, int v) {
  DWORD x = (DWORD)v;
  return setsockopt(D(fd), level, name, (const char *)&x, sizeof x) == 0;
}

int nn_dgram_enable_info(int fd) {
  int n = 0;
  n += opt(fd, IPPROTO_IP, IP_PKTINFO, 1);
  n += opt(fd, IPPROTO_IP, IP_RECVTTL, 1);
  n += opt(fd, IPPROTO_IP, IP_RECVTOS, 1);
  n += opt(fd, IPPROTO_IPV6, IPV6_PKTINFO, 1);
  n += opt(fd, IPPROTO_IPV6, IPV6_HOPLIMIT, 1);
  n += opt(fd, IPPROTO_IPV6, IPV6_RECVTCLASS, 1);
  return recvmsg_fn(D(fd)) ? n : 0;
}

long nn_dgram_recv_info(int fd, void *buf, size_t len, void *src, unsigned int *srclen,
                        nn_dinfo *info) {
  union { char b[512]; WSACMSGHDR align; } ctl;
  WSABUF data;
  WSAMSG m;
  WSACMSGHDR *c;
  DWORD got = 0;
  LPFN_WSARECVMSG fn = recvmsg_fn(D(fd));
  memset(info, 0, sizeof *info);
  info->ttl = -1;
  info->tos = -1;
  if (!fn) { SetLastError(95); return -1; }
  data.buf = (char *)buf;
  data.len = (ULONG)len;
  memset(&m, 0, sizeof m);
  m.name = (LPSOCKADDR)src;
  m.namelen = (INT)*srclen;
  m.lpBuffers = &data;
  m.dwBufferCount = 1;
  m.Control.buf = ctl.b;
  m.Control.len = sizeof ctl.b;
  if (fn(D(fd), &m, &got, NULL, NULL) != 0) {
    if (WSAGetLastError() != WSAEMSGSIZE) return dfail();
    info->truncated = 1;
    got = (DWORD)len;
  }
  *srclen = (unsigned)m.namelen;
  if (m.dwFlags & MSG_TRUNC) info->truncated = 1;
  for (c = WSA_CMSG_FIRSTHDR(&m); c != NULL; c = WSA_CMSG_NXTHDR(&m, c)) {
    unsigned char *d = WSA_CMSG_DATA(c);
    if (c->cmsg_level == IPPROTO_IP) {
      if (c->cmsg_type == IP_PKTINFO) {
        IN_PKTINFO pi; memcpy(&pi, d, sizeof pi);
        memcpy(info->dst, &pi.ipi_addr, 4);
        info->dst_family = AF_INET;
        info->ifindex = (unsigned)pi.ipi_ifindex;
      } else if (c->cmsg_type == IP_TTL) {
        int v; memcpy(&v, d, sizeof v); info->ttl = v;
      } else if (c->cmsg_type == IP_TOS) {
        int v; memcpy(&v, d, sizeof v); info->tos = v & 0xff;
      }
    } else if (c->cmsg_level == IPPROTO_IPV6) {
      if (c->cmsg_type == IPV6_PKTINFO) {
        IN6_PKTINFO pi; memcpy(&pi, d, sizeof pi);
        memcpy(info->dst, &pi.ipi6_addr, 16);
        info->dst_family = AF_INET6;
        info->ifindex = (unsigned)pi.ipi6_ifindex;
      } else if (c->cmsg_type == IPV6_HOPLIMIT) {
        int v; memcpy(&v, d, sizeof v); info->ttl = v;
      } else if (c->cmsg_type == IPV6_TCLASS) {
        int v; memcpy(&v, d, sizeof v); info->tos = v & 0xff;
      }
    }
  }
  return (long)got;
}

long nn_dgram_send_from(int fd, const void *buf, size_t len, const void *dst, unsigned int dstlen,
                        const unsigned char *src, int src_family, unsigned int ifindex) {
  union { char b[128]; WSACMSGHDR align; } ctl;
  WSABUF data;
  WSAMSG m;
  WSACMSGHDR *c = (WSACMSGHDR *)ctl.b;
  DWORD sent = 0;
  memset(&ctl, 0, sizeof ctl);
  data.buf = (char *)buf;
  data.len = (ULONG)len;
  memset(&m, 0, sizeof m);
  m.name = (LPSOCKADDR)dst;
  m.namelen = (INT)dstlen;
  m.lpBuffers = &data;
  m.dwBufferCount = 1;
  m.Control.buf = ctl.b;
  if (src_family == AF_INET) {
    IN_PKTINFO pi;
    memset(&pi, 0, sizeof pi);
    memcpy(&pi.ipi_addr, src, 4);
    pi.ipi_ifindex = ifindex;
    c->cmsg_level = IPPROTO_IP;
    c->cmsg_type = IP_PKTINFO;
    c->cmsg_len = WSA_CMSG_LEN(sizeof pi);
    memcpy(WSA_CMSG_DATA(c), &pi, sizeof pi);
    m.Control.len = (ULONG)WSA_CMSG_SPACE(sizeof pi);
  } else {
    IN6_PKTINFO pi;
    memset(&pi, 0, sizeof pi);
    memcpy(&pi.ipi6_addr, src, 16);
    pi.ipi6_ifindex = ifindex;
    c->cmsg_level = IPPROTO_IPV6;
    c->cmsg_type = IPV6_PKTINFO;
    c->cmsg_len = WSA_CMSG_LEN(sizeof pi);
    memcpy(WSA_CMSG_DATA(c), &pi, sizeof pi);
    m.Control.len = (ULONG)WSA_CMSG_SPACE(sizeof pi);
  }
  if (WSASendMsg(D(fd), &m, 0, &sent, NULL, NULL) != 0) return dfail();
  return (long)sent;
}

int nn_mcast_membership(int fd, int join, const void *group, unsigned int grouplen, unsigned int ifindex) {
  int v6 = ((const struct sockaddr *)group)->sa_family == AF_INET6;
  if (ifindex == 0) {
    if (!v6) {
      struct ip_mreq r;
      memset(&r, 0, sizeof r);
      memcpy(&r.imr_multiaddr, &((const struct sockaddr_in *)group)->sin_addr, 4);
      r.imr_interface.s_addr = htonl(INADDR_ANY);
      return setsockopt(D(fd), IPPROTO_IP, join ? IP_ADD_MEMBERSHIP : IP_DROP_MEMBERSHIP,
                        (const char *)&r, sizeof r) == 0 ? 0 : dfail();
    } else {
      struct ipv6_mreq r;
      memset(&r, 0, sizeof r);
      memcpy(&r.ipv6mr_multiaddr, &((const struct sockaddr_in6 *)group)->sin6_addr, 16);
      r.ipv6mr_interface = 0;
      return setsockopt(D(fd), IPPROTO_IPV6, join ? IPV6_ADD_MEMBERSHIP : IPV6_DROP_MEMBERSHIP,
                        (const char *)&r, sizeof r) == 0 ? 0 : dfail();
    }
  } else {
    GROUP_REQ r;
    memset(&r, 0, sizeof r);
    r.gr_interface = ifindex;
    memcpy(&r.gr_group, group, grouplen);
    return setsockopt(D(fd), v6 ? IPPROTO_IPV6 : IPPROTO_IP, join ? MCAST_JOIN_GROUP : MCAST_LEAVE_GROUP,
                      (const char *)&r, sizeof r) == 0 ? 0 : dfail();
  }
}

int nn_mcast_interface(int fd, int v6, unsigned int ifindex) {
  /* IPv4 takes an index as the address 0.0.0.index, in network order. */
  DWORD x = v6 ? (DWORD)ifindex : htonl(ifindex);
  return setsockopt(D(fd), v6 ? IPPROTO_IPV6 : IPPROTO_IP, v6 ? IPV6_MULTICAST_IF : IP_MULTICAST_IF,
                    (const char *)&x, sizeof x) == 0 ? 0 : dfail();
}

int nn_mcast_ttl(int fd, int v6, int ttl) {
  return opt(fd, v6 ? IPPROTO_IPV6 : IPPROTO_IP, v6 ? IPV6_MULTICAST_HOPS : IP_MULTICAST_TTL, ttl) ? 0 : dfail();
}

int nn_mcast_loop(int fd, int v6, int on) {
  return opt(fd, v6 ? IPPROTO_IPV6 : IPPROTO_IP, v6 ? IPV6_MULTICAST_LOOP : IP_MULTICAST_LOOP, on) ? 0 : dfail();
}

#else
#define _GNU_SOURCE
#define __APPLE_USE_RFC_3542 1
#include <string.h>
#include <errno.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#include "nn_types.h"

#ifdef __APPLE__
#  ifndef IP_RECVPKTINFO
#    define IP_RECVPKTINFO 26
#  endif
#endif

/* Ask the kernel to attach destination, interface, TTL/hop limit and
   TOS/traffic class to received datagrams (IPv4 and IPv6 levels, so a
   dual-stack socket reports both). Returns how many options took. */
int nn_dgram_enable_info(int fd) {
  int on = 1, n = 0;
#ifdef IP_PKTINFO
#  ifdef __APPLE__
  n += setsockopt(fd, IPPROTO_IP, IP_RECVPKTINFO, &on, sizeof on) == 0;
#  else
  n += setsockopt(fd, IPPROTO_IP, IP_PKTINFO, &on, sizeof on) == 0;
#  endif
#endif
#ifdef IP_RECVTTL
  n += setsockopt(fd, IPPROTO_IP, IP_RECVTTL, &on, sizeof on) == 0;
#endif
#ifdef IP_RECVTOS
  n += setsockopt(fd, IPPROTO_IP, IP_RECVTOS, &on, sizeof on) == 0;
#endif
#ifdef IPV6_RECVPKTINFO
  n += setsockopt(fd, IPPROTO_IPV6, IPV6_RECVPKTINFO, &on, sizeof on) == 0;
#endif
#ifdef IPV6_RECVHOPLIMIT
  n += setsockopt(fd, IPPROTO_IPV6, IPV6_RECVHOPLIMIT, &on, sizeof on) == 0;
#endif
#ifdef IPV6_RECVTCLASS
  n += setsockopt(fd, IPPROTO_IPV6, IPV6_RECVTCLASS, &on, sizeof on) == 0;
#endif
  return n;
}

/* One datagram with its metadata. Returns its length, or -1 with errno. */
long nn_dgram_recv_info(int fd, void *buf, size_t len, void *src, unsigned int *srclen,
                        nn_dinfo *info) {
  union { char b[512]; struct cmsghdr align; } ctl;
  struct iovec iov = { buf, len };
  struct msghdr m;
  struct cmsghdr *c;
  long n;
  memset(&m, 0, sizeof m);
  m.msg_name = src;
  m.msg_namelen = *srclen;
  m.msg_iov = &iov;
  m.msg_iovlen = 1;
  m.msg_control = ctl.b;
  m.msg_controllen = sizeof ctl.b;
  n = recvmsg(fd, &m, 0);
  if (n < 0) return -1;
  *srclen = m.msg_namelen;
  memset(info, 0, sizeof *info);
  info->ttl = -1;
  info->tos = -1;
  info->truncated = (m.msg_flags & MSG_TRUNC) != 0;
  for (c = CMSG_FIRSTHDR(&m); c != NULL; c = CMSG_NXTHDR(&m, c)) {
    unsigned char *d = CMSG_DATA(c);
    if (c->cmsg_level == IPPROTO_IP) {
#ifdef IP_PKTINFO
      if (c->cmsg_type == IP_PKTINFO) {
        struct in_pktinfo pi; memcpy(&pi, d, sizeof pi);
        memcpy(info->dst, &pi.ipi_addr, 4);
        info->dst_family = AF_INET;
        info->ifindex = (unsigned int)pi.ipi_ifindex;
      }
#endif
#if defined(IP_TTL) && !defined(__APPLE__)
      if (c->cmsg_type == IP_TTL) { int v; memcpy(&v, d, sizeof v); info->ttl = v; }
#endif
#ifdef __APPLE__
      if (c->cmsg_type == IP_RECVTTL) info->ttl = d[0];
      if (c->cmsg_type == IP_RECVTOS) info->tos = d[0];
#else
#  ifdef IP_TOS
      if (c->cmsg_type == IP_TOS) info->tos = d[0];
#  endif
#endif
    } else if (c->cmsg_level == IPPROTO_IPV6) {
#ifdef IPV6_PKTINFO
      if (c->cmsg_type == IPV6_PKTINFO) {
        struct in6_pktinfo pi; memcpy(&pi, d, sizeof pi);
        memcpy(info->dst, &pi.ipi6_addr, 16);
        info->dst_family = AF_INET6;
        info->ifindex = (unsigned int)pi.ipi6_ifindex;
      }
#endif
#ifdef IPV6_HOPLIMIT
      if (c->cmsg_type == IPV6_HOPLIMIT) { int v; memcpy(&v, d, sizeof v); info->ttl = v; }
#endif
#ifdef IPV6_TCLASS
      if (c->cmsg_type == IPV6_TCLASS) { int v; memcpy(&v, d, sizeof v); info->tos = v; }
#endif
    }
  }
  return n;
}

/* Send from a chosen source address (and interface): IP_PKTINFO or
   IPV6_PKTINFO. `src` is 4 or 16 bytes per `src_family`. */
long nn_dgram_send_from(int fd, const void *buf, size_t len, const void *dst, unsigned int dstlen,
                        const unsigned char *src, int src_family, unsigned int ifindex) {
  union { char b[128]; struct cmsghdr align; } ctl;
  struct iovec iov = { (void *)buf, len };
  struct msghdr m;
  struct cmsghdr *c;
  memset(&m, 0, sizeof m);
  memset(&ctl, 0, sizeof ctl);
  m.msg_name = (void *)dst;
  m.msg_namelen = dstlen;
  m.msg_iov = &iov;
  m.msg_iovlen = 1;
  m.msg_control = ctl.b;
  c = (struct cmsghdr *)ctl.b;
  if (src_family == AF_INET) {
#ifdef IP_PKTINFO
    struct in_pktinfo pi;
    memset(&pi, 0, sizeof pi);
    memcpy(&pi.ipi_spec_dst, src, 4);
    pi.ipi_ifindex = ifindex;
    c->cmsg_level = IPPROTO_IP;
    c->cmsg_type = IP_PKTINFO;
    c->cmsg_len = CMSG_LEN(sizeof pi);
    memcpy(CMSG_DATA(c), &pi, sizeof pi);
    m.msg_controllen = CMSG_SPACE(sizeof pi);
#else
    errno = EOPNOTSUPP; return -1;
#endif
  } else {
    struct in6_pktinfo pi;
    memset(&pi, 0, sizeof pi);
    memcpy(&pi.ipi6_addr, src, 16);
    pi.ipi6_ifindex = ifindex;
    c->cmsg_level = IPPROTO_IPV6;
    c->cmsg_type = IPV6_PKTINFO;
    c->cmsg_len = CMSG_LEN(sizeof pi);
    memcpy(CMSG_DATA(c), &pi, sizeof pi);
    m.msg_controllen = CMSG_SPACE(sizeof pi);
  }
  return sendmsg(fd, &m, 0);
}

/* Join (join = 1) or leave a multicast group on interface `ifindex`
   (0: the kernel's choice). `group` is a sockaddr of the group's family. */
int nn_mcast_membership(int fd, int join, const void *group, unsigned int grouplen, unsigned int ifindex) {
  struct group_req r;
  int v6 = ((const struct sockaddr *)group)->sa_family == AF_INET6;
  int level = v6 ? IPPROTO_IPV6 : IPPROTO_IP;
  if (ifindex == 0) {
    /* The kernel's choice of interface: the classic calls take "any". */
    if (!v6) {
      struct ip_mreq m;
      memset(&m, 0, sizeof m);
      memcpy(&m.imr_multiaddr, &((const struct sockaddr_in *)group)->sin_addr, 4);
      m.imr_interface.s_addr = htonl(INADDR_ANY);
      return setsockopt(fd, IPPROTO_IP, join ? IP_ADD_MEMBERSHIP : IP_DROP_MEMBERSHIP, &m, sizeof m);
    } else {
      struct ipv6_mreq m;
      memset(&m, 0, sizeof m);
      memcpy(&m.ipv6mr_multiaddr, &((const struct sockaddr_in6 *)group)->sin6_addr, 16);
      m.ipv6mr_interface = 0;
      return setsockopt(fd, IPPROTO_IPV6, join ? IPV6_JOIN_GROUP : IPV6_LEAVE_GROUP, &m, sizeof m);
    }
  }
  memset(&r, 0, sizeof r);
  r.gr_interface = ifindex;
  memcpy(&r.gr_group, group, grouplen);
  return setsockopt(fd, level, join ? MCAST_JOIN_GROUP : MCAST_LEAVE_GROUP, &r, sizeof r);
}

/* The interface outgoing multicast leaves through. */
int nn_mcast_interface(int fd, int v6, unsigned int ifindex) {
  if (v6) return setsockopt(fd, IPPROTO_IPV6, IPV6_MULTICAST_IF, &ifindex, sizeof ifindex);
#ifdef __APPLE__
  return setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IFINDEX, &ifindex, sizeof ifindex);
#else
  struct ip_mreqn r;
  memset(&r, 0, sizeof r);
  r.imr_ifindex = (int)ifindex;
  return setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &r, sizeof r);
#endif
}

int nn_mcast_ttl(int fd, int v6, int ttl) {
  if (v6) return setsockopt(fd, IPPROTO_IPV6, IPV6_MULTICAST_HOPS, &ttl, sizeof ttl);
  unsigned char t = (unsigned char)ttl;
  return setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &t, sizeof t);
}

int nn_mcast_loop(int fd, int v6, int on) {
  if (v6) { unsigned int v = (unsigned int)on; return setsockopt(fd, IPPROTO_IPV6, IPV6_MULTICAST_LOOP, &v, sizeof v); }
  unsigned char v = (unsigned char)on;
  return setsockopt(fd, IPPROTO_IP, IP_MULTICAST_LOOP, &v, sizeof v);
}
#endif
