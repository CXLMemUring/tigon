//
// Created by Yi Lu on 9/11/18.
//

#pragma once

#include <atomic>
#include <list>
#include <tuple>
#include <memory>
#include <unordered_set>
#include <xmmintrin.h>
#include <sys/syscall.h>  // For gettid()

#include "common/CCSet.h"
#include "common/CCHashTable.h"
#include "common/CXLMemory.h"
#include "common/CXL_EBR.h"
#include "core/Context.h"
#include "core/CXLTable.h"
#include "core/Table.h"
#include "glog/logging.h"

#include "protocol/Pasha/MigrationManager.h"
#include "protocol/Pasha/SCCManager.h"

#include <boost/interprocess/offset_ptr.hpp>

namespace star
{

// Simple memcpy without AVX (glibc's memcpy may use AVX2 despite GLIBC_TUNABLES)
static inline void simple_memcpy_pasha(void* dest, const void* src, size_t len) {
        volatile unsigned char* d = static_cast<volatile unsigned char*>(dest);
        const volatile unsigned char* s = static_cast<const volatile unsigned char*>(src);
        for (size_t i = 0; i < len; i++) {
                d[i] = s[i];
        }
}

// Cache flush for cross-VM visibility (invalidate cache line)
static inline void cxl_clflush(const void *addr, uint64_t len) {
        static constexpr uint64_t cacheline_size = 64;
        for (uint64_t ptr = (uint64_t)addr & ~(cacheline_size - 1); ptr < (uint64_t)addr + len; ptr += cacheline_size) {
                _mm_clflush((void *)ptr);
        }
        _mm_sfence();
}

// Cache writeback for cross-VM visibility (write back and keep in cache)
static inline void cxl_clwb(const void *addr, uint64_t len) {
        static constexpr uint64_t cacheline_size = 64;
        for (uint64_t ptr = (uint64_t)addr & ~(cacheline_size - 1); ptr < (uint64_t)addr + len; ptr += cacheline_size) {
                _mm_clflush((void *)ptr);  // Fallback: use clflush since clwb may not be available
        }
        _mm_sfence();
}

struct TwoPLPashaSharedDataSCC {
        TwoPLPashaSharedDataSCC()
                : tid(0)
                , flags(0)
                , ref_cnt(0)
        {}

        static constexpr int valid_flag_index = 0;

        bool get_flag(int flag_index) {
                return (flags & (1 << flag_index)) != 0;
        }

        void set_flag(int flag_index) {
                flags |= (1 << flag_index);  // Set the specific bit to 1
        }

        void clear_flag(int flag_index) {
                flags &= ~(1 << flag_index);  // Clear the specific bit to 0
        }

        uint64_t tid{ 0 };

        // is_valid
        uint8_t flags{ 0 };

        // multi-host transaction accessing a cxl row would increase its reference count by 1
        // a migrated row can only be moved out if its ref_cnt == 0
        // TODO: should be removed ultimately
        uint8_t ref_cnt{ 0 };

        // migration policy metadata - keep it here to maintain compatibility with LRU
        // TODO: should be moved to HWcc ultimately
        char migration_policy_meta[MigrationManager::migration_policy_meta_size];

        char data[];
};

struct TwoPLPashaMetadataLocal {
        TwoPLPashaMetadataLocal()
                : tid(0)
                , is_valid(false)
                , is_migrated(false)
                , is_data_modified_since_moved_out(true)
                , migrated_row(nullptr)
                , scc_data(nullptr)
        {
                // this spinlock will only be shared within a single process
                pthread_spin_init(&latch, PTHREAD_PROCESS_PRIVATE);
        }

        void lock()
	{
                pthread_spin_lock(&latch);
	}

	void unlock()
	{
		pthread_spin_unlock(&latch);
	}

        pthread_spinlock_t latch;

	uint64_t tid{ 0 };

        bool is_valid{ false };

        bool is_migrated{ false };

        bool is_data_modified_since_moved_out{ true };      // conservatively set this as true by default

        char *migrated_row{ nullptr };

        TwoPLPashaSharedDataSCC *scc_data{ nullptr };
};

struct TwoPLPashaMetadataShared {
        TwoPLPashaMetadataShared(TwoPLPashaSharedDataSCC *scc_data)
        {
                uint64_t scc_data_cxl_offset = 0;

                bool ret = CXLMemory::cxlalloc_pointer_to_offset_wrapper(scc_data, &scc_data_cxl_offset);
                DCHECK(ret == true);

                atomic_word.store(scc_data_cxl_offset << SCC_DATA_OFFSET, std::memory_order_release);
        }

	void lock()
	{
retry:
                // CRITICAL: Invalidate cache before reading to see writes from other VMs
                cxl_clflush(&atomic_word, sizeof(atomic_word));

		uint64_t v_before_lock = atomic_word.load(std::memory_order_acquire);
                uint64_t v_after_lock = (v_before_lock | (LATCH_BIT_MASK << LATCH_BIT_OFFSET));

		if ((v_before_lock & (LATCH_BIT_MASK << LATCH_BIT_OFFSET)) == 0) {
			if (atomic_word.compare_exchange_strong(v_before_lock, v_after_lock)) {
                                // CRITICAL: Flush after acquiring lock to ensure other VMs see it
                                cxl_clwb(&atomic_word, sizeof(atomic_word));

                                // Verify we actually got the lock by re-reading from memory
                                cxl_clflush(&atomic_word, sizeof(atomic_word));
                                uint64_t v_verify = atomic_word.load(std::memory_order_acquire);
                                if ((v_verify & (LATCH_BIT_MASK << LATCH_BIT_OFFSET)) == 0) {
                                        // Another VM may have stolen the lock, retry
                                        goto retry;
                                }
				return;
                        } else {
			        goto retry;
                        }
		} else {
			goto retry;
		}
	}

	void unlock()
	{
                // NOTE: Do NOT clflush here - we may have made local modifications
                // while holding the lock that we need to preserve

                // nobody can modify this atomic word without acquiring the latch
                // so it is safe to just do regular store instead compare_and_swap
                uint64_t v_before_unlock = atomic_word.load(std::memory_order_acquire);
                uint64_t v_after_unlock = (v_before_unlock & ~(LATCH_BIT_MASK << LATCH_BIT_OFFSET));

                // Note: During migration, newly created metadata may be unlocked without being locked first
                // This is safe since we're just clearing the latch bit
                if ((v_before_unlock & (LATCH_BIT_MASK << LATCH_BIT_OFFSET)) == 0) {
                        // Latch not held - nothing to do
                        return;
                }

		atomic_word.store(v_after_unlock, std::memory_order_release);

                // CRITICAL: Flush after releasing lock to ensure other VMs see ALL changes
                // (including modifications made while holding the lock)
                cxl_clwb(&atomic_word, sizeof(atomic_word));
	}

        TwoPLPashaSharedDataSCC *get_scc_data()
        {
                uint64_t scc_data_cxl_offset = atomic_word.load(std::memory_order_acquire) & (SCC_DATA_MASK << SCC_DATA_OFFSET);
                void *scc_data_ptr = CXLMemory::cxlalloc_offset_to_pointer_wrapper(scc_data_cxl_offset);

                return reinterpret_cast<TwoPLPashaSharedDataSCC *>(scc_data_ptr);
        }

        // next-key information
        bool get_next_key_real_bit()
        {
                return is_bit_set(is_next_key_real_bit_index);
        }

        void set_next_key_real_bit()
        {
                set_bit(is_next_key_real_bit_index);
        }

        void clear_next_key_real_bit()
        {
                clear_bit(is_next_key_real_bit_index);
        }

        bool get_prev_key_real_bit()
        {
                return is_bit_set(is_prev_key_real_bit_index);
        }

        void set_prev_key_real_bit()
        {
                set_bit(is_prev_key_real_bit_index);
        }

        void clear_prev_key_real_bit()
        {
                clear_bit(is_prev_key_real_bit_index);
        }

        // Function to set a bit at a given position in the bitmap (ATOMIC)
        // Note: Called while holding lock, so no flush needed here - unlock() will flush
        void set_bit(uint64_t bit_index)
        {
                atomic_word.fetch_or(1ull << bit_index, std::memory_order_acq_rel);
        }

        // Function to clear a bit at a given position in the bitmap (ATOMIC)
        // Note: Called while holding lock, so no flush needed here - unlock() will flush
        void clear_bit(uint64_t bit_index)
        {
                atomic_word.fetch_and(~(1ull << bit_index), std::memory_order_acq_rel);
        }

        // Function to check if a bit is set (returns true if set, false if clear)
        // Note: Called while holding lock, so no flush needed - lock() already flushed
        bool is_bit_set(uint64_t bit_index)
        {
                return (atomic_word.load(std::memory_order_acquire) & (1ull << bit_index)) != 0;
        }

        // read lock
        // Note: Called while holding lock, so no flush needed - lock() already flushed
        uint64_t get_reader_count()
        {
                return (atomic_word.load(std::memory_order_acquire) >> READ_LOCK_BITS_OFFSET) & READ_LOCK_BITS_MASK;
        }

        // Note: Called while holding lock, so no extra flush needed - unlock() will flush
        void set_reader_count(uint64_t reader_count)
        {
                // Use CAS loop to atomically set reader count
                uint64_t orig_atomic_word, new_atomic_word;
                do {
                        orig_atomic_word = atomic_word.load(std::memory_order_acquire);
                        new_atomic_word = orig_atomic_word & ~(READ_LOCK_BITS_MASK << READ_LOCK_BITS_OFFSET);
                        new_atomic_word |= (reader_count << READ_LOCK_BITS_OFFSET);
                } while (!atomic_word.compare_exchange_weak(orig_atomic_word, new_atomic_word,
                                std::memory_order_acq_rel, std::memory_order_acquire));
        }

        // Note: Called while holding lock, so no flush needed here - unlock() will flush
        void increase_reader_count()
        {
                // ATOMIC: add to the reader count bits
                atomic_word.fetch_add(1ull << READ_LOCK_BITS_OFFSET, std::memory_order_acq_rel);
        }

        // Note: Called while holding lock, so no flush needed here - unlock() will flush
        void decrease_reader_count()
        {
                // ATOMIC: subtract from the reader count bits
                atomic_word.fetch_sub(1ull << READ_LOCK_BITS_OFFSET, std::memory_order_acq_rel);
        }

        uint64_t get_reader_count_max()
        {
                return READ_LOCK_BITS_MASK;
        }

        // write lock
        bool is_write_locked()
        {
                return is_bit_set(WRITE_LOCK_BIT_OFFSET);
        }

        void set_write_locked()
        {
                set_bit(WRITE_LOCK_BIT_OFFSET);
        }

        void clear_write_locked()
        {
                clear_bit(WRITE_LOCK_BIT_OFFSET);
        }

        bool is_data_modified_since_moved_in()
        {
                return is_bit_set(is_data_modified_since_moved_in_bit_index);
        }

        void set_is_data_modified_since_moved_in()
        {
                set_bit(is_data_modified_since_moved_in_bit_index);
        }

        void clear_is_data_modified_since_moved_in()
        {
                clear_bit(is_data_modified_since_moved_in_bit_index);
        }

        // SCC
        // Note: Called while holding lock, so no flush needed here - unlock() will flush
        void clear_all_scc_bits()
        {
                // ATOMIC: clear all SCC bits at once
                atomic_word.fetch_and(~(SCC_BITS_MASK << SCC_BITS_OFFSET), std::memory_order_acq_rel);
        }

        void set_scc_bit(uint64_t host_id)
        {
                set_bit(host_id + SCC_BITS_OFFSET);
        }

