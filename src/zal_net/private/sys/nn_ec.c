/* EventCount for threads that are not event loops (blocking pool, logger,
   dedicated engines): prepare, recheck, then commit or cancel. A notify with
   no sleeper registered costs one atomic increment and no system call.
   Mutex + condition variable, so it is portable; the epoch closes the gap
   between the caller's recheck and its sleep. */
#include <stdint.h>
#include <stdlib.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

typedef struct {
  SRWLOCK m;
  CONDITION_VARIABLE c;
  uint32_t epoch;
  int sleepers;
} nn_ec;

void *nn_ec_new(void) {
  nn_ec *ec = calloc(1, sizeof *ec);
  if (!ec) return NULL;
  InitializeSRWLock(&ec->m);
  InitializeConditionVariable(&ec->c);
  return ec;
}

unsigned nn_ec_prepare(void *p) {
  nn_ec *ec = p;
  __atomic_add_fetch(&ec->sleepers, 1, __ATOMIC_SEQ_CST);
  return __atomic_load_n(&ec->epoch, __ATOMIC_SEQ_CST);
}

void nn_ec_cancel(void *p) {
  nn_ec *ec = p;
  __atomic_sub_fetch(&ec->sleepers, 1, __ATOMIC_SEQ_CST);
}

void nn_ec_commit(void *p, unsigned ticket, int timeout_ms) {
  nn_ec *ec = p;
  ULONGLONG until = timeout_ms >= 0 ? GetTickCount64() + (ULONGLONG)timeout_ms : 0;
  AcquireSRWLockExclusive(&ec->m);
  while (__atomic_load_n(&ec->epoch, __ATOMIC_SEQ_CST) == ticket) {
    DWORD wait = INFINITE;
    if (timeout_ms >= 0) {
      ULONGLONG now = GetTickCount64();
      if (now >= until) break;
      wait = (DWORD)(until - now);
    }
    if (!SleepConditionVariableSRW(&ec->c, &ec->m, wait, 0) && GetLastError() == ERROR_TIMEOUT) break;
  }
  ReleaseSRWLockExclusive(&ec->m);
  __atomic_sub_fetch(&ec->sleepers, 1, __ATOMIC_SEQ_CST);
}

static void nn_ec_wake(nn_ec *ec, int all) {
  __atomic_add_fetch(&ec->epoch, 1, __ATOMIC_SEQ_CST);
  if (__atomic_load_n(&ec->sleepers, __ATOMIC_SEQ_CST) == 0) return;
  AcquireSRWLockExclusive(&ec->m);
  if (all) WakeAllConditionVariable(&ec->c);
  else WakeConditionVariable(&ec->c);
  ReleaseSRWLockExclusive(&ec->m);
}

void nn_ec_notify_one(void *p) { nn_ec_wake(p, 0); }
void nn_ec_notify_all(void *p) { nn_ec_wake(p, 1); }

#else
#include <pthread.h>
#include <time.h>
#include <errno.h>

typedef struct {
  pthread_mutex_t m;
  pthread_cond_t c;
  uint32_t epoch;     /* bumped by every notify */
  int sleepers;       /* threads between prepare and commit/cancel */
} nn_ec;

void *nn_ec_new(void) {
  nn_ec *ec = calloc(1, sizeof *ec);
  if (!ec) return NULL;
  pthread_mutex_init(&ec->m, NULL);
  pthread_cond_init(&ec->c, NULL);
  return ec;
}

unsigned nn_ec_prepare(void *p) {
  nn_ec *ec = p;
  __atomic_add_fetch(&ec->sleepers, 1, __ATOMIC_SEQ_CST);
  return __atomic_load_n(&ec->epoch, __ATOMIC_SEQ_CST);
}

void nn_ec_cancel(void *p) {
  nn_ec *ec = p;
  __atomic_sub_fetch(&ec->sleepers, 1, __ATOMIC_SEQ_CST);
}

/* Sleep until a notify after `ticket`, or `timeout_ms` (-1: no limit). */
void nn_ec_commit(void *p, unsigned ticket, int timeout_ms) {
  nn_ec *ec = p;
  struct timespec ts;
  if (timeout_ms >= 0) {
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec += timeout_ms / 1000;
    ts.tv_nsec += (long)(timeout_ms % 1000) * 1000000L;
    if (ts.tv_nsec >= 1000000000L) { ts.tv_sec += 1; ts.tv_nsec -= 1000000000L; }
  }
  pthread_mutex_lock(&ec->m);
  while (__atomic_load_n(&ec->epoch, __ATOMIC_SEQ_CST) == ticket) {
    if (timeout_ms < 0) pthread_cond_wait(&ec->c, &ec->m);
    else if (pthread_cond_timedwait(&ec->c, &ec->m, &ts) == ETIMEDOUT) break;
  }
  pthread_mutex_unlock(&ec->m);
  __atomic_sub_fetch(&ec->sleepers, 1, __ATOMIC_SEQ_CST);
}

static void nn_ec_wake(nn_ec *ec, int all) {
  __atomic_add_fetch(&ec->epoch, 1, __ATOMIC_SEQ_CST);
  if (__atomic_load_n(&ec->sleepers, __ATOMIC_SEQ_CST) == 0) return;
  pthread_mutex_lock(&ec->m);
  if (all) pthread_cond_broadcast(&ec->c);
  else pthread_cond_signal(&ec->c);
  pthread_mutex_unlock(&ec->m);
}

void nn_ec_notify_one(void *p) { nn_ec_wake(p, 0); }
void nn_ec_notify_all(void *p) { nn_ec_wake(p, 1); }
#endif

void nn_ec_free(void *p) {
  nn_ec *ec = p;
#ifndef _WIN32
  pthread_cond_destroy(&ec->c);
  pthread_mutex_destroy(&ec->m);
#endif
  free(ec);
}
