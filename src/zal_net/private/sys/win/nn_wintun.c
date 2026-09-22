/* TUN devices on Windows through Wintun (https://www.wintun.net).

   wintun.dll is loaded at run time, from the program's directory or
   System32, and creating an adapter needs administrator rights. The
   adapter lives as long as its device: closing it removes the adapter.

   Wintun signals new packets on an event, not a socket, so each device has
   a waiter thread and a wake socket the reader parks on. A reader that
   finds the ring empty arms the waiter (then looks once more); the armed
   waiter waits on the session's read event and writes a byte to the wake
   socket. Spurious wakes are possible and harmless: the reader looks again. */
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <windows.h>
#include <iphlpapi.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* The few Wintun entry points used (wintun.h, which is not vendored). */
typedef void *wt_adapter;
typedef void *wt_session;
typedef wt_adapter(WINAPI *wt_create_fn)(const WCHAR *name, const WCHAR *type, const GUID *guid);
typedef void(WINAPI *wt_close_adapter_fn)(wt_adapter a);
typedef void(WINAPI *wt_luid_fn)(wt_adapter a, NET_LUID *luid);
typedef wt_session(WINAPI *wt_start_fn)(wt_adapter a, DWORD capacity);
typedef void(WINAPI *wt_end_fn)(wt_session s);
typedef HANDLE(WINAPI *wt_event_fn)(wt_session s);
typedef BYTE *(WINAPI *wt_recv_fn)(wt_session s, DWORD *size);
typedef void(WINAPI *wt_release_fn)(wt_session s, const BYTE *p);
typedef BYTE *(WINAPI *wt_alloc_fn)(wt_session s, DWORD size);
typedef void(WINAPI *wt_send_fn)(wt_session s, const BYTE *p);

static struct {
  INIT_ONCE once;
  int ok;
  wt_create_fn create;
  wt_close_adapter_fn close_adapter;
  wt_luid_fn luid;
  wt_start_fn start;
  wt_end_fn end;
  wt_event_fn event;
  wt_recv_fn recv;
  wt_release_fn release;
  wt_alloc_fn alloc;
  wt_send_fn send;
} wt = {INIT_ONCE_STATIC_INIT};

#define NN_WINTUN_CAPACITY 0x400000   /* 4 MiB rings */

int nn_wake_pair(int *r, int *w);
void nn_wake_signal(int w);
void nn_wake_drain(int r);

