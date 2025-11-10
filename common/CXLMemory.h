//
// Created by Yibo Huang on 8/8/24.
//

#pragma once

#include <atomic>
#include <string>
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/file.h>

#include "core/Context.h"

#include "cxlalloc.h"
#include <glog/logging.h>

// Boost interprocess for managed shared memory
#include <boost/interprocess/managed_external_buffer.hpp>
#include <boost/interprocess/allocators/allocator.hpp>

namespace star
{

class CXLMemory {
    public:
        // statistics
        enum {
                TOTAL_USAGE,
                TOTAL_HW_CC_USAGE,
                INDEX_USAGE,
                METADATA_USAGE,
                DATA_USAGE,
                TRANSPORT_USAGE,
                MISC_USAGE,
                INDEX_ALLOCATION,
                METADATA_ALLOCATION,
                DATA_ALLOCATION,
                TRANSPORT_ALLOCATION,
                MISC_ALLOCATION,
                INDEX_FREE,
                METADATA_FREE,
                DATA_FREE,
                TRANSPORT_FREE,
                MISC_FREE
        };

        static constexpr uint64_t default_cxl_mem_size = (128 * 1024 * 1024);  // 128MB

        static constexpr uint64_t cxl_transport_root_index = 0;
        static constexpr uint64_t cxl_data_migration_root_index = 1;
        static constexpr uint64_t cxl_lru_trackers_root_index = 2;
        static constexpr uint64_t cxl_global_epoch_root_index = 3;
        static constexpr uint64_t cxl_global_ebr_meta_root_index = 4;

        // File system synchronization support
        static int sync_fd;
        static std::string sync_file_path;
        static bool use_file_sync;

        // Direct file-based metadata storage (bypassing cxlalloc's root table)
        // Store offsets at the beginning of the file (first 4KB reserved for metadata)
        static constexpr size_t METADATA_REGION_SIZE = 4096;
        static constexpr size_t MAX_ROOT_ENTRIES = 512;  // 4096 / 8 = 512 uint64_t entries
        static constexpr off_t METADATA_FILE_OFFSET = 0;  // Metadata at start of file
        static constexpr uint64_t METADATA_NO_DATA = UINT64_MAX;  // Sentinel value for "no data"

        // mmap-based shared metadata for device files (/dev/pmem0)
        // This region is mmapped separately from cxlalloc's heap
        static void* metadata_mmap_base;
        static int metadata_fd;
        static bool use_mmap_metadata;

        // Custom shared memory allocator (replaces cxlalloc)
        // Memory layout: [0-4KB]: metadata, [4KB-256MB]: heap allocations
        static constexpr size_t HEAP_START_OFFSET = 4096;  // Start after metadata region
        static void* shared_heap_base;           // Base address of mmap'd region
        static std::atomic<uint64_t> shared_heap_offset;  // Current allocation offset (bump allocator)
        static uint64_t shared_heap_size;        // Total size of heap region
        static bool use_custom_allocator;        // Whether to use custom allocator

        // Boost interprocess managed segment for offset_ptr compatibility
        typedef boost::interprocess::managed_external_buffer::segment_manager segment_manager_t;
        static boost::interprocess::managed_external_buffer* managed_segment;

        void init(Context context)
        {
                this->context = context;
        }

