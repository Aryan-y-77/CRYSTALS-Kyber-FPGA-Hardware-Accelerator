// poly.cpp
#include "poly.h"
#include "barrett.h"
#include <cstring>

void poly_add(poly_t r, const poly_t a, const poly_t b) {
    for (int i = 0; i < N; i++) {
        r[i] = mod_add(a[i], b[i]);
    }
}

void poly_sub(poly_t r, const poly_t a, const poly_t b) {
    for (int i = 0; i < N; i++) {
        r[i] = mod_sub(a[i], b[i]);
    }
}

uint16_t compress_coeff(uint16_t x, int d) {
    uint32_t t = ((uint32_t)x << d) + Q / 2;
    t /= Q;
    return (uint16_t)(t & ((1 << d) - 1));
}

uint16_t decompress_coeff(uint16_t x, int d) {
    return (uint16_t)(((uint32_t)x * Q + (1 << (d - 1))) >> d);
}

void poly_compress(uint8_t* r, const poly_t a, int d) {
    size_t total_bytes = (256 * d + 7) / 8;
    memset(r, 0, total_bytes);
    for (int i = 0; i < 256; i++) {
        uint16_t t = compress_coeff(a[i], d);
        for (int j = 0; j < d; j++) {
            if (t & (1 << j)) {
                r[(i * d + j) / 8] |= (1 << ((i * d + j) % 8));
            }
        }
    }
}

void poly_decompress(poly_t r, const uint8_t* a, int d) {
    for (int i = 0; i < 256; i++) {
        uint16_t t = 0;
        for (int j = 0; j < d; j++) {
            if (a[(i * d + j) / 8] & (1 << ((i * d + j) % 8))) {
                t |= (1 << j);
            }
        }
        r[i] = decompress_coeff(t, d);
    }
}

void poly_tobytes(uint8_t r[384], const poly_t a) {
    for (int i = 0; i < 64; i++) {
        uint16_t t0 = a[4 * i + 0];
        uint16_t t1 = a[4 * i + 1];
        uint16_t t2 = a[4 * i + 2];
        uint16_t t3 = a[4 * i + 3];
        
        r[6 * i + 0] = (uint8_t)(t0);
        r[6 * i + 1] = (uint8_t)((t0 >> 8) | (t1 << 4));
        r[6 * i + 2] = (uint8_t)(t1 >> 4);
        r[6 * i + 3] = (uint8_t)(t2);
        r[6 * i + 4] = (uint8_t)((t2 >> 8) | (t3 << 4));
        r[6 * i + 5] = (uint8_t)(t3 >> 4);
    }
}

void poly_frombytes(poly_t r, const uint8_t a[384]) {
    for (int i = 0; i < 64; i++) {
        r[4 * i + 0] = (uint16_t)(a[6 * i + 0]) | ((uint16_t)(a[6 * i + 1] & 0x0F) << 8);
        r[4 * i + 1] = (uint16_t)(a[6 * i + 1] >> 4) | ((uint16_t)(a[6 * i + 2]) << 4);
        r[4 * i + 2] = (uint16_t)(a[6 * i + 3]) | ((uint16_t)(a[6 * i + 4] & 0x0F) << 8);
        r[4 * i + 3] = (uint16_t)(a[6 * i + 4] >> 4) | ((uint16_t)(a[6 * i + 5]) << 4);
    }
}

void poly_frommsg(poly_t r, const uint8_t msg[32]) {
    for (int i = 0; i < 256; i++) {
        uint16_t bit = (msg[i / 8] >> (i % 8)) & 1;
        r[i] = bit * ((Q + 1) / 2);
    }
}

void poly_tomsg(uint8_t msg[32], const poly_t a) {
    memset(msg, 0, 32);
    for (int i = 0; i < 256; i++) {
        uint16_t t = a[i];
        uint16_t bit = (((uint32_t)t << 1) + 1665) >> 13;
        msg[i / 8] |= (bit << (i % 8));
    }
}