static BOOL CALLBACK wt_load(PINIT_ONCE once, PVOID param, PVOID *ctx) {
  HMODULE h = LoadLibraryExW(L"wintun.dll", NULL,
                             LOAD_LIBRARY_SEARCH_APPLICATION_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
  (void)once; (void)param; (void)ctx;
  if (h == NULL) return TRUE;
  wt.create = (wt_create_fn)(void *)GetProcAddress(h, "WintunCreateAdapter");
  wt.close_adapter = (wt_close_adapter_fn)(void *)GetProcAddress(h, "WintunCloseAdapter");
  wt.luid = (wt_luid_fn)(void *)GetProcAddress(h, "WintunGetAdapterLUID");
  wt.start = (wt_start_fn)(void *)GetProcAddress(h, "WintunStartSession");
  wt.end = (wt_end_fn)(void *)GetProcAddress(h, "WintunEndSession");
  wt.event = (wt_event_fn)(void *)GetProcAddress(h, "WintunGetReadWaitEvent");
  wt.recv = (wt_recv_fn)(void *)GetProcAddress(h, "WintunReceivePacket");
  wt.release = (wt_release_fn)(void *)GetProcAddress(h, "WintunReleaseReceivePacket");
  wt.alloc = (wt_alloc_fn)(void *)GetProcAddress(h, "WintunAllocateSendPacket");
  wt.send = (wt_send_fn)(void *)GetProcAddress(h, "WintunSendPacket");
  wt.ok = wt.create && wt.close_adapter && wt.luid && wt.start && wt.end && wt.event &&
          wt.recv && wt.release && wt.alloc && wt.send;
  if (!wt.ok) FreeLibrary(h);
  return TRUE;
}

typedef struct {
  wt_adapter adapter;
  wt_session session;
  HANDLE read_ev;             /* Wintun's; not ours to close */
  HANDLE arm_ev, quit_ev, thread;
  int wake;                   /* the wake socket (nn_wake_pair: one socket) */
} nn_wintun;

static DWORD WINAPI wt_waiter(LPVOID p) {
  nn_wintun *t = (nn_wintun *)p;
  HANDLE arm[2], rd[2];
  arm[0] = t->arm_ev; arm[1] = t->quit_ev;
  rd[0] = t->read_ev; rd[1] = t->quit_ev;
  for (;;) {
    if (WaitForMultipleObjects(2, arm, FALSE, INFINITE) != WAIT_OBJECT_0) break;
    if (WaitForMultipleObjects(2, rd, FALSE, INFINITE) != WAIT_OBJECT_0) break;
    nn_wake_signal(t->wake);
  }
  return 0;
}

static void wt_free(nn_wintun *t) {
  if (t->thread) {
    SetEvent(t->quit_ev);
    WaitForSingleObject(t->thread, INFINITE);
    CloseHandle(t->thread);
  }
  if (t->arm_ev) CloseHandle(t->arm_ev);
  if (t->quit_ev) CloseHandle(t->quit_ev);
  if (t->session) wt.end(t->session);
  if (t->adapter) wt.close_adapter(t->adapter);
  free(t);
}

/* A new adapter named `name` (UTF-8; "" for "nimony") with a session, its
   interface alias (UTF-8) in `alias`, and its wake socket in `*wake` (the
   caller closes that one). NULL on failure, with `*err`: 1 wintun.dll is
   missing, 2 no adapter (`*code`: the Windows error; 5 is access denied),
   3 no session, 4 no memory, events, thread or wake socket. */
void *nn_wintun_open(const char *name, int *err, unsigned *code, char *alias, int alias_cap,
                     int *wake) {
  WCHAR wname[128], walias[IF_MAX_STRING_SIZE + 1];
  NET_LUID luid;
  nn_wintun *t;
  *err = 0;
  *code = 0;
  *wake = -1;
  InitOnceExecuteOnce(&wt.once, wt_load, NULL, NULL);
  if (!wt.ok) { *err = 1; return NULL; }
  if (name == NULL || name[0] == 0) name = "nimony";
  if (!MultiByteToWideChar(CP_UTF8, 0, name, -1, wname, 128)) { *err = 2; *code = GetLastError(); return NULL; }
  t = (nn_wintun *)calloc(1, sizeof *t);
  if (t == NULL) { *err = 4; return NULL; }
  t->wake = -1;
  t->adapter = wt.create(wname, L"zal-net", NULL);
  if (t->adapter == NULL) { *err = 2; *code = GetLastError(); wt_free(t); return NULL; }
  t->session = wt.start(t->adapter, NN_WINTUN_CAPACITY);
  if (t->session == NULL) { *err = 3; *code = GetLastError(); wt_free(t); return NULL; }
  t->read_ev = wt.event(t->session);
  t->arm_ev = CreateEventW(NULL, FALSE, FALSE, NULL);
  t->quit_ev = CreateEventW(NULL, TRUE, FALSE, NULL);
  if (!t->arm_ev || !t->quit_ev || nn_wake_pair(&t->wake, &t->wake) != 0) {
    *err = 4; wt_free(t); return NULL;
  }
  t->thread = CreateThread(NULL, 64 * 1024, wt_waiter, t, 0, NULL);
  if (t->thread == NULL) {
    *err = 4;
    closesocket((SOCKET)(uintptr_t)(uint32_t)t->wake);
    wt_free(t);
    return NULL;
  }
  alias[0] = 0;
  wt.luid(t->adapter, &luid);
  if (ConvertInterfaceLuidToAlias(&luid, walias, IF_MAX_STRING_SIZE + 1) == NO_ERROR)
    WideCharToMultiByte(CP_UTF8, 0, walias, -1, alias, alias_cap - 1, NULL, NULL);
  *wake = t->wake;
  return t;
}

/* Packet length or -GetLastError(). ERROR_NO_MORE_ITEMS means the ring
   is empty and its waiter has been armed; the Nim boundary maps it to IoAgain. */
intptr_t nn_wintun_recv(void *h, void *p, size_t n) {
  nn_wintun *t = (nn_wintun *)h;
  int pass;
  for (pass = 0; pass < 2; pass++) {
    DWORD size = 0;
    BYTE *pkt = wt.recv(t->session, &size);
    if (pkt != NULL) {
      size_t k = size < n ? size : n;
      memcpy(p, pkt, k);
      wt.release(t->session, pkt);
      return (intptr_t)k;
    }
    {
      DWORD error = GetLastError();
      if (error != ERROR_NO_MORE_ITEMS) return -(intptr_t)error;
    }
    if (pass == 0) {
      nn_wake_drain(t->wake);
      SetEvent(t->arm_ev);
    }
  }
  return -(intptr_t)ERROR_NO_MORE_ITEMS;
}

/* Packet length or -GetLastError(); ERROR_BUFFER_OVERFLOW means ring full. */
intptr_t nn_wintun_send(void *h, const void *p, size_t n) {
  nn_wintun *t = (nn_wintun *)h;
  BYTE *out;
  if (n == 0 || n > 0xFFFF) return -(intptr_t)ERROR_INVALID_PARAMETER;
  out = wt.alloc(t->session, (DWORD)n);
  if (out == NULL) return -(intptr_t)GetLastError();
  memcpy(out, p, n);
  wt.send(t->session, out);
  return (intptr_t)n;
}

/* Stop the waiter, end the session and remove the adapter. The wake
   socket stays open: the caller closes it (after unparking its readers). */
void nn_wintun_close(void *h) {
  if (h != NULL) wt_free((nn_wintun *)h);
}