	static constexpr int LATCH_BIT_OFFSET = 63;
	static constexpr uint64_t LATCH_BIT_MASK = 0x1ull;

        static constexpr int SCC_DATA_OFFSET = 0;
	static constexpr uint64_t SCC_DATA_MASK = 0x1fffffffffull;

        static constexpr int SCC_BITS_OFFSET = 47;
	static constexpr uint64_t SCC_BITS_MASK = 0xffffull;

        static constexpr int READ_LOCK_BITS_OFFSET = 42;
	static constexpr uint64_t READ_LOCK_BITS_MASK = 0x1full;

        static constexpr int WRITE_LOCK_BIT_OFFSET = 41;
	static constexpr uint64_t WRITE_LOCK_BIT_MASK = 0x1ull;

        static constexpr int is_data_modified_since_moved_in_bit_index = 40;

        static constexpr int scc_bits_base_index = 47;
        static constexpr int scc_bits_num = 8;

        static constexpr int is_next_key_real_bit_index = 39;
        static constexpr int is_prev_key_real_bit_index = 38;
        static constexpr int second_chance_bit_index = 37;

        // bit 63: latch bit
        // bit 62 - 47: software cache-coherence metadata
        // bit 46 - 42: read lock bits
        // bit 41 - 41: write lock bit
        // bit 40 - 40: is_data_modified_since_moved_in
        // bit 39 - 38: is_next_key_real, is_prev_key_real
        // bit 37 - 37: second chance bit
        // bit 36 - 0: scc_data - enough for referencing 128 GB shared CXL memory
        std::atomic<uint64_t> atomic_word{ 0 };
};

uint64_t TwoPLPashaMetadataLocalInit(bool is_tuple_valid);

class TwoPLPashaHelper {
    public:
	using MetaDataType = std::atomic<uint64_t>;

        TwoPLPashaHelper(std::size_t coordinator_id, Context context, std::vector<std::vector<CXLTableBase *> > &cxl_tbl_vecs)
                : coordinator_id(coordinator_id)
                , context(context)
                , cxl_tbl_vecs(cxl_tbl_vecs)
        {
        }

	uint64_t read(const std::tuple<MetaDataType *, void *> &row, void *dest, std::size_t size, std::atomic<uint64_t> &local_cxl_access)
	{
                MetaDataType &meta = *std::get<0>(row);
                TwoPLPashaMetadataLocal *lmeta = reinterpret_cast<TwoPLPashaMetadataLocal *>(meta.load());
                uint64_t tid_ = 0;

                lmeta->lock();
                DCHECK(lmeta->is_valid == true);
                if (lmeta->is_migrated == false) {
		        void *src = std::get<1>(row);
		        simple_memcpy_pasha(dest, src, size);
                        tid_ = lmeta->tid;
                } else {
                        // statistics
                        local_cxl_access.fetch_add(1);

                        TwoPLPashaMetadataShared *smeta = reinterpret_cast<TwoPLPashaMetadataShared *>(lmeta->migrated_row);
                        TwoPLPashaSharedDataSCC *scc_data = smeta->get_scc_data();

                        void *src = scc_data->data;
                        smeta->lock();
                        scc_manager->prepare_read(nullptr, coordinator_id, scc_data, sizeof(TwoPLPashaSharedDataSCC) + size);
                        DCHECK(scc_data->get_flag(TwoPLPashaSharedDataSCC::valid_flag_index) == true);
                        scc_manager->do_read(nullptr, coordinator_id, dest, src, size);
                        tid_ = scc_data->tid;
                        smeta->unlock();
                }
                lmeta->unlock();

		return remove_lock_bit(tid_);
	}

        uint64_t remote_read(char *row, void *dest, std::size_t size)
	{
                // unused
		CHECK(0);
	}

        void update(const std::tuple<MetaDataType *, void *> &row, const void *value, std::size_t value_size)
	{
		MetaDataType &meta = *std::get<0>(row);
                TwoPLPashaMetadataLocal *lmeta = reinterpret_cast<TwoPLPashaMetadataLocal *>(meta.load());

		lmeta->lock();
                DCHECK(lmeta->is_valid == true);
                if (lmeta->is_migrated == false) {
                        void *data_ptr = std::get<1>(row);
                        simple_memcpy_pasha(data_ptr, value, value_size);
                        lmeta->is_data_modified_since_moved_out = true;
                } else {
                        TwoPLPashaMetadataShared *smeta = reinterpret_cast<TwoPLPashaMetadataShared *>(lmeta->migrated_row);
                        TwoPLPashaSharedDataSCC *scc_data = smeta->get_scc_data();
                        void *data_ptr = scc_data->data;

                        smeta->lock();
                        DCHECK(scc_data->get_flag(TwoPLPashaSharedDataSCC::valid_flag_index) == true);
                        scc_manager->do_write(nullptr, coordinator_id, data_ptr, value, value_size);
                        smeta->set_is_data_modified_since_moved_in();
                        smeta->unlock();
                }
		lmeta->unlock();
	}

        void remote_update(char *row, const void *value, std::size_t value_size)
	{
		TwoPLPashaMetadataShared *smeta = reinterpret_cast<TwoPLPashaMetadataShared *>(row);
                TwoPLPashaSharedDataSCC *scc_data = smeta->get_scc_data();
                void *data_ptr = scc_data->data;

		smeta->lock();
                DCHECK(scc_data->get_flag(TwoPLPashaSharedDataSCC::valid_flag_index) == true);
                scc_manager->do_write(nullptr, coordinator_id, data_ptr, value, value_size);
                smeta->set_is_data_modified_since_moved_in();
                smeta->unlock();
	}

	/**
	 * [write lock bit (1) |  read lock bit (9) -- 512 - 1 locks | seq id  (54) ]
	 *
	 */

	static bool is_read_locked(uint64_t value)
	{
		return value & (READ_LOCK_BIT_MASK << READ_LOCK_BIT_OFFSET);
	}

	static bool is_write_locked(uint64_t value)
	{
		return value & (WRITE_LOCK_BIT_MASK << WRITE_LOCK_BIT_OFFSET);
	}

	static uint64_t read_lock_num(uint64_t value)
	{
		return (value >> READ_LOCK_BIT_OFFSET) & READ_LOCK_BIT_MASK;
	}

        void set_read_lock_num(uint64_t &value, uint64_t reader_count)
        {
                value &= ~(READ_LOCK_BIT_MASK << READ_LOCK_BIT_OFFSET);
                value += (reader_count << READ_LOCK_BIT_OFFSET);
        }

        static uint64_t read_lock_max()
	{
		return READ_LOCK_BIT_MASK;
	}

        void set_write_lock_bit(uint64_t &value)
        {
                value |= (WRITE_LOCK_BIT_MASK << WRITE_LOCK_BIT_OFFSET);
        }

        void clear_write_lock_bit(uint64_t &value)
        {
                value &= ~(WRITE_LOCK_BIT_MASK << WRITE_LOCK_BIT_OFFSET);
        }

	uint64_t read_lock(std::atomic<uint64_t> &meta, void* data_ptr, uint64_t size, bool &success)
	{
                TwoPLPashaMetadataLocal *lmeta = reinterpret_cast<TwoPLPashaMetadataLocal *>(meta.load());
                uint64_t old_value = 0, new_value = 0;
                uint64_t tid = 0;

                lmeta->lock();
                if (lmeta->is_migrated == false) {
                        if (lmeta->is_valid == false) {
                                success = false;
                                goto out_unlock_lmeta;
                        }

                        old_value = lmeta->tid;
                        tid = remove_lock_bit(old_value);

                        // can we get the lock?
                        bool write_locked_rl = is_write_locked(old_value);
                        uint64_t reader_cnt_rl = read_lock_num(old_value);
                        if (write_locked_rl || reader_cnt_rl == read_lock_max()) {
                                static std::atomic<uint64_t> read_lock_local_fail{0};
                                uint64_t fail_cnt = read_lock_local_fail.fetch_add(1, std::memory_order_relaxed);
                                if (fail_cnt < 100 || fail_cnt % 10000 == 0) {
                                        LOG(WARNING) << "read_lock (LOCAL): fail #" << fail_cnt
                                                     << " write_locked=" << write_locked_rl
                                                     << " reader_cnt=" << reader_cnt_rl
                                                     << " tid=0x" << std::hex << old_value << std::dec
                                                     << " lmeta=" << (void*)lmeta;
                                }
                                success = false;
                                goto out_unlock_lmeta;
                        }

                        // OK, we can get the lock
                        new_value = old_value + (1ull << READ_LOCK_BIT_OFFSET);
                        lmeta->tid = new_value;
                        success = true;
                } else {
                        TwoPLPashaMetadataShared *smeta = reinterpret_cast<TwoPLPashaMetadataShared *>(lmeta->migrated_row);
                        TwoPLPashaSharedDataSCC *scc_data = smeta->get_scc_data();

                        smeta->lock();

                        // SCC prepare read
                        scc_manager->prepare_read(smeta, coordinator_id, scc_data, sizeof(TwoPLPashaSharedDataSCC) + size);

                        if (smeta->is_data_modified_since_moved_in() == true) {
                                if (scc_data->get_flag(TwoPLPashaSharedDataSCC::valid_flag_index) == false) {
                                        smeta->unlock();
                                        success = false;
                                        goto out_unlock_lmeta;
                                }

                                old_value = scc_data->tid;
                                tid = remove_lock_bit(old_value);

                                // we update our local cache
                                lmeta->is_valid = scc_data->get_flag(TwoPLPashaSharedDataSCC::valid_flag_index);
                                lmeta->tid = scc_data->tid;
                                scc_manager->do_read(nullptr, coordinator_id, data_ptr, scc_data->data, size);

                                // unset the flag
                                smeta->clear_is_data_modified_since_moved_in();
                        } else {
                                if (lmeta->is_valid == false) {
                                        smeta->unlock();
                                        success = false;
                                        goto out_unlock_lmeta;
                                }

                                old_value = lmeta->tid;
                                tid = remove_lock_bit(old_value);
                        }

                        // can we get the lock?
                        bool write_locked_rlock = smeta->is_write_locked();
                        uint64_t reader_cnt_rlock = smeta->get_reader_count();
                        if (write_locked_rlock || reader_cnt_rlock == smeta->get_reader_count_max()) {
                                static std::atomic<uint64_t> local_rlock_fail_count{0};
                                uint64_t fail_cnt = local_rlock_fail_count.fetch_add(1, std::memory_order_relaxed);
                                if (fail_cnt < 100 || fail_cnt % 10000 == 0) {
                                        LOG(WARNING) << "take_read_lock_and_read (migrated): fail #" << fail_cnt
                                                     << " reader_cnt=" << reader_cnt_rlock
                                                     << " write_locked=" << write_locked_rlock
                                                     << " smeta=" << (void*)smeta;
                                }
                                success = false;
                                smeta->unlock();
                                goto out_unlock_lmeta;
                        }

                        // OK, we can get the lock
                        smeta->increase_reader_count();
                        success = true;

                        smeta->unlock();
                }

out_unlock_lmeta:
                lmeta->unlock();
		return tid;
	}

