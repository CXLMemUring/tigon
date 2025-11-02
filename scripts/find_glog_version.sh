#!/bin/bash
# Find the glog version used by the VM binaries

echo "========================================="
echo "Finding glog version in VM binaries"
echo "========================================="
echo

echo "[1] Checking libglog in Node 0..."
ssh root@192.168.100.10 "ls -la /lib/x86_64-linux-gnu/libglog* 2>/dev/null"
echo

echo "[2] Checking for version strings..."
ssh root@192.168.100.10 "strings /lib/x86_64-linux-gnu/libglog.so.0 | grep -E 'glog|^[0-9]+\.[0-9]+\.[0-9]+' | head -30"
echo

echo "[3] Checking package info (if available)..."
ssh root@192.168.100.10 "dpkg -l 2>/dev/null | grep glog || echo 'dpkg not available or no glog package'"
echo

echo "[4] Checking what bench_tpcc binary needs..."
ssh root@192.168.100.10 "ldd /root/pasha/bench_tpcc | grep glog"
echo

echo "[5] Checking library metadata..."
ssh root@192.168.100.10 "readelf -d /lib/x86_64-linux-gnu/libglog.so.0 2>/dev/null | grep SONAME"
echo

echo "========================================="
echo "Recommendations:"
echo "========================================="
echo "1. If version found above, install matching libglog-dev"
echo "2. Or copy the entire /lib/x86_64-linux-gnu/libglog* to host"
echo "3. Or use Docker with matching OS version"
echo
