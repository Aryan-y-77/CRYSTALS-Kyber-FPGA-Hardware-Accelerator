// tiny_sha3.c
#include "tiny_sha3.h"
#include <string.h>

static const uint64_t keccakf_rndc[24] = {
    0x0000000000000001, 0x0000000000008082, 0x800000000000808a,
    0x8000000080008000, 0x000000000000808b, 0x0000000080000001,
    0x8000000080008081, 0x8000000000008009, 0x000000000000008a,
    0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
    0x000000008000808b, 0x800000000000008b, 0x8000000000008089,
    0x8000000000008003, 0x8000000000008002, 0x8000000000000080,
    0x000000000000800a, 0x800000008000000a, 0x8000000080008081,
    0x8000000000008080, 0x0000000080000001, 0x8000000080008008
};

static const uint32_t keccakf_rotc[24] = {
    1,  3,  6,  10, 15, 21, 28, 36, 45, 55, 2,  14,
    27, 41, 56, 8,  25, 43, 62, 18, 39, 61, 20, 44
};

static const uint32_t keccakf_piln[24] = {
    10, 7,  11, 17, 18, 3, 5,  16, 8,  21, 24, 4,
    15, 23, 19, 13, 12, 2, 20, 14, 22, 9,  6,  1
};

static void keccakf(uint64_t s[25]) {
    uint64_t t, bc[5];
    for (int r = 0; r < 24; r++) {
        for (int i = 0; i < 5; i++)
            bc[i] = s[i] ^ s[i + 5] ^ s[i + 10] ^ s[i + 15] ^ s[i + 20];
        for (int i = 0; i < 5; i++) {
            t = bc[(i + 4) % 5] ^ ((bc[(i + 1) % 5] << 1) | (bc[(i + 1) % 5] >> 63));
            for (int j = 0; j < 25; j += 5)
                s[j + i] ^= t;
        }
        t = s[1];
        for (int i = 0; i < 24; i++) {
            uint32_t j = keccakf_piln[i];
            bc[0] = s[j];
            s[j] = (t << keccakf_rotc[i]) | (t >> (64 - keccakf_rotc[i]));
            t = bc[0];
        }
        for (int j = 0; j < 25; j += 5) {
            for (int i = 0; i < 5; i++)
                bc[i] = s[j + i];
            for (int i = 0; i < 5; i++)
                s[j + i] ^= (~bc[(i + 1) % 5]) & bc[(i + 2) % 5];
        }
        s[0] ^= keccakf_rndc[r];
    }
}

void sha3_init(sha3_context *c, size_t mdlen) {
    memset(c, 0, sizeof(sha3_context));
    c->rate = 200 - 2 * mdlen;
    c->xof = 0;
}

void sha3_update(sha3_context *c, const void *data, size_t len) {
    const uint8_t *p = (const uint8_t *)data;
    while (len--) {
        c->buf[c->bp++] = *p++;
        if (c->bp == c->rate) {
            for (uint32_t i = 0; i < c->rate / 8; i++)
                c->s[i] ^= ((uint64_t *)c->buf)[i];
            keccakf(c->s);
            c->bp = 0;
        }
    }
}

const uint8_t *sha3_final(sha3_context *c) {
    c->buf[c->bp++] = 0x06;
    memset(c->buf + c->bp, 0, c->rate - c->bp);
    c->buf[c->rate - 1] |= 0x80;
    for (uint32_t i = 0; i < c->rate / 8; i++)
        c->s[i] ^= ((uint64_t *)c->buf)[i];
    keccakf(c->s);
    return (const uint8_t *)c->s;
}

void shake_init(sha3_context *c, int security) {
    memset(c, 0, sizeof(sha3_context));
    c->rate = 200 - 2 * (security / 8);
    c->xof = 1;
}

void shake_xof(sha3_context *c) {
    c->buf[c->bp++] = 0x1f;
    memset(c->buf + c->bp, 0, c->rate - c->bp);
    c->buf[c->rate - 1] |= 0x80;
    for (uint32_t i = 0; i < c->rate / 8; i++)
        c->s[i] ^= ((uint64_t *)c->buf)[i];
    keccakf(c->s);
    c->bp = 0;
    memcpy(c->buf, c->s, c->rate);
}

void shake_out(sha3_context *c, uint8_t *out, size_t len) {
    while (len--) {
        if (c->bp == c->rate) {
            keccakf(c->s);
            memcpy(c->buf, c->s, c->rate);
            c->bp = 0;
        }
        *out++ = c->buf[c->bp++];
    }
}