        uint64_t take_read_lock_and_read(const std::tuple<MetaDataType *, void *> &row, void *dest, std::size_t size, bool &success, std::atomic<uint64_t> &local_cxl_access)
	{
                MetaDataType &meta = *std::get<0>(row);
                TwoPLPashaMetadataLocal *lmeta = reinterpret_cast<TwoPLPashaMetadataLocal *>(meta.load());
                uint64_t old_value = 0, new_value = 0;
                uint64_t tid = 0;

                lmeta->lock();
                if (lmeta->is_migrated == false) {
                        void *src = std::get<1>(row);

                        if (lmeta->is_valid == false) {
                                success = false;
                                goto out_unlock_lmeta;
                        }

                        old_value = lmeta->tid;
                        tid = remove_lock_bit(old_value);

                        // can we get the lock?
                        bool write_locked_trlr = is_write_locked(old_value);
                        uint64_t reader_cnt_trlr = read_lock_num(old_value);
                        if (write_locked_trlr || reader_cnt_trlr == read_lock_max()) {
                                static std::atomic<uint64_t> trlr_local_fail{0};
                                uint64_t fail_cnt = trlr_local_fail.fetch_add(1, std::memory_order_relaxed);
                                if (fail_cnt < 100 || fail_cnt % 10000 == 0) {
                                        LOG(WARNING) << "take_read_lock_and_read (LOCAL): fail #" << fail_cnt
                                                     << " write_locked=" << write_locked_trlr
                                                     << " reader_cnt=" << reader_cnt_trlr
                                                     << " tid=0x" << std::hex << old_value << std::dec
                                                     << " lmeta=" << (void*)lmeta;
                                }
                                success = false;
                                goto out_unlock_lmeta;
                        }

                        // OK, we can get the lock
                        new_value = old_value + (1ull << READ_LOCK_BIT_OFFSET);
                        lmeta->tid = new_value;
                        success = true;

                        // read the data
                        simple_memcpy_pasha(dest, src, size);
                } else {
                        TwoPLPashaMetadataShared *smeta = reinterpret_cast<TwoPLPashaMetadataShared *>(lmeta->migrated_row);
                        TwoPLPashaSharedDataSCC *scc_data = smeta->get_scc_data();
                        void *src = nullptr;

                        smeta->lock();

                        // SCC prepare read
                        scc_manager->prepare_read(smeta, coordinator_id, scc_data, sizeof(TwoPLPashaSharedDataSCC) + size);

                        if (smeta->is_data_modified_since_moved_in() == true) {
                                // statistics
                                local_cxl_access.fetch_add(1);

                                if (scc_data->get_flag(TwoPLPashaSharedDataSCC::valid_flag_index) == false) {
                                        smeta->unlock();
                                        success = false;
                                        goto out_unlock_lmeta;
                                }

                                old_value = scc_data->tid;
                                tid = remove_lock_bit(old_value);

                                // we update our local cache
                                lmeta->is_valid = scc_data->get_flag(TwoPLPashaSharedDataSCC::valid_flag_index);
                                lmeta->tid = scc_data->tid;
                                scc_manager->do_read(nullptr, coordinator_id, std::get<1>(row), scc_data->data, size);

                                // unset the flag
                                smeta->clear_is_data_modified_since_moved_in();

                                src = std::get<1>(row);
                        } else {
                                if (lmeta->is_valid == false) {
                                        smeta->unlock();
                                        success = false;
                                        goto out_unlock_lmeta;
                                }

                                old_value = lmeta->tid;
                                tid = remove_lock_bit(old_value);

                                src = std::get<1>(row);
                        }

                        // can we get the lock?
                        if (smeta->is_write_locked() || smeta->get_reader_count() == smeta->get_reader_count_max()) {
                                success = false;
                                smeta->unlock();
                                goto out_unlock_lmeta;
                        }

                        // OK, we can get the lock
                        smeta->increase_reader_count();
                        success = true;

                        // read the data from the local copy
                        simple_memcpy_pasha(dest, src, size);

                        smeta->unlock();
                }

out_unlock_lmeta:
                lmeta->unlock();
		return tid;
	}

        uint64_t remote_take_read_lock_and_read(char *row, void *dest, std::size_t size, bool inc_ref_cnt, bool &success)
	{
		TwoPLPashaMetadataShared *smeta = reinterpret_cast<TwoPLPashaMetadataShared *>(row);
                TwoPLPashaSharedDataSCC *scc_data = smeta->get_scc_data();
                void *src = scc_data->data;
                uint64_t old_value = 0, new_value = 0;
                uint64_t tid = 0;

		smeta->lock();

                // SCC prepare read
                scc_manager->prepare_read(smeta, coordinator_id, scc_data, sizeof(TwoPLPashaSharedDataSCC) + size);

                if (scc_data->get_flag(TwoPLPashaSharedDataSCC::valid_flag_index) == false) {
                        success = false;
                        smeta->unlock();
                        return remove_lock_bit(old_value);
                }

                old_value = scc_data->tid;
                tid = remove_lock_bit(old_value);

                // can we get the lock?
                if (smeta->is_write_locked() || smeta->get_reader_count() == smeta->get_reader_count_max()) {
                        success = false;
                        smeta->unlock();
                        return tid;
                }

                // OK, we can get the lock
                smeta->increase_reader_count();
                success = true;

                // read the data
                scc_manager->do_read(nullptr, coordinator_id, dest, src, size);

                // increase reference counting only if we get the lock
                if (inc_ref_cnt == true) {
                        scc_data->ref_cnt++;
                }

                smeta->unlock();

		return tid;
	}

        uint64_t remote_read_lock_and_inc_ref_cnt(char *row, uint64_t size, bool &success)
	{
		TwoPLPashaMetadataShared *smeta = reinterpret_cast<TwoPLPashaMetadataShared *>(row);
                TwoPLPashaSharedDataSCC *scc_data = smeta->get_scc_data();
                uint64_t old_value = 0, new_value = 0;
                uint64_t tid = 0;

		smeta->lock();

                // SCC prepare read
                scc_manager->prepare_read(smeta, coordinator_id, scc_data, sizeof(TwoPLPashaSharedDataSCC) + size);

                if (scc_data->get_flag(TwoPLPashaSharedDataSCC::valid_flag_index) == false) {
                        success = false;
                        smeta->unlock();
                        return remove_lock_bit(old_value);
                }

                old_value = scc_data->tid;
                tid = remove_lock_bit(old_value);

                // can we get the lock?
                if (smeta->is_write_locked() || smeta->get_reader_count() == smeta->get_reader_count_max()) {
                        success = false;
                        smeta->unlock();
                        return tid;
                }

                // OK, we can get the lock
                smeta->increase_reader_count();
                success = true;

                // increase reference counting only if we get the lock
                scc_data->ref_cnt++;

                smeta->unlock();

		return tid;
	}

	uint64_t write_lock(std::atomic<uint64_t> &meta, void* data_ptr, uint64_t size, bool &success)
	{
                TwoPLPashaMetadataLocal *lmeta = reinterpret_cast<TwoPLPashaMetadataLocal *>(meta.load());
                uint64_t old_value = 0, new_value = 0;
                uint64_t tid = 0;

                lmeta->lock();
                if (lmeta->is_migrated == false) {
                        if (lmeta->is_valid == false) {
                                success = false;
                                goto out_unlock_lmeta;
                        }

                        old_value = lmeta->tid;
                        tid = remove_lock_bit(old_value);

                        // can we get the lock?
                        bool read_locked = is_read_locked(old_value);
                        bool write_locked = is_write_locked(old_value);
                        if (read_locked || write_locked) {
                                static std::atomic<uint64_t> local_wlock_local_fail{0};
                                uint64_t fail_cnt = local_wlock_local_fail.fetch_add(1, std::memory_order_relaxed);
                                if (fail_cnt < 100 || fail_cnt % 10000 == 0) {
                                        LOG(WARNING) << "write_lock (LOCAL): fail #" << fail_cnt
                                                     << " read_locked=" << read_locked
                                                     << " write_locked=" << write_locked
                                                     << " tid=0x" << std::hex << old_value << std::dec
                                                     << " lmeta=" << (void*)lmeta
                                                     << " is_migrated=" << lmeta->is_migrated;
                                }
                                success = false;
                                goto out_unlock_lmeta;
                        }

                        // OK, we can get the lock
                        new_value = old_value + (WRITE_LOCK_BIT_MASK << WRITE_LOCK_BIT_OFFSET);
                        lmeta->tid = new_value;
                        success = true;

                        // DIAGNOSTIC: Track scan write lock acquisitions
                        static std::atomic<uint64_t> scan_wlock_acquire_cnt{0};
                        uint64_t scan_acq_cnt = scan_wlock_acquire_cnt.fetch_add(1, std::memory_order_relaxed);
                        // Log if: first 50, every 1000th, OR if old_tid base matches tid 30
                        uint64_t scan_base_old_tid = old_value & 0x00FFFFFFFFFFFFFF;
                        bool scan_is_tid30 = (scan_base_old_tid == 0x1e);
                        if (scan_acq_cnt < 50 || scan_acq_cnt % 1000 == 0 || scan_is_tid30) {
                                LOG(INFO) << "SCAN_WLOCK_ACQUIRE (LOCAL): #" << scan_acq_cnt
                                          << " lmeta=" << (void*)lmeta
                                          << " old_tid=0x" << std::hex << old_value << std::dec
                                          << " new_tid=0x" << std::hex << new_value << std::dec
                                          << (scan_is_tid30 ? " *** TID30 ROW ***" : "");
                        }
                } else {
                        TwoPLPashaMetadataShared *smeta = reinterpret_cast<TwoPLPashaMetadataShared *>(lmeta->migrated_row);
                        TwoPLPashaSharedDataSCC *scc_data = smeta->get_scc_data();

                        smeta->lock();

                        // SCC prepare read
                        scc_manager->prepare_read(smeta, coordinator_id, scc_data, sizeof(TwoPLPashaSharedDataSCC) + size);

                        if (smeta->is_data_modified_since_moved_in() == true) {
                                if (scc_data->get_flag(TwoPLPashaSharedDataSCC::valid_flag_index) == false) {
                                        smeta->unlock();
                                        success = false;
                                        goto out_unlock_lmeta;
                                }

                                old_value = scc_data->tid;
                                tid = remove_lock_bit(old_value);

                                // we update our local cache
                                lmeta->is_valid = scc_data->get_flag(TwoPLPashaSharedDataSCC::valid_flag_index);
                                lmeta->tid = scc_data->tid;
                                scc_manager->do_read(nullptr, coordinator_id, data_ptr, scc_data->data, size);

                                // unset the flag
                                smeta->clear_is_data_modified_since_moved_in();
                        } else {
                                if (lmeta->is_valid == false) {
                                        smeta->unlock();
                                        success = false;
                                        goto out_unlock_lmeta;
                                }

                                old_value = lmeta->tid;
                                tid = remove_lock_bit(old_value);
                        }

                        // can we get the lock?
                        uint64_t reader_cnt_local = smeta->get_reader_count();
                        bool write_locked_local = smeta->is_write_locked();
                        if (reader_cnt_local > 0 || write_locked_local) {
                                static std::atomic<uint64_t> local_wlock_fail_count{0};
                                uint64_t fail_cnt = local_wlock_fail_count.fetch_add(1, std::memory_order_relaxed);
                                if (fail_cnt < 100 || fail_cnt % 10000 == 0) {
                                        LOG(WARNING) << "take_write_lock_and_read (migrated): fail #" << fail_cnt
                                                     << " reader_cnt=" << reader_cnt_local
                                                     << " write_locked=" << write_locked_local
                                                     << " smeta=" << (void*)smeta;
                                }
                                success = false;
                                smeta->unlock();
                                goto out_unlock_lmeta;
                        }

                        // OK, we can get the lock
                        smeta->set_write_locked();
                        success = true;

                        smeta->unlock();
                }

out_unlock_lmeta:
                lmeta->unlock();
		return tid;
	}

