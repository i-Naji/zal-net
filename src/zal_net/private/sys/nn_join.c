/* Joinable library workers. The handle owns its launch record until join. */
#include <stdlib.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <process.h>
typedef struct { HANDLE thread; void (*fn)(void *); void *arg; } nn_worker;
static unsigned __stdcall nn_worker_entry(void *arg) {
  nn_worker *w = arg;
  w->fn(w->arg);
  return 0;
}
#else
#include <pthread.h>
typedef struct { pthread_t thread; void (*fn)(void *); void *arg; } nn_worker;
static void *nn_worker_entry(void *arg) {
  nn_worker *w = arg;
  w->fn(w->arg);
  return NULL;
}
#endif
void *nn_worker_start(void (*fn)(void *), void *arg) {
  nn_worker *w = calloc(1, sizeof *w);
  if (!w) return NULL;
  w->fn = fn;
  w->arg = arg;
#ifdef _WIN32
  w->thread = (HANDLE)_beginthreadex(NULL, 0, nn_worker_entry, w, 0, NULL);
  if (!w->thread) { free(w); return NULL; }
#else
  pthread_attr_t attr;
  if (pthread_attr_init(&attr) != 0) { free(w); return NULL; }
  (void)pthread_attr_setstacksize(&attr, 8u << 20);
  int rc = pthread_create(&w->thread, &attr, nn_worker_entry, w);
  pthread_attr_destroy(&attr);
  if (rc != 0) { free(w); return NULL; }
#endif
  return w;
}
int nn_worker_join(void *raw) {
  nn_worker *w = raw;
#ifdef _WIN32
  if (WaitForSingleObject(w->thread, INFINITE) != WAIT_OBJECT_0) return 0;
  CloseHandle(w->thread);
#else
  if (pthread_join(w->thread, NULL) != 0) return 0;
#endif
  free(w);
  return 1;
}
