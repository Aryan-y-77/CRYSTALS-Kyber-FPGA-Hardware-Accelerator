// keccak_wrap.cpp
#include "keccak_wrap.h"
#include "tiny_sha3.h"
#include <cstring>

void shake128(const uint8_t* seed, size_t seed_len,
              uint8_t* output, size_t out_len) {
    sha3_context ctx;
    shake_init(&ctx, 128);
    sha3_update(&ctx, seed, seed_len);
    shake_xof(&ctx);
    shake_out(&ctx, output, out_len);
}

void shake256(const uint8_t* seed, size_t seed_len,
              const uint8_t* nonce, size_t nonce_len,
              uint8_t* output, size_t out_len) {
    sha3_context ctx;
    shake_init(&ctx, 256);
    sha3_update(&ctx, seed, seed_len);
    sha3_update(&ctx, nonce, nonce_len);
    shake_xof(&ctx);
    shake_out(&ctx, output, out_len);
}

void sha3_256(const uint8_t* input, size_t in_len,
              uint8_t output[32]) {
    sha3_context ctx;
    sha3_init(&ctx, 32);
    sha3_update(&ctx, input, in_len);
    const uint8_t* res = sha3_final(&ctx);
    memcpy(output, res, 32);
}

void sha3_512(const uint8_t* input, size_t in_len,
              uint8_t output[64]) {
    sha3_context ctx;
    sha3_init(&ctx, 64);
    sha3_update(&ctx, input, in_len);
    const uint8_t* res = sha3_final(&ctx);
    memcpy(output, res, 64);
}