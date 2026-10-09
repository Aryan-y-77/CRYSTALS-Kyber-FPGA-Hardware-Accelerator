// ntt.h
#ifndef NTT_H
#define NTT_H

#include "kyber_params.h"

extern const uint16_t ZETAS_FORWARD[128];
extern const uint16_t ZETAS_INVERSE[128];

void ntt_forward(poly_t f);
void ntt_inverse(poly_t f);
void poly_basemul(poly_t h, const poly_t f, const poly_t g);

#endif // NTT_H