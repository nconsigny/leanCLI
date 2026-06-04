#pragma once
#include <stdint.h>
#include <vulkan/vulkan.h>

uint32_t slhvkNumWorkGroups(uint32_t threadsCount);

int slhvkFindDeviceComputeQueueFamily(VkPhysicalDevice physicalDevice);

int slhvkAllocateBufferMemory(
  VkDevice device,
  VkPhysicalDevice physicalDevice,
  VkBuffer buffer,
  VkMemoryPropertyFlags desiredMemoryFlags,
  VkMemoryPropertyFlags* actualMemoryFlags,
  VkDeviceMemory* memoryPtr
);

int slhvkSetupDescriptorSetLayout(
  VkDevice device,
  uint32_t bindingCount,
  VkDescriptorSetLayout* descriptorSetLayout
);

void slhvkBindBuffersToDescriptorSet(
  VkDevice device,
  const VkBuffer* buffers,
  uint32_t buffersCount,
  VkDescriptorSet descriptorSet
);

/* 128-24 fork: cooperative duty-cycle throttle. Wraps a GPU fence wait so the
 * caller can put the CPU to sleep after the wait, keeping average GPU usage
 * below 100 % and letting the desktop compositor get GPU time between phases.
 *
 *   SLHVK_GPU_DUTY=<decimal in (0, 1]>   default 1.0 (no throttling)
 *
 * For duty=0.8, after a phase that ran for E nanoseconds the CPU sleeps for
 * E * (1-duty)/duty = E/4 ns before returning. Across the phase + sleep
 * window the average GPU utilisation is `duty`. */
int slhvkWaitFenceThrottled(VkDevice device, VkFence fence, uint64_t timeoutNs);
