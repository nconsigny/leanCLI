// SPDX-License-Identifier: MIT
//
// Small command-line wrapper around HACL SHA-256.

#include "lk_hex.h"

#if __has_include(<Hacl_Hash_SHA2.h>)
#include <Hacl_Hash_SHA2.h>
#elif __has_include(<hacl/Hacl_Hash_SHA2.h>)
#include <hacl/Hacl_Hash_SHA2.h>
#else
#error "HACL SHA2 header not found"
#endif

int main(int argc, char **argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: leancli-hacl-sha256 <hex>\n");
    return 2;
  }
  uint32_t in_len = 0;
  uint8_t *input = lk_decode_hex(argv[1], &in_len);
  if (!input) {
    fprintf(stderr, "invalid hex input\n");
    return 2;
  }
  uint8_t out[32] = {0};
  Hacl_Hash_SHA2_hash_256(out, input, in_len);
  lk_print_hex(out, sizeof(out));
  free(input);
  return 0;
}