        uint64_t take_write_lock_and_read(const std::tuple<MetaDataType *, void *> &row, void *dest, std::size_t size, bool &success, std::atomic<uint64_t> &local_cxl_access)
	{
                MetaDataType &meta = *std::get<0>(row);
                TwoPLPashaMetadataLocal *lmeta = reinterpret_cast<TwoPLPashaMetadataLocal *>(meta.load());
                uint64_t old_value = 0, new_value = 0;
                uint64_t tid = 0;

                lmeta->lock();
                if (lmeta->is_migrated == false) {
                        void *src = std::get<1>(row);

                        if (lmeta->is_valid == false) {
                                success = false;
                                goto out_unlock_lmeta;
                        }

                        old_value = lmeta->tid;
                        tid = remove_lock_bit(old_value);

                        // can we get the lock?
                        bool read_locked_twlr = is_read_locked(old_value);
                        bool write_locked_twlr = is_write_locked(old_value);
                        if (read_locked_twlr || write_locked_twlr) {
                                static std::atomic<uint64_t> twlr_local_fail{0};
                                static std::unordered_set<void*> logged_stuck_lmetas;
                                static pthread_spinlock_t log_lock;
                                static bool log_lock_init = false;
                                if (!log_lock_init) {
                                        pthread_spin_init(&log_lock, PTHREAD_PROCESS_PRIVATE);
                                        log_lock_init = true;
                                }
                                uint64_t fail_cnt = twlr_local_fail.fetch_add(1, std::memory_order_relaxed);

                                // Log first failure for each unique lmeta
                                pthread_spin_lock(&log_lock);
                                bool first_for_this_lmeta = (logged_stuck_lmetas.find((void*)lmeta) == logged_stuck_lmetas.end());
                                if (first_for_this_lmeta && logged_stuck_lmetas.size() < 20) {
                                        logged_stuck_lmetas.insert((void*)lmeta);
                                }
                                pthread_spin_unlock(&log_lock);

                                if (first_for_this_lmeta || fail_cnt % 10000 == 0) {
                                        LOG(WARNING) << "take_write_lock_and_read (LOCAL): fail #" << fail_cnt
                                                     << " read_locked=" << read_locked_twlr
                                                     << " write_locked=" << write_locked_twlr
                                                     << " tid=0x" << std::hex << old_value << std::dec
                                                     << " lmeta=" << (void*)lmeta
                                                     << " is_valid=" << lmeta->is_valid
                                                     << " is_migrated=" << lmeta->is_migrated
                                                     << (first_for_this_lmeta ? " *** FIRST FAILURE FOR THIS LOCK ***" : "");
                                }
                                success = false;
                                goto out_unlock_lmeta;
                        }

                        // OK, we can get the lock
                        new_value = old_value + (WRITE_LOCK_BIT_MASK << WRITE_LOCK_BIT_OFFSET);
                        lmeta->tid = new_value;
                        success = true;

                        // DIAGNOSTIC: Track outstanding write locks
                        static std::atomic<int64_t> outstanding_wlocks{0};
                        static std::atomic<uint64_t> wlock_acquire_cnt{0};
                        uint64_t acq_cnt = wlock_acquire_cnt.fetch_add(1, std::memory_order_relaxed);
                        int64_t outstanding = outstanding_wlocks.fetch_add(1, std::memory_order_relaxed) + 1;
                        // Log if: first 50, every 1000th, OR if old_tid base matches tid 30 (stuck lock)
                        uint64_t base_old_tid = old_value & 0x00FFFFFFFFFFFFFF;  // Remove lock bits
                        bool is_tid30 = (base_old_tid == 0x1e);
                        if (acq_cnt < 50 || acq_cnt % 1000 == 0 || is_tid30) {
                                LOG(INFO) << "WLOCK_ACQUIRE (LOCAL): #" << acq_cnt
                                          << " outstanding=" << outstanding
                                          << " lmeta=" << (void*)lmeta
                                          << " old_tid=0x" << std::hex << old_value << std::dec
                                          << " new_tid=0x" << std::hex << new_value << std::dec
                                          << (is_tid30 ? " *** TID30 ROW ***" : "");
                        }

                        // read the data
                        simple_memcpy_pasha(dest, src, size);
                } else {
                        TwoPLPashaMetadataShared *smeta = reinterpret_cast<TwoPLPashaMetadataShared *>(lmeta->migrated_row);
                        TwoPLPashaSharedDataSCC *scc_data = smeta->get_scc_data();
                        void *src = nullptr;

                        smeta->lock();

                        // SCC prepare read
                        scc_manager->prepare_read(smeta, coordinator_id, scc_data, sizeof(TwoPLPashaSharedDataSCC) + size);

                        if (smeta->is_data_modified_since_moved_in() == true) {
                                // statistics
                                local_cxl_access.fetch_add(1);

                                if (scc_data->get_flag(TwoPLPashaSharedDataSCC::valid_flag_index) == false) {
                                        smeta->unlock();
                                        success = false;
                                        goto out_unlock_lmeta;
                                }

                                old_value = scc_data->tid;
                                tid = remove_lock_bit(old_value);

                                // we update our local cache
                                lmeta->is_valid = scc_data->get_flag(TwoPLPashaSharedDataSCC::valid_flag_index);
                                lmeta->tid = scc_data->tid;
                                scc_manager->do_read(nullptr, coordinator_id, std::get<1>(row), scc_data->data, size);

                                // unset the flag
                                smeta->clear_is_data_modified_since_moved_in();

                                src = std::get<1>(row);
                        } else {
                                if (lmeta->is_valid == false) {
                                        smeta->unlock();
                                        success = false;
                                        goto out_unlock_lmeta;
                                }

                                old_value = lmeta->tid;
                                tid = remove_lock_bit(old_value);

                                src = std::get<1>(row);
                        }

                        // can we get the lock?
                        if (smeta->get_reader_count() > 0 || smeta->is_write_locked()) {
                                success = false;
                                smeta->unlock();
                                goto out_unlock_lmeta;
                        }

                        // OK, we can get the lock
                        smeta->set_write_locked();
                        success = true;

                        // read the data from the local copy
                        simple_memcpy_pasha(dest, src, size);

                        smeta->unlock();
                }

out_unlock_lmeta:
                lmeta->unlock();
		return tid;
	}

        uint64_t remote_take_write_lock_and_read(char *row, void *dest, std::size_t size, bool inc_ref_cnt, bool &success)
	{
		TwoPLPashaMetadataShared *smeta = reinterpret_cast<TwoPLPashaMetadataShared *>(row);
                TwoPLPashaSharedDataSCC *scc_data = smeta->get_scc_data();
                void *src = scc_data->data;
                uint64_t old_value = 0, new_value = 0;
                uint64_t tid = 0;

		smeta->lock();

                // SCC prepare read
                scc_manager->prepare_read(smeta, coordinator_id, scc_data, sizeof(TwoPLPashaSharedDataSCC) + size);

                if (scc_data->get_flag(TwoPLPashaSharedDataSCC::valid_flag_index) == false) {
                        success = false;
                        smeta->unlock();
                        return remove_lock_bit(old_value);
                }

                old_value = scc_data->tid;
                tid = remove_lock_bit(old_value);

                // can we get the lock?
                uint64_t reader_cnt = smeta->get_reader_count();
                bool write_locked = smeta->is_write_locked();
                if (reader_cnt > 0 || write_locked) {
                        static std::atomic<uint64_t> lock_fail_count{0};
                        uint64_t fail_cnt = lock_fail_count.fetch_add(1, std::memory_order_relaxed);
                        if (fail_cnt < 100 || fail_cnt % 10000 == 0) {
                                LOG(WARNING) << "remote_take_write_lock_and_read: lock fail #" << fail_cnt
                                             << " reader_cnt=" << reader_cnt << " write_locked=" << write_locked
                                             << " smeta=" << (void*)smeta;
                        }
                        success = false;
                        smeta->unlock();
                        return tid;
                }

                // OK, we can get the lock
                smeta->set_write_locked();
                success = true;

                // read the data
                scc_manager->do_read(nullptr, coordinator_id, dest, src, size);

                // increase reference counting only if we get the lock
                if (inc_ref_cnt == true) {
                        scc_data->ref_cnt++;
                }

                smeta->unlock();

		return tid;
	}

        uint64_t remote_write_lock_and_inc_ref_cnt(char *row, uint64_t size, bool &success)
	{
		TwoPLPashaMetadataShared *smeta = reinterpret_cast<TwoPLPashaMetadataShared *>(row);
                TwoPLPashaSharedDataSCC *scc_data = smeta->get_scc_data();
                uint64_t old_value = 0, new_value = 0;
                uint64_t tid = 0;

		smeta->lock();

                // SCC prepare read
                scc_manager->prepare_read(smeta, coordinator_id, scc_data, sizeof(TwoPLPashaSharedDataSCC) + size);

                if (scc_data->get_flag(TwoPLPashaSharedDataSCC::valid_flag_index) == false) {
                        success = false;
                        smeta->unlock();
                        return tid;
                }

                old_value = scc_data->tid;
                tid = remove_lock_bit(old_value);

                // can we get the lock?
                uint64_t reader_cnt2 = smeta->get_reader_count();
                bool write_locked2 = smeta->is_write_locked();
                if (reader_cnt2 > 0 || write_locked2) {
                        static std::atomic<uint64_t> lock_fail_count2{0};
                        uint64_t fail_cnt = lock_fail_count2.fetch_add(1, std::memory_order_relaxed);
                        if (fail_cnt < 100 || fail_cnt % 10000 == 0) {
                                LOG(WARNING) << "remote_write_lock_and_inc_ref_cnt: lock fail #" << fail_cnt
                                             << " reader_cnt=" << reader_cnt2 << " write_locked=" << write_locked2
                                             << " smeta=" << (void*)smeta;
                        }
                        success = false;
                        smeta->unlock();
                        return tid;
                }

                // OK, we can get the lock
                smeta->set_write_locked();
                success = true;

                // increase reference counting only if we get the lock
                scc_data->ref_cnt++;

                smeta->unlock();

		return tid;
	}

	static void read_lock_release(std::atomic<uint64_t> &meta)
	{
                TwoPLPashaMetadataLocal *lmeta = reinterpret_cast<TwoPLPashaMetadataLocal *>(meta.load());
                uint64_t old_value = 0, new_value = 0;

                lmeta->lock();
                if (lmeta->is_migrated == false) {
                        DCHECK(lmeta->is_valid == true);
                        old_value = lmeta->tid;
			DCHECK(is_read_locked(old_value));
			DCHECK(!is_write_locked(old_value));
			new_value = old_value - (1ull << READ_LOCK_BIT_OFFSET);
                        lmeta->tid = new_value;
                } else {
                        TwoPLPashaMetadataShared *smeta = reinterpret_cast<TwoPLPashaMetadataShared *>(lmeta->migrated_row);

                        smeta->lock();
			DCHECK(smeta->get_reader_count() > 0);
			DCHECK(smeta->is_write_locked() == false);
			smeta->decrease_reader_count();
                        smeta->unlock();
                }
                lmeta->unlock();
	}

        static void remote_read_lock_release(char *row)
	{
		TwoPLPashaMetadataShared *smeta = reinterpret_cast<TwoPLPashaMetadataShared *>(row);
                TwoPLPashaSharedDataSCC *scc_data = smeta->get_scc_data();
                uint64_t old_value = 0, new_value = 0;

		smeta->lock();
                DCHECK(smeta->get_reader_count() > 0);
                DCHECK(smeta->is_write_locked() == false);
                smeta->decrease_reader_count();

                smeta->unlock();
	}

