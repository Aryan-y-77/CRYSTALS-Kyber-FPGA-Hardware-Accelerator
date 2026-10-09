// kyber_params.h
#ifndef KYBER_PARAMS_H
#define KYBER_PARAMS_H

#include <stdint.h>

// Fixed constants
#define Q         3329
#define N         256
#define MU        5039    // Barrett precomputed: ceil(2^24 / Q)
#define N_INV     3303    // N^-1 mod Q = 256^-1 mod 3329
#define TWO_INV   1665    // 2^-1 mod Q
#define ZETA      17      // Primitive 256th root of unity in Z_Q
#define XI        289     // ZETA^2 = 128th root of unity

// Typedefs
typedef uint16_t coeff_t;
typedef coeff_t poly_t[N];
typedef poly_t polyvec_t[4];

// Barrett reduction output struct
struct BarrettResult {
    uint16_t res;
    uint16_t quo;
};

// Global runtime parameter (default 3) - defined in barrett.cpp
extern int KYBER_K;

// Macros for compression bits based on k
#define D_U(k) ((k) == 4 ? 11 : 10)
#define D_V(k) ((k) == 4 ?  5 :  4)

#endif // KYBER_PARAMS_H