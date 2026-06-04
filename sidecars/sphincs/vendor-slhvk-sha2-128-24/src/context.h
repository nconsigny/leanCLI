#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <vulkan/vulkan.h>

#include "slhvk.h"

#define N SLHVK_N

#define PRIMARY_SIGNING_PIPELINE_DESCRIPTOR_COUNT 5
#define SECONDARY_SIGNING_PIPELINE_DESCRIPTOR_COUNT 4
#define KEYGEN_PIPELINE_DESCRIPTOR_COUNT 4
#define VERIFY_PIPELINE_DESCRIPTOR_COUNT 2

// Buffer sizes. Cast through size_t so 128-24's multi-GB buffers don't overflow int.
//
// WOTS_CHAIN_BUFFER_SIZE: the upstream slhvk design computes WOTS chain tips into
// a flat buffer of size N * WOTS_CHAIN_COUNT * XMSS_LEAVES * LAYERS = 4.25 GB at
// 128-24, exceeding Vulkan's per-descriptor maxStorageBufferRange (4 GB - 1).
// We use a FUSED shader (keygen_xmss_leaves.comp) that computes tips inline per
// thread, so this buffer is now a placeholder kept only to satisfy descriptor
// set layout binding 2 — no shader actually reads or writes it.
#define WOTS_CHAIN_BUFFER_SIZE ((size_t) 1024)
#define XMSS_NODES_BUFFER_SIZE ((size_t) N * SLHVK_XMSS_LEAVES * SLHVK_HYPERTREE_LAYERS)
#define XMSS_MESSAGES_BUFFER_SIZE (sizeof(uint32_t) * SLHVK_WOTS_CHAIN_COUNT * SLHVK_HYPERTREE_LAYERS)
#define FORS_MESSAGE_BUFFER_SIZE (sizeof(uint32_t) * SLHVK_FORS_TREE_COUNT)
// 128-24 fork: N * FORS_TREE_COUNT * FORS_LEAVES_COUNT = 16 * 6 * 2^24 = 1.6 GB.
// Fits within Vulkan's per-descriptor cap (4 GB − 1). The earlier "chunked
// over trees" attempt is kept in git history; with adequate VRAM the upstream
// flat-buffer model is simpler and matches what we cross-validated at 128s.
#define FORS_NODES_BUFFER_SIZE ((size_t) N * SLHVK_FORS_TREE_COUNT * SLHVK_FORS_LEAVES_COUNT)
#define FORS_ROOTS_BUFFER_SIZE (N * SLHVK_FORS_TREE_COUNT)
#define FORS_PUBKEY_STAGING_BUFFER_SIZE (sizeof(uint32_t) * SLHVK_WOTS_CHAIN_COUNT)

typedef struct CommonSigningInputs {
  // The SHA256 state after absorbing the `pk_seed` and padding.
  uint32_t sha256State[8];

  // Secret seed from the private key.
  uint32_t skSeed[SLHVK_HASH_WORDS];

  // adrs[1:4]
  uint64_t treeAddress;

  // the index of the layer 0 keypair to be used for signing the message.
  uint32_t signingKeypairAddress;

  // Indicates if top-level XMSS tree leaves have been preloaded into memory, saving
  // us from redundant recomputation.
  uint32_t cachedTreeLayers;
} CommonSigningInputs;