	static void write_lock_release(std::atomic<uint64_t> &meta)
	{
                TwoPLPashaMetadataLocal *lmeta = reinterpret_cast<TwoPLPashaMetadataLocal *>(meta.load());
                uint64_t old_value = 0, new_value = 0;

                lmeta->lock();
                if (lmeta->is_migrated == false) {
                        DCHECK(lmeta->is_valid == true);
                        old_value = lmeta->tid;

                        // DIAGNOSTIC: Track write lock releases (abort path)
                        static std::atomic<uint64_t> wlock_release_abort_cnt{0};
                        uint64_t rel_cnt = wlock_release_abort_cnt.fetch_add(1, std::memory_order_relaxed);
                        bool was_locked = is_write_locked(old_value);
                        if (rel_cnt < 50 || rel_cnt % 1000 == 0 || !was_locked) {
                                LOG(INFO) << "WLOCK_RELEASE_ABORT (LOCAL): #" << rel_cnt
                                          << " lmeta=" << (void*)lmeta
                                          << " old_tid=0x" << std::hex << old_value << std::dec
                                          << " write_locked=" << was_locked
                                          << (!was_locked ? " *** RELEASING UNHELD LOCK! ***" : "");
                        }

                        DCHECK(!is_read_locked(old_value));
                        DCHECK(is_write_locked(old_value));
                        new_value = old_value - (1ull << WRITE_LOCK_BIT_OFFSET);
                        lmeta->tid = new_value;
                } else {
                        TwoPLPashaMetadataShared *smeta = reinterpret_cast<TwoPLPashaMetadataShared *>(lmeta->migrated_row);

                        smeta->lock();
                        DCHECK(smeta->get_reader_count() == 0);
                        DCHECK(smeta->is_write_locked() == true);
                        smeta->clear_write_locked();
                        smeta->unlock();
                }
                lmeta->unlock();
	}

        static void remote_write_lock_release(char *row)
	{
		TwoPLPashaMetadataShared *smeta = reinterpret_cast<TwoPLPashaMetadataShared *>(row);
                TwoPLPashaSharedDataSCC *scc_data = smeta->get_scc_data();
                uint64_t old_value = 0, new_value = 0;

		smeta->lock();
                uint64_t reader_cnt = smeta->get_reader_count();
                bool write_locked = smeta->is_write_locked();
                if (reader_cnt != 0 || !write_locked) {
                        static std::atomic<uint64_t> release_fail_count{0};
                        uint64_t fail_cnt = release_fail_count.fetch_add(1, std::memory_order_relaxed);
                        if (fail_cnt < 100 || fail_cnt % 10000 == 0) {
                                LOG(WARNING) << "remote_write_lock_release: unexpected state #" << fail_cnt
                                             << " reader_cnt=" << reader_cnt << " write_locked=" << write_locked
                                             << " smeta=" << (void*)smeta;
                        }
                }
                DCHECK(reader_cnt == 0);
                DCHECK(write_locked == true);
                smeta->clear_write_locked();
                smeta->unlock();
	}

	void write_lock_release(std::atomic<uint64_t> &meta, uint64_t size, uint64_t new_tid)
	{
                TwoPLPashaMetadataLocal *lmeta = reinterpret_cast<TwoPLPashaMetadataLocal *>(meta.load());
                uint64_t old_value = 0;

                lmeta->lock();
                if (lmeta->is_migrated == false) {
                        DCHECK(lmeta->is_valid == true);
                        old_value = lmeta->tid;

                        // DIAGNOSTIC: Track write lock releases (commit path)
                        static std::atomic<uint64_t> wlock_release_commit_cnt{0};
                        uint64_t rel_cnt = wlock_release_commit_cnt.fetch_add(1, std::memory_order_relaxed);
                        bool was_locked = is_write_locked(old_value);
                        // Also log when setting tid to 30 (the stuck lock's tid)
                        uint64_t base_new_tid = new_tid & 0x00FFFFFFFFFFFFFF;
                        bool setting_tid30 = (base_new_tid == 0x1e);
                        if (rel_cnt < 50 || rel_cnt % 1000 == 0 || !was_locked || setting_tid30) {
                                LOG(INFO) << "WLOCK_RELEASE_COMMIT (LOCAL): #" << rel_cnt
                                          << " lmeta=" << (void*)lmeta
                                          << " old_tid=0x" << std::hex << old_value << std::dec
                                          << " new_tid=0x" << std::hex << new_tid << std::dec
                                          << " write_locked=" << was_locked
                                          << (!was_locked ? " *** RELEASING UNHELD LOCK! ***" : "")
                                          << (setting_tid30 ? " *** SETTING TID30 ***" : "");
                        }

                        DCHECK(!is_read_locked(old_value));
                        DCHECK(is_write_locked(old_value));
                        DCHECK(!is_read_locked(new_tid));
                        DCHECK(!is_write_locked(new_tid));
                        lmeta->tid = new_tid;
                } else {
                        TwoPLPashaMetadataShared *smeta = reinterpret_cast<TwoPLPashaMetadataShared *>(lmeta->migrated_row);
                        TwoPLPashaSharedDataSCC *scc_data = smeta->get_scc_data();

                        smeta->lock();
                        DCHECK(smeta->get_reader_count() == 0);
                        DCHECK(smeta->is_write_locked() == true);
                        smeta->clear_write_locked();

                        scc_data->tid = new_tid;

                        scc_manager->finish_write(smeta, coordinator_id, scc_data, sizeof(TwoPLPashaMetadataShared) + size);
                        smeta->unlock();
                }
                lmeta->unlock();
	}

        void remote_write_lock_release(char *row, uint64_t size, uint64_t new_value)
	{
		TwoPLPashaMetadataShared *smeta = reinterpret_cast<TwoPLPashaMetadataShared *>(row);
                TwoPLPashaSharedDataSCC *scc_data = smeta->get_scc_data();
                uint64_t old_value = 0;

		smeta->lock();
                DCHECK(scc_data->get_flag(TwoPLPashaSharedDataSCC::valid_flag_index) == true);

                old_value = scc_data->tid;
                DCHECK(smeta->get_reader_count() == 0);
                DCHECK(smeta->is_write_locked() == true);
                smeta->clear_write_locked();

                scc_data->tid = new_value;

                scc_manager->finish_write(smeta, coordinator_id, scc_data, sizeof(TwoPLPashaMetadataShared) + size);
                smeta->unlock();
	}

        static void modify_tuple_valid_bit(std::atomic<uint64_t> &meta, bool is_valid)
        {
                TwoPLPashaMetadataLocal *lmeta = reinterpret_cast<TwoPLPashaMetadataLocal *>(meta.load());

                lmeta->lock();
                if (lmeta->is_migrated == true) {
                        TwoPLPashaMetadataShared *smeta = reinterpret_cast<TwoPLPashaMetadataShared *>(lmeta->migrated_row);
                        TwoPLPashaSharedDataSCC *scc_data = smeta->get_scc_data();

                        smeta->lock();
                        DCHECK(scc_data->get_flag(TwoPLPashaSharedDataSCC::valid_flag_index) == !is_valid);
                        if (is_valid == true) {
                                scc_data->set_flag(TwoPLPashaSharedDataSCC::valid_flag_index);
                        } else {
                                scc_data->clear_flag(TwoPLPashaSharedDataSCC::valid_flag_index);
                        }
                        smeta->unlock();
                } else {
                        DCHECK(lmeta->is_valid == !is_valid);
                        lmeta->is_valid = is_valid;
                }
                lmeta->unlock();
        }

        static void remote_modify_tuple_valid_bit(char *row, bool is_valid)
        {
                TwoPLPashaMetadataShared *smeta = reinterpret_cast<TwoPLPashaMetadataShared *>(row);
                TwoPLPashaSharedDataSCC *scc_data = smeta->get_scc_data();

		smeta->lock();
                DCHECK(scc_data->ref_cnt > 0);
                DCHECK(scc_data->get_flag(TwoPLPashaSharedDataSCC::valid_flag_index) == !is_valid);
                if (is_valid == true) {
                        scc_data->set_flag(TwoPLPashaSharedDataSCC::valid_flag_index);
                } else {
                        scc_data->clear_flag(TwoPLPashaSharedDataSCC::valid_flag_index);
                }
                smeta->unlock();
        }

	static uint64_t remove_lock_bit(uint64_t value)
	{
		return value & ~(LOCK_BIT_MASK << LOCK_BIT_OFFSET);
	}

	static uint64_t remove_read_lock_bit(uint64_t value)
	{
		return value & ~(READ_LOCK_BIT_MASK << READ_LOCK_BIT_OFFSET);
	}

	static uint64_t remove_write_lock_bit(uint64_t value)
	{
		return value & ~(WRITE_LOCK_BIT_MASK << WRITE_LOCK_BIT_OFFSET);
	}

        void commit_pasha_metadata_init()
        {
                init_finished.store(1, std::memory_order_release);
        }

        void wait_for_pasha_metadata_init()
        {
                while (init_finished.load(std::memory_order_acquire) == 0);
        }

        CXLTableBase *get_cxl_table(std::size_t table_id, std::size_t partition_id)
        {
                return cxl_tbl_vecs[table_id][partition_id];
        }

        // used for modelling the overhead of always go through the CXL indexes for local search
        void model_cxl_search_overhead(const std::tuple<MetaDataType *, void *> &row, std::size_t table_id, std::size_t partition_id, const void *key)
        {
                MetaDataType &meta = *std::get<0>(row);
                TwoPLPashaMetadataLocal *lmeta = reinterpret_cast<TwoPLPashaMetadataLocal *>(meta.load());

                lmeta->lock();
                if (lmeta->is_migrated == true) {
                        // the tuple is migrated, so we should search through the CXL index
                        CXLTableBase *target_cxl_table = cxl_tbl_vecs[table_id][partition_id];
                        char *migrated_row = reinterpret_cast<char *>(target_cxl_table->search(key));
                        DCHECK(migrated_row != nullptr);
                }
                lmeta->unlock();
        }

        // used for remote point queries
        char *get_migrated_row(std::size_t table_id, std::size_t partition_id, const void *key, bool inc_ref_cnt)
        {
                CXLTableBase *target_cxl_table = cxl_tbl_vecs[table_id][partition_id];
                char *migrated_row = reinterpret_cast<char *>(target_cxl_table->search(key));
                void *migration_policy_meta = nullptr;

                if (migrated_row != nullptr) {
                        TwoPLPashaMetadataShared *smeta = reinterpret_cast<TwoPLPashaMetadataShared *>(migrated_row);
                        TwoPLPashaSharedDataSCC *scc_data = smeta->get_scc_data();

                        smeta->lock();
                        if (scc_data->get_flag(TwoPLPashaSharedDataSCC::valid_flag_index) == true) {
                                if (inc_ref_cnt == true) {
                                        scc_data->ref_cnt++;
                                        migration_policy_meta = &scc_data->migration_policy_meta;
                                }
                        } else {
                                migrated_row = nullptr;
                        }
                        smeta->unlock();
                }

                if (migration_policy_meta != nullptr) {
                        migration_manager->access_row(migration_policy_meta, partition_id);
                }

                return migrated_row;
        }

        // used for remote point queries
        void release_migrated_row(std::size_t table_id, std::size_t partition_id, const void *key)
        {
                CXLTableBase *target_cxl_table = cxl_tbl_vecs[table_id][partition_id];
                char *migrated_row = reinterpret_cast<char *>(target_cxl_table->search(key));
                DCHECK(migrated_row != nullptr);

                TwoPLPashaMetadataShared *smeta = reinterpret_cast<TwoPLPashaMetadataShared *>(migrated_row);
                TwoPLPashaSharedDataSCC *scc_data = smeta->get_scc_data();

                smeta->lock();
                DCHECK(scc_data->ref_cnt > 0);
                scc_data->ref_cnt--;
                smeta->unlock();
        }

