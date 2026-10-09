// sampling.h
#ifndef SAMPLING_H
#define SAMPLING_H

#include "kyber_params.h"

void gen_matrix_entry(poly_t a, const uint8_t rho[32],
                      uint8_t i, uint8_t j);

void gen_matrix(polyvec_t a[4], const uint8_t rho[32],
                int transposed);

void cbd_sample(const uint8_t* buf, int eta, poly_t f);

void poly_getnoise(poly_t f, const uint8_t sigma[32],
                   uint8_t nonce, int eta);

#endif // SAMPLING_H