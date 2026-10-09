// ntt.cpp
#include "ntt.h"
#include "barrett.h"
#include <cstdio>
#include <cstdint>

const uint16_t ZETAS_FORWARD[128];
const uint16_t ZETAS_INVERSE[128];

static uint8_t rev7(uint8_t x) {
    uint8_t res = 0;
    for (int i = 0; i < 7; ++i) {
        res = (res << 1) | (x & 1);
        x >>= 1;
    }
    return res;
}

// Static initializer to compute and print twiddle tables
struct NttTableInit {
    NttTableInit() {
        uint16_t pow17[128];
        pow17[0] = 1;
        for (int i = 1; i < 128; ++i) {
            pow17[i] = mod_mul(pow17[i - 1], ZETA);
        }

        uint16_t fwd[128];
        uint16_t inv[128];

        for (int i = 0; i < 128; ++i) {
            fwd[i] = pow17[rev7(i)];
        }

        for (int i = 0; i < 128; ++i) {
            inv[i] = mod_mul(Q - fwd[127 - i], TWO_INV);
        }

        // Copy to global const arrays using const_cast (safe during static init)
        uint16_t* fwd_ptr = const_cast<uint16_t*>(ZETAS_FORWARD);
        uint16_t* inv_ptr = const_cast<uint16_t*>(ZETAS_INVERSE);
        for (int i = 0; i < 128; ++i) {
            fwd_ptr[i] = fwd[i];
            inv_ptr[i] = inv[i];
        }

        // Print tables for Verilog ROM copy-paste
        printf("// Verilog ROM: ZETAS_FORWARD\n");
        printf("localparam [11:0] ZETAS_FWD [0:127] = '{\n");
        for (int i = 0; i < 128; ++i) {
            printf("    12'd%4u%s\n", fwd[i], (i == 127) ? "" : ",");
        }
        printf("};\n\n");

        printf("// Verilog ROM: ZETAS_INVERSE\n");
        printf("localparam [11:0] ZETAS_INV [0:127] = '{\n");
        for (int i = 0; i < 128; ++i) {
            printf("    12'd%4u%s\n", inv[i], (i == 127) ? "" : ",");
        }
        printf("};\n\n");
    }
} ntt_table_init_instance;

void ntt_forward(poly_t f) {
    int len = 128;
    int k = 0;
    while (len >= 2) {
        for (int start = 0; start < 256; start += 2 * len) {
            uint16_t zeta = ZETAS_FORWARD[k++];
            for (int j = start; j < start + len; ++j) {
                uint16_t t = mod_mul(zeta, f[j + len]);
                f[j + len] = mod_sub(f[j], t);
                f[j]       = mod_add(f[j], t);
            }
        }
        len /= 2;
    }
}

void ntt_inverse(poly_t f) {
    int len = 2;
    int k = 0;
    while (len <= 128) {
        for (int start = 0; start < 256; start += 2 * len) {
            uint16_t zeta = ZETAS_INVERSE[k++];
            for (int j = start; j < start + len; ++j) {
                uint16_t t = f[j];
                f[j]       = mod_add(t, f[j + len]);
                f[j + len] = mod_mul(zeta, mod_sub(t, f[j + len]));
            }
        }
        len *= 2;
    }
    
    // Final multiply by TWO_INV for the last stage merge
    for (int i = 0; i < 256; ++i) {
        f[i] = mod_mul(f[i], TWO_INV);
    }
}

void poly_basemul(poly_t h, const poly_t f, const poly_t g) {
    for (int i = 0; i < 128; ++i) {
        // PWM0
        uint16_t m0 = mod_mul(f[2 * i],     g[2 * i]);
        uint16_t m1 = mod_mul(f[2 * i + 1], g[2 * i + 1]);
        uint16_t s0 = mod_add(f[2 * i],     f[2 * i + 1]);
        uint16_t s1 = mod_add(g[2 * i],     g[2 * i + 1]);

        // PWM1
        uint16_t m2 = mod_mul(s0, s1);
        uint16_t s2 = mod_add(m0, m1);
        uint16_t zeta_k = ZETAS_FORWARD[64 + i];
        uint16_t m3 = mod_mul(m1, zeta_k);

        h[2 * i]     = mod_add(m0, m3);
        h[2 * i + 1] = mod_sub(m2, s2);
    }
}