        void init_cxlalloc_for_given_thread(uint64_t threads_num_per_host, uint64_t thread_id, uint64_t hosts_num, uint64_t host_id)
        {
                std::string backend = context.cxl_backend.empty() ? std::string("ivshmem") : context.cxl_backend;
                std::string resource = context.cxl_memory_resource.empty() ? std::string("SS") : context.cxl_memory_resource;

                std::string effective_backend = backend;
                bool is_device_file = (resource.find("/dev/dax") == 0) || (resource.find("/dev/pmem") == 0);

                if (backend == "dax" || backend == "mmap") {
                        CHECK(resource != "SS") << "Backend " << backend << " requires --cxl_memory_resource to point at a file or device";

                        // Use mmap backend for both device files and regular files
                        // Device files like /dev/pmem0 are shared across VMs via QEMU CXL hooks
                        effective_backend = "mmap";

                        // Enable file synchronization ONLY for mmap backend with regular files (not device files)
                        // Device files (/dev/dax*, /dev/pmem*) don't support pwrite/pread operations
                        bool is_shared_file = (backend == "mmap" && !is_device_file);

                        if (hosts_num > 1 && thread_id == 0 && is_shared_file) {  // Only for shared regular files
                                use_file_sync = true;
                                sync_file_path = resource;

                                // Open file for direct metadata access (don't mmap - cxlalloc will do that)
                                sync_fd = open(resource.c_str(), O_RDWR | O_SYNC);
                                if (sync_fd < 0) {
                                        LOG(ERROR) << "Failed to open " << resource << " for file sync: " << strerror(errno);
                                        use_file_sync = false;
                                } else {
                                        // Initialize metadata region to zero on first node only
                                        if (host_id == 0) {
                                                uint64_t zeros[MAX_ROOT_ENTRIES] = {0};
                                                ssize_t written = pwrite(sync_fd, zeros, METADATA_REGION_SIZE, METADATA_FILE_OFFSET);
                                                if (written != METADATA_REGION_SIZE) {
                                                        LOG(ERROR) << "Failed to initialize metadata region: " << strerror(errno);
                                                        use_file_sync = false;
                                                } else {
                                                        fsync(sync_fd);
                                                        LOG(INFO) << "File synchronization enabled: initialized " << METADATA_REGION_SIZE << " bytes metadata region";
                                                }
                                        } else {
                                                LOG(INFO) << "File synchronization enabled for multi-node mmap backend";
                                        }
                                }
                        }

                        // For device files (/dev/pmem0), use mmap-based metadata sharing
                        if (hosts_num > 1 && thread_id == 0 && is_device_file) {
                                use_mmap_metadata = true;

                                // Open device for metadata mmap (separate from cxlalloc's mmap)
                                metadata_fd = open(resource.c_str(), O_RDWR);
                                if (metadata_fd < 0) {
                                        LOG(ERROR) << "Failed to open " << resource << " for mmap metadata: " << strerror(errno);
                                        use_mmap_metadata = false;
                                } else {
                                        // mmap first 4KB as shared metadata region
                                        metadata_mmap_base = mmap(NULL, default_cxl_mem_size,
                                                                  PROT_READ | PROT_WRITE,
                                                                  MAP_SHARED, metadata_fd, 0);

                                        if (metadata_mmap_base == MAP_FAILED) {
                                                LOG(ERROR) << "Failed to mmap metadata region: " << strerror(errno);
                                                use_mmap_metadata = false;
                                                close(metadata_fd);
                                                metadata_fd = -1;
                                        } else {
                                                // Initialize metadata region to METADATA_NO_DATA sentinel value on first node only
                                                if (host_id == 0) {
                                                        uint64_t* metadata = (uint64_t*)metadata_mmap_base;
                                                        for (size_t i = 0; i < MAX_ROOT_ENTRIES; i++) {
                                                                metadata[i] = METADATA_NO_DATA;
                                                        }
                                                        msync(metadata_mmap_base, METADATA_REGION_SIZE, MS_SYNC);
                                                        LOG(INFO) << "Shared metadata region initialized at " << metadata_mmap_base
                                                                  << " (" << METADATA_REGION_SIZE << " bytes)";
                                                } else {
                                                        LOG(INFO) << "Shared metadata region mapped at " << metadata_mmap_base
                                                                  << " (" << METADATA_REGION_SIZE << " bytes)";
                                                }
                                        }
                                }
                        }
                }

                // Initialize custom allocator (replaces cxlalloc)
                if (use_mmap_metadata && metadata_mmap_base != nullptr) {
                        // Use our mmap'd region for allocations (no need for cxlalloc!)
                        use_custom_allocator = true;
                        shared_heap_base = metadata_mmap_base;
                        shared_heap_size = default_cxl_mem_size;

                        // Initialize boost managed segment (only once for thread 0)
                        if (thread_id == 0) {
                                try {
                                        // Calculate heap region (after metadata)
                                        void* heap_start = static_cast<char*>(shared_heap_base) + HEAP_START_OFFSET;
                                        size_t heap_size = shared_heap_size - HEAP_START_OFFSET;

                                        if (host_id == 0) {
                                                // First node: create and initialize the managed segment
                                                managed_segment = new boost::interprocess::managed_external_buffer(
                                                        boost::interprocess::create_only,
                                                        heap_start,
                                                        heap_size
                                                );
                                                LOG(INFO) << "Boost managed segment CREATED: heap_start=" << heap_start
                                                          << " heap_size=" << heap_size;
                                        } else {
                                                // Other nodes: open existing managed segment
                                                managed_segment = new boost::interprocess::managed_external_buffer(
                                                        boost::interprocess::open_only,
                                                        heap_start,
                                                        heap_size
                                                );
                                                LOG(INFO) << "Boost managed segment OPENED: heap_start=" << heap_start
                                                          << " heap_size=" << heap_size;
                                        }

                                        shared_heap_offset.store(HEAP_START_OFFSET);
                                        LOG(INFO) << "Custom allocator initialized with boost::interprocess";
                                } catch (const std::exception& e) {
                                        LOG(ERROR) << "Failed to initialize boost managed segment: " << e.what();
                                        use_custom_allocator = false;
                                        managed_segment = nullptr;
                                }
                        }
                        LOG(INFO) << "Custom allocator ready for thread " << thread_id
                                  << " (replaces cxlalloc)"
                                  << " (global ID = " << thread_id + threads_num_per_host * host_id
                                  << ") on host " << host_id;
                } else {
                        // Fallback: no custom allocator, use regular malloc
                        use_custom_allocator = false;
                        LOG(WARNING) << "Custom allocator NOT available (no mmap metadata). "
                                     << "Allocations will use regular heap (not shared across VMs).";
                }
        }

