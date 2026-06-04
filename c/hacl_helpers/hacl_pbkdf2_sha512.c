// SPDX-License-Identifier: MIT
//
// PBKDF2-HMAC-SHA512 glue built only from HACL HMAC-SHA512.

#include "lk_hex.h"

#if __has_include(<Hacl_HMAC.h>)
#include <Hacl_HMAC.h>
#elif __has_include(<hacl/Hacl_HMAC.h>)
#include <hacl/Hacl_HMAC.h>
#else
#error "HACL HMAC header not found"
#endif

static void store_be32(uint8_t out[4], uint32_t x) {
  out[0] = (uint8_t)((x >> 24) & 0xff);
  out[1] = (uint8_t)((x >> 16) & 0xff);
  out[2] = (uint8_t)((x >> 8) & 0xff);
  out[3] = (uint8_t)(x & 0xff);
}

int main(int argc, char **argv) {
  if (argc != 5) {
    fprintf(stderr, "usage: leancli-hacl-pbkdf2 <password-hex> <salt-hex> <iters> <dk-len>\n");
    return 2;
  }

  uint32_t pass_len = 0;
  uint32_t salt_len = 0;
  uint32_t iters = 0;
  uint32_t dk_len = 0;
  uint8_t *pass = lk_decode_hex(argv[1], &pass_len);
  uint8_t *salt = lk_decode_hex(argv[2], &salt_len);
  if (!pass || !salt || !lk_parse_u32(argv[3], &iters) || !lk_parse_u32(argv[4], &dk_len) ||
      iters == 0) {
    fprintf(stderr, "invalid input\n");
    free(pass);
    free(salt);
    return 2;
  }

  uint8_t *dk = calloc(dk_len == 0 ? 1 : dk_len, 1);
  uint8_t *salt_block = calloc((size_t)salt_len + 4, 1);
  if (!dk || !salt_block) {
    fprintf(stderr, "allocation failed\n");
    free(pass);
    free(salt);
    free(dk);
    free(salt_block);
    return 1;
  }
  memcpy(salt_block, salt, salt_len);

  uint32_t blocks = (dk_len + 63) / 64;
  for (uint32_t block = 1; block <= blocks; block++) {
    uint8_t u[64] = {0};
    uint8_t t[64] = {0};
    store_be32(salt_block + salt_len, block);
    Hacl_HMAC_compute_sha2_512(u, pass, pass_len, salt_block, salt_len + 4);
    memcpy(t, u, sizeof(t));
    for (uint32_t i = 1; i < iters; i++) {
      Hacl_HMAC_compute_sha2_512(u, pass, pass_len, u, sizeof(u));
      for (size_t j = 0; j < sizeof(t); j++) t[j] ^= u[j];
    }
    uint32_t offset = (block - 1) * 64;
    uint32_t take = dk_len - offset < 64 ? dk_len - offset : 64;
    memcpy(dk + offset, t, take);
  }

  lk_print_hex(dk, dk_len);
  free(pass);
  free(salt);
  free(dk);
  free(salt_block);
  return 0;
}
