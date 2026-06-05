// SPDX-License-Identifier: MIT
//
// Small command-line wrapper around HACL HMAC-SHA512.

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if __has_include(<Hacl_HMAC.h>)
#include <Hacl_HMAC.h>
#elif __has_include(<hacl/Hacl_HMAC.h>)
#include <hacl/Hacl_HMAC.h>
#else
#error "HACL HMAC header not found"
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

int main(int argc, char **argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: leancli-hacl-hmac-sha512 <key-hex> <msg-hex>\n");
    return 2;
  }
  uint32_t key_len = 0;
  uint32_t msg_len = 0;
  uint8_t *key = decode_hex(argv[1], &key_len);
  uint8_t *msg = decode_hex(argv[2], &msg_len);
  if (!key || !msg) {
    fprintf(stderr, "invalid hex input\n");
    free(key);
    free(msg);
    return 2;
  }
  uint8_t out[64] = {0};
  Hacl_HMAC_compute_sha2_512(out, key, key_len, msg, msg_len);
  print_hex(out, 64);
  free(key);
  free(msg);
  return 0;
}
