// tiny_sha3.h
#ifndef TINY_SHA3_H
#define TINY_SHA3_H

#include <stdint.h>
#include <stddef.h>

typedef struct {
    uint64_t s[25];
    uint8_t  buf[200];
    uint32_t bp;
    uint32_t rate;
    uint32_t xof;
} sha3_context;

void sha3_init(sha3_context *c, size_t mdlen);
const uint8_t *sha3_final(sha3_context *c);
void sha3_update(sha3_context *c, const void *data, size_t len);

void shake_init(sha3_context *c, int security);
void shake_xof(sha3_context *c);
void shake_out(sha3_context *c, uint8_t *out, size_t len);

#endif // TINY_SHA3_H