        // backward compatibility
        void *cxlalloc_malloc_wrapper(uint64_t size, int category, uint64_t metadata_size, uint64_t data_size)
        {
                // collect statistics
                switch (category) {
                case INDEX_ALLOCATION:
                        size_total_hw_cc_usage.fetch_add(size);
                        size_index_usage.fetch_add(size);
                        break;
                case DATA_ALLOCATION:
                        size_total_hw_cc_usage.fetch_add(metadata_size);
                        size_metadata_usage.fetch_add(metadata_size);
                        size_data_usage.fetch_add(data_size);
                        break;
                case TRANSPORT_ALLOCATION:
                        size_transport_usage.fetch_add(size);
                        break;
                case MISC_ALLOCATION:
                        size_total_hw_cc_usage.fetch_add(size);
                        size_misc_usage.fetch_add(size);
                        break;
                default:
                        CHECK(0);
                }

                // Use custom allocator if available, otherwise fallback to malloc
                if (use_custom_allocator && managed_segment != nullptr) {
                        // Use boost managed segment allocator (compatible with offset_ptr)
                        try {
                                void* ptr = managed_segment->allocate(size);
                                if (ptr == nullptr) {
                                        LOG(FATAL) << "Boost managed segment allocation failed! size=" << size;
                                }
                                return ptr;
                        } catch (const boost::interprocess::bad_alloc& e) {
                                LOG(FATAL) << "Out of shared memory! size=" << size << " error: " << e.what();
                                return nullptr;
                        }
                } else {
                        // Fallback: use regular malloc (not shared)
                        return malloc(size);
                }
        }

        void cxlalloc_free_wrapper(void *ptr, uint64_t size, int category, uint64_t metadata_size, uint64_t data_size)
        {
                // collect statistics
                switch (category) {
                case INDEX_FREE:
                        size_total_hw_cc_usage.fetch_sub(size);
                        size_index_usage.fetch_sub(size);
                        break;
                case DATA_FREE:
                        size_total_hw_cc_usage.fetch_sub(metadata_size);
                        size_metadata_usage.fetch_sub(metadata_size);
                        size_data_usage.fetch_sub(data_size);
                        break;
                case TRANSPORT_FREE:
                        size_transport_usage.fetch_sub(size);
                        break;
                case MISC_FREE:
                        size_total_hw_cc_usage.fetch_sub(size);
                        size_misc_usage.fetch_sub(size);
                        break;
                default:
                        CHECK(0);
                }
        }

