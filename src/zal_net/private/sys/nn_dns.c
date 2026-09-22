/* Keep errno from getaddrinfo's EAI_SYSTEM failure before any cleanup call. */
#include <errno.h>
#ifdef _WIN32
int nn_gai_system_error(int code) { (void)code; return 0; }
#else
#include <netdb.h>
int nn_gai_system_error(int code) {
#ifdef EAI_SYSTEM
  if (code == EAI_SYSTEM) return errno;
#endif
  return 0;
}
#endif
