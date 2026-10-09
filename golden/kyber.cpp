// kyber.cpp
#include "kyber.h"
#include "barrett.h"
#include "ntt.h"
#include "sampling.h"
#include "poly.h"
#include "keccak_wrap.h"
#include <cstring>
#include <cstdio>
#include <cstdlib>

// Test-mode FO pass flag (exposed for test_kyber.cpp)
int last_fo_pass = -1;

// ---------- Deterministic RNG ----------
static uint8_t rng_seed[64];
static int rng_initialized = 0;
static uint8_t rng_buf[2048];
static size_t rng_pos = 0;
static size_t rng_avail = 0;
static uint32_t rng_ctr = 0;

void kyber_set_seed(const uint8_t* seed, size_t len) {
    memset(rng_seed, 0, sizeof(rng_seed));
    size_t copy_len = len < sizeof(rng_seed) ? len : sizeof(rng_seed);
    memcpy(rng_seed, seed, copy_len);
    rng_initialized = 1;
    rng_pos = 0;
    rng_avail = 0;
    rng_ctr = 0;
}

static void rng_refill() {
    uint8_t ctr_bytes[4];
    ctr_bytes[0] = rng_ctr & 0xFF;
    ctr_bytes[1] = (rng_ctr >> 8) & 0xFF;
    ctr_bytes[2] = (rng_ctr >> 16) & 0xFF;
    ctr_bytes[3] = (rng_ctr >> 24) & 0xFF;
    rng_ctr++;
    shake256(rng_seed, 64, ctr_bytes, 4, rng_buf, sizeof(rng_buf));
    rng_pos = 0;
    rng_avail = sizeof(rng_buf);
}

static void random_bytes(uint8_t* out, size_t len) {
    if (!rng_initialized) {
        FILE* f = fopen("/dev/urandom", "rb");
        if (f) {
            size_t rd = fread(out, 1, len, f);
            fclose(f);
            if (rd == len) return;
        }
        memset(out, 0, len);
        return;
    }
    for (size_t i = 0; i < len; i++) {
        if (rng_pos >= rng_avail) rng_refill();
        out[i] = rng_buf[rng_pos++];
    }
}

// ---------- Core Encryption (steps 5-9 of Encap) ----------
static void encrypt_core(const uint8_t* pk, const uint8_t* m,
                         const uint8_t* coins, uint8_t* ct) {
    int k = KYBER_K;
    int du = D_U(k);
    int dv = D_V(k);

    // Parse pk: t_hat[0..k-1] || rho
    poly_t t_hat[4];
    uint8_t rho[32];
    for (int i = 0; i < k; i++)
        poly_frombytes(t_hat[i], pk + i * 384);
    memcpy(rho, pk + k * 384, 32);

    // Generate A^T
    polyvec_t AT[4];
    gen_matrix(AT, rho, 1);

    // Sample r, e1, e2 from coins (eta2 = 2 for all parameter sets)
    poly_t r_hat[4], e1[4], e2;
    for (int i = 0; i < k; i++) {
        poly_getnoise(r_hat[i], coins, (uint8_t)i, 2);
        ntt_forward(r_hat[i]);
    }
    for (int i = 0; i < k; i++)
        poly_getnoise(e1[i], coins, (uint8_t)(k + i), 2);
    poly_getnoise(e2, coins, (uint8_t)(2 * k), 2);

    // u = INTT(A^T * r_hat) + e1
    poly_t u[4];
    for (int i = 0; i < k; i++) {
        memset(u[i], 0, sizeof(poly_t));
        for (int j = 0; j < k; j++) {
            poly_t tmp;
            poly_basemul(tmp, AT[i][j], r_hat[j]);
            poly_add(u[i], u[i], tmp);
        }
        ntt_inverse(u[i]);
        poly_add(u[i], u[i], e1[i]);
    }

    // v = INTT(t_hat^T * r_hat) + e2 + decode(m)
    poly_t v;
    memset(v, 0, sizeof(poly_t));
    for (int i = 0; i < k; i++) {
        poly_t tmp;
        poly_basemul(tmp, t_hat[i], r_hat[i]);
        poly_add(v, v, tmp);
    }
    ntt_inverse(v);
    poly_add(v, v, e2);

    poly_t m_poly;
    poly_frommsg(m_poly, m);
    poly_add(v, v, m_poly);

    // Encode ct = Compress(u, du) || Compress(v, dv)
    for (int i = 0; i < k; i++)
        poly_compress(ct + i * du * 32, u[i], du);
    poly_compress(ct + k * du * 32, v, dv);
}

