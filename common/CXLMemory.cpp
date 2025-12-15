//
// Created by Yibo Huang on 8/8/24.
//

#include "common/CXLMemory.h"

namespace star
{

CXLMemory cxl_memory;

// Initialize static members for file system synchronization
int CXLMemory::sync_fd = -1;
std::string CXLMemory::sync_file_path = "";
bool CXLMemory::use_file_sync = false;

// Initialize static members for mmap-based metadata sharing
void* CXLMemory::metadata_mmap_base = nullptr;
int CXLMemory::metadata_fd = -1;
bool CXLMemory::use_mmap_metadata = false;

// Initialize static members for custom allocator (simple bump allocator)
void* CXLMemory::shared_heap_base = nullptr;
std::atomic<uint64_t> CXLMemory::shared_heap_offset(0);
uint64_t CXLMemory::shared_heap_size = 0;
bool CXLMemory::use_custom_allocator = false;
bool CXLMemory::bump_allocator_initialized = false;

}