        // new APIs
        void *cxlalloc_malloc_wrapper(uint64_t size, int category)
        {
                // collect statistics
                switch (category) {
                case INDEX_ALLOCATION:
                        size_total_hw_cc_usage.fetch_add(size);
                        size_index_usage.fetch_add(size);
                        break;
                case METADATA_ALLOCATION:
                        if (context.migration_policy == "LRU") {
                                size_total_hw_cc_usage.fetch_add(size + 24);
                        } else {
                                size_total_hw_cc_usage.fetch_add(size);
                        }
                        size_metadata_usage.fetch_add(size);
                        break;
                case DATA_ALLOCATION:
                        if (context.enable_scc == false) {
                                size_total_hw_cc_usage.fetch_add(size);
                        }
                        size_data_usage.fetch_add(size);
                        break;
                case TRANSPORT_ALLOCATION:
                        size_transport_usage.fetch_add(size);
                        break;
                case MISC_ALLOCATION:
                        size_total_hw_cc_usage.fetch_add(size);
                        size_misc_usage.fetch_add(size);
                        break;
                default:
                        CHECK(0);
                }

                // Use the same allocator implementation (calls first wrapper)
                return cxlalloc_malloc_wrapper(size, category, 0, 0);
        }

	// 1-argument overload for EBR code (no size/category tracking)
	void cxlalloc_free_wrapper(void *ptr)
	{
		if (use_custom_allocator && managed_segment != nullptr) {
			// Boost managed segment handles its own deallocation internally
			// No explicit deallocate needed for EBR objects
		} else if (!use_custom_allocator) {
			cxlalloc_free(ptr);
		}
	}

        void cxlalloc_free_wrapper(void *ptr, uint64_t size, int category)
        {
                // collect statistics
                switch (category) {
                case INDEX_FREE:
                        size_total_hw_cc_usage.fetch_sub(size);
                        size_index_usage.fetch_sub(size);
                        break;
                case METADATA_FREE:
                        if (context.migration_policy == "LRU") {
                                size_total_hw_cc_usage.fetch_sub(size + 24);
                        } else {
                                size_total_hw_cc_usage.fetch_sub(size);
                        }
                        size_metadata_usage.fetch_sub(size);
                        break;
                case DATA_FREE:
                        if (context.enable_scc == false) {
                                size_total_hw_cc_usage.fetch_sub(size);
                        }
                        size_data_usage.fetch_sub(size);
                        break;
                case TRANSPORT_FREE:
                        size_transport_usage.fetch_sub(size);
                        break;
                case MISC_FREE:
                        size_total_hw_cc_usage.fetch_sub(size);
                        size_misc_usage.fetch_sub(size);
                        break;
                default:
                        CHECK(0);
                }
        }

        // Synchronize memory to file system
        static void sync_to_filesystem()
        {
                if (!use_file_sync || sync_fd < 0) {
                        return;
                }

                // Force sync to disk
                fsync(sync_fd);

                // Invalidate page cache to ensure other processes see updates
                // Use posix_fadvise to hint kernel to drop cache
                posix_fadvise(sync_fd, 0, 0, POSIX_FADV_DONTNEED);

                LOG(INFO) << "CXL: Synced shared memory to filesystem";
        }

