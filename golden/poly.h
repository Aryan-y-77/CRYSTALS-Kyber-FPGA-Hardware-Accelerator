// poly.h
#ifndef POLY_H
#define POLY_H

#include "kyber_params.h"

void poly_add(poly_t r, const poly_t a, const poly_t b);
void poly_sub(poly_t r, const poly_t a, const poly_t b);

uint16_t compress_coeff(uint16_t x, int d);
uint16_t decompress_coeff(uint16_t x, int d);

void poly_compress(uint8_t* r, const poly_t a, int d);
void poly_decompress(poly_t r, const uint8_t* a, int d);

void poly_tobytes(uint8_t r[384], const poly_t a);
void poly_frombytes(poly_t r, const uint8_t a[384]);

void poly_frommsg(poly_t r, const uint8_t msg[32]);
void poly_tomsg(uint8_t msg[32], const poly_t a);

#endif // POLY_H