        // used for remote scan
        static void decrease_reference_count_via_ptr(void *cxl_row)
        {
                TwoPLPashaMetadataShared *smeta = reinterpret_cast<TwoPLPashaMetadataShared *>(cxl_row);
                TwoPLPashaSharedDataSCC *scc_data = smeta->get_scc_data();

                smeta->lock();
                DCHECK(scc_data->ref_cnt > 0);
                scc_data->ref_cnt--;
                smeta->unlock();
        }

        // used for remote point queries
        bool remove_migrated_row(std::size_t table_id, std::size_t partition_id, const void *key)
        {
                CXLTableBase *target_cxl_table = cxl_tbl_vecs[table_id][partition_id];
                return target_cxl_table->remove(key, nullptr);
        }

        migration_result move_from_hashmap_to_shared_region(ITable *table, const void *key, const std::tuple<MetaDataType *, void *> &row, bool inc_ref_cnt, void *&migration_policy_meta)
	{
                MetaDataType &meta = *std::get<0>(row);
                TwoPLPashaMetadataLocal *lmeta = reinterpret_cast<TwoPLPashaMetadataLocal *>(meta.load());
                void *local_data = std::get<1>(row);
                bool insert_ret = false;
                migration_result res = migration_result::FAIL_OOM;

		lmeta->lock();
                if (lmeta->is_migrated == false) {
                        TwoPLPashaMetadataShared *smeta = reinterpret_cast<TwoPLPashaMetadataShared *>(cxl_memory.cxlalloc_malloc_wrapper(sizeof(TwoPLPashaMetadataShared), CXLMemory::METADATA_ALLOCATION));
                        if (smeta == nullptr) {
                                res = migration_result::FAIL_OOM;
                                lmeta->unlock();
                                return res;
                        }

                        TwoPLPashaSharedDataSCC *scc_data = nullptr;
                        if (lmeta->scc_data == nullptr || context.enable_scc == false) {
                                // there is no cached copy in CXL - allocate SCC data
                                scc_data = reinterpret_cast<TwoPLPashaSharedDataSCC *>(cxl_memory.cxlalloc_malloc_wrapper(sizeof(TwoPLPashaSharedDataSCC) + table->value_size(), CXLMemory::DATA_ALLOCATION));
                                if (scc_data == nullptr) {
                                        res = migration_result::FAIL_OOM;
                                        lmeta->unlock();
                                        return res;
                                }

                                lmeta->scc_data = scc_data;
                        } else {
                                // we have a cached copy in CXL - reuse it
                                scc_data = lmeta->scc_data;
                        }
                        new(smeta) TwoPLPashaMetadataShared(scc_data);

                        // init migration policy metadata
                        migration_manager->init_migration_policy_metadata(&scc_data->migration_policy_meta, table, key, row, sizeof(TwoPLPashaMetadataShared));
                        migration_policy_meta = scc_data->migration_policy_meta;

                        // init software cache-coherence metadata
                        scc_manager->init_scc_metadata(smeta, coordinator_id);

                        // take the CXL latch
                        smeta->lock();

                        // copy metadata
                        if (lmeta->is_valid == true) {
                                scc_data->set_flag(TwoPLPashaSharedDataSCC::valid_flag_index);
                        } else {
                                scc_data->clear_flag(TwoPLPashaSharedDataSCC::valid_flag_index);
                        }
                        scc_data->tid = lmeta->tid;
                        smeta->set_reader_count(read_lock_num(lmeta->tid));
                        if (is_write_locked(lmeta->tid) == true) {
                                smeta->set_write_locked();
                        } else {
                                smeta->clear_write_locked();
                        }
                        DCHECK(read_lock_num(lmeta->tid) == smeta->get_reader_count());
                        DCHECK(is_write_locked(lmeta->tid) == smeta->is_write_locked());

                        // copy data
                        if (lmeta->is_data_modified_since_moved_out == true || context.enable_migration_optimization == false) {
                                scc_manager->do_write(nullptr, coordinator_id, scc_data->data, local_data, table->value_size());
                        }
                        lmeta->is_data_modified_since_moved_out = false;    // optimization to reduce memcpy when moving data in
                        smeta->clear_is_data_modified_since_moved_in();   // optimization to reduce memcpy when moving data out

                        // increase the reference count for the requesting host
                        if (inc_ref_cnt == true) {
                                scc_data->ref_cnt++;
                        }

                        // insert into the corresponding CXL table
                        CXLTableBase *target_cxl_table = cxl_tbl_vecs[table->tableID()][table->partitionID()];
                        insert_ret = target_cxl_table->insert(key, smeta);
                        DCHECK(insert_ret == true);

                        // mark the local row as migrated
                        lmeta->migrated_row = reinterpret_cast<char *>(smeta);
                        lmeta->is_migrated = true;

                        scc_manager->finish_write(smeta, coordinator_id, scc_data, sizeof(TwoPLPashaSharedDataSCC) + table->value_size());

                        // release the CXL latch
                        smeta->unlock();

                        // LOG(INFO) << "moved in a row with key " << key << " from table " << table->tableID();

                        res = migration_result::SUCCESS;
                } else {
                        if (inc_ref_cnt == true) {
                                // increase the reference count for the requesting host, even if it is already migrated
                                TwoPLPashaMetadataShared *smeta = reinterpret_cast<TwoPLPashaMetadataShared *>(lmeta->migrated_row);
                                TwoPLPashaSharedDataSCC *scc_data = smeta->get_scc_data();

                                smeta->lock();
                                scc_data->ref_cnt++;
                                smeta->unlock();
                        }
                        res = migration_result::FAIL_ALREADY_IN_CXL;
                }
		lmeta->unlock();

		return res;
	}

        migration_result move_from_btree_to_shared_region(ITable *table, const void *key, const std::tuple<MetaDataType *, void *> &row, bool inc_ref_cnt, void *&migration_policy_meta)
	{
                bool insert_ret = false;
                bool update_next_key_ret = false;
                migration_result res = migration_result::FAIL_OOM;

                auto move_in_processor = [&](const void *prev_key, void *prev_meta, void *prev_data, const void *cur_key, void *cur_meta, void *cur_data, const void *next_key, void *next_meta, void *next_data) {
                        auto prev_lmeta = reinterpret_cast<TwoPLPashaMetadataLocal *>(prev_meta);
                        auto cur_lmeta = reinterpret_cast<TwoPLPashaMetadataLocal *>(cur_meta);
                        auto next_lmeta = reinterpret_cast<TwoPLPashaMetadataLocal *>(next_meta);

                        bool is_next_key_migrated = false, next_key_exist = false;
                        bool is_prev_key_migrated = false, prev_key_exist = false;

                        // check if the previous tuple is migrated
                        // and update its next-key information
                        if (prev_lmeta != nullptr) {
                                prev_lmeta->lock();
                                if (prev_lmeta->is_migrated == true) {
                                        is_prev_key_migrated = true;
                                }
                                prev_lmeta->unlock();
                                prev_key_exist = true;
                        }

                        // check if the next tuple is migrated
                        // and update its prev-key information
                        if (next_lmeta != nullptr) {
                                next_lmeta->lock();
                                if (next_lmeta->is_migrated == true) {
                                        is_next_key_migrated = true;
                                }
                                next_lmeta->unlock();
                                next_key_exist = true;
                        }

                        // check if the current tuple is migrated
                        // if yes, do the migration and update the next-key information
                        cur_lmeta->lock();
                        if (cur_lmeta->is_migrated == false) {
                                // allocate the CXL row
                                TwoPLPashaMetadataShared *cur_smeta = reinterpret_cast<TwoPLPashaMetadataShared *>(cxl_memory.cxlalloc_malloc_wrapper(sizeof(TwoPLPashaMetadataShared), CXLMemory::METADATA_ALLOCATION));
                                if (cur_smeta == nullptr) {
                                        res = migration_result::FAIL_OOM;
                                        cur_lmeta->unlock();
                                        return;
                                }

                                TwoPLPashaSharedDataSCC *cur_scc_data = nullptr;
                                if (cur_lmeta->scc_data == nullptr || context.enable_scc == false) {
                                        // there is no cached copy in CXL - allocate SCC data
                                        cur_scc_data = reinterpret_cast<TwoPLPashaSharedDataSCC *>(cxl_memory.cxlalloc_malloc_wrapper(sizeof(TwoPLPashaSharedDataSCC) + table->value_size(), CXLMemory::DATA_ALLOCATION));
                                        if (cur_scc_data == nullptr) {
                                                res = migration_result::FAIL_OOM;
                                                cur_lmeta->unlock();
                                                return;
                                        }

                                        cur_lmeta->scc_data = cur_scc_data;
                                } else {
                                        // we have a cached copy in CXL - reuse it
                                        cur_scc_data = cur_lmeta->scc_data;
                                }
                                new(cur_smeta) TwoPLPashaMetadataShared(cur_scc_data);

                                // init migration policy metadata
                                migration_manager->init_migration_policy_metadata(&cur_scc_data->migration_policy_meta, table, key, row, sizeof(TwoPLPashaMetadataShared));
                                migration_policy_meta = cur_scc_data->migration_policy_meta;

                                // init software cache-coherence metadata
                                scc_manager->init_scc_metadata(cur_smeta, coordinator_id);

                                // take the CXL latch
                                cur_smeta->lock();

                                // copy metadata
                                if (cur_lmeta->is_valid == true) {
                                        cur_scc_data->set_flag(TwoPLPashaSharedDataSCC::valid_flag_index);
                                } else {
                                        cur_scc_data->clear_flag(TwoPLPashaSharedDataSCC::valid_flag_index);
                                }
                                cur_scc_data->tid = cur_lmeta->tid;
                                cur_smeta->set_reader_count(read_lock_num(cur_lmeta->tid));
                                if (is_write_locked(cur_lmeta->tid) == true) {
                                        cur_smeta->set_write_locked();
                                } else {
                                        cur_smeta->clear_write_locked();
                                }
                                DCHECK(read_lock_num(cur_lmeta->tid) == cur_smeta->get_reader_count());
                                DCHECK(is_write_locked(cur_lmeta->tid) == cur_smeta->is_write_locked());

                                // copy data
                                if (cur_lmeta->is_data_modified_since_moved_out == true || context.enable_migration_optimization == false) {
                                        scc_manager->do_write(nullptr, coordinator_id, cur_scc_data->data, cur_data, table->value_size());
                                }
                                cur_lmeta->is_data_modified_since_moved_out = false;    // optimization to reduce memcpy when moving data in
                                cur_smeta->clear_is_data_modified_since_moved_in();   // optimization to reduce memcpy when moving data out

                                // increase the reference count for the requesting host
                                if (inc_ref_cnt == true) {
                                        cur_scc_data->ref_cnt++;
                                }

                                // update the next-key information
                                if (is_next_key_migrated == true) {
                                        cur_smeta->set_next_key_real_bit();
                                } else {
                                        cur_smeta->clear_next_key_real_bit();
                                }

                                // update the prev-key information
                                if (is_prev_key_migrated == true) {
                                        cur_smeta->set_prev_key_real_bit();
                                } else {
                                        cur_smeta->clear_prev_key_real_bit();
                                }

                                // insert into the corresponding CXL table
                                CXLTableBase *target_cxl_table = cxl_tbl_vecs[table->tableID()][table->partitionID()];
                                insert_ret = target_cxl_table->insert(key, cur_smeta);
                                DCHECK(insert_ret == true);

                                // mark the local row as migrated
                                cur_lmeta->migrated_row = reinterpret_cast<char *>(cur_smeta);
                                cur_lmeta->is_migrated = true;

                                scc_manager->finish_write(cur_smeta, coordinator_id, cur_scc_data, sizeof(TwoPLPashaSharedDataSCC) + table->value_size());

                                // release the CXL latch
                                cur_smeta->unlock();

                                // lazily update the next-key information for the previous key
                                if (prev_lmeta != nullptr) {
                                        prev_lmeta->lock();
                                        if (prev_lmeta->is_migrated == true) {
                                                auto prev_smeta = reinterpret_cast<TwoPLPashaMetadataShared *>(prev_lmeta->migrated_row);

                                                prev_smeta->lock();
                                                prev_smeta->set_next_key_real_bit();
                                                prev_smeta->unlock();
                                        }
                                        prev_lmeta->unlock();
                                }

                                // lazily update the next-key information for the previous key
                                if (next_lmeta != nullptr) {
                                        next_lmeta->lock();
                                        if (next_lmeta->is_migrated == true) {
                                                auto next_smeta = reinterpret_cast<TwoPLPashaMetadataShared *>(next_lmeta->migrated_row);

                                                next_smeta->lock();
                                                next_smeta->set_prev_key_real_bit();
                                                next_smeta->unlock();
                                        }
                                        next_lmeta->unlock();
                                }

                                res = migration_result::SUCCESS;
                        } else {
                                // lazily update the next-key information for the previous key
                                if (prev_lmeta != nullptr) {
                                        prev_lmeta->lock();
                                        if (prev_lmeta->is_migrated == true) {
                                                auto prev_smeta = reinterpret_cast<TwoPLPashaMetadataShared *>(prev_lmeta->migrated_row);

                                                prev_smeta->lock();
                                                prev_smeta->set_next_key_real_bit();
                                                prev_smeta->unlock();
                                        }
                                        prev_lmeta->unlock();
                                }

                                // lazily update the next-key information for the previous key
                                if (next_lmeta != nullptr) {
                                        next_lmeta->lock();
                                        if (next_lmeta->is_migrated == true) {
                                                auto next_smeta = reinterpret_cast<TwoPLPashaMetadataShared *>(next_lmeta->migrated_row);

                                                next_smeta->lock();
                                                next_smeta->set_prev_key_real_bit();
                                                next_smeta->unlock();
                                        }
                                        next_lmeta->unlock();
                                }

                                if (inc_ref_cnt == true) {
                                        // increase the reference count for the requesting host, even if it is already migrated
                                        TwoPLPashaMetadataShared *cur_smeta = reinterpret_cast<TwoPLPashaMetadataShared *>(cur_lmeta->migrated_row);
                                        auto cur_scc_data = reinterpret_cast<TwoPLPashaSharedDataSCC *>(cur_smeta->get_scc_data());

                                        cur_smeta->lock();
                                        cur_scc_data->ref_cnt++;
                                        cur_smeta->unlock();
                                }
                                res = migration_result::FAIL_ALREADY_IN_CXL;

                                // the next-key information should already been updated
                        }
                        cur_lmeta->unlock();
		};

                // update next-key information
                update_next_key_ret = table->search_and_update_next_key_info(key, move_in_processor);
                DCHECK(update_next_key_ret == true);

		return res;
	}

