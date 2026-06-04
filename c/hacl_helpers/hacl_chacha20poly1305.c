// SPDX-License-Identifier: MIT
//
// Small command-line wrapper around HACL ChaCha20-Poly1305.

#include "lk_hex.h"

#if __has_include(<Hacl_AEAD_Chacha20Poly1305.h>)
#include <Hacl_AEAD_Chacha20Poly1305.h>
#elif __has_include(<hacl/Hacl_AEAD_Chacha20Poly1305.h>)
#include <hacl/Hacl_AEAD_Chacha20Poly1305.h>
#else
#error "HACL ChaCha20-Poly1305 header not found"
#endif

int main(int argc, char **argv) {
  if (argc != 6) {
    fprintf(stderr, "usage: leancli-hacl-chacha20poly1305 <seal|open> <key-hex> <nonce-hex> <aad-hex> <payload-hex>\n");
    return 2;
  }

  int seal = strcmp(argv[1], "seal") == 0;
  int open = strcmp(argv[1], "open") == 0;
  if (!seal && !open) {
    fprintf(stderr, "mode must be seal or open\n");
    return 2;
  }

  uint32_t key_len = 0;
  uint32_t nonce_len = 0;
  uint32_t aad_len = 0;
  uint32_t payload_len = 0;
  uint8_t *key = lk_decode_hex(argv[2], &key_len);
  uint8_t *nonce = lk_decode_hex(argv[3], &nonce_len);
  uint8_t *aad = lk_decode_hex(argv[4], &aad_len);
  uint8_t *payload = lk_decode_hex(argv[5], &payload_len);
  if (!key || !nonce || !aad || !payload || key_len != 32 || nonce_len != 12) {
    fprintf(stderr, "invalid input\n");
    free(key);
    free(nonce);
    free(aad);
    free(payload);
    return 2;
  }

  if (seal) {
    uint8_t *out = calloc((size_t)payload_len + 16, 1);
    if (!out) {
      fprintf(stderr, "allocation failed\n");
      free(key);
      free(nonce);
      free(aad);
      free(payload);
      return 1;
    }
    Hacl_AEAD_Chacha20Poly1305_encrypt(out, out + payload_len, payload, payload_len,
                                       aad, aad_len, key, nonce);
    lk_print_hex(out, (size_t)payload_len + 16);
    free(out);
  } else {
    if (payload_len < 16) {
      fprintf(stderr, "ciphertext+tag must be at least 16 bytes\n");
      free(key);
      free(nonce);
      free(aad);
      free(payload);
      return 2;
    }
    uint32_t msg_len = payload_len - 16;
    uint8_t *out = calloc(msg_len == 0 ? 1 : msg_len, 1);
    if (!out) {
      fprintf(stderr, "allocation failed\n");
      free(key);
      free(nonce);
      free(aad);
      free(payload);
      return 1;
    }
    uint32_t rc = Hacl_AEAD_Chacha20Poly1305_decrypt(out, payload, msg_len, aad, aad_len,
                                                     key, nonce, payload + msg_len);
    if (rc != 0) {
      fprintf(stderr, "authentication failed\n");
      free(out);
      free(key);
      free(nonce);
      free(aad);
      free(payload);
      return 1;
    }
    lk_print_hex(out, msg_len);
    free(out);
  }

  free(key);
  free(nonce);
  free(aad);
  free(payload);
  return 0;
}