        static void commit_shared_data_initialization(uint64_t root_index, void *shared_data)
        {
                // Only call cxlalloc functions if NOT using custom allocator
                // if (!use_custom_allocator) {
                //         cxlalloc_set_root(root_index, shared_data);
                // }

                // Convert pointer to offset for sharing
                uint64_t offset = 0;
                bool conversion_success = false;

                // Simple pointer arithmetic: offset = ptr - base
                offset = static_cast<char*>(shared_data) - static_cast<char*>(shared_heap_base);
                conversion_success = true;

                if (conversion_success) {
                        // Store offset in cxlalloc's root table for single-process scenario
                        // if (!use_custom_allocator) {
                        //         cxlalloc_set_root(root_index + 1000, (void*)offset);
                        // }

                        // NEW: For multi-process sharing via mmap metadata (device files)
                        if (use_mmap_metadata && metadata_mmap_base != nullptr) {
                                CHECK(root_index < MAX_ROOT_ENTRIES) << "root_index " << root_index << " exceeds MAX_ROOT_ENTRIES";

                                // Write offset directly to shared mmap region
                                uint64_t* metadata = (uint64_t*)metadata_mmap_base;
                                metadata[root_index] = offset;

                                // Ensure visibility (memory barrier + cache flush)
                                __sync_synchronize();
                                msync(&metadata[root_index], sizeof(uint64_t), MS_SYNC);

                                LOG(INFO) << "CXL: Wrote offset " << offset << " to shared metadata[" << root_index << "]";
                        }
                        // For multi-process file sharing (regular files), write offset via pwrite
                        else if (use_file_sync && sync_fd >= 0) {
                                CHECK(root_index < MAX_ROOT_ENTRIES) << "root_index " << root_index << " exceeds MAX_ROOT_ENTRIES";

                                // Write offset to file at metadata region
                                off_t file_offset = METADATA_FILE_OFFSET + (root_index * sizeof(uint64_t));
                                ssize_t written = pwrite(sync_fd, &offset, sizeof(uint64_t), file_offset);

                                if (written == sizeof(uint64_t)) {
                                        // Force sync to disk for 9p filesystem
                                        fdatasync(sync_fd);  // Faster than fsync, just syncs data
                                        __sync_synchronize();  // Memory barrier
                                        LOG(INFO) << "CXL: Stored offset " << offset << " for root_index " << root_index << " in file metadata (offset " << file_offset << ")";
                                } else {
                                        LOG(ERROR) << "CXL: Failed to write offset to file: " << strerror(errno);
                                }
                        } else {
                                LOG(INFO) << "CXL: Stored offset " << offset << " for root_index " << root_index;
                        }
                }
        }

        static void wait_and_retrieve_cxl_shared_data(uint64_t root_index, void **shared_data)
        {
                void *addr = NULL;
                int retry_count = 0;
                const int MAX_RETRIES = 300;  // Try for ~30 seconds - allow time for Node 0 startup

                while (retry_count < MAX_RETRIES) {
                        // First try: Check if already in cxlalloc's root table (only for non-custom allocator)
                        if (!use_custom_allocator) {
                                addr = cxlalloc_get_root(root_index);
                                if (addr) {
                                        LOG(INFO) << "CXL: Retrieved shared data for root_index " << root_index;
                                        *shared_data = addr;
                                        return;
                                }
                        }

                        // Second try: For mmap metadata (device files), read from shared mmap region
                        if (use_mmap_metadata && metadata_mmap_base != nullptr) {
                                CHECK(root_index < MAX_ROOT_ENTRIES) << "root_index " << root_index << " exceeds MAX_ROOT_ENTRIES";

                                // Ensure we see latest data (memory barrier)
                                __sync_synchronize();

                                // Read offset from shared mmap region
                                uint64_t* metadata = (uint64_t*)metadata_mmap_base;
                                uint64_t offset = metadata[root_index];

                                // DEBUG: Log what we're reading
                                if (retry_count % 30 == 0) {  // Every 3 seconds
                                        LOG(INFO) << "CXL DEBUG: Reading metadata[" << root_index << "] = " << offset
                                                  << " (METADATA_NO_DATA=" << METADATA_NO_DATA << ") retry=" << retry_count;
                                }

                                // Check if data is available (not the sentinel value)
                                if (offset != METADATA_NO_DATA) {
                                        // Convert offset to local pointer (offset can be 0, which is valid!)
                                        if (use_custom_allocator) {
                                                addr = static_cast<char*>(shared_heap_base) + offset;
                                        } else {
                                                addr = cxlalloc_offset_to_pointer(offset);
                                        }

                                        if (addr) {
                                                LOG(INFO) << "CXL: Read offset " << offset << " from shared metadata[" << root_index << "]";
                                                *shared_data = addr;
                                                // Store in local root for future access (only for non-custom allocator)
                                                // if (!use_custom_allocator) {
                                                //         cxlalloc_set_root(root_index, addr);
                                                // }
                                                return;
                                        }
                                }
                        }
                        // Third try: For multi-process file sharing (regular files), read offset from file
                        else if (use_file_sync && sync_fd >= 0) {
                                CHECK(root_index < MAX_ROOT_ENTRIES) << "root_index " << root_index << " exceeds MAX_ROOT_ENTRIES";

                                // Ensure we see latest data from other nodes (9p filesystem)
                                if (retry_count % 10 == 0) {  // Every 1 second
                                        // Force kernel to read fresh data from server
                                        posix_fadvise(sync_fd, 0, METADATA_REGION_SIZE, POSIX_FADV_DONTNEED);
                                }

                                // Read offset from file
                                off_t file_offset = METADATA_FILE_OFFSET + (root_index * sizeof(uint64_t));
                                uint64_t offset = 0;
                                ssize_t bytes_read = pread(sync_fd, &offset, sizeof(uint64_t), file_offset);

                                if (bytes_read == sizeof(uint64_t) && offset != 0) {
                                        __sync_synchronize();  // Memory barrier

                                        // Convert offset to local pointer
                                        if (use_custom_allocator) {
                                                addr = static_cast<char*>(shared_heap_base) + offset;
                                        } else {
                                                addr = cxlalloc_offset_to_pointer(offset);
                                        }

                                        if (addr) {
                                                LOG(INFO) << "CXL: Retrieved data via file metadata offset " << offset << " for root_index " << root_index << " (file offset " << file_offset << ")";
                                                *shared_data = addr;
                                                // Store in local root for future access (only for non-custom allocator)
                                                // if (!use_custom_allocator) {
                                                //         cxlalloc_set_root(root_index, addr);
                                                // }
                                                return;
                                        }
                                }
                        } else {
                                // Fourth try: Get offset from cxlalloc's root table (legacy approach)
                                uint64_t offset = (uint64_t)cxlalloc_get_root(root_index + 1000);
                                if (offset != 0) {
                                        // Convert offset to local pointer
                                        if (use_custom_allocator) {
                                                addr = static_cast<char*>(shared_heap_base) + offset;
                                        } else {
                                                addr = cxlalloc_offset_to_pointer(offset);
                                        }

                                        if (addr) {
                                                LOG(INFO) << "CXL: Retrieved data via offset " << offset << " for root_index " << root_index;
                                                *shared_data = addr;
                                                // if (!use_custom_allocator) {
                                                //         cxlalloc_set_root(root_index, addr);
                                                // }
                                                return;
                                        }
                                }
                        }

                        usleep(100000);  // 100ms
                        retry_count++;
                }

                LOG(ERROR) << "CXL: Failed to retrieve shared data for root_index " << root_index << " after " << MAX_RETRIES << " retries";
                LOG(ERROR) << "CXL: This suggests memory is not shared between nodes. Each node is using independent CXL memory.";
                *shared_data = NULL;
        }

