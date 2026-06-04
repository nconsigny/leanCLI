// SPDX-License-Identifier: MIT

#include "../hacl_helpers/lk_hex.h"

#include <secp256k1.h>
#include <secp256k1_recovery.h>

int main(int argc, char **argv) {
  if (argc != 5) {
    fprintf(stderr, "usage: leancli-secp256k1-recover <digest-hex> <r-hex> <s-hex> <v>\n");
    return 2;
  }

  uint32_t digest_len = 0;
  uint32_t r_len = 0;
  uint32_t s_len = 0;
  uint32_t v = 0;
  uint8_t *digest = lk_decode_hex(argv[1], &digest_len);
  uint8_t *r = lk_decode_hex(argv[2], &r_len);
  uint8_t *s = lk_decode_hex(argv[3], &s_len);
  if (!digest || !r || !s || digest_len != 32 || r_len != 32 || s_len != 32 ||
      !lk_parse_u32(argv[4], &v) || v > 3) {
    fprintf(stderr, "invalid input\n");
    free(digest);
    free(r);
    free(s);
    return 2;
  }

  uint8_t compact[64] = {0};
  memcpy(compact, r, 32);
  memcpy(compact + 32, s, 32);

  secp256k1_context *ctx = secp256k1_context_create(SECP256K1_CONTEXT_NONE);
  secp256k1_ecdsa_recoverable_signature sig;
  secp256k1_pubkey pubkey;
  if (!ctx ||
      !secp256k1_ecdsa_recoverable_signature_parse_compact(ctx, &sig, compact, (int)v) ||
      !secp256k1_ecdsa_recover(ctx, &pubkey, &sig, digest)) {
    fprintf(stderr, "recovery failed\n");
    secp256k1_context_destroy(ctx);
    free(digest);
    free(r);
    free(s);
    return 1;
  }

  uint8_t out[65] = {0};
  size_t out_len = sizeof(out);
  secp256k1_ec_pubkey_serialize(ctx, out, &out_len, &pubkey, SECP256K1_EC_UNCOMPRESSED);
  lk_print_hex(out, out_len);

  secp256k1_context_destroy(ctx);
  free(digest);
  free(r);
  free(s);
  return 0;
}
