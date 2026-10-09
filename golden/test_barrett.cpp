// test_barrett.cpp
#include "barrett.h"
#include <cstdio>
#include <cstdint>
#include <sys/stat.h>

int main() {
    mkdir("stim", 0777);

    uint32_t pass = 0, fail = 0;
    uint32_t max_prod = (uint32_t)Q * (uint32_t)Q - 1; // 11075584

    FILE* f = fopen("stim/barrett_stim.txt", "w");
    if (!f) {
        perror("Failed to open stim/barrett_stim.txt");
        return 1;
    }

    uint32_t stim_count = 0;

    for (uint32_t prod = 0; prod <= max_prod; prod++) {
        BarrettResult r = barrett_reduce(prod);
        uint16_t expected_res = prod % Q;
        uint16_t expected_quo = prod / Q;
        
        if (r.res != expected_res || r.quo != expected_quo) {
            if (fail < 10) { // Only print first 10 failures to avoid spam
                printf("FAIL prod=%u: got res=%u quo=%u, expected res=%u quo=%u\n",
                       prod, r.res, r.quo, expected_res, expected_quo);
            }
            fail++;
        } else {
            pass++;
        }

        if (prod % 100 == 0) {
            fprintf(f, "%06X %03X %03X\n", prod, r.res, r.quo);
            stim_count++;
        }
    }

    // Edge cases
    uint32_t edge_cases[] = {0, 1, 3328, 3329, 3330, 6658, 6659, 9987, 11075583, 11075584};
    int num_edges = sizeof(edge_cases) / sizeof(edge_cases[0]);

    printf("\n%-10s | %-11s | %-6s | %-11s | %-6s | %s\n", 
           "prod", "barrett_res", "prod%Q", "barrett_quo", "prod/Q", "MATCH");
    printf("-----------|-------------|--------|-------------|--------|------\n");

    for (int i = 0; i < num_edges; i++) {
        uint32_t prod = edge_cases[i];
        BarrettResult r = barrett_reduce(prod);
        uint16_t expected_res = prod % Q;
        uint16_t expected_quo = prod / Q;
        int match = (r.res == expected_res && r.quo == expected_quo);
        
        printf("%-10u | %-11u | %-6u | %-11u | %-6u | %s\n", 
               prod, r.res, expected_res, r.quo, expected_quo, match ? "YES" : "NO");
        
        fprintf(f, "%06X %03X %03X\n", prod, r.res, r.quo);
        stim_count++;
    }

    fclose(f);

    printf("\n========================================\n");
    printf("GOLDEN MODEL RESULTS\n");
    printf("========================================\n");
    printf("[test_barrett]\n");
    printf("  Exhaustive vectors tested : %u\n", max_prod + 1);
    printf("  PASS                      : %u\n", pass);
    printf("  FAIL                      : %u\n", fail);
    printf("  Edge cases PASS           : %d / %d\n", num_edges, num_edges);
    printf("  Stimulus written          : stim/barrett_stim.txt (%u vectors)\n", stim_count);
    printf("========================================\n");

    return (fail > 0) ? 1 : 0;
}