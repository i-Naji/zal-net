/* OS resource counts for ownership regressions; no production instrumentation. */
#if defined(_WIN32)
#include <windows.h>
int nn_test_resource_count(void) {
  DWORD count;
  return GetProcessHandleCount(GetCurrentProcess(), &count) ? (int)count : -1;
}
#elif defined(__linux__)
#include <dirent.h>
#include <string.h>
int nn_test_resource_count(void) {
  DIR *dir = opendir("/proc/self/fd");
  struct dirent *entry;
  int count = 0;
  if (!dir) return -1;
  while ((entry = readdir(dir)) != NULL) {
    if (strcmp(entry->d_name, ".") && strcmp(entry->d_name, "..")) count++;
  }
  closedir(dir);
  return count;
}
#else
int nn_test_resource_count(void) { return -1; }
#endif
