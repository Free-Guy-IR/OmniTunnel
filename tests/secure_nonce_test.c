#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/random.h>

#ifdef MOCK_FAIL
static ssize_t mock_getrandom(void *b, size_t n, unsigned int flags) {
    (void)b; (void)n; (void)flags;
    errno = ENOSYS;
    return -1;
}
static int mock_open_fail(const char *path, int oflag) {
    (void)path; (void)oflag;
    errno = EACCES;
    return -1;
}
#define getrandom(b, n, f) mock_getrandom((b), (n), (f))
#define open(p, fl) mock_open_fail((p), (fl))
#endif

#include "../src/tcrypto.h"

#ifdef MOCK_FAIL
static int run_fail_closed(void) {
    pid_t pid = fork();
    if (pid < 0) {
        perror("fork");
        return 1;
    }
    if (pid == 0) {
        unsigned char x[NONCE_LEN];
        memset(x, 0, sizeof x);
        ts_random(x, sizeof x);
        _exit(0);
    }
    int st = 0;
    if (waitpid(pid, &st, 0) != pid) {
        perror("waitpid");
        return 1;
    }
    if (!WIFEXITED(st)) {
        fprintf(stderr, "FAIL: child did not exit normally (no predictable fallback must still terminate)\n");
        return 1;
    }
    if (WEXITSTATUS(st) != 70) {
        fprintf(stderr, "FAIL: entropy sources unavailable but ts_random returned (exit=%d) instead of fail-closed _exit(70)\n", WEXITSTATUS(st));
        return 1;
    }
    printf("ok: fail-closed _exit(70) when getrandom and /dev/urandom both fail\n");
    return 0;
}
#else
static int lcg_sequence_match(const unsigned char *b, size_t n) {
    for (size_t g = 0; g < n; g++) {
        if (b[g] != (unsigned char)(g * 1103515245u + 12345u)) return 0;
    }
    return 1;
}
static int all_zero(const unsigned char *b, size_t n) {
    for (size_t g = 0; g < n; g++) if (b[g]) return 0;
    return 1;
}
static int run_live(void) {
    unsigned char a[NONCE_LEN], b[NONCE_LEN];
    ts_random(a, sizeof a);
    ts_random(b, sizeof b);
    if (memcmp(a, b, sizeof a) == 0) {
        fprintf(stderr, "FAIL: two draws identical (nonce source is deterministic)\n");
        return 1;
    }
    if (lcg_sequence_match(a, sizeof a) || lcg_sequence_match(b, sizeof b)) {
        fprintf(stderr, "FAIL: output equals the removed predictable LCG sequence\n");
        return 1;
    }
    if (all_zero(a, sizeof a) || all_zero(b, sizeof b)) {
        fprintf(stderr, "FAIL: nonce draw is all zero\n");
        return 1;
    }
    int flat = 1;
    for (size_t g = 1; g < sizeof a; g++) if (a[g] != a[0]) { flat = 0; break; }
    if (flat) {
        fprintf(stderr, "FAIL: nonce draw is a constant byte\n");
        return 1;
    }
    printf("ok: nonce source non-deterministic, no LCG path\n");
    return 0;
}
#endif

int main(void) {
#ifdef MOCK_FAIL
    if (run_fail_closed() != 0) return 1;
#else
    if (run_live() != 0) return 1;
#endif
    printf("secure_nonce_test PASS\n");
    return 0;
}
