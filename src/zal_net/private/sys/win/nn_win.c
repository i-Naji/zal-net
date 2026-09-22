/* zal-net's Windows platform layer: Winsock behind POSIX-shaped calls.

   Byte counts are intptr_t: Windows is LLP64, so a C long (32 bits) would
   not match the Nim int the bindings declare.

   Descriptors are SOCKETs narrowed to int, as in Nimony's std/ioring: they
   are kernel handles, 4-aligned and well inside 31 bits. Every call that
   fails stores a POSIX errno value (Linux numbering) with SetLastError, so
   the Nim side's osLastError() and its EAGAIN/EINTR checks work unchanged.
   Winsock is started by a constructor, before any Nim code runs. */
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <mswsock.h>
#include <mstcpip.h>
#include <windows.h>
#include <timeapi.h>
#include <iphlpapi.h>
#include <icmpapi.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <limits.h>

#include "../nn_types.h"                /* nn_iovec, nn_pollfd, nn_msghdr, nn_ifinfo... */

#ifndef SIO_UDP_CONNRESET
#define SIO_UDP_CONNRESET _WSAIOW(IOC_VENDOR, 12)
#endif
#ifndef SIO_UDP_NETRESET
#define SIO_UDP_NETRESET _WSAIOW(IOC_VENDOR, 15)
#endif

static SOCKET S(int fd) { return (SOCKET)(uintptr_t)(uint32_t)fd; }

static int map_wsa(int e) {
  switch (e) {
  case WSAEWOULDBLOCK: return 11;      /* EAGAIN */
  case WSAEINTR: return 4;
  case WSAEINPROGRESS: return 115;
  case WSAEALREADY: return 114;
  case WSAECONNRESET: return 104;
  case WSAECONNREFUSED: return 111;
  case WSAECONNABORTED: return 103;
  case WSAETIMEDOUT: return 110;
  case WSAENOTCONN: return 107;
  case WSAESHUTDOWN: return 32;        /* EPIPE: send after shutdown */
  case WSAEBADF: case WSA_INVALID_HANDLE: return 9;
  case WSAENOTSOCK: return 88;
  case WSAEINVAL: return 22;
  case WSAEMFILE: return 24;
  case WSAENOBUFS: return 105;
  case WSAEADDRINUSE: return 98;
  case WSAEADDRNOTAVAIL: return 99;
  case WSAENETUNREACH: return 101;
  case WSAEHOSTUNREACH: return 113;
  case WSAENETDOWN: return 100;
  case WSAENETRESET: return 102;
  case WSAEHOSTDOWN: return 112;
  case WSAEMSGSIZE: return 90;
  case WSAEACCES: return 13;
  case WSAEAFNOSUPPORT: return 97;
  case WSAEPFNOSUPPORT: return 96;
  case WSAEPROTONOSUPPORT: return 93;
  case WSAESOCKTNOSUPPORT: return 94;
  case WSAEOPNOTSUPP: return 95;
  case WSAEISCONN: return 106;
  case WSAEDESTADDRREQ: return 89;
  case WSAEFAULT: return 14;
  case WSA_OPERATION_ABORTED: return 125;   /* ECANCELED */
  case WSAEDISCON: return 104;
  case ERROR_NOT_ENOUGH_MEMORY: return 12;
  default: return e > 0 && e < 200 ? e : 5;  /* EIO */
  }
}

static int fail(void) { SetLastError((DWORD)map_wsa(WSAGetLastError())); return -1; }
static intptr_t failL(void) { fail(); return -1; }

/* ------------------------------------------------------------- startup */

#ifndef PROCESS_POWER_THROTTLING_IGNORE_TIMER_RESOLUTION
#define PROCESS_POWER_THROTTLING_IGNORE_TIMER_RESOLUTION 0x4
#endif

/* Winsock, and 1 ms timers: waits (epoll_wait, condition variables,
   Sleep) otherwise round up to the 15.6 ms scheduler tick. Since Windows
   10 2004 this affects only this process; Windows 11 ignores it for a
   process without a visible window unless the process opts out of that
   power throttling, which a server has to. */
