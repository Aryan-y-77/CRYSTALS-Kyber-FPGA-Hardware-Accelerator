// kyber.h
#ifndef KYBER_H
#define KYBER_H

#include "kyber_params.h"

void kyber_keygen(uint8_t* pk, uint8_t* sk);
void kyber_encap(const uint8_t* pk, uint8_t* ct, uint8_t ss[32]);
void kyber_decap(const uint8_t* sk, const uint8_t* ct, uint8_t ss[32]);

// For testing/KAT injection
void kyber_set_seed(const uint8_t* seed, size_t len);

#endif // KYBER_H