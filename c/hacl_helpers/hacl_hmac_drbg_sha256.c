// SPDX-License-Identifier: MIT
//
// Small command-line wrapper around HACL HMAC-DRBG-SHA256.

#include "lk_hex.h"

#if __has_include(<Hacl_HMAC_DRBG.h>)
#include <Hacl_HMAC_DRBG.h>
#elif __has_include(<hacl/Hacl_HMAC_DRBG.h>)
#include <hacl/Hacl_HMAC_DRBG.h>
#else
#error "HACL HMAC-DRBG header not found"
#endif

int main(int argc, char **argv) {
  if (argc != 6) {
    fprintf(stderr, "usage: leancli-hacl-hmac-drbg <entropy-hex> <nonce-hex> <personalization-hex> <additional-hex> <out-len>\n");
    return 2;
  }

  uint32_t entropy_len = 0;
  uint32_t nonce_len = 0;
  uint32_t personalization_len = 0;
  uint32_t additional_len = 0;
  uint32_t out_len = 0;
  uint8_t *entropy = lk_decode_hex(argv[1], &entropy_len);
  uint8_t *nonce = lk_decode_hex(argv[2], &nonce_len);
  uint8_t *personalization = lk_decode_hex(argv[3], &personalization_len);
  uint8_t *additional = lk_decode_hex(argv[4], &additional_len);
  if (!entropy || !nonce || !personalization || !additional || !lk_parse_u32(argv[5], &out_len)) {
    fprintf(stderr, "invalid input\n");
    free(entropy);
    free(nonce);
    free(personalization);
    free(additional);
    return 2;
  }

  uint8_t *out = calloc(out_len == 0 ? 1 : out_len, 1);
  if (!out) {
    fprintf(stderr, "allocation failed\n");
    free(entropy);
    free(nonce);
    free(personalization);
    free(additional);
    return 1;
  }

  Hacl_HMAC_DRBG_state st = Hacl_HMAC_DRBG_create_in(Spec_Hash_Definitions_SHA2_256);
  Hacl_HMAC_DRBG_instantiate(Spec_Hash_Definitions_SHA2_256, st, entropy_len, entropy,
                             nonce_len, nonce, personalization_len, personalization);
  bool ok = Hacl_HMAC_DRBG_generate(Spec_Hash_Definitions_SHA2_256, out, st, out_len,
                                    additional_len, additional);
  Hacl_HMAC_DRBG_free(Spec_Hash_Definitions_SHA2_256, st);
  if (!ok) {
    fprintf(stderr, "HMAC-DRBG generate failed\n");
    free(entropy);
    free(nonce);
    free(personalization);
    free(additional);
    free(out);
    return 1;
  }

  lk_print_hex(out, out_len);
  free(entropy);
  free(nonce);
  free(personalization);
  free(additional);
  free(out);
  return 0;
}
