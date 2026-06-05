// SPDX-License-Identifier: MIT
//
// Small command-line wrapper around HACL's raw Keccak primitive.
// Ethereum Keccak-256 is Keccak(rate=1088, capacity=512, suffix=0x01, out=32).

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if __has_include(<Hacl_Hash_SHA3.h>)
#include <Hacl_Hash_SHA3.h>
#elif __has_include(<hacl/Hacl_Hash_SHA3.h>)
#include <hacl/Hacl_Hash_SHA3.h>
#else
#error "HACL SHA3/Keccak header not found"
#endif

static int hex_digit(char c) {
  if ('0' <= c && c <= '9') return c - '0';
  if ('a' <= c && c <= 'f') return c - 'a' + 10;
  if ('A' <= c && c <= 'F') return c - 'A' + 10;
  return -1;
}

static uint8_t *decode_hex(const char *hex, uint32_t *out_len) {
  if (hex[0] == '0' && (hex[1] == 'x' || hex[1] == 'X')) hex += 2;
  size_t n = strlen(hex);
  if (n % 2 != 0) return NULL;
  uint8_t *out = calloc(n / 2, 1);
  if (!out) return NULL;
  for (size_t i = 0; i < n / 2; i++) {
    int hi = hex_digit(hex[2 * i]);
    int lo = hex_digit(hex[2 * i + 1]);
    if (hi < 0 || lo < 0) {
      free(out);
      return NULL;
    }
    out[i] = (uint8_t)((hi << 4) | lo);
  }
  *out_len = (uint32_t)(n / 2);
  return out;
}

static void print_hex(const uint8_t *bytes, size_t len) {
  printf("0x");
  for (size_t i = 0; i < len; i++) printf("%02x", bytes[i]);
  printf("\n");
}

static void lk_store64_le(uint8_t *out, uint64_t x) {
  for (size_t i = 0; i < 8; i++) out[i] = (uint8_t)((x >> (8 * i)) & 0xff);
}

static void ethereum_keccak256(uint8_t out[32], const uint8_t *input, uint32_t input_len) {
  const uint32_t rate = 136; // 1088 bits
  uint64_t state[25] = {0};
  uint32_t offset = 0;

  while (input_len - offset >= rate) {
    uint8_t block[256] = {0};
    memcpy(block, input + offset, rate);
    Hacl_Hash_SHA3_absorb_inner_32(rate, block, state);
    offset += rate;
  }

  uint8_t final_block[256] = {0};
  uint32_t rem = input_len - offset;
  memcpy(final_block, input + offset, rem);
  final_block[rem] ^= 0x01;       // Ethereum Keccak domain separator.
  final_block[rate - 1] ^= 0x80;  // Multi-rate padding terminator.
  Hacl_Hash_SHA3_absorb_inner_32(rate, final_block, state);

  uint8_t state_bytes[200] = {0};
  for (size_t i = 0; i < 25; i++) lk_store64_le(state_bytes + 8 * i, state[i]);
  memcpy(out, state_bytes, 32);
}

int main(int argc, char **argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: leancli-hacl-keccak256 <hex>\n");
    return 2;
  }
  uint32_t in_len = 0;
  uint8_t *input = decode_hex(argv[1], &in_len);
  if (!input) {
    fprintf(stderr, "invalid hex input\n");
    return 2;
  }
  uint8_t out[32] = {0};

  ethereum_keccak256(out, input, in_len);

  print_hex(out, 32);
  free(input);
  return 0;
}
