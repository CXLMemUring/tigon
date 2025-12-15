// Stub implementation for cxlalloc to avoid AVX2/AVX512 instructions
// This allows the code to run on CPUs without AVX2 support

#include "cxlalloc.h"
#include <cstdlib>
#include <cstring>
#include <map>
#include <mutex>

static std::map<size_t, void*> root_table;
static std::mutex root_mutex;
static void* heap_base = nullptr;
static size_t heap_size = 0;

extern "C" {

void cxlalloc_init_backend(const char *backend) {
    // No-op stub
}

void cxlalloc_set_log(const char *level) {
    // No-op stub
}

void cxlalloc_init(const char *name,
                   size_t size,
                   uint8_t thread_id,
                   uint8_t thread_count,
                   uint8_t process_id,
                   uint8_t process_count) {
    // No-op stub - custom allocator handles this
}

bool cxlalloc_is_clean(void) {
    return true;
}

void cxlalloc_init_thread(size_t thread_id) {
    // No-op stub
}

void *cxlalloc_malloc(size_t size) {
    return malloc(size);
}

void cxlalloc_link(void *pointer) {
    // No-op stub
}

void cxlalloc_free(void *pointer) {
    free(pointer);
}

void cxlalloc_unlink(void *pointer) {
    // No-op stub
}

void *cxlalloc_realloc(void *pointer, size_t size) {
    return realloc(pointer, size);
}

void *cxlalloc_memalign(size_t size, size_t alignment) {
    void* ptr = nullptr;
    posix_memalign(&ptr, alignment, size);
    return ptr;
}

void *cxlalloc_get_root(size_t index) {
    std::lock_guard<std::mutex> lock(root_mutex);
    auto it = root_table.find(index);
    if (it != root_table.end()) {
        return it->second;
    }
    return nullptr;
}

void cxlalloc_set_root(size_t index, void *pointer) {
    std::lock_guard<std::mutex> lock(root_mutex);
    root_table[index] = pointer;
}

void cxlalloc_close(void) {
    std::lock_guard<std::mutex> lock(root_mutex);
    root_table.clear();
}

bool cxlalloc_pointer_to_offset(const void *pointer, uint64_t *offset) {
    // Stub: return pointer as offset (works for single-process)
    *offset = reinterpret_cast<uint64_t>(pointer);
    return true;
}

void *cxlalloc_offset_to_pointer(uint64_t offset) {
    // Stub: return offset as pointer (works for single-process)
    return reinterpret_cast<void*>(offset);
}

} // extern "C"
