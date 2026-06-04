#pragma once
#include <stdint.h>

// =============================================================================
// SLH-DSA-SHA2-128-24 (NIST SP 800-230 IPD, April 2026) parameters.
//
// Forked from conduition/slhvk (which targets SLH-DSA-SHA2-128s, FIPS 205).
// All hash conventions are FIPS 205 bit-exact (22-byte compressed ADRSc,
// nested MGF1 Hmsg). The on-chain verifier `SLH-DSA-SHA2-128-24verifier.sol`
// accepts these signatures.
//
// Parameter changes vs upstream 128s:
//   HYPERTREE_HEIGHT : 63 -> 22
//   HYPERTREE_LAYERS :  7 -> 1    (d=1, single XMSS tree)
//   LOG_W            :  4 -> 2    (w=4)
//   FORS_TREE_COUNT  : 14 -> 6
//   FORS_TREE_HEIGHT : 12 -> 24
// =============================================================================

// Security parameter (n).
#define SLHVK_N 16
#define SLHVK_HASH_WORDS (SLHVK_N / 4)

// Hypertree.
#define SLHVK_HYPERTREE_HEIGHT 22
#define SLHVK_HYPERTREE_LAYERS 1

// Winternitz parameter. lgw=2 -> w=4. (Adds a new branch in convert_to_base_w.)
#define SLHVK_LOG_W 2

// FORS.
#define SLHVK_FORS_TREE_COUNT 6
#define SLHVK_FORS_TREE_HEIGHT 24

/*** The rest are derivative constants. ***/

#define SLHVK_WOTS_CHAIN_LEN (1 << SLHVK_LOG_W)
#define SLHVK_WOTS_CHAIN_COUNT1 (8 * SLHVK_N / SLHVK_LOG_W)

// ceil(ceil(log2(WOTS_CHAIN_COUNT1 * (WOTS_CHAIN_LEN - 1))) / LOG_W)
// 128-24 (lgw=2, n=16): l1=64, l1*(w-1)=192, bit-len=8, l2=ceil(8/2)=4.
// 128s   (lgw=4, n=16): l1=32, l1*(w-1)=480, bit-len=9, l2=ceil(9/4)=3.
// 128f   (lgw=8, n=16): l1=16, l1*(w-1)=4080, bit-len=12, l2=ceil(12/8)=2.
#if SLHVK_LOG_W == 2
  #define SLHVK_WOTS_CHAIN_COUNT2 4
#elif SLHVK_LOG_W == 4
  #define SLHVK_WOTS_CHAIN_COUNT2 3
#elif SLHVK_LOG_W == 8
  #define SLHVK_WOTS_CHAIN_COUNT2 2
#endif

#define SLHVK_WOTS_CHAIN_COUNT (SLHVK_WOTS_CHAIN_COUNT1 + SLHVK_WOTS_CHAIN_COUNT2)
#define SLHVK_WOTS_SIGNATURE_SIZE (SLHVK_WOTS_CHAIN_COUNT * SLHVK_N)

#define SLHVK_FORS_DIGEST_SIZE ((SLHVK_FORS_TREE_COUNT * SLHVK_FORS_TREE_HEIGHT + 7) / 8)
#define SLHVK_FORS_LEAVES_COUNT (1 << SLHVK_FORS_TREE_HEIGHT)
#define SLHVK_FORS_SIGNATURE_SIZE (SLHVK_N * SLHVK_FORS_TREE_COUNT * (1 + SLHVK_FORS_TREE_HEIGHT))

#define SLHVK_HYPERTREE_SIGNATURE_SIZE (SLHVK_N * SLHVK_HYPERTREE_LAYERS * (SLHVK_XMSS_HEIGHT + SLHVK_WOTS_CHAIN_COUNT))

