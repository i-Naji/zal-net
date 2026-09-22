/* Detached threads that own their launch record: no thread handle is kept. */
#include <stdlib.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <process.h>

struct nn_thread_start { void (*fn)(void *); void *arg; };

static unsigned __stdcall nn_thread_entry(void *raw) {
  struct nn_thread_start job = *(struct nn_thread_start *)raw;
  free(raw);
  job.fn(job.arg);
  return 0;
}

int nn_start_thread(void (*fn)(void *), void *arg) {
  struct nn_thread_start *job = malloc(sizeof(*job));
  uintptr_t h;
  if (!job) return -1;
  job->fn = fn;
  job->arg = arg;
  h = _beginthreadex(NULL, 0, nn_thread_entry, job, 0, NULL);
  if (h == 0) { free(job); return -1; }
  CloseHandle((HANDLE)h);
  return 0;
}

#else
#include <pthread.h>

struct nn_thread_start { void (*fn)(void *); void *arg; };

static void *nn_thread_entry(void *raw) {
  struct nn_thread_start job = *(struct nn_thread_start *)raw;
  free(raw);
  job.fn(job.arg);
  return NULL;
}

int nn_start_thread(void (*fn)(void *), void *arg) {
  struct nn_thread_start *job = malloc(sizeof(*job));
  pthread_attr_t attr;
  pthread_t thread;
  int rc;
  if (!job) return -1;
  job->fn = fn;
  job->arg = arg;
  if (pthread_attr_init(&attr) != 0) { free(job); return -1; }
  /* glibc's default; musl's is 128 KiB. Reserved, not committed. */
  (void)pthread_attr_setstacksize(&attr, 8u << 20);
  rc = pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
  if (rc == 0) rc = pthread_create(&thread, &attr, nn_thread_entry, job);
  pthread_attr_destroy(&attr);
  if (rc != 0) free(job);
  return rc;
}
#endif
