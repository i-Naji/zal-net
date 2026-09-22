/* Async-signal-safe publication; do not clobber an interrupted syscall's errno. */
#include <errno.h>
#include <unistd.h>
int nn_signal_post(int fd, int sig) {
  int saved = errno;
  unsigned char value = (unsigned char)sig;
  ssize_t n;
  do { n = write(fd, &value, 1); } while (n < 0 && errno == EINTR);
  errno = saved;
  return n == 1;
}
