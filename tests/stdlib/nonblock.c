#include <fcntl.h>
/* The header preserves fcntl's variadic ABI on macOS ARM64. */
int zal_test_nonblock(int fd) {
  int flags = fcntl(fd, F_GETFL);
  if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) return -1;
  return (fcntl(fd, F_GETFL) & O_NONBLOCK) != 0 ? 0 : -1;
}
