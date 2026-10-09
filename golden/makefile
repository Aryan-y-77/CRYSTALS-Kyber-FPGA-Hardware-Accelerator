# Makefile
CXX = g++
CC  = gcc
CXXFLAGS = -O2 -Wall -Wextra -std=c++17 -I.
CFLAGS   = -O2 -Wall -I.

all: test_barrett test_ntt test_kyber dump_all

test_barrett: test_barrett.cpp barrett.cpp kyber_params.h barrett.h
	$(CXX) $(CXXFLAGS) -o $@ test_barrett.cpp barrett.cpp

test_ntt: test_ntt.cpp barrett.cpp ntt.cpp kyber_params.h barrett.h ntt.h
	$(CXX) $(CXXFLAGS) -o $@ test_ntt.cpp barrett.cpp ntt.cpp

test_kyber: test_kyber.cpp barrett.cpp ntt.cpp sampling.cpp \
            poly.cpp kyber.cpp keccak_wrap.cpp tiny_sha3.c \
            kyber_params.h barrett.h ntt.h sampling.h poly.h kyber.h keccak_wrap.h tiny_sha3.h
	$(CXX) $(CXXFLAGS) -o $@ test_kyber.cpp barrett.cpp ntt.cpp sampling.cpp \
            poly.cpp kyber.cpp keccak_wrap.cpp tiny_sha3.c

dump_all: dump_all.cpp
	$(CXX) $(CXXFLAGS) -o $@ dump_all.cpp

clean:
	rm -f test_barrett test_ntt test_kyber dump_all
	rm -rf stim/

stim:
	mkdir -p stim
	./test_barrett
	./test_ntt
	./test_kyber
	./dump_all