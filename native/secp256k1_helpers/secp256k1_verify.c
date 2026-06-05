// SPDX-License-Identifier: MIT

#include "../hacl_helpers/lk_hex.h"

#include <secp256k1.h>

int main(int argc, char **argv) {
  if (argc != 5) {
    fprintf(stderr, "usage: leancli-secp256k1-verify <digest-hex> <r-hex> <s-hex> <pubkey-hex>\n");
    return 2;
  }

  uint32_t digest_len = 0;
  uint32_t r_len = 0;
  uint32_t s_len = 0;
  uint32_t pubkey_len = 0;
  uint8_t *digest = lk_decode_hex(argv[1], &digest_len);
  uint8_t *r = lk_decode_hex(argv[2], &r_len);
  uint8_t *s = lk_decode_hex(argv[3], &s_len);
  uint8_t *pubkey_bytes = lk_decode_hex(argv[4], &pubkey_len);
  if (!digest || !r || !s || !pubkey_bytes || digest_len != 32 || r_len != 32 || s_len != 32) {
    fprintf(stderr, "invalid input\n");
    free(digest);
    free(r);
    free(s);
    free(pubkey_bytes);
    return 2;
  }

  uint8_t compact[64] = {0};
  memcpy(compact, r, 32);
  memcpy(compact + 32, s, 32);

  secp256k1_context *ctx = secp256k1_context_create(SECP256K1_CONTEXT_NONE);
  secp256k1_ecdsa_signature sig;
  secp256k1_pubkey pubkey;
  uint8_t out = 0;
  if (ctx &&
      secp256k1_ecdsa_signature_parse_compact(ctx, &sig, compact) &&
      secp256k1_ec_pubkey_parse(ctx, &pubkey, pubkey_bytes, pubkey_len)) {
    secp256k1_ecdsa_signature normalized;
    secp256k1_ecdsa_signature_normalize(ctx, &normalized, &sig);
    out = secp256k1_ecdsa_verify(ctx, &normalized, digest, &pubkey) ? 1 : 0;
  }

  lk_print_hex(&out, 1);
  secp256k1_context_destroy(ctx);
  free(digest);
  free(r);
  free(s);
  free(pubkey_bytes);
  return 0;
}
