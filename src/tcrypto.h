/* tcrypto.h - libsodium-shaped AEAD backed by vendored Monocypher, so the
 * whole suite builds as ONE self-contained static binary (no external crypto
 * lib) and cross-compiles trivially for amd64 and arm64.
 *
 * Wire layout is unchanged from the libsodium version: a 24-byte nonce
 * followed by ciphertext with a 16-byte tag appended. XChaCha20-Poly1305. */
#ifndef TCRYPTO_H
#define TCRYPTO_H
#include <stddef.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/random.h>
#include "monocypher.h"

#define NONCE_LEN 24
#define TAG_LEN   16
#define KEY_LEN   32

static inline void ts_random(void *buf, size_t n) {
    unsigned char *b = (unsigned char *)buf;
    size_t g = 0;
    while (g < n) {
        ssize_t r = getrandom(b + g, n - g, 0);
        if (r > 0) { g += (size_t)r; continue; }
        if (r < 0 && errno == EINTR) continue;
        break;
    }
    if (g < n) {
        int fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
        if (fd >= 0) {
            while (g < n) {
                ssize_t r = read(fd, b + g, n - g);
                if (r > 0) { g += (size_t)r; continue; }
                if (r < 0 && errno == EINTR) continue;
                break;
            }
            close(fd);
        }
    }
    if (g < n) _exit(70);
}

/* Drop-in replacements with the SAME signatures as libsodium's
 * crypto_aead_chacha20poly1305_ietf_{encrypt,decrypt}, so switching the crypto
 * backend is a pure rename at every call site. ad/nsec are unused. */
static inline int aead_enc(unsigned char *c, unsigned long long *clen,
                           const unsigned char *m, unsigned long long mlen,
                           const unsigned char *ad, unsigned long long adlen,
                           const unsigned char *nsec,
                           const unsigned char *npub, const unsigned char *k) {
    (void)ad; (void)adlen; (void)nsec;
    crypto_aead_lock(c, c + mlen, k, npub, NULL, 0, m, (size_t)mlen);
    *clen = mlen + TAG_LEN;
    return 0;
}
static inline int aead_dec(unsigned char *m, unsigned long long *mlen,
                           unsigned char *nsec,
                           const unsigned char *c, unsigned long long clen,
                           const unsigned char *ad, unsigned long long adlen,
                           const unsigned char *npub, const unsigned char *k) {
    (void)nsec; (void)ad; (void)adlen;
    if (clen < TAG_LEN) return -1;
    unsigned long long ct = clen - TAG_LEN;
    if (crypto_aead_unlock(m, c + ct, k, npub, NULL, 0, c, (size_t)ct) != 0) return -1;
    *mlen = ct;
    return 0;
}

#endif
