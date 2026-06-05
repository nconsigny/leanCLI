// SPDX-License-Identifier: MIT

#include "../hacl_helpers/lk_hex.h"

#include <secp256k1.h>
#include <secp256k1_recovery.h>

int main(int argc, char **argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: leancli-secp256k1-sign <privkey-hex> <digest-hex>\n");
    return 2;
  }

  uint32_t priv_len = 0;
  uint32_t digest_len = 0;
  uint8_t *priv = lk_decode_hex(argv[1], &priv_len);
  uint8_t *digest = lk_decode_hex(argv[2], &digest_len);
  if (!priv || !digest || priv_len != 32 || digest_len != 32) {
    fprintf(stderr, "invalid input\n");
    free(priv);
    free(digest);
    return 2;
  }

  secp256k1_context *ctx = secp256k1_context_create(SECP256K1_CONTEXT_NONE);
  if (!ctx || !secp256k1_ec_seckey_verify(ctx, priv)) {
    fprintf(stderr, "invalid private key\n");
    secp256k1_context_destroy(ctx);
    free(priv);
    free(digest);
    return 2;
  }

  secp256k1_ecdsa_recoverable_signature sig;
  if (!secp256k1_ecdsa_sign_recoverable(ctx, &sig, digest, priv, NULL, NULL)) {
    fprintf(stderr, "signing failed\n");
    secp256k1_context_destroy(ctx);
    free(priv);
    free(digest);
    return 1;
  }

  uint8_t out[65] = {0};
  int recid = 0;
  secp256k1_ecdsa_recoverable_signature_serialize_compact(ctx, out, &recid, &sig);
  out[64] = (uint8_t)recid;
  lk_print_hex(out, sizeof(out));

  secp256k1_context_destroy(ctx);
  free(priv);
  free(digest);
  return 0;
}
