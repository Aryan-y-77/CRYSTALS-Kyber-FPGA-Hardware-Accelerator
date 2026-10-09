// dump_all.cpp
#include <cstdlib>
#include <cstdio>

int main() {
    printf("=====================================================\n");
    printf("  CRYSTALS-Kyber Golden Model Master Stimulus Runner \n");
    printf("=====================================================\n\n");

    printf("[1/3] Running Barrett Reduction Tests...\n");
    int ret1 = system("./test_barrett");
    if (ret1 != 0) {
        printf("ERROR: test_barrett failed.\n");
        return 1;
    }

    printf("\n[2/3] Running NTT Tests...\n");
    int ret2 = system("./test_ntt");
    if (ret2 != 0) {
        printf("ERROR: test_ntt failed.\n");
        return 1;
    }

    printf("\n[3/3] Running Kyber Protocol Tests...\n");
    int ret3 = system("./test_kyber");
    if (ret3 != 0) {
        printf("ERROR: test_kyber failed.\n");
        return 1;
    }

    printf("\n=====================================================\n");
    printf("  All tests PASSED. Stimulus files generated in stim/\n");
    printf("=====================================================\n");

    return 0;
}