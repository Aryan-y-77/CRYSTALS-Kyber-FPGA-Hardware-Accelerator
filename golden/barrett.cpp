// barrett.cpp
#include "barrett.h"

// Global runtime parameter
int KYBER_K = 3;

BarrettResult barrett_reduce(uint32_t prod) {
    // Step 1: Quotient approximation
    uint16_t quo_approx = (prod >> 12) + (prod >> 14) - (prod >> 18) - (prod >> 20);

    // Step 2: Shift-add decomposition of q × quo_approx
    // 3329 in binary is 110100000001 (bits 11, 10, 8, 0)
    uint32_t q_times_quo = (quo_approx << 11) + (quo_approx << 10) + (quo_approx << 8) + quo_approx;

    // Step 3: Difference (lower 15 bits)
    int16_t diff = (int16_t)(prod & 0x7FFF) - (int16_t)(q_times_quo & 0x7FFF);

    // Step 4: 5-case switch on top 3 bits of 15-bit signed value
    int16_t qmux;
    uint16_t quo_corr;
    switch ((diff >> 12) & 0x7) {
        case 0: qmux =      0; quo_corr = quo_approx;     break;
        case 1: qmux =     -Q; quo_corr = quo_approx + 1; break;
        case 5: qmux =  3 * Q; quo_corr = quo_approx - 3; break;
        case 6: qmux =  3 * Q; quo_corr = quo_approx - 3; break;
        case 7: qmux =  2 * Q; quo_corr = quo_approx - 2; break;
        default: qmux =    0;  quo_corr = quo_approx;     break;
    }

    // Step 5: Apply correction
    int16_t res_comb = diff + qmux;

    // Step 6: Final guard subtract
    uint16_t res_final, quo_final;
    if (res_comb >= Q) {
        res_final = res_comb - Q;
        quo_final = quo_corr + 1;
    } else {
        res_final = (uint16_t)res_comb;
        quo_final = quo_corr;
    }

    return BarrettResult{ res_final, quo_final };
}

uint16_t mod_mul(uint16_t a, uint16_t b) {
    return barrett_reduce((uint32_t)a * (uint32_t)b).res;
}

uint16_t mod_add(uint16_t a, uint16_t b) {
    uint16_t sum = a + b;
    return (sum >= Q) ? (sum - Q) : sum;
}

uint16_t mod_sub(uint16_t a, uint16_t b) {
    return (a >= b) ? (a - b) : (a - b + Q);
}