typedef struct SlhvkContext_T {
  VkInstance instance;

  // Resources for the primary device
  VkPhysicalDevice           primaryPhysicalDevice;
  VkPhysicalDeviceProperties primaryDeviceProperties;
  uint32_t                   primaryDeviceQueueFamily;
  VkDevice                   primaryDevice;
  VkDescriptorPool           primaryDescriptorPool;
  VkCommandPool              primaryCommandPool;

  // Resources for the secondary device
  VkPhysicalDevice           secondaryPhysicalDevice;
  VkPhysicalDeviceProperties secondaryDeviceProperties;
  uint32_t                   secondaryDeviceQueueFamily;
  VkDevice                   secondaryDevice;
  VkDescriptorPool           secondaryDescriptorPool;
  VkCommandPool              secondaryCommandPool;


  /*******  Signing resources (primary)  **********/
  VkShaderModule        wotsTipsPrecomputeShader;
  VkShaderModule        xmssLeavesPrecomputeShader;
  VkShaderModule        xmssMerkleSignShader;
  VkShaderModule        xmssMerkleSignTopShader; /* 128-24 fork: top-phase XMSS build */
  VkShaderModule        wotsSignShader;
  VkPipeline            wotsTipsPrecomputePipeline;
  /* 128-24 fork: dispatch-base variant for the throttled chunked path. */
  VkPipeline            wotsTipsPrecomputeChunkPipeline;
  VkPipeline            xmssLeavesPrecomputePipeline;
  VkPipeline            xmssMerkleSignPipeline;
  VkPipeline            xmssMerkleSignTopPipeline; /* 128-24 fork: top-phase XMSS build */
  VkPipeline            wotsSignPipeline;
  VkPipelineLayout      primarySigningPipelineLayout;
  VkDescriptorSetLayout primarySigningDescriptorSetLayout;
  VkDescriptorSet       primarySigningDescriptorSet;
  VkEvent               primaryXmssRootTreeCopyDoneEvent;

  /*******  Signing resources (secondary)  **********/
  VkShaderModule        forsLeavesGenShader;
  VkShaderModule        forsMerkleSignShader;
  VkPipeline            forsLeavesGenPipeline;
  /* 128-24 fork: dispatch-base variant of FORS leaves gen for the throttled
   * chunked path on the secondary queue. */
  VkPipeline            forsLeavesGenChunkPipeline;
  VkPipeline            forsMerkleSignPipeline;
  VkPipelineLayout      secondarySigningPipelineLayout;
  VkDescriptorSetLayout secondarySigningDescriptorSetLayout;
  VkDescriptorSet       secondarySigningDescriptorSet;

  /*******  Keygen resources  ***********/
  VkShaderModule        keygenWotsTipsShader;
  VkShaderModule        keygenXmssLeavesShader;
  VkShaderModule        keygenXmssRootsShader;
  VkPipeline            keygenWotsTipsPipeline;
  VkPipeline            keygenXmssLeavesPipeline;
  /* 128-24 fork: dispatch-base variant of keygen XMSS leaves, used by the
   * throttled chunked path. Same shader, second pipeline with
   * VK_PIPELINE_CREATE_DISPATCH_BASE_BIT. */
  VkPipeline            keygenXmssLeavesChunkPipeline;
  VkPipeline            keygenXmssRootsPipeline;
  VkPipelineLayout      keygenPipelineLayout;
  VkDescriptorSetLayout keygenDescriptorSetLayout;
  VkDescriptorSet       keygenDescriptorSet;

  /********  Verify resources  **********/
  VkShaderModule        verifyShader;
  VkPipeline            verifyPipeline;
  VkPipelineLayout      verifyPipelineLayout;
  VkDescriptorSetLayout verifyDescriptorSetLayout;
  VkDescriptorSet       verifyDescriptorSet;

  // primary device buffers
  VkBuffer primaryInputsBufferDeviceLocal;
  VkBuffer primaryInputsBufferHostVisible;
  VkBuffer primaryWotsChainBuffer;
  VkBuffer primaryXmssNodesBuffer;
  VkBuffer primaryXmssMessagesBuffer;
  VkBuffer primaryForsPubkeyStagingBuffer;
  VkBuffer primaryHypertreeSignatureBufferDeviceLocal;
  VkBuffer primaryHypertreeSignatureBufferHostVisible;

  // primary device memory backings (one per buffer)
  VkDeviceMemory primaryInputsBufferDeviceLocalMemory;
  VkDeviceMemory primaryInputsBufferHostVisibleMemory;
  VkDeviceMemory primaryWotsChainBufferMemory;
  VkDeviceMemory primaryXmssNodesBufferMemory;
  VkDeviceMemory primaryXmssMessagesBufferMemory;
  VkDeviceMemory primaryForsPubkeyStagingBufferMemory;
  VkDeviceMemory primaryHypertreeSignatureBufferDeviceLocalMemory;
  VkDeviceMemory primaryHypertreeSignatureBufferHostVisibleMemory;

  // secondary device buffers
  VkBuffer secondaryInputsBufferDeviceLocal;
  VkBuffer secondaryInputsBufferHostVisible;
  VkBuffer secondaryForsMessageBufferDeviceLocal;
  VkBuffer secondaryForsMessageBufferHostVisible;
  VkBuffer secondaryForsNodesBuffer;
  VkBuffer secondaryForsSignatureBufferDeviceLocal;
  VkBuffer secondaryForsSignatureBufferHostVisible;
  VkBuffer secondaryForsRootsBuffer;

  // secondary device memory backings (one per buffer)
  VkDeviceMemory secondaryInputsBufferDeviceLocalMemory;
  VkDeviceMemory secondaryInputsBufferHostVisibleMemory;
  VkDeviceMemory secondaryForsMessageBufferDeviceLocalMemory;
  VkDeviceMemory secondaryForsMessageBufferHostVisibleMemory;
  VkDeviceMemory secondaryForsNodesBufferMemory;
  VkDeviceMemory secondaryForsSignatureBufferDeviceLocalMemory;
  VkDeviceMemory secondaryForsSignatureBufferHostVisibleMemory;
  VkDeviceMemory secondaryForsRootsBufferMemory;

  // primary device memory metadata
  VkMemoryPropertyFlags primaryDeviceLocalMemoryFlags;
  VkMemoryPropertyFlags primaryDeviceHostVisibleMemoryFlags;

  // secondary device memory metadata
  VkMemoryPropertyFlags secondaryDeviceLocalMemoryFlags;
  VkMemoryPropertyFlags secondaryDeviceHostVisibleMemoryFlags;

  // primary device command buffers
  VkCommandBuffer primaryHypertreePresignCommandBuffer;
  VkCommandBuffer primaryHypertreeFinishCommandBuffer;
  VkCommandBuffer primaryXmssRootTreeCopyCommandBuffer;
  VkCommandBuffer primaryKeygenCommandBuffer;
  VkCommandBuffer primaryVerifyCommandBuffer;
  /* 128-24 fork: chunked WOTS tips dispatch — re-recorded per chunk at sign time. */
  VkCommandBuffer primaryWotsTipsChunkCommandBuffer;
  /* 128-24 fork: throttled-path twin of primaryHypertreePresignCommandBuffer
   * that skips the WOTS tips dispatch (already handled by chunked submissions). */
  VkCommandBuffer primaryHypertreePresignNoWotsCommandBuffer;

  // secondary device command buffer
  VkCommandBuffer secondaryForsCommandBuffer;
  /* 128-24 fork: FORS cmd buffer variant that SKIPS the FORS leaves gen
   * dispatch — used by the throttled chunked path, paired with a separate
   * chunked submission of forsLeavesGenChunkPipeline. */
  VkCommandBuffer secondaryForsCommandBufferNoLeaves;
  /* 128-24 fork: re-recorded per chunk at sign time. */
  VkCommandBuffer secondaryForsLeavesChunkCommandBuffer;
} SlhvkContext_T;
