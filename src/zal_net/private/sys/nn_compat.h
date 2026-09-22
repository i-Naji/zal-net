/* Linux compatibility switches shared by the C helpers (nn_linux.c). */
#ifndef NN_COMPAT_H
#define NN_COMPAT_H
#include <stdlib.h>

/* Whether the C library may declare a call: glibc from version maj.min;
   musl and the others declare them all. */
#if defined(__GLIBC__) && !defined(__UCLIBC__)
#  define NN_GLIBC_MIN(maj, min) (__GLIBC__ > (maj) || (__GLIBC__ == (maj) && __GLIBC_MINOR__ >= (min)))
#else
#  define NN_GLIBC_MIN(maj, min) 1
#endif

/* NN_LINUX_COMPAT=1 forces the fallbacks for old kernels. */
static inline int nn_compat(void) {
  static int v = -1;
  if (v < 0) {
    const char *e = getenv("NN_LINUX_COMPAT");
    v = e != NULL && e[0] == '1';
  }
  return v;
}
#endif
