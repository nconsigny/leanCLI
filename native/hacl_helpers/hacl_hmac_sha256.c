// SPDX-License-Identifier: MIT
//
// Small command-line wrapper around HACL HMAC-SHA256.

#include "lk_hex.h"

#if __has_include(<Hacl_HMAC.h>)
#include <Hacl_HMAC.h>
#elif __has_include(<hacl/Hacl_HMAC.h>)
#include <hacl/Hacl_HMAC.h>
#else
#error "HACL HMAC header not found"
#endif

int main(int argc, char **argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: leancli-hacl-hmac-sha256 <key-hex> <msg-hex>\n");
    return 2;
  }
  uint32_t key_len = 0;
  uint32_t msg_len = 0;
  uint8_t *key = lk_decode_hex(argv[1], &key_len);
  uint8_t *msg = lk_decode_hex(argv[2], &msg_len);
  if (!key || !msg) {
    fprintf(stderr, "invalid hex input\n");
    free(key);
    free(msg);
    return 2;
  }
  uint8_t out[32] = {0};
  Hacl_HMAC_compute_sha2_256(out, key, key_len, msg, msg_len);
  lk_print_hex(out, sizeof(out));
  free(key);
  free(msg);
  return 0;
}
