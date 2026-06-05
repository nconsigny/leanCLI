// SPDX-License-Identifier: MIT

#ifndef LK_HEX_H
#define LK_HEX_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int lk_hex_digit(char c) {
  if ('0' <= c && c <= '9') return c - '0';
  if ('a' <= c && c <= 'f') return c - 'a' + 10;
  if ('A' <= c && c <= 'F') return c - 'A' + 10;
  return -1;
}

static uint8_t *lk_decode_hex(const char *hex, uint32_t *out_len) {
  if (hex[0] == '0' && (hex[1] == 'x' || hex[1] == 'X')) hex += 2;
  size_t n = strlen(hex);
  if (n % 2 != 0 || n / 2 > UINT32_MAX) return NULL;
  size_t bytes_len = n / 2;
  uint8_t *out = calloc(bytes_len == 0 ? 1 : bytes_len, 1);
  if (!out) return NULL;
  for (size_t i = 0; i < bytes_len; i++) {
    int hi = lk_hex_digit(hex[2 * i]);
    int lo = lk_hex_digit(hex[2 * i + 1]);
    if (hi < 0 || lo < 0) {
      free(out);
      return NULL;
    }
    out[i] = (uint8_t)((hi << 4) | lo);
  }
  *out_len = (uint32_t)bytes_len;
  return out;
}

static void lk_print_hex(const uint8_t *bytes, size_t len) {
  printf("0x");
  for (size_t i = 0; i < len; i++) printf("%02x", bytes[i]);
  printf("\n");
}

static int lk_parse_u32(const char *s, uint32_t *out) {
  char *end = NULL;
  unsigned long v = strtoul(s, &end, 10);
  if (!end || *end != '\0' || v > UINT32_MAX) return 0;
  *out = (uint32_t)v;
  return 1;
}

#endif