        uint64_t get_stats(int category)
        {
                switch (category) {
                case INDEX_USAGE:
                        return size_index_usage;
                case METADATA_USAGE:
                        return size_metadata_usage;
                case DATA_USAGE:
                        return size_data_usage;
                case TRANSPORT_USAGE:
                        return size_transport_usage;
                case MISC_USAGE:
                        return size_misc_usage;
                case TOTAL_HW_CC_USAGE:
                        return size_total_hw_cc_usage;
                case TOTAL_USAGE:
                        return size_index_usage + size_metadata_usage + size_data_usage + size_transport_usage + size_misc_usage;      // does not need to be consistent
                default:
                        CHECK(0);
                }
        }

        void print_stats()
        {
                LOG(INFO) << "local CXL memory usage:"
                          << " size_index_usage: " << get_stats(INDEX_USAGE)
                          << " size_metadata_usage: " << get_stats(METADATA_USAGE)
                          << " size_data_usage: " << get_stats(DATA_USAGE)
                          << " size_transport_usage: " << get_stats(TRANSPORT_USAGE)
                          << " size_misc_usage: " << get_stats(MISC_USAGE)
                          << " total_size_hw_cc_usage: " << get_stats(TOTAL_HW_CC_USAGE)
                          << " total_usage: " << get_stats(TOTAL_USAGE);
        }

    private:
        Context context;

        std::atomic<uint64_t> size_index_usage{ 0 };
        std::atomic<uint64_t> size_metadata_usage{ 0 };
        std::atomic<uint64_t> size_data_usage{ 0 };
        std::atomic<uint64_t> size_transport_usage{ 0 };
        std::atomic<uint64_t> size_misc_usage{ 0 };

        std::atomic<uint64_t> size_total_hw_cc_usage{ 0 };
};

extern CXLMemory cxl_memory;

}
