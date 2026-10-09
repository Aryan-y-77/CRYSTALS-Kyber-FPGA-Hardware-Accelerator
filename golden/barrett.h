// barrett.h
#ifndef BARRETT_H
#define BARRETT_H

#include "kyber_params.h"

BarrettResult barrett_reduce(uint32_t prod);
uint16_t mod_mul(uint16_t a, uint16_t b);
uint16_t mod_add(uint16_t a, uint16_t b);
uint16_t mod_sub(uint16_t a, uint16_t b);

#endif // BARRETT_H