__attribute__((constructor)) static void nn_win_start(void) {
  WSADATA d;
  PROCESS_POWER_THROTTLING_STATE st;
  WSAStartup(MAKEWORD(2, 2), &d);
  memset(&st, 0, sizeof st);
  st.Version = PROCESS_POWER_THROTTLING_CURRENT_VERSION;
  st.ControlMask = PROCESS_POWER_THROTTLING_IGNORE_TIMER_RESOLUTION;
  st.StateMask = 0;
  SetProcessInformation(GetCurrentProcess(), ProcessPowerThrottling, &st, sizeof st);
  timeBeginPeriod(1);
}

/* ------------------------------------------------------------- sockets */

/* An ICMP port-unreachable (or TTL expired) would fail the next receive
   on a UDP socket with WSAECONNRESET (WSAENETRESET); POSIX sockets never
   do that to an unconnected socket. */
static void udp_quiet(SOCKET s) {
  BOOL off = FALSE;
  DWORD got = 0;
  WSAIoctl(s, SIO_UDP_CONNRESET, &off, sizeof off, NULL, 0, &got, NULL, NULL);
  WSAIoctl(s, SIO_UDP_NETRESET, &off, sizeof off, NULL, 0, &got, NULL, NULL);
}

static SOCKET new_socket(int af, int type, int proto, DWORD flags) {
  return WSASocketW(af, type, proto, NULL, 0, flags | WSA_FLAG_NO_HANDLE_INHERIT);
}

int nn_sock_socket(int af, int type, int proto) {
  SOCKET s = new_socket(af, type, proto, WSA_FLAG_OVERLAPPED);
  if (s == INVALID_SOCKET) return fail();
  if (type == SOCK_DGRAM) udp_quiet(s);
  return (int)(uint32_t)(uintptr_t)s;
}

int nn_sock_close(int fd) { return closesocket(S(fd)) == 0 ? 0 : fail(); }

int nn_sock_nonblock(int fd, int on) {
  u_long v = on ? 1 : 0;
  return ioctlsocket(S(fd), FIONBIO, &v) == 0 ? 0 : fail();
}

int nn_sock_bind(int fd, const void *sa, unsigned len) {
  return bind(S(fd), (const struct sockaddr *)sa, (int)len) == 0 ? 0 : fail();
}

int nn_sock_connect(int fd, const void *sa, unsigned len) {
  if (connect(S(fd), (const struct sockaddr *)sa, (int)len) == 0) return 0;
  if (WSAGetLastError() == WSAEWOULDBLOCK) { SetLastError(115); return -1; }  /* EINPROGRESS */
  return fail();
}

int nn_sock_listen(int fd, int backlog) { return listen(S(fd), backlog) == 0 ? 0 : fail(); }

int nn_sock_accept(int fd, void *sa, unsigned *len) {
  int l = len ? (int)*len : 0;
  SOCKET s = accept(S(fd), (struct sockaddr *)sa, len ? &l : NULL);
  u_long one = 1;
  if (s == INVALID_SOCKET) return fail();
  if (len) *len = (unsigned)l;
  ioctlsocket(s, FIONBIO, &one);
  SetHandleInformation((HANDLE)s, HANDLE_FLAG_INHERIT, 0);
  return (int)(uint32_t)(uintptr_t)s;
}

int nn_sock_shutdown(int fd, int how) { return shutdown(S(fd), how) == 0 ? 0 : fail(); }

int nn_sock_setsockopt(int fd, int level, int opt, const void *v, unsigned len) {
  return setsockopt(S(fd), level, opt, (const char *)v, (int)len) == 0 ? 0 : fail();
}

int nn_sock_getsockopt(int fd, int level, int opt, void *v, unsigned *len) {
  int l = (int)*len;
  if (getsockopt(S(fd), level, opt, (char *)v, &l) != 0) return fail();
  if (level == SOL_SOCKET && opt == SO_ERROR && l == sizeof(int)) {
    int error;
    memcpy(&error, v, sizeof(error));
    if (error != 0) { error = map_wsa(error); memcpy(v, &error, sizeof(error)); }
  }
  *len = (unsigned)l;
  return 0;
}