// XMSS.
#define SLHVK_XMSS_HEIGHT (SLHVK_HYPERTREE_HEIGHT / SLHVK_HYPERTREE_LAYERS)
#define SLHVK_XMSS_LEAVES (1 << SLHVK_XMSS_HEIGHT)
#define SLHVK_XMSS_CACHED_TREE_SIZE (SLHVK_N * SLHVK_XMSS_LEAVES)

// Serialized SLH-DSA signature size. 128-24: 16 + 2400 + 1440 = 3856 bytes.
#define SLHVK_SIGNATURE_SIZE (SLHVK_N + SLHVK_FORS_SIGNATURE_SIZE + SLHVK_HYPERTREE_SIGNATURE_SIZE)

// Msg digest bytes used to select an XMSS tree (M1). At d=1 this is zero.
#define SLHVK_TREE_ADDRESS_DIGEST_SIZE ((SLHVK_HYPERTREE_HEIGHT - SLHVK_XMSS_HEIGHT + 7) / 8)

// Msg digest bytes used to select WOTS/FORS leaf (M2). 128-24: ceil(22/8)=3.
#define SLHVK_KEYPAIR_ADDRESS_DIGEST_SIZE ((SLHVK_XMSS_HEIGHT + 7) / 8)

// Hashed message digest size in bytes (m). 128-24: 0+3+18=21.
#define SLHVK_MESSAGE_DIGEST_SIZE (SLHVK_TREE_ADDRESS_DIGEST_SIZE + SLHVK_KEYPAIR_ADDRESS_DIGEST_SIZE + SLHVK_FORS_DIGEST_SIZE)


// Vulkan parameters.
#define SLHVK_DEFAULT_WORK_GROUP_SIZE 64


typedef struct SlhvkContext_T* SlhvkContext;

typedef enum SlhvkError {
  SLHVK_SUCCESS = 0,
  SLHVK_ERROR_NO_COMPUTE_DEVICE = 40,
  SLHVK_ERROR_MEMORY_TYPE_NOT_FOUND = 41,
} SlhvkError;

void slhvkContextFree(SlhvkContext ctx);
int slhvkContextInit(SlhvkContext* ctxPtr);


typedef struct SlhvkCachedRootTree_T* SlhvkCachedRootTree;

int slhvkCachedRootTreeInit(SlhvkContext ctx, SlhvkCachedRootTree* cachedRootTreePtr);
void slhvkCachedRootTreeFree(SlhvkCachedRootTree cachedRootTree);


int slhvkSignPure(
  SlhvkContext ctx,
  uint8_t const skSeed[SLHVK_N],
  uint8_t const skPrf[SLHVK_N],
  uint8_t const pkSeed[SLHVK_N],
  uint8_t const pkRoot[SLHVK_N],
  uint8_t const addrnd[SLHVK_N],
  uint8_t const* contextString,
  uint8_t contextStringSize,
  uint8_t const* rawMessage,
  size_t rawMessageSize,
  const SlhvkCachedRootTree cachedXmssRootTree,
  uint8_t signatureOutput[SLHVK_SIGNATURE_SIZE]
);

int slhvkKeygenBulk(
  SlhvkContext ctx,
  uint32_t keysCount,
  uint8_t const* const* skSeeds,
  uint8_t const* const* pkSeeds,
  uint8_t** pkRootsOut,
  SlhvkCachedRootTree* cachedRootTreesOut
);

int slhvkKeygen(
  SlhvkContext ctx,
  uint8_t const skSeed[SLHVK_N],
  uint8_t const pkSeed[SLHVK_N],
  uint8_t* pkRoot,
  SlhvkCachedRootTree cachedRootTree
);

int slhvkVerifyPure(
  SlhvkContext ctx,
  uint32_t signaturesLen,
  uint8_t const* const* contextStrings,
  uint8_t const* contextStringSizes,
  uint8_t const* const* pkSeeds,
  uint8_t const* const* pkRoots,
  uint8_t const* const* signatures,
  uint8_t const* const* messages,
  size_t const* messageSizes,
  int* verifyResultsOut
);
