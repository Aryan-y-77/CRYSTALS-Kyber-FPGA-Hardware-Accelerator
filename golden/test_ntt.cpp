// test_ntt.cpp
#include "kyber_params.h"
#include "barrett.h"
#include "ntt.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sys/stat.h>

void schoolbook_conv(poly_t h, const poly_t f, const poly_t g) {
    for (int i = 0; i < N; i++) {
        uint16_t acc = 0;
        for (int j = 0; j <= i; j++)
            acc = mod_add(acc, mod_mul(f[j], g[i - j]));
        for (int j = i + 1; j < N; j++)
            acc = mod_sub(acc, mod_mul(f[j], g[N + i - j]));
        h[i] = acc; // acc is already reduced mod Q by mod_add/mod_sub
    }
}

void random_poly(poly_t p) {
    for (int i = 0; i < N; i++) {
        p[i] = rand() % Q;
    }
}

void write_poly(FILE* f, const poly_t p) {
    for (int i = 0; i < N; i++) {
        fprintf(f, "%03X", p[i]);
        if (i < N - 1) fprintf(f, " ");
    }
    fprintf(f, "\n");
}

int main() {
    mkdir("stim", 0777);
    srand(12345);

    int rt_pass = 0, rt_fail = 0;
    int conv_pass = 0, conv_fail = 0;

    // Roundtrip test
    for (int i = 0; i < 10000; i++) {
        poly_t p_orig, p_test;
        random_poly(p_orig);
        memcpy(p_test, p_orig, sizeof(poly_t));

        ntt_forward(p_test);
        ntt_inverse(p_test);

        bool match = true;
        for (int j = 0; j < N; j++) {
            if (p_test[j] != p_orig[j]) {
                match = false;
                break;
            }
        }
        if (match) rt_pass++;
        else rt_fail++;
    }

    // Convolution test
    for (int i = 0; i < 1000; i++) {
        poly_t f, g, h_ref, h_ntt;
        random_poly(f);
        random_poly(g);

        schoolbook_conv(h_ref, f, g);

        poly_t f_ntt, g_ntt;
        memcpy(f_ntt, f, sizeof(poly_t));
        memcpy(g_ntt, g, sizeof(poly_t));
        ntt_forward(f_ntt);
        ntt_forward(g_ntt);

        poly_basemul(h_ntt, f_ntt, g_ntt);
        ntt_inverse(h_ntt);

        bool match = true;
        for (int j = 0; j < N; j++) {
            if (h_ntt[j] != h_ref[j]) {
                match = false;
                break;
            }
        }
        if (match) conv_pass++;
        else conv_fail++;
    }

    // Stimulus generation
    FILE* f_ntt = fopen("stim/ntt_stim.txt", "w");
    FILE* f_intt = fopen("stim/intt_stim.txt", "w");

    for (int i = 0; i < 1000; i++) {
        poly_t p;
        random_poly(p);

        // NTT stim
        write_poly(f_ntt, p);
        poly_t p_ntt;
        memcpy(p_ntt, p, sizeof(poly_t));
        ntt_forward(p_ntt);
        write_poly(f_ntt, p_ntt);

        // INTT stim
        write_poly(f_intt, p_ntt);
        poly_t p_intt;
        memcpy(p_intt, p_ntt, sizeof(poly_t));
        ntt_inverse(p_intt);
        write_poly(f_intt, p_intt);
    }

    fclose(f_ntt);
    fclose(f_intt);

    printf("\n========================================\n");
    printf("GOLDEN MODEL RESULTS\n");
    printf("========================================\n");
    printf("[test_ntt]\n");
    printf("  Roundtrip vectors         : 10,000\n");
    printf("  Roundtrip PASS            : %d\n", rt_pass);
    printf("  Convolution vectors       : 1,000\n");
    printf("  Convolution PASS          : %d\n", conv_pass);
    printf("  Stimulus written          : stim/ntt_stim.txt, stim/intt_stim.txt\n");
    printf("========================================\n");

    return (rt_fail > 0 || conv_fail > 0) ? 1 : 0;
}