int nn_sock_getsockname(int fd, void *sa, unsigned *len) {
  int l = (int)*len;
  if (getsockname(S(fd), (struct sockaddr *)sa, &l) != 0) return fail();
  *len = (unsigned)l;
  return 0;
}

int nn_sock_getpeername(int fd, void *sa, unsigned *len) {
  int l = (int)*len;
  if (getpeername(S(fd), (struct sockaddr *)sa, &l) != 0) return fail();
  *len = (unsigned)l;
  return 0;
}

/* Flags other than MSG_PEEK/MSG_OOB mean nothing to Winsock (sockets are
   non-blocking already); they are dropped. */
static int wflags(int f) { return f & (MSG_PEEK | MSG_OOB); }

intptr_t nn_sock_recv(int fd, void *buf, size_t n, int flags) {
  int k = recv(S(fd), (char *)buf, n > INT_MAX ? INT_MAX : (int)n, wflags(flags));
  if (k >= 0) return k;
  switch (WSAGetLastError()) {
  case WSAEMSGSIZE: return (intptr_t)n;   /* datagram truncated */
  case WSAESHUTDOWN: return 0;            /* reading shut down here: end of stream, as on POSIX */
  default: return failL();
  }
}

intptr_t nn_sock_send(int fd, const void *buf, size_t n, int flags) {
  int k = send(S(fd), (const char *)buf, n > INT_MAX ? INT_MAX : (int)n, wflags(flags));
  return k >= 0 ? k : failL();
}

intptr_t nn_sock_read(int fd, void *buf, size_t n) { return nn_sock_recv(fd, buf, n, 0); }
intptr_t nn_sock_write(int fd, const void *buf, size_t n) { return nn_sock_send(fd, buf, n, 0); }

intptr_t nn_sock_recvfrom(int fd, void *buf, size_t n, int flags, void *sa, unsigned *len) {
  int l = len ? (int)*len : 0;
  int k = recvfrom(S(fd), (char *)buf, n > INT_MAX ? INT_MAX : (int)n, wflags(flags),
                   (struct sockaddr *)sa, len ? &l : NULL);
  if (k < 0) {
    if (WSAGetLastError() != WSAEMSGSIZE) return failL();
    k = (int)n;
  }
  if (len) *len = (unsigned)l;
  return k;
}

intptr_t nn_sock_sendto(int fd, const void *buf, size_t n, int flags, const void *sa, unsigned len) {
  int k = sendto(S(fd), (const char *)buf, n > INT_MAX ? INT_MAX : (int)n, wflags(flags),
                 (const struct sockaddr *)sa, (int)len);
  return k >= 0 ? k : failL();
}

#define NN_IOV_MAX 64

intptr_t nn_sock_readv(int fd, const nn_iovec *iov, int cnt) {
  WSABUF b[NN_IOV_MAX];
  DWORD got = 0, flags = 0;
  int i;
  if (cnt > NN_IOV_MAX) cnt = NN_IOV_MAX;
  for (i = 0; i < cnt; i++) { b[i].buf = (char *)iov[i].base; b[i].len = (ULONG)iov[i].len; }
  if (WSARecv(S(fd), b, (DWORD)cnt, &got, &flags, NULL, NULL) != 0) {
    int e = WSAGetLastError();
    if (e == WSAEDISCON || e == WSAESHUTDOWN) return 0;   /* end of stream, as on POSIX */
    return failL();
  }
  return (intptr_t)got;
}

intptr_t nn_sock_writev(int fd, const nn_iovec *iov, int cnt) {
  WSABUF b[NN_IOV_MAX];
  DWORD sent = 0;
  int i;
  if (cnt > NN_IOV_MAX) cnt = NN_IOV_MAX;
  for (i = 0; i < cnt; i++) { b[i].buf = (char *)iov[i].base; b[i].len = (ULONG)iov[i].len; }
  if (WSASend(S(fd), b, (DWORD)cnt, &sent, 0, NULL, NULL) != 0) return failL();
  return (intptr_t)sent;
}

