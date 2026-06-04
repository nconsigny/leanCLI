#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <vulkan/vulkan.h>

#include "context.h"
#include "hashing.h"
#include "keygen.h"
#include "sha256.h"
#include "vkutil.h"

static void prepstate(ShaContext* shaCtx, const uint8_t pkSeed[N]) {
  uint8_t block[64] = {0};
  memcpy(block, pkSeed, N);
  slhvkSha256Init(shaCtx);
  slhvkSha256Update(shaCtx, block, 64);
}

int slhvkSignPure(
  SlhvkContext ctx,
  uint8_t const skSeed[N],
  uint8_t const skPrf[N],
  uint8_t const pkSeed[N],
  uint8_t const pkRoot[N],
  uint8_t const addrnd[N],
  uint8_t const* contextString,
  uint8_t contextStringSize,
  uint8_t const* rawMessage,
  size_t rawMessageSize,
  const SlhvkCachedRootTree cachedXmssRootTree,
  uint8_t signatureOutput[SLHVK_SIGNATURE_SIZE]
) {
  // Deterministic mode
  if (addrnd == NULL) addrnd = pkSeed;

  uint8_t randomizer[N];
  slhvkMessagePrf(
    skPrf,
    addrnd,
    contextString,
    contextStringSize,
    rawMessage,
    rawMessageSize,
    randomizer
  );

  uint32_t forsIndices[SLHVK_FORS_TREE_COUNT];
  uint64_t treeAddress;
  uint32_t signingKeypairAddress;
  slhvkDigestAndSplitMsg(
    randomizer,
    pkSeed,
    pkRoot,
    contextString,
    contextStringSize,
    rawMessage,
    rawMessageSize,
    forsIndices,
    &treeAddress,
    &signingKeypairAddress
  );

  VkQueue primaryQueue;
  vkGetDeviceQueue(ctx->primaryDevice, ctx->primaryDeviceQueueFamily, 0, &primaryQueue);

  VkQueue secondaryQueue;
  if (ctx->secondaryDevice == ctx->primaryDevice) {
    secondaryQueue = primaryQueue;
  } else {
    vkGetDeviceQueue(ctx->secondaryDevice, ctx->secondaryDeviceQueueFamily, 0, &secondaryQueue);
  }

  // We create two fences to await the final outputs on each device.
  VkFence primaryFence = NULL;
  VkFence secondaryFence = NULL;

  VkFenceCreateInfo fenceCreateInfo = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
  int err = vkCreateFence(ctx->primaryDevice, &fenceCreateInfo, NULL, &primaryFence);
  if (err) goto cleanup;
  err = vkCreateFence(ctx->secondaryDevice, &fenceCreateInfo, NULL, &secondaryFence);
  if (err) goto cleanup;

  // Prehash the pk_seed value.
  ShaContext shaCtxInitial;
  prepstate(&shaCtxInitial, pkSeed);

  // Write inputs straight to the device local buffers if we can.
  VkDeviceMemory primaryInputsMemory = (ctx->primaryDeviceLocalMemoryFlags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)
    ? ctx->primaryInputsBufferDeviceLocalMemory
    : ctx->primaryInputsBufferHostVisibleMemory;
  VkDeviceMemory secondaryInputsMemory = (ctx->secondaryDeviceLocalMemoryFlags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)
    ? ctx->secondaryInputsBufferDeviceLocalMemory
    : ctx->secondaryInputsBufferHostVisibleMemory;

  VkDeviceMemory memories[2] = { primaryInputsMemory, secondaryInputsMemory };
  VkDevice       devices[2]  = { ctx->primaryDevice, ctx->secondaryDevice };

  for (int i = 0; i < 2; i++) {
    CommonSigningInputs* mapped = NULL;
    err = vkMapMemory(
      devices[i],
      memories[i],
      0, // offset
      sizeof(CommonSigningInputs),
      0, // flags
      (void**) &mapped
    );
    if (err) goto cleanup;

    memcpy(&mapped->sha256State[0], shaCtxInitial.state, sizeof(uint32_t) * 8);

    // Copy the skSeed into a big-endian encoded u32 array
    for (size_t i = 0; i < SLHVK_HASH_WORDS; i++) {
      size_t i4 = i * sizeof(uint32_t);
      mapped->skSeed[i] = ((uint32_t) skSeed[i4] << 24) | ((uint32_t) skSeed[i4 + 1] << 16) |
                          ((uint32_t) skSeed[i4 + 2] << 8) | (uint32_t) skSeed[i4 + 3];
    }
    mapped->treeAddress = treeAddress;
    mapped->signingKeypairAddress = signingKeypairAddress;
    mapped->cachedTreeLayers = (cachedXmssRootTree == NULL ? 0 : 1);
    vkUnmapMemory(devices[i], memories[i]);
  }

  // Start the command buffer which may be used to copy the root XMSS tree to the correct
  // region of the XMSS nodes buffer.
  err = vkResetCommandBuffer(ctx->primaryXmssRootTreeCopyCommandBuffer, 0);
  if (err) goto cleanup;

  VkCommandBufferBeginInfo cmdBufBeginInfo = {
    .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
  };
  err = vkBeginCommandBuffer(ctx->primaryXmssRootTreeCopyCommandBuffer, &cmdBufBeginInfo);
  if (err) goto cleanup;

  // Copy the cached root tree to the xmss nodes buffer.
  if (cachedXmssRootTree != NULL) {
    VkBufferCopy regions = {
      .size = SLHVK_XMSS_CACHED_TREE_SIZE,
      .dstOffset = N * SLHVK_XMSS_LEAVES * (SLHVK_HYPERTREE_LAYERS - 1),
    };
    vkCmdCopyBuffer(
      ctx->primaryXmssRootTreeCopyCommandBuffer,
      cachedXmssRootTree->buffer,  // src
      ctx->primaryXmssNodesBuffer, // dest
      1, // region count
      &regions // regions
    );
  }

  // 128-24 fork: explicit TRANSFER_WRITE -> SHADER_READ barrier so the entire
  // cache->nodesBuffer copy is visible to the subsequent XMSS shaders. Pairs
  // with the analogous SHADER_WRITE -> TRANSFER_READ barrier in keygen.c that
  // makes the leaves shader's output available to the cache copy. With both
  // barriers in place the cached XMSS root tree is deterministic across runs.
  if (cachedXmssRootTree != NULL) {
    VkBufferMemoryBarrier cacheCopyAvailabilityBarrier = {
      .sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
      .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
      .dstAccessMask = VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT,
      .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
      .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
      .buffer = ctx->primaryXmssNodesBuffer,
      .offset = 0,
      .size = VK_WHOLE_SIZE,
    };
    vkCmdPipelineBarrier(
      ctx->primaryXmssRootTreeCopyCommandBuffer,
      VK_PIPELINE_STAGE_TRANSFER_BIT,
      VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
      0,
      0, NULL,
      1, &cacheCopyAvailabilityBarrier,
      0, NULL
    );
  }

  // Signal the event AFTER the TRANSFER stage (and our explicit barrier above)
  // completes (upstream's COMPUTE_SHADER_BIT was the wrong stage for a buffer copy).
  vkCmdSetEvent(
    ctx->primaryXmssRootTreeCopyCommandBuffer,
    ctx->primaryXmssRootTreeCopyDoneEvent,
    VK_PIPELINE_STAGE_ALL_COMMANDS_BIT
  );

  err = vkEndCommandBuffer(ctx->primaryXmssRootTreeCopyCommandBuffer);
  if (err) goto cleanup;

  /* 128-24 fork: chunked WOTS tips precompute (throttle).
   *
   * SLHVK_GPU_DUTY <  1.0  → chunked path: re-record the WOTS tips dispatch
   *                          as N slices via vkCmdDispatchBase, submit each
   *                          with fence wait + CPU sleep between them so
   *                          the GPU genuinely idles in the gaps (real btop
   *                          % drop, not just longer wall time). The cache
   *                          copy piggy-backs on chunk 0's submission to
   *                          overlap with WOTS work. After all chunks the
   *                          `primaryHypertreePresignNoWotsCommandBuffer` is
   *                          submitted (XMSS leaves + merkle only).
   *
   * SLHVK_GPU_DUTY == 1.0 → fast path: original behavior — submit
   *                          [cache_copy, primaryHypertreePresignCommandBuffer]
   *                          (which has WOTS tips inside) as a single
   *                          vkQueueSubmit. No CPU sync between phases.
   *
   * Default chunk count: 8 in throttled mode. Override with SLHVK_GPU_CHUNKS=N.
   */
  uint32_t nChunks;
  {
    const char* envChunks = getenv("SLHVK_GPU_CHUNKS");
    if (envChunks != NULL && envChunks[0] != '\0') {
      long v = strtol(envChunks, NULL, 10);
      if (v >= 1 && v <= 256) nChunks = (uint32_t) v;
      else nChunks = 1;
    } else {
      const char* envDuty = getenv("SLHVK_GPU_DUTY");
      double duty = (envDuty != NULL) ? atof(envDuty) : 1.0;
      nChunks = (duty > 0.0 && duty < 1.0) ? 8u : 1u;
    }
  }

  if (nChunks == 1) {
    /* Fast path: submit cache_copy + presign (WOTS tips inside) in one
     * VkSubmitInfo — same shape as the original upstream signing flow. */
    VkCommandBuffer fastBufs[2] = {
      ctx->primaryXmssRootTreeCopyCommandBuffer,
      ctx->primaryHypertreePresignCommandBuffer,
    };
    VkSubmitInfo fastSubmitInfo = {
      .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
      .commandBufferCount = 2,
      .pCommandBuffers = fastBufs,
    };
    err = vkQueueSubmit(primaryQueue, 1, &fastSubmitInfo, primaryFence);
    if (err) goto cleanup;
  } else {
    /* Throttled path: N chunked WOTS tips submissions + presign_no_wots. */
    const uint32_t wotsTipsTotalWorkgroups =
      slhvkNumWorkGroups(SLHVK_HYPERTREE_LAYERS * SLHVK_XMSS_LEAVES * SLHVK_WOTS_CHAIN_COUNT);

    VkCommandBufferBeginInfo wotsCmdBufBeginInfo = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
    };
    for (uint32_t chunk = 0; chunk < nChunks; chunk++) {
      uint32_t chunkBase = (uint32_t) ((uint64_t) wotsTipsTotalWorkgroups * chunk / nChunks);
      uint32_t chunkEnd  = (uint32_t) ((uint64_t) wotsTipsTotalWorkgroups * (chunk + 1) / nChunks);
      uint32_t chunkSize = chunkEnd - chunkBase;
      if (chunkSize == 0) continue;

      err = vkResetCommandBuffer(ctx->primaryWotsTipsChunkCommandBuffer, 0);
      if (err) goto cleanup;
      err = vkBeginCommandBuffer(ctx->primaryWotsTipsChunkCommandBuffer, &wotsCmdBufBeginInfo);
      if (err) goto cleanup;
      vkCmdBindDescriptorSets(
        ctx->primaryWotsTipsChunkCommandBuffer,
        VK_PIPELINE_BIND_POINT_COMPUTE,
        ctx->primarySigningPipelineLayout,
        0, 1, &ctx->primarySigningDescriptorSet,
        0, NULL
      );
      vkCmdBindPipeline(
        ctx->primaryWotsTipsChunkCommandBuffer,
        VK_PIPELINE_BIND_POINT_COMPUTE,
        ctx->wotsTipsPrecomputeChunkPipeline
      );
      vkCmdDispatchBase(
        ctx->primaryWotsTipsChunkCommandBuffer,
        chunkBase, 0, 0,
        chunkSize, 1, 1
      );
      err = vkEndCommandBuffer(ctx->primaryWotsTipsChunkCommandBuffer);
      if (err) goto cleanup;

      VkCommandBuffer chunkSubmitBufs[2];
      uint32_t chunkSubmitCount = 0;
      if (chunk == 0) {
        chunkSubmitBufs[chunkSubmitCount++] = ctx->primaryXmssRootTreeCopyCommandBuffer;
      }
      chunkSubmitBufs[chunkSubmitCount++] = ctx->primaryWotsTipsChunkCommandBuffer;

      VkSubmitInfo wotsSubmitInfo = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .commandBufferCount = chunkSubmitCount,
        .pCommandBuffers = chunkSubmitBufs,
      };
      err = vkQueueSubmit(primaryQueue, 1, &wotsSubmitInfo, primaryFence);
      if (err) goto cleanup;
      err = slhvkWaitFenceThrottled(ctx->primaryDevice, primaryFence, 100e9);
      if (err) goto cleanup;
      err = vkResetFences(ctx->primaryDevice, 1, &primaryFence);
      if (err) goto cleanup;
    }

    /* After all chunks, submit the presign cmd buffer that SKIPS WOTS tips. */
    VkCommandBuffer presignBufs[1] = {
      ctx->primaryHypertreePresignNoWotsCommandBuffer,
    };
    VkSubmitInfo presignSubmitInfo = {
      .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
      .commandBufferCount = 1,
      .pCommandBuffers = presignBufs,
    };
    err = vkQueueSubmit(primaryQueue, 1, &presignSubmitInfo, primaryFence);
    if (err) goto cleanup;
  }

  // Write the FORS indices to the FORS message buffer so it will be signed.
  VkDeviceMemory forsMessageMemory = (ctx->secondaryDeviceLocalMemoryFlags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)
    ? ctx->secondaryForsMessageBufferDeviceLocalMemory
    : ctx->secondaryForsMessageBufferHostVisibleMemory;
  uint32_t* mappedForsMessage = NULL;
  err = vkMapMemory(
    ctx->secondaryDevice,
    forsMessageMemory,
    0, // offset
    FORS_MESSAGE_BUFFER_SIZE,
    0, // flags
    (void**) &mappedForsMessage
  );
  if (err) goto cleanup;
  memcpy(mappedForsMessage, forsIndices, FORS_MESSAGE_BUFFER_SIZE);
  vkUnmapMemory(ctx->secondaryDevice, forsMessageMemory);

  /* 128-24 fork: throttled-path chunked FORS leaves gen on the secondary
   * queue. nChunks was already computed up top for the primary throttle. */
  if (nChunks == 1) {
    /* Fast path: original — submit the full FORS cmd buffer once. */
    VkSubmitInfo submitInfo = {
      .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
      .commandBufferCount = 1,
      .pCommandBuffers = &ctx->secondaryForsCommandBuffer,
    };
    err = vkQueueSubmit(secondaryQueue, 1, &submitInfo, secondaryFence);
    if (err) goto cleanup;
  } else {
    /* Throttled path: chunked FORS leaves gen + no-leaves FORS cmd buffer. */
    const uint32_t forsLeavesTotalWg =
      slhvkNumWorkGroups(SLHVK_FORS_TREE_COUNT * SLHVK_FORS_LEAVES_COUNT);
    VkCommandBufferBeginInfo forsChunkBeginInfo = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
    };
    for (uint32_t chunk = 0; chunk < nChunks; chunk++) {
      uint32_t base = (uint32_t) ((uint64_t) forsLeavesTotalWg * chunk / nChunks);
      uint32_t end  = (uint32_t) ((uint64_t) forsLeavesTotalWg * (chunk + 1) / nChunks);
      uint32_t size = end - base;
      if (size == 0) continue;

      err = vkResetCommandBuffer(ctx->secondaryForsLeavesChunkCommandBuffer, 0);
      if (err) goto cleanup;
      err = vkBeginCommandBuffer(ctx->secondaryForsLeavesChunkCommandBuffer, &forsChunkBeginInfo);
      if (err) goto cleanup;

      /* On the FIRST chunk only, replicate the staging->device input copies
       * that the prebuilt FORS cmd buffer would have done. Without these,
       * when staging is used (non-ReBAR), the chunked dispatch reads stale
       * device-local FORS inputs/messages and produces a wrong FORS sig.
       *
       * IMPORTANT: do NOT vkCmdFillBuffer the host-visible source to zero
       * here — the prebuilt no-leaves FORS cmd buffer that runs AFTER all
       * chunks ALSO copies from the same host-visible source. If we zero it
       * here, the no-leaves cmd buffer's copy writes zeros to device-local,
       * clobbering the inputs that the merkle sign shader will then read.
       * The security wipe is left to the no-leaves cmd buffer's preamble. */
      if (chunk == 0 &&
          (ctx->secondaryDeviceLocalMemoryFlags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) == 0) {
        VkBufferCopy regions = { .size = sizeof(CommonSigningInputs) };
        vkCmdCopyBuffer(
          ctx->secondaryForsLeavesChunkCommandBuffer,
          ctx->secondaryInputsBufferHostVisible,
          ctx->secondaryInputsBufferDeviceLocal,
          1, &regions
        );
        regions.size = FORS_MESSAGE_BUFFER_SIZE;
        vkCmdCopyBuffer(
          ctx->secondaryForsLeavesChunkCommandBuffer,
          ctx->secondaryForsMessageBufferHostVisible,
          ctx->secondaryForsMessageBufferDeviceLocal,
          1, &regions
        );
        VkMemoryBarrier copyToShaderBarrier = {
          .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER,
          .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
          .dstAccessMask = VK_ACCESS_SHADER_READ_BIT,
        };
        vkCmdPipelineBarrier(
          ctx->secondaryForsLeavesChunkCommandBuffer,
          VK_PIPELINE_STAGE_TRANSFER_BIT,
          VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
          0,
          1, &copyToShaderBarrier,
          0, NULL, 0, NULL
        );
      }

      vkCmdBindDescriptorSets(
        ctx->secondaryForsLeavesChunkCommandBuffer,
        VK_PIPELINE_BIND_POINT_COMPUTE,
        ctx->secondarySigningPipelineLayout,
        0, 1, &ctx->secondarySigningDescriptorSet,
        0, NULL
      );
      vkCmdBindPipeline(
        ctx->secondaryForsLeavesChunkCommandBuffer,
        VK_PIPELINE_BIND_POINT_COMPUTE,
        ctx->forsLeavesGenChunkPipeline
      );
      vkCmdDispatchBase(
        ctx->secondaryForsLeavesChunkCommandBuffer,
        base, 0, 0,
        size, 1, 1
      );
      err = vkEndCommandBuffer(ctx->secondaryForsLeavesChunkCommandBuffer);
      if (err) goto cleanup;

      VkSubmitInfo chunkSubmit = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .commandBufferCount = 1,
        .pCommandBuffers = &ctx->secondaryForsLeavesChunkCommandBuffer,
      };
      err = vkQueueSubmit(secondaryQueue, 1, &chunkSubmit, secondaryFence);
      if (err) goto cleanup;
      err = slhvkWaitFenceThrottled(ctx->secondaryDevice, secondaryFence, 100e9);
      if (err) goto cleanup;
      err = vkResetFences(ctx->secondaryDevice, 1, &secondaryFence);
      if (err) goto cleanup;
    }

    /* After leaves chunks, submit the FORS cmd buffer variant that SKIPS
     * the leaves gen dispatch (the merkle sign + copies portion only). */
    VkSubmitInfo submitInfo = {
      .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
      .commandBufferCount = 1,
      .pCommandBuffers = &ctx->secondaryForsCommandBufferNoLeaves,
    };
    err = vkQueueSubmit(secondaryQueue, 1, &submitInfo, secondaryFence);
    if (err) goto cleanup;
  }

  // Wait for secondary (FORS) shaders to complete
  err = slhvkWaitFenceThrottled(ctx->secondaryDevice, secondaryFence, 100e9);
  if (err) goto cleanup;

  // Read the FORS roots output.
  uint8_t* mappedForsRoots = NULL;
  err = vkMapMemory(
    ctx->secondaryDevice,
    ctx->secondaryForsRootsBufferMemory,
    0, // offset
    FORS_ROOTS_BUFFER_SIZE,
    0, // flags
    (void**) &mappedForsRoots
  );
  if (err) goto cleanup;
  uint8_t forsRoots[FORS_ROOTS_BUFFER_SIZE];
  memcpy(forsRoots, mappedForsRoots, FORS_ROOTS_BUFFER_SIZE);
  vkUnmapMemory(ctx->secondaryDevice, ctx->secondaryForsRootsBufferMemory);

  uint32_t wotsMessage[SLHVK_WOTS_CHAIN_COUNT];
  slhvkHashForsRootsToWotsMessage(
    forsRoots,
    treeAddress,
    signingKeypairAddress,
    &shaCtxInitial,
    wotsMessage
  );

  // Copy the encoded FORS pubkey WOTS message to the primary device staging buffer.
  uint32_t* mappedWotsMessage = NULL;
  err = vkMapMemory(
    ctx->primaryDevice,
    ctx->primaryForsPubkeyStagingBufferMemory,
    0, // offset
    FORS_PUBKEY_STAGING_BUFFER_SIZE,
    0, // flags
    (void**) &mappedWotsMessage
  );
  if (err) goto cleanup;
  for (int i = 0; i < SLHVK_WOTS_CHAIN_COUNT; i++) {
    mappedWotsMessage[i] = wotsMessage[i];
  }
  vkUnmapMemory(ctx->primaryDevice, ctx->primaryForsPubkeyStagingBufferMemory);

  // Wait for the XMSS precomputation shaders to finish. These take up the majority of runtime.
  err = slhvkWaitFenceThrottled(ctx->primaryDevice, primaryFence, 100e9);
  if (err) goto cleanup;

  // Reset this fence so we can reuse it for the final submission.
  err = vkResetFences(ctx->primaryDevice, 1, &primaryFence);
  if (err) goto cleanup;

  // Submit and await the final WOTS signing shader.
  VkSubmitInfo finalWotsSubmitInfo = {
    .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
    .commandBufferCount = 1,
    .pCommandBuffers = &ctx->primaryHypertreeFinishCommandBuffer,
  };
  err = vkQueueSubmit(primaryQueue, 1, &finalWotsSubmitInfo, primaryFence);
  if (err) goto cleanup;
  err = slhvkWaitFenceThrottled(ctx->primaryDevice, primaryFence, 100e9);
  if (err) goto cleanup;

  // Copy the randomizer to the signature output
  memcpy(signatureOutput, randomizer, N);

  // Copy the FORS signature to the output pointer
  uint8_t forsSig[SLHVK_FORS_SIGNATURE_SIZE];
  VkDeviceMemory forsSigMemory = (ctx->secondaryDeviceLocalMemoryFlags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)
    ? ctx->secondaryForsSignatureBufferDeviceLocalMemory
    : ctx->secondaryForsSignatureBufferHostVisibleMemory;
  uint8_t* mappedSignature = NULL;
  err = vkMapMemory(ctx->secondaryDevice, forsSigMemory, 0, SLHVK_FORS_SIGNATURE_SIZE, 0, (void**) &mappedSignature);
  if (err) goto cleanup;
  memcpy(&signatureOutput[N], mappedSignature, SLHVK_FORS_SIGNATURE_SIZE);
  memcpy(forsSig, mappedSignature, SLHVK_FORS_SIGNATURE_SIZE);
  vkUnmapMemory(ctx->secondaryDevice, forsSigMemory);

  // Copy the hypertree signature to the output pointer
  VkDeviceMemory hypertreeSigMemory = (ctx->primaryDeviceLocalMemoryFlags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)
    ? ctx->primaryHypertreeSignatureBufferDeviceLocalMemory
    : ctx->primaryHypertreeSignatureBufferHostVisibleMemory;
  err = vkMapMemory(ctx->primaryDevice, hypertreeSigMemory, 0, SLHVK_HYPERTREE_SIGNATURE_SIZE, 0, (void**) &mappedSignature);
  if (err) goto cleanup;
  memcpy(&signatureOutput[N + SLHVK_FORS_SIGNATURE_SIZE], mappedSignature, SLHVK_HYPERTREE_SIGNATURE_SIZE);
  vkUnmapMemory(ctx->primaryDevice, hypertreeSigMemory);

cleanup:
  vkDestroyFence(ctx->primaryDevice, primaryFence, NULL);
  vkDestroyFence(ctx->secondaryDevice, secondaryFence, NULL);
  return err;
}