        migration_result move_from_partition_to_shared_region(ITable *table, const void *key, const std::tuple<MetaDataType *, void *> &row, bool inc_ref_cnt, void *&migration_policy_meta)
	{
                migration_result res = migration_result::FAIL_OOM;

                if (this->context.enable_phantom_detection == true) {
                        if (table->tableType() == ITable::HASHMAP) {
                                res = move_from_hashmap_to_shared_region(table, key, row, inc_ref_cnt, migration_policy_meta);
                        } else if (table->tableType() == ITable::BTREE) {
                                res = move_from_btree_to_shared_region(table, key, row, inc_ref_cnt, migration_policy_meta);
                        } else {
                                DCHECK(0);
                        }
                } else {
                        res = move_from_hashmap_to_shared_region(table, key, row, inc_ref_cnt, migration_policy_meta);
                }

                // statistics
                if (res == migration_result::SUCCESS) {
                        // LOG(INFO) << "moved in a row with key " << table->get_plain_key(key) << " from table " << table->tableID();
                        num_data_move_in.fetch_add(1);
                }

		return res;
	}

        bool move_from_hashmap_to_partition(ITable *table, const void *key, const std::tuple<MetaDataType *, void *> &row)
	{
                MetaDataType &meta = *std::get<0>(row);
		TwoPLPashaMetadataLocal *lmeta = reinterpret_cast<TwoPLPashaMetadataLocal *>(meta.load());
                void *local_data = std::get<1>(row);
                bool ret = false;

                lmeta->lock();
                if (lmeta->is_migrated == true) {
                        TwoPLPashaMetadataShared *smeta = reinterpret_cast<TwoPLPashaMetadataShared *>(lmeta->migrated_row);
                        TwoPLPashaSharedDataSCC *scc_data = smeta->get_scc_data();

                        // take the CXL latch
                        smeta->lock();

                        // reference count > 0, cannot move out the tuple
                        if (scc_data->ref_cnt > 0) {
                                smeta->unlock();
                                lmeta->unlock();
                                return false;
                        }

                        scc_manager->prepare_read(smeta, coordinator_id, scc_data, sizeof(TwoPLPashaSharedDataSCC) + table->value_size());

                        // copy metadata back
                        lmeta->is_valid = scc_data->get_flag(TwoPLPashaSharedDataSCC::valid_flag_index);
                        lmeta->tid = scc_data->tid;
                        set_read_lock_num(lmeta->tid, smeta->get_reader_count());
                        if (smeta->is_write_locked() == true) {
                                set_write_lock_bit(lmeta->tid);
                        } else {
                                clear_write_lock_bit(lmeta->tid);
                        }
                        DCHECK(read_lock_num(lmeta->tid) == smeta->get_reader_count());
                        DCHECK(is_write_locked(lmeta->tid) == smeta->is_write_locked());

                        // copy data back
                        if (smeta->is_data_modified_since_moved_in() == true || context.enable_migration_optimization == false) {
                                scc_manager->do_read(nullptr, coordinator_id, local_data, scc_data->data, table->value_size());
                        }
                        lmeta->is_data_modified_since_moved_out = false;
                        smeta->clear_is_data_modified_since_moved_in();

                        // set the migrated row as invalid
                        scc_data->clear_flag(TwoPLPashaSharedDataSCC::valid_flag_index);

                        // remove from CXL index
                        CXLTableBase *target_cxl_table = cxl_tbl_vecs[table->tableID()][table->partitionID()];
                        ret = target_cxl_table->remove(key, lmeta->migrated_row);
                        DCHECK(ret == true);

                        // mark the local row as not migrated
                        lmeta->migrated_row = nullptr;
                        lmeta->is_migrated = false;

                        // free the CXL row
                        if (context.enable_scc == false) {
                                cxl_memory.cxlalloc_free_wrapper(smeta->get_scc_data(), sizeof(TwoPLPashaSharedDataSCC) + table->value_size(), CXLMemory::DATA_FREE);
                                global_ebr_meta->add_retired_object(smeta->get_scc_data(), sizeof(TwoPLPashaSharedDataSCC) + table->value_size(), CXLMemory::DATA_FREE);
                        }
                        cxl_memory.cxlalloc_free_wrapper(smeta, sizeof(TwoPLPashaMetadataShared), CXLMemory::METADATA_FREE);
                        global_ebr_meta->add_retired_object(smeta, sizeof(TwoPLPashaMetadataShared), CXLMemory::METADATA_FREE);

                        // release the CXL latch
                        smeta->unlock();
                } else {
                        DCHECK(0);
                }
                lmeta->unlock();

                return true;
	}

        bool move_from_btree_to_partition(ITable *table, const void *key, const std::tuple<MetaDataType *, void *> &row)
	{
                bool move_out_success = false;
                bool ret = false;

                auto move_out_processor = [&](const void *prev_key, void *prev_meta, void *prev_data, const void *cur_key, void *cur_meta, void *cur_data, const void *next_key, void *next_meta, void *next_data) {
                        auto prev_lmeta = reinterpret_cast<TwoPLPashaMetadataLocal *>(prev_meta);
                        auto cur_lmeta = reinterpret_cast<TwoPLPashaMetadataLocal *>(cur_meta);
                        auto next_lmeta = reinterpret_cast<TwoPLPashaMetadataLocal *>(next_meta);

                        bool is_cur_tuple_moved_out = false;

                        // eagerly update the next-key information for the previous tuple
                        if (prev_lmeta != nullptr) {
                                prev_lmeta->lock();
                                if (prev_lmeta->is_migrated == true) {
                                        auto prev_smeta = reinterpret_cast<TwoPLPashaMetadataShared *>(prev_lmeta->migrated_row);

                                        prev_smeta->lock();
                                        prev_smeta->clear_next_key_real_bit();
                                        prev_smeta->unlock();
                                }
                                prev_lmeta->unlock();
                        }

                        // eagerly update the prev-key information for the next tuple
                        if (next_lmeta != nullptr) {
                                next_lmeta->lock();
                                if (next_lmeta->is_migrated == true) {
                                        auto next_smeta = reinterpret_cast<TwoPLPashaMetadataShared *>(next_lmeta->migrated_row);

                                        next_smeta->lock();
                                        next_smeta->clear_prev_key_real_bit();
                                        next_smeta->unlock();
                                }
                                next_lmeta->unlock();
                        }

                        cur_lmeta->lock();
                        DCHECK(cur_lmeta->is_valid = true);
                        if (cur_lmeta->is_migrated == true) {
                                TwoPLPashaMetadataShared *cur_smeta = reinterpret_cast<TwoPLPashaMetadataShared *>(cur_lmeta->migrated_row);
                                TwoPLPashaSharedDataSCC *cur_scc_data = cur_smeta->get_scc_data();

                                // take the CXL latch
                                cur_smeta->lock();

                                // reference count > 0, cannot move out the tuple -> early return
                                if (cur_scc_data->ref_cnt > 0) {
                                        cur_smeta->unlock();
                                        cur_lmeta->unlock();
                                        move_out_success = false;
                                        return;
                                }

                                scc_manager->prepare_read(cur_smeta, coordinator_id, cur_scc_data, sizeof(TwoPLPashaSharedDataSCC) + table->value_size());

                                // copy metadata back
                                cur_lmeta->is_valid = cur_scc_data->get_flag(TwoPLPashaSharedDataSCC::valid_flag_index);
                                cur_lmeta->tid = cur_scc_data->tid;
                                set_read_lock_num(cur_lmeta->tid, cur_smeta->get_reader_count());
                                if (cur_smeta->is_write_locked() == true) {
                                        set_write_lock_bit(cur_lmeta->tid);
                                } else {
                                        clear_write_lock_bit(cur_lmeta->tid);
                                }
                                DCHECK(read_lock_num(cur_lmeta->tid) == cur_smeta->get_reader_count());
                                DCHECK(is_write_locked(cur_lmeta->tid) == cur_smeta->is_write_locked());

                                // copy data back
                                if (cur_smeta->is_data_modified_since_moved_in() == true || context.enable_migration_optimization == false) {
                                        scc_manager->do_read(nullptr, coordinator_id, cur_data, cur_smeta->get_scc_data()->data, table->value_size());
                                }
                                cur_lmeta->is_data_modified_since_moved_out = false;
                                cur_smeta->clear_is_data_modified_since_moved_in();

                                // set the migrated row as invalid
                                cur_scc_data->clear_flag(TwoPLPashaSharedDataSCC::valid_flag_index);

                                // mark the local row as not migrated
                                cur_lmeta->migrated_row = nullptr;
                                cur_lmeta->is_migrated = false;

                                // free the CXL row
                                if (context.enable_scc == false) {
                                        cxl_memory.cxlalloc_free_wrapper(cur_smeta->get_scc_data(), sizeof(TwoPLPashaSharedDataSCC) + table->value_size(), CXLMemory::DATA_FREE);
                                        global_ebr_meta->add_retired_object(cur_smeta->get_scc_data(), sizeof(TwoPLPashaSharedDataSCC) + table->value_size(), CXLMemory::DATA_FREE);
                                }
                                cxl_memory.cxlalloc_free_wrapper(cur_smeta, sizeof(TwoPLPashaMetadataShared), CXLMemory::METADATA_FREE);
                                global_ebr_meta->add_retired_object(cur_smeta, sizeof(TwoPLPashaMetadataShared), CXLMemory::METADATA_FREE);

                                // release the CXL latch
                                cur_smeta->unlock();

                                // remove the current-key from the CXL index
                                // it is safe to do so because there is no concurrent data move in/out
                                CXLTableBase *target_cxl_table = cxl_tbl_vecs[table->tableID()][table->partitionID()];
                                ret = target_cxl_table->remove(key, nullptr);
                                DCHECK(ret == true);
                        } else {
                                DCHECK(0);
                        }
                        cur_lmeta->unlock();

                        move_out_success = true;
		};

                // update next-key information
                ret = table->search_and_update_next_key_info(key, move_out_processor);
                DCHECK(ret == true);

		return move_out_success;
	}

