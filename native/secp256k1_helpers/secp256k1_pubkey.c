// SPDX-License-Identifier: MIT

#include "../hacl_helpers/lk_hex.h"

#include <secp256k1.h>

int main(int argc, char **argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: leancli-secp256k1-pubkey <privkey-hex> <compressed|uncompressed>\n");
    return 2;
  }

  uint32_t priv_len = 0;
  uint8_t *priv = lk_decode_hex(argv[1], &priv_len);
  if (!priv || priv_len != 32) {
    fprintf(stderr, "invalid private key hex\n");
    free(priv);
    return 2;
  }

  unsigned int flags = 0;
  size_t out_len = 0;
  if (strcmp(argv[2], "compressed") == 0) {
    flags = SECP256K1_EC_COMPRESSED;
    out_len = 33;
  } else if (strcmp(argv[2], "uncompressed") == 0) {
    flags = SECP256K1_EC_UNCOMPRESSED;
    out_len = 65;
  } else {
    fprintf(stderr, "mode must be compressed or uncompressed\n");
    free(priv);
    return 2;
  }

  secp256k1_context *ctx = secp256k1_context_create(SECP256K1_CONTEXT_NONE);
  secp256k1_pubkey pubkey;
  if (!ctx || !secp256k1_ec_pubkey_create(ctx, &pubkey, priv)) {
    fprintf(stderr, "pubkey creation failed\n");
    secp256k1_context_destroy(ctx);
    free(priv);
    return 2;
  }

  uint8_t out[65] = {0};
  secp256k1_ec_pubkey_serialize(ctx, out, &out_len, &pubkey, flags);
  lk_print_hex(out, out_len);

  secp256k1_context_destroy(ctx);
  free(priv);
  return 0;
}
