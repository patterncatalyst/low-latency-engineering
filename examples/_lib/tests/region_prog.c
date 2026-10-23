/* Test program for lib.sh perf_region and cachegrind_run.
 *
 *   region_prog OUTSIDE REGION
 *
 * Touches a 64 MiB buffer at a stride that misses L1 on nearly every access, OUTSIDE times with
 * the counters off, then REGION times between "enable" and "disable" on LOWLAT_PERF_CTL (when set),
 * and writes REGION to LOWLAT_OPS_FILE. A correct region count therefore does not move with
 * OUTSIDE. region_work is the function cachegrind_run counts through CACHEGRIND_FUNCTION.
 */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define SIZE (64u << 20)

static volatile uint8_t *buf;

#define WORK_BODY                                                         \
  uint64_t sum = 0;                                                       \
  size_t at = 0;                                                          \
  for (long i = 0; i < n; i++) {                                          \
    at = (at + 4099u * 64u) % SIZE; /* odd multiple of a line: new line */ \
    sum += buf[at];                                                       \
  }                                                                       \
  return sum;

/* Two functions with one body, so cachegrind can tell them apart by name. */
__attribute__((noinline)) uint64_t outside_work(long n) { WORK_BODY }
__attribute__((noinline)) uint64_t region_work(long n) { WORK_BODY }

static void control(int fd_ctl, int fd_ack, const char *word) {
  if (fd_ctl < 0) return;
  char line[16];
  if (write(fd_ctl, word, strlen(word)) < 0 || write(fd_ctl, "\n", 1) < 0) exit(3);
  ssize_t got = read(fd_ack, line, sizeof line);
  if (got < 3 || strncmp(line, "ack", 3) != 0) exit(4);
}

int main(int argc, char **argv) {
  if (argc != 3) return 2;
  long outside = atol(argv[1]), region = atol(argv[2]);
  buf = malloc(SIZE);
  if (!buf) return 1;
  memset((void *)buf, 1, SIZE);
  const char *ctl = getenv("LOWLAT_PERF_CTL"), *ack = getenv("LOWLAT_PERF_ACK");
  int fd_ctl = ctl ? open(ctl, O_WRONLY) : -1;
  int fd_ack = ack ? open(ack, O_RDONLY) : -1;
  uint64_t a = outside_work(outside);
  control(fd_ctl, fd_ack, "enable");
  uint64_t b = region_work(region);
  control(fd_ctl, fd_ack, "disable");
  const char *ops = getenv("LOWLAT_OPS_FILE");
  if (ops) {
    FILE *f = fopen(ops, "w");
    if (f) { fprintf(f, "%ld\n", region); fclose(f); }
  }
  return (a + b) == 0xdeadbeef; /* keeps the sums alive */
}