        bool move_from_shared_region_to_partition(ITable *table, const void *key, const std::tuple<MetaDataType *, void *> &row)
	{
                bool move_out_success = false;

                if (this->context.enable_phantom_detection == true) {
                        if (table->tableType() == ITable::HASHMAP) {
                                move_out_success = move_from_hashmap_to_partition(table, key, row);
                        } else if (table->tableType() == ITable::BTREE) {
                                move_out_success = move_from_btree_to_partition(table, key, row);
                        } else {
                                DCHECK(0);
                        }
                } else {
                        move_out_success = move_from_hashmap_to_partition(table, key, row);
                }

                // statistics
                if (move_out_success == true) {
                        // LOG(INFO) << "moved out a row with key " << table->get_plain_key(key) << " from table " << table->tableID();
                        num_data_move_out.fetch_add(1);
                }

		return move_out_success;
	}

        bool insert_and_update_next_key_info(ITable *table, const void *key, const void *value, bool require_lock_next_key, ITable::row_entity &next_row_entity)
        {
                auto adjacent_tuples_processor = [&](const void *prev_key, MetaDataType *prev_meta, void *prev_data, const void *next_key, MetaDataType *next_meta, void *next_data) -> bool {
                        TwoPLPashaMetadataLocal *prev_lmeta = nullptr, *next_lmeta = nullptr;
                        if (prev_meta != nullptr) {
                                prev_lmeta = reinterpret_cast<TwoPLPashaMetadataLocal *>(prev_meta->load());
                        }
                        if (next_meta != nullptr) {
                                next_lmeta = reinterpret_cast<TwoPLPashaMetadataLocal *>(next_meta->load());
                        }

                        if (require_lock_next_key == true) {
                                // try to acquire the write lock of the next key
                                DCHECK(next_meta != nullptr);
                                std::atomic<uint64_t> &meta = *reinterpret_cast<std::atomic<uint64_t> *>(next_meta);
                                bool lock_success = false;
                                write_lock(meta, next_data, table->value_size(), lock_success);
                                if (lock_success == true) {
                                        ITable::row_entity next_row(next_key, table->key_size(), &meta, next_data, table->value_size());
                                        next_row_entity = next_row;

                                        // update the next key information for the previous key
                                        if (prev_lmeta != nullptr) {
                                                prev_lmeta->lock();
                                                if (prev_lmeta->is_migrated == true) {
                                                        auto prev_smeta = reinterpret_cast<TwoPLPashaMetadataShared *>(prev_lmeta->migrated_row);

                                                        prev_smeta->lock();
                                                        prev_smeta->clear_next_key_real_bit();
                                                        prev_smeta->unlock();
                                                }
                                                prev_lmeta->unlock();
                                        }

                                        // update the previous key information for the next key
                                        if (next_lmeta != nullptr) {
                                                next_lmeta->lock();
                                                if (next_lmeta->is_migrated == true) {
                                                        auto next_smeta = reinterpret_cast<TwoPLPashaMetadataShared *>(next_lmeta->migrated_row);

                                                        next_smeta->lock();
                                                        next_smeta->clear_prev_key_real_bit();
                                                        next_smeta->unlock();
                                                }
                                                next_lmeta->unlock();
                                        }
                                }
                                return lock_success;
                        } else {
                                // update the next key information for the previous key
                                if (prev_lmeta != nullptr) {
                                        prev_lmeta->lock();
                                        if (prev_lmeta->is_migrated == true) {
                                                auto prev_smeta = reinterpret_cast<TwoPLPashaMetadataShared *>(prev_lmeta->migrated_row);

                                                prev_smeta->lock();
                                                prev_smeta->clear_next_key_real_bit();
                                                prev_smeta->unlock();
                                        }
                                        prev_lmeta->unlock();
                                }

                                // update the previous key information for the next key
                                if (next_lmeta != nullptr) {
                                        next_lmeta->lock();
                                        if (next_lmeta->is_migrated == true) {
                                                auto next_smeta = reinterpret_cast<TwoPLPashaMetadataShared *>(next_lmeta->migrated_row);

                                                next_smeta->lock();
                                                next_smeta->clear_prev_key_real_bit();
                                                next_smeta->unlock();
                                        }
                                        next_lmeta->unlock();
                                }
                                return true;
                        }
                };

                // insert a placeholder and update adjacent tuple information if necessary
                return table->insert_and_process_adjacent_tuples(key, value, adjacent_tuples_processor, true);
        }

        bool delete_and_update_next_key_info(ITable *table, const void *key, bool is_local_delete, bool &need_move_out_from_migration_tracker, void *&migration_policy_meta)
	{
                 auto adjacent_tuples_processor = [&](const void *prev_key, void *prev_meta, void *prev_data, const void *cur_key, void *cur_meta, void *cur_data, const void *next_key, void *next_meta, void *next_data) -> bool {
                        auto prev_lmeta = reinterpret_cast<TwoPLPashaMetadataLocal *>(prev_meta);
                        auto cur_lmeta = reinterpret_cast<TwoPLPashaMetadataLocal *>(cur_meta);
                        auto next_lmeta = reinterpret_cast<TwoPLPashaMetadataLocal *>(next_meta);

                        bool is_next_key_migrated = false;
                        bool is_prev_key_migrated = false;
                        bool need_remove_from_cxl_index = false;

                        // take the latches of the previous and the next keys
                        if (prev_lmeta != nullptr) {
                                prev_lmeta->lock();
                        }
                        if (next_lmeta != nullptr) {
                                next_lmeta->lock();
                        }

                        // update the next-key information for the previous key
                        if (prev_lmeta != nullptr) {
                                if (prev_lmeta->is_migrated == true) {
                                        auto prev_smeta = reinterpret_cast<TwoPLPashaMetadataShared *>(prev_lmeta->migrated_row);

                                        prev_smeta->lock();
                                        if (next_lmeta != nullptr && next_lmeta->is_migrated == false) {
                                                prev_smeta->clear_next_key_real_bit();
                                        } else if (next_lmeta != nullptr && next_lmeta->is_migrated == true) {
                                                // We should treat migrated tuples as equal no matter they are valid or not.
                                                // Since we are removing the migrated tuple but keeping the local tuple, we should mark the next key as false.
                                                prev_smeta->clear_next_key_real_bit();
                                        } else {
                                                prev_smeta->clear_next_key_real_bit();
                                        }
                                        prev_smeta->unlock();
                                }
                        }

                        // update the prev-key information for next key
                        if (next_lmeta != nullptr) {
                                if (next_lmeta->is_migrated == true) {
                                        auto next_smeta = reinterpret_cast<TwoPLPashaMetadataShared *>(next_lmeta->migrated_row);

                                        next_smeta->lock();
                                        if (prev_lmeta != nullptr && prev_lmeta->is_migrated == false) {
                                                next_smeta->clear_prev_key_real_bit();
                                        } else if (prev_lmeta != nullptr && prev_lmeta->is_migrated == true) {
                                                // We should treat migrated tuples as equal no matter they are valid or not.
                                                // Since we are removing the migrated tuple but keeping the local tuple, we should mark the previous key as false.
                                                next_smeta->clear_prev_key_real_bit();
                                        } else {
                                                next_smeta->clear_prev_key_real_bit();
                                        }
                                        next_smeta->unlock();
                                }
                        }

                        // release the latches of the previous and the next keys
                        if (prev_lmeta != nullptr) {
                                prev_lmeta->unlock();
                        }
                        if (next_lmeta != nullptr) {
                                next_lmeta->unlock();
                        }

                        // mark both the local and the migrated tuples as invalid
                        DCHECK(cur_lmeta != nullptr);
                        cur_lmeta->lock();
                        if (cur_lmeta->is_migrated == true) {
                                auto cur_smeta = reinterpret_cast<TwoPLPashaMetadataShared *>(cur_lmeta->migrated_row);
                                auto cur_scc_data = cur_smeta->get_scc_data();

                                cur_smeta->lock();
                                if (is_local_delete == true) {
                                        DCHECK(cur_scc_data->get_flag(TwoPLPashaSharedDataSCC::valid_flag_index) == true);
                                        cur_scc_data->clear_flag(TwoPLPashaSharedDataSCC::valid_flag_index);
                                } else {
                                        DCHECK(cur_scc_data->get_flag(TwoPLPashaSharedDataSCC::valid_flag_index) == false);
                                }
                                migration_policy_meta = cur_scc_data->migration_policy_meta;
                                cur_smeta->unlock();

                                need_remove_from_cxl_index = true;
                                need_move_out_from_migration_tracker = true;

                                cur_lmeta->is_migrated = false;
                        }

                        // local tuple might be invalid here because it can be moved back after being marked as invalid by a remote host
                        cur_lmeta->is_valid = false;
                        cur_lmeta->unlock();

                        // remove the migrated row from the CXL index
                        if (need_remove_from_cxl_index) {
                                bool remove_success = remove_migrated_row(table->tableID(), table->partitionID(), key);
                                DCHECK(remove_success == true);
                        }

                        return true;
                };

                // update next key info, mark both the local and the migrated tuples as invalid, and remove the migrated tuple
                bool success = table->remove_and_process_adjacent_tuples(key, adjacent_tuples_processor);
                DCHECK(success == true);

                return true;
	}

    public:
	static constexpr int LOCK_BIT_OFFSET = 58;
	static constexpr uint64_t LOCK_BIT_MASK = 0x3full;

	static constexpr int READ_LOCK_BIT_OFFSET = 58;
	static constexpr uint64_t READ_LOCK_BIT_MASK = 0x1full;

	static constexpr int WRITE_LOCK_BIT_OFFSET = 63;
	static constexpr uint64_t WRITE_LOCK_BIT_MASK = 0x1ull;

    private:
        std::size_t coordinator_id;

        Context context;

        std::vector<std::vector<CXLTableBase *> > &cxl_tbl_vecs;

        std::atomic<uint64_t> init_finished;
};

extern TwoPLPashaHelper *twopl_pasha_global_helper;

} // namespace star
