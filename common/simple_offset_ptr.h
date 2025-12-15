//
// Simple offset_ptr implementation without AVX instructions
// Drop-in replacement for boost::interprocess::offset_ptr
//

#pragma once

#include <cstdint>
#include <cstddef>

namespace star {

// Simple offset pointer that stores offset from itself to the pointed object
// This avoids boost::interprocess which may use AVX instructions
template<typename T>
class simple_offset_ptr {
public:
    using element_type = T;
    using pointer = T*;
    using reference = T&;

    // Constructors
    simple_offset_ptr() noexcept : m_offset(1) {}  // 1 means null (offset 0 is valid)

    simple_offset_ptr(std::nullptr_t) noexcept : m_offset(1) {}

    simple_offset_ptr(T* ptr) noexcept {
        set(ptr);
    }

    simple_offset_ptr(const simple_offset_ptr& other) noexcept {
        set(other.get());
    }

    template<typename U>
    simple_offset_ptr(const simple_offset_ptr<U>& other) noexcept {
        set(static_cast<T*>(other.get()));
    }

    // Assignment
    simple_offset_ptr& operator=(T* ptr) noexcept {
        set(ptr);
        return *this;
    }

    simple_offset_ptr& operator=(const simple_offset_ptr& other) noexcept {
        set(other.get());
        return *this;
    }

    simple_offset_ptr& operator=(std::nullptr_t) noexcept {
        m_offset = 1;
        return *this;
    }

    // Accessors
    T* get() const noexcept {
        if (m_offset == 1) return nullptr;
        return reinterpret_cast<T*>(reinterpret_cast<uintptr_t>(this) + m_offset);
    }

    T* operator->() const noexcept {
        return get();
    }

    T& operator*() const noexcept {
        return *get();
    }

    // Conversion to bool
    explicit operator bool() const noexcept {
        return m_offset != 1;
    }

    // Comparison
    bool operator==(const simple_offset_ptr& other) const noexcept {
        return get() == other.get();
    }

    bool operator!=(const simple_offset_ptr& other) const noexcept {
        return get() != other.get();
    }

    bool operator==(std::nullptr_t) const noexcept {
        return m_offset == 1;
    }

    bool operator!=(std::nullptr_t) const noexcept {
        return m_offset != 1;
    }

    // Array access
    T& operator[](std::size_t idx) const noexcept {
        return get()[idx];
    }

    // Pointer arithmetic
    simple_offset_ptr& operator++() noexcept {
        T* ptr = get();
        if (ptr) set(ptr + 1);
        return *this;
    }

    simple_offset_ptr operator++(int) noexcept {
        simple_offset_ptr tmp(*this);
        ++(*this);
        return tmp;
    }

    simple_offset_ptr& operator--() noexcept {
        T* ptr = get();
        if (ptr) set(ptr - 1);
        return *this;
    }

    simple_offset_ptr operator--(int) noexcept {
        simple_offset_ptr tmp(*this);
        --(*this);
        return tmp;
    }

    simple_offset_ptr operator+(std::ptrdiff_t n) const noexcept {
        simple_offset_ptr tmp;
        T* ptr = get();
        if (ptr) tmp.set(ptr + n);
        return tmp;
    }

    simple_offset_ptr operator-(std::ptrdiff_t n) const noexcept {
        simple_offset_ptr tmp;
        T* ptr = get();
        if (ptr) tmp.set(ptr - n);
        return tmp;
    }

private:
    void set(T* ptr) noexcept {
        if (ptr == nullptr) {
            m_offset = 1;
        } else {
            m_offset = reinterpret_cast<uintptr_t>(ptr) - reinterpret_cast<uintptr_t>(this);
        }
    }

    // Store offset as signed to handle pointers before and after this
    std::intptr_t m_offset;
};

} // namespace star
