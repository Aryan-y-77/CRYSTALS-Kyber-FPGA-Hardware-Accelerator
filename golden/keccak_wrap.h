// keccak_wrap.h
#ifndef KECCAK_WRAP_H
#define KECCAK_WRAP_H

#include <stdint.h>
#include <stddef.h>

void shake128(const uint8_t* seed, size_t seed_len,
              uint8_t* output, size_t out_len);

void shake256(const uint8_t* seed, size_t seed_len,
              const uint8_t* nonce, size_t nonce_len,
              uint8_t* output, size_t out_len);

void sha3_256(const uint8_t* input, size_t in_len,
              uint8_t output[32]);

void sha3_512(const uint8_t* input, size_t in_len,
              uint8_t output[64]);

#endif // KECCAK_WRAP_H