/* poll(2) over WSAPoll, whose event bits differ: the POSIX ones (POLLIN 1,
   POLLOUT 4; POLLERR 8, POLLHUP 16, POLLNVAL 32 back) are translated. */
int nn_sock_poll(nn_pollfd *fds, int n, int timeout_ms) {
  WSAPOLLFD p[64];
  int i, r;
  if (n > 64) n = 64;
  for (i = 0; i < n; i++) {
    SHORT ev = 0;
    if (fds[i].events & 1) ev |= POLLRDNORM;
    if (fds[i].events & 4) ev |= POLLWRNORM;
    p[i].fd = S(fds[i].fd);
    p[i].events = ev;
    p[i].revents = 0;
  }
  r = WSAPoll(p, (ULONG)n, timeout_ms);
  if (r < 0) return fail();
  for (i = 0; i < n; i++) {
    SHORT re = p[i].revents, out = 0;
    if (re & (POLLRDNORM | POLLRDBAND)) out |= 1;
    if (re & POLLWRNORM) out |= 4;
    if (re & POLLERR) out |= 8;
    if (re & POLLHUP) out |= 16;
    if (re & POLLNVAL) out |= 32;
    fds[i].revents = out;
  }
  return r;
}

/* A connected pair of TCP sockets over loopback (socketpair). */
int nn_sock_pair(int *out) {
  SOCKET l = INVALID_SOCKET, a = INVALID_SOCKET, c = INVALID_SOCKET;
  struct sockaddr_in sa;
  int len = sizeof sa;
  u_long one = 1;
  memset(&sa, 0, sizeof sa);
  sa.sin_family = AF_INET;
  sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  l = new_socket(AF_INET, SOCK_STREAM, 0, 0);
  if (l == INVALID_SOCKET) goto bad;
  if (bind(l, (struct sockaddr *)&sa, sizeof sa) != 0 || listen(l, 1) != 0) goto bad;
  if (getsockname(l, (struct sockaddr *)&sa, &len) != 0) goto bad;
  c = new_socket(AF_INET, SOCK_STREAM, 0, WSA_FLAG_OVERLAPPED);
  if (c == INVALID_SOCKET || connect(c, (struct sockaddr *)&sa, sizeof sa) != 0) goto bad;
  a = accept(l, NULL, NULL);
  if (a == INVALID_SOCKET) goto bad;
  closesocket(l);
  ioctlsocket(a, FIONBIO, &one);
  ioctlsocket(c, FIONBIO, &one);
  SetHandleInformation((HANDLE)a, HANDLE_FLAG_INHERIT, 0);
  out[0] = (int)(uint32_t)(uintptr_t)a;
  out[1] = (int)(uint32_t)(uintptr_t)c;
  return 0;
bad:
  fail();
  if (l != INVALID_SOCKET) closesocket(l);
  if (c != INVALID_SOCKET) closesocket(c);
  return -1;
}

/* -------------------------------------------------------- mmsg batches */

/* recvmmsg/sendmmsg as loops, over the Nim MsgHdr/MmsgHdr (the Linux
   layout, nn_types.h; one buffer per datagram, which is how zal-net
   fills them). */

int nn_recvmmsg(int fd, nn_mmsghdr *v, unsigned vlen, int flags, void *timeout) {
  unsigned i;
  int count = 0;
  (void)flags; (void)timeout;
  for (i = 0; i < vlen; i++) {
    nn_msghdr *h = &v[i].msg_hdr;
    int l = (int)h->msg_namelen;
    int k = recvfrom(S(fd), (char *)h->msg_iov[0].base, (int)h->msg_iov[0].len, 0,
                     (struct sockaddr *)h->msg_name, h->msg_name ? &l : NULL);
    h->msg_flags = 0;
    if (k < 0) {
      if (WSAGetLastError() == WSAEMSGSIZE) {
        k = (int)h->msg_iov[0].len;
        h->msg_flags = 0x20;             /* MSG_TRUNC */
      } else {
        if (count == 0) return fail();
        break;
      }
    }
    if (h->msg_name) h->msg_namelen = (unsigned)l;
    h->msg_controllen = 0;
    v[i].msg_len = (unsigned)k;
    count++;
  }
  return count;
}

int nn_sendmmsg(int fd, nn_mmsghdr *v, unsigned vlen, int flags) {
  unsigned i;
  int count = 0;
  (void)flags;
  for (i = 0; i < vlen; i++) {
    nn_msghdr *h = &v[i].msg_hdr;
    int k = h->msg_name
      ? sendto(S(fd), (const char *)h->msg_iov[0].base, (int)h->msg_iov[0].len, 0,
               (const struct sockaddr *)h->msg_name, (int)h->msg_namelen)
      : send(S(fd), (const char *)h->msg_iov[0].base, (int)h->msg_iov[0].len, 0);
    if (k < 0) {
      if (count == 0) return fail();
      break;
    }
    v[i].msg_len = (unsigned)k;
    count++;
  }
  return count;
}

/* TCP keepalive through SIO_KEEPALIVE_VALS (Windows 2000 on), for systems
   without TCP_KEEPIDLE/TCP_KEEPINTVL (before Windows 10 1709). The probe
   count is the system's (10). */
int nn_keepalive_vals(int fd, int on, int idle_ms, int interval_ms) {
  struct tcp_keepalive k;
  DWORD got = 0;
  k.onoff = on ? 1 : 0;
  k.keepalivetime = (ULONG)idle_ms;
  k.keepaliveinterval = (ULONG)interval_ms;
  return WSAIoctl(S(fd), SIO_KEEPALIVE_VALS, &k, sizeof k, NULL, 0, &got, NULL, NULL) == 0 ? 0 : fail();
}

/* --------------------------------------------------------------- wakes */

/* A wake channel: one UDP socket on loopback, connected to itself. `r` and
   `w` are the same socket. Pollable like any socket. */
int nn_wake_pair(int *r, int *w) {
  SOCKET s = new_socket(AF_INET, SOCK_DGRAM, 0, WSA_FLAG_OVERLAPPED);
  struct sockaddr_in sa;
  int len = sizeof sa;
  u_long one = 1;
  if (s == INVALID_SOCKET) return fail();
  memset(&sa, 0, sizeof sa);
  sa.sin_family = AF_INET;
  sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (bind(s, (struct sockaddr *)&sa, sizeof sa) != 0 ||
      getsockname(s, (struct sockaddr *)&sa, &len) != 0 ||
      connect(s, (struct sockaddr *)&sa, sizeof sa) != 0) {
    fail();
    closesocket(s);
    return -1;
  }
  ioctlsocket(s, FIONBIO, &one);
  udp_quiet(s);
  *r = *w = (int)(uint32_t)(uintptr_t)s;
  return 0;
}

void nn_wake_signal(int w) {
  char b = 1;
  send(S(w), &b, 1, 0);
}

void nn_wake_drain(int r) {
  char buf[64];
  while (recv(S(r), buf, sizeof buf, 0) > 0) {}
}

/* ------------------------------------------------------------- process */

int nn_getpid(void) { return (int)GetCurrentProcessId(); }

void nn_sleep_us(unsigned us) { Sleep(us < 1000 ? 1 : us / 1000); }

void *nn_map_anon(size_t len) {
  return VirtualAlloc(NULL, len, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
}

void nn_unmap_anon(void *p, size_t len) {
  (void)len;
  if (p) VirtualFree(p, 0, MEM_RELEASE);
}

/* Wall-clock nanoseconds since the Unix epoch. */
int64_t nn_realtime_ns(void) {
  FILETIME ft;
  ULARGE_INTEGER u;
  GetSystemTimePreciseAsFileTime(&ft);
  u.LowPart = ft.dwLowDateTime;
  u.HighPart = ft.dwHighDateTime;
  return ((int64_t)u.QuadPart - 116444736000000000LL) * 100;
}

/* ------------------------------------------------------------ resolver */

int nn_inet_pton(int af, const char *src, void *dst) { return inet_pton(af, src, dst); }

const char *nn_inet_ntop(int af, const void *src, char *dst, unsigned size) {
  return inet_ntop(af, src, dst, (size_t)size);
}

int nn_getaddrinfo(const char *node, const char *service, const struct addrinfo *hints,
                   struct addrinfo **res) {
  return getaddrinfo(node, service, hints, res);
}

void nn_freeaddrinfo(struct addrinfo *res) { freeaddrinfo(res); }

const char *nn_gai_strerror(int err) { return gai_strerrorA(err); }

/* ---------------------------------------------------------- interfaces */

/* nn_ifaddr and nn_ifinfo: nn_types.h. */

/* Up to `max` interfaces into `out`: how many, or -1. */
int nn_if_list(nn_ifinfo *out, int max) {
  ULONG size = 16384, rc;
  IP_ADAPTER_ADDRESSES *all = NULL, *a;
  int n = 0, tries;
  for (tries = 0; tries < 4; tries++) {
    all = (IP_ADAPTER_ADDRESSES *)malloc(size);
    if (!all) return -1;
    rc = GetAdaptersAddresses(AF_UNSPEC, GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST |
                              GAA_FLAG_SKIP_DNS_SERVER, NULL, all, &size);
    if (rc == ERROR_SUCCESS) break;
    free(all);
    all = NULL;
    if (rc != ERROR_BUFFER_OVERFLOW) return -1;
  }
  if (!all) return -1;
  for (a = all; a != NULL && n < max; a = a->Next) {
    nn_ifinfo *o = &out[n++];
    IP_ADAPTER_UNICAST_ADDRESS *u;
    memset(o, 0, sizeof *o);
    o->index = a->IfIndex ? a->IfIndex : a->Ipv6IfIndex;
    WideCharToMultiByte(CP_UTF8, 0, a->FriendlyName, -1, o->name, sizeof o->name - 1, NULL, NULL);
    o->mtu = a->Mtu == 0xffffffffu ? -1 : (int)a->Mtu;
    if (a->OperStatus == IfOperStatusUp) o->flags |= 1u | 16u;
    if (a->IfType == IF_TYPE_SOFTWARE_LOOPBACK) o->flags |= 4u;
    else if (a->IfType == IF_TYPE_PPP || a->IfType == IF_TYPE_TUNNEL) o->flags |= 8u;
    else o->flags |= 2u;
    if (!(a->Flags & IP_ADAPTER_NO_MULTICAST)) o->flags |= 32u;
    for (u = a->FirstUnicastAddress; u != NULL && o->naddrs < NN_IF_ADDRS; u = u->Next) {
      struct sockaddr *sa = u->Address.lpSockaddr;
      nn_ifaddr *d = &o->addrs[o->naddrs];
      if (sa->sa_family == AF_INET) {
        memcpy(d->ip, &((struct sockaddr_in *)sa)->sin_addr, 4);
      } else if (sa->sa_family == AF_INET6) {
        memcpy(d->ip, &((struct sockaddr_in6 *)sa)->sin6_addr, 16);
      } else continue;
      d->family = sa->sa_family;
      d->prefix = u->OnLinkPrefixLength;
      o->naddrs++;
    }
  }
  free(all);
  return n;
}

/* Interface configuration, by alias (the friendly name). */
static int nn_if_luid(const char *name, NET_LUID *luid) {
  WCHAR w[IF_MAX_STRING_SIZE + 1];
  if (!MultiByteToWideChar(CP_UTF8, 0, name, -1, w, IF_MAX_STRING_SIZE + 1)) return -1;
  return ConvertInterfaceAliasToLuid(w, luid) == NO_ERROR ? 0 : -1;
}

/* 1 when the interface is up, 0 when it is not, -1 when there is none. */
int nn_if_is_up(const char *name) {
  NET_LUID luid;
  MIB_IF_ROW2 row;
  if (nn_if_luid(name, &luid) != 0) return -1;
  memset(&row, 0, sizeof row);
  row.InterfaceLuid = luid;
  if (GetIfEntry2(&row) != NO_ERROR) return -1;
  return row.OperStatus == IfOperStatusUp;
}

/* The IPv4 and IPv6 MTU (either may be off on the interface): 0, or -1. */
int nn_if_set_mtu(const char *name, int mtu) {
  static const ADDRESS_FAMILY fams[2] = {AF_INET, AF_INET6};
  NET_LUID luid;
  int i, done = 0;
  if (nn_if_luid(name, &luid) != 0) return -1;
  for (i = 0; i < 2; i++) {
    MIB_IPINTERFACE_ROW row;
    InitializeIpInterfaceEntry(&row);
    row.Family = fams[i];
    row.InterfaceLuid = luid;
    if (GetIpInterfaceEntry(&row) != NO_ERROR) continue;
    row.NlMtu = (ULONG)mtu;
    row.SitePrefixLength = 0;           /* Set refuses IPv4 rows otherwise */
    if (SetIpInterfaceEntry(&row) == NO_ERROR) done = 1;
  }
  return done ? 0 : -1;
}

/* An IPv4 address (usable at once: no duplicate detection) and, with a
   peer, an on-link route to it: a point-to-point link. 0, or -1. */
int nn_if_add_addr4(const char *name, const unsigned char *ip, int prefix, const unsigned char *peer) {
  NET_LUID luid;
  MIB_UNICASTIPADDRESS_ROW row;
  DWORD rc;
  if (nn_if_luid(name, &luid) != 0) return -1;
  InitializeUnicastIpAddressEntry(&row);
  row.InterfaceLuid = luid;
  row.Address.Ipv4.sin_family = AF_INET;
  memcpy(&row.Address.Ipv4.sin_addr, ip, 4);
  row.OnLinkPrefixLength = (UINT8)prefix;
  row.DadState = IpDadStatePreferred;
  rc = CreateUnicastIpAddressEntry(&row);
  if (rc != NO_ERROR && rc != ERROR_OBJECT_ALREADY_EXISTS) return -1;
  if (peer[0] | peer[1] | peer[2] | peer[3]) {
    MIB_IPFORWARD_ROW2 r;
    InitializeIpForwardEntry(&r);
    r.InterfaceLuid = luid;
    r.DestinationPrefix.Prefix.Ipv4.sin_family = AF_INET;
    memcpy(&r.DestinationPrefix.Prefix.Ipv4.sin_addr, peer, 4);
    r.DestinationPrefix.PrefixLength = 32;
    r.NextHop.Ipv4.sin_family = AF_INET;   /* 0.0.0.0: on-link */
    r.Metric = 0;
    rc = CreateIpForwardEntry2(&r);
    if (rc != NO_ERROR && rc != ERROR_OBJECT_ALREADY_EXISTS) return -1;
  }
  return 0;
}

/* ---------------------------------------------------------------- ping */

/* One echo request through the ICMP helper API (no privileges needed);
   blocks up to `timeout_ms`. 0 with `src`, `rtt_ms` and `ttl` (-1 for
   IPv6) filled, -110 on a timeout, -1 for any other failure. */
int nn_icmp_echo(int v6, const unsigned char *dst, int timeout_ms, int payload,
                 unsigned char *src, int *rtt_ms, int *ttl) {
  char data[1400];
  char reply[sizeof(ICMPV6_ECHO_REPLY) + sizeof(ICMP_ECHO_REPLY) + 1400 + 64];
  HANDLE h;
  DWORD n;
  int i;
  if (payload < 0) payload = 0;
  if (payload > (int)sizeof data) payload = (int)sizeof data;
  for (i = 0; i < payload; i++) data[i] = (char)(i & 0xff);
  *ttl = -1;
  if (!v6) {
    IPAddr a;
    ICMP_ECHO_REPLY *r = (ICMP_ECHO_REPLY *)reply;
    memcpy(&a, dst, 4);
    h = IcmpCreateFile();
    if (h == INVALID_HANDLE_VALUE) return -1;
    n = IcmpSendEcho(h, a, data, (WORD)payload, NULL, reply, sizeof reply, (DWORD)timeout_ms);
    i = n == 0 ? (GetLastError() == IP_REQ_TIMED_OUT ? -110 : -1)
               : r->Status == IP_SUCCESS ? 0 : r->Status == IP_REQ_TIMED_OUT ? -110 : -1;
    if (i == 0) {
      memcpy(src, &r->Address, 4);
      *rtt_ms = (int)r->RoundTripTime;
      *ttl = r->Options.Ttl;
    }
    IcmpCloseHandle(h);
    return i;
  } else {
    struct sockaddr_in6 from, to;
    ICMPV6_ECHO_REPLY *r = (ICMPV6_ECHO_REPLY *)reply;
    memset(&from, 0, sizeof from);
    memset(&to, 0, sizeof to);
    from.sin6_family = to.sin6_family = AF_INET6;
    memcpy(&to.sin6_addr, dst, 16);
    h = Icmp6CreateFile();
    if (h == INVALID_HANDLE_VALUE) return -1;
    n = Icmp6SendEcho2(h, NULL, NULL, NULL, &from, &to, data, (WORD)payload, NULL,
                       reply, sizeof reply, (DWORD)timeout_ms);
    if (n > 0) n = Icmp6ParseReplies(reply, sizeof reply);
    i = n == 0 ? (GetLastError() == IP_REQ_TIMED_OUT ? -110 : -1)
               : r->Status == IP_SUCCESS ? 0 : r->Status == IP_REQ_TIMED_OUT ? -110 : -1;
    if (i == 0) {
      memcpy(src, r->Address.sin6_addr, 16);
      *rtt_ms = (int)r->RoundTripTime;
    }
    IcmpCloseHandle(h);
    return i;
  }
}

/* ------------------------------------------------------------- console */

#define NN_CTRL_MAX 8
static int (*g_ctrl_cb[NN_CTRL_MAX])(int);
static int g_nctrl;

static BOOL WINAPI nn_ctrl_handler(DWORD ev) {
  /* Ctrl+C and Ctrl+Break read as SIGINT; closing the console, logoff and
     shutdown as SIGTERM. The newest callback runs first; one that returns
     nonzero takes the event, as a POSIX handler installed later replaces
     an earlier one. Otherwise the default handler ends the process. */
  int sig = (ev == CTRL_C_EVENT || ev == CTRL_BREAK_EVENT) ? 2 : 15;
  int i = __atomic_load_n(&g_nctrl, __ATOMIC_ACQUIRE);
  if (i > NN_CTRL_MAX) i = NN_CTRL_MAX;
  while (--i >= 0)
    if (g_ctrl_cb[i] && g_ctrl_cb[i](sig)) return TRUE;
  return FALSE;
}

/* Run the registered handlers as the system would for `sig` (2: Ctrl+C,
   15: close); 1 when one took it. For tests: a real Ctrl+Break reaches
   every process on the console. */
int nn_console_ctrl_raise(int sig) {
  return nn_ctrl_handler(sig == 2 ? CTRL_C_EVENT : CTRL_CLOSE_EVENT) ? 1 : 0;
}

/* Call `cb` (on a thread the system creates) for console control events. */
int nn_on_console_ctrl(int (*cb)(int)) {
  int i = __atomic_load_n(&g_nctrl, __ATOMIC_ACQUIRE);
  if (i >= NN_CTRL_MAX) return -1;
  g_ctrl_cb[i] = cb;
  __atomic_store_n(&g_nctrl, i + 1, __ATOMIC_RELEASE);
  if (i == 0 && !SetConsoleCtrlHandler(nn_ctrl_handler, TRUE)) return -1;
  return 0;
}