// ---------- KeyGen ----------
void kyber_keygen(uint8_t* pk, uint8_t* sk) {
    int k = KYBER_K;
    int pk_len = k * 384 + 32;

    // Step 1: random d
    uint8_t d[32];
    random_bytes(d, 32);

    // Step 2: (rho, sigma) = SHA3-512(d)
    uint8_t buf[64];
    sha3_512(d, 32, buf);
    uint8_t* rho   = buf;
    uint8_t* sigma = buf + 32;

    // Step 3: matrix A
    polyvec_t A[4];
    gen_matrix(A, rho, 0);

    // Steps 4-5: sample s, e  (eta1 = 3 for k=2, else 2)
    int eta1 = (k == 2) ? 3 : 2;
    poly_t s[4], e[4];
    for (int i = 0; i < k; i++)
        poly_getnoise(s[i], sigma, (uint8_t)i, eta1);
    for (int i = 0; i < k; i++)
        poly_getnoise(e[i], sigma, (uint8_t)(k + i), eta1);

    // Step 6: NTT forward
    for (int i = 0; i < k; i++) {
        ntt_forward(s[i]);
        ntt_forward(e[i]);
    }

    // Step 7: t_hat = A * s_hat + e_hat
    poly_t t_hat[4];
    for (int i = 0; i < k; i++) {
        memset(t_hat[i], 0, sizeof(poly_t));
        for (int j = 0; j < k; j++) {
            poly_t tmp;
            poly_basemul(tmp, A[i][j], s[j]);
            poly_add(t_hat[i], t_hat[i], tmp);
        }
        poly_add(t_hat[i], t_hat[i], e[i]);
    }

    // Step 8: pk = encode(t_hat) || rho
    for (int i = 0; i < k; i++)
        poly_tobytes(pk + i * 384, t_hat[i]);
    memcpy(pk + k * 384, rho, 32);

    // Step 9: sk = encode(s_hat) || pk || H(pk) || z
    for (int i = 0; i < k; i++)
        poly_tobytes(sk + i * 384, s[i]);
    memcpy(sk + k * 384, pk, pk_len);
    sha3_256(pk, pk_len, sk + k * 384 + pk_len);
    random_bytes(sk + k * 384 + pk_len + 32, 32);
}

// ---------- Encapsulation ----------
void kyber_encap(const uint8_t* pk, uint8_t* ct, uint8_t ss[32]) {
    int k = KYBER_K;
    int pk_len = k * 384 + 32;
    int ct_len = k * D_U(k) * 32 + D_V(k) * 32;

    // Step 1: random m
    uint8_t m[32];
    random_bytes(m, 32);

    // Step 2: m = H(m)
    sha3_256(m, 32, m);

    // Step 3: H_pk = H(pk)
    uint8_t H_pk[32];
    sha3_256(pk, pk_len, H_pk);

    // Step 4: (K_bar, r_seed) = G(m || H_pk)
    uint8_t g_input[64];
    memcpy(g_input, m, 32);
    memcpy(g_input + 32, H_pk, 32);
    uint8_t g_out[64];
    sha3_512(g_input, 64, g_out);
    uint8_t* K_bar  = g_out;
    uint8_t* r_seed = g_out + 32;

    // Steps 5-9: core encryption
    encrypt_core(pk, m, r_seed, ct);

    // Step 10: H_ct = H(ct)
    uint8_t H_ct[32];
    sha3_256(ct, ct_len, H_ct);

    // Step 11: ss = H(K_bar || H_ct)
    uint8_t kdf_input[64];
    memcpy(kdf_input, K_bar, 32);
    memcpy(kdf_input + 32, H_ct, 32);
    sha3_256(kdf_input, 64, ss);
}

// ---------- Decapsulation ----------
void kyber_decap(const uint8_t* sk, const uint8_t* ct, uint8_t ss[32]) {
    int k = KYBER_K;
    int pk_len = k * 384 + 32;
    int ct_len = k * D_U(k) * 32 + D_V(k) * 32;
    int du = D_U(k);
    int dv = D_V(k);

    // Step 1: Parse sk -> s_hat, pk, H_pk, z
    poly_t s_hat[4];
    for (int i = 0; i < k; i++)
        poly_frombytes(s_hat[i], sk + i * 384);
    const uint8_t* pk   = sk + k * 384;
    const uint8_t* H_pk = sk + k * 384 + pk_len;
    const uint8_t* z    = sk + k * 384 + pk_len + 32;

    // Step 2: Decompress u, v from ct
    poly_t u[4], v;
    for (int i = 0; i < k; i++)
        poly_decompress(u[i], ct + i * du * 32, du);
    poly_decompress(v, ct + k * du * 32, dv);

    // Step 3: m' = Compress(v - INTT(s_hat^T * u_hat), 1)
    for (int i = 0; i < k; i++)
        ntt_forward(u[i]);

    poly_t mp;
    memset(mp, 0, sizeof(poly_t));
    for (int i = 0; i < k; i++) {
        poly_t tmp;
        poly_basemul(tmp, s_hat[i], u[i]);
        poly_add(mp, mp, tmp);
    }
    ntt_inverse(mp);
    poly_sub(mp, v, mp);

    uint8_t m_prime[32];
    poly_tomsg(m_prime, mp);

    // Step 4: (K_bar', r') = G(m' || H_pk)
    uint8_t g_input[64];
    memcpy(g_input, m_prime, 32);
    memcpy(g_input + 32, H_pk, 32);
    uint8_t g_out[64];
    sha3_512(g_input, 64, g_out);
    uint8_t* K_bar_prime = g_out;
    uint8_t* r_prime     = g_out + 32;

    // Step 5: Re-encrypt ct'
    uint8_t ct_prime[1568]; // max ct size (k=4)
    encrypt_core(pk, m_prime, r_prime, ct_prime);

    // Step 6: FO check — constant-time comparison only
    uint8_t ct_eq = 0;
    for (int i = 0; i < ct_len; i++)
        ct_eq |= (ct[i] ^ ct_prime[i]);
    int fo_pass = (ct_eq == 0);
    last_fo_pass = fo_pass;

    // Step 7: H_ct = H(ct)
    uint8_t H_ct[32];
    sha3_256(ct, ct_len, H_ct);

    // Steps 8-9: ss = H(K_bar' || H_ct) or H(z || H_ct)
    uint8_t kdf_input[64];
    if (fo_pass)
        memcpy(kdf_input, K_bar_prime, 32);
    else
        memcpy(kdf_input, z, 32);
    memcpy(kdf_input + 32, H_ct, 32);
    sha3_256(kdf_input, 64, ss);
}