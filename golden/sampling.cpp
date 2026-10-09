// sampling.cpp
#include "sampling.h"
#include "keccak_wrap.h"
#include "barrett.h"
#include <cstring>

void gen_matrix_entry(poly_t a, const uint8_t rho[32], uint8_t i, uint8_t j) {
    uint8_t seed[34];
    memcpy(seed, rho, 32);
    seed[32] = j;
    seed[33] = i;

    // Squeeze enough bytes. 512 bytes is more than enough for 256 coefficients 
    // (requires at most ~384 bytes due to rejection sampling).
    uint8_t buf[512];
    shake128(seed, 34, buf, sizeof(buf));

    int k = 0;
    int idx = 0;
    while (k < 256) {
        uint16_t d1 = buf[idx] | ((uint16_t)(buf[idx + 1] & 0x0F) << 8);
        uint16_t d2 = (buf[idx + 1] >> 4) | ((uint16_t)buf[idx + 2] << 4);
        idx += 3;

        if (d1 < Q) a[k++] = d1;
        if (k < 256 && d2 < Q) a[k++] = d2;
    }
}

void gen_matrix(polyvec_t a[4], const uint8_t rho[32], int transposed) {
    for (int i = 0; i < KYBER_K; i++) {
        for (int j = 0; j < KYBER_K; j++) {
            if (transposed) {
                gen_matrix_entry(a[i][j], rho, j, i);
            } else {
                gen_matrix_entry(a[i][j], rho, i, j);
            }
        }
    }
}

void cbd_sample(const uint8_t* buf, int eta, poly_t f) {
    if (eta == 2) {
        for (int i = 0; i < 256; i++) {
            int byte_idx = i / 2;
            int shift = (i % 2) * 4;
            uint8_t bits = (buf[byte_idx] >> shift) & 0x0F;
            
            uint8_t a = (bits & 1) + ((bits >> 1) & 1);
            uint8_t b = ((bits >> 2) & 1) + ((bits >> 3) & 1);
            f[i] = mod_sub(a, b);
        }
    } else if (eta == 3) {
        int idx = 0;
        for (int i = 0; i < 256; i += 4) {
            uint32_t bits = buf[idx] | ((uint32_t)buf[idx + 1] << 8) | ((uint32_t)buf[idx + 2] << 16);
            idx += 3;
            
            for (int k = 0; k < 4; k++) {
                uint8_t b_val = (bits >> (k * 6)) & 0x3F;
                uint8_t a = (b_val & 1) + ((b_val >> 1) & 1) + ((b_val >> 2) & 1);
                uint8_t b = ((b_val >> 3) & 1) + ((b_val >> 4) & 1) + ((b_val >> 5) & 1);
                f[i + k] = mod_sub(a, b);
            }
        }
    }
}

void poly_getnoise(poly_t f, const uint8_t sigma[32], uint8_t nonce, int eta) {
    uint8_t buf[192]; // Max size needed is 64 * 3 = 192 bytes for eta=3
    shake256(sigma, 32, &nonce, 1, buf, 64 * eta);
    cbd_sample(buf, eta, f);
}