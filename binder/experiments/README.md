# Android Binder & HwBinder Performance Testing

## Compilation & Execution

### 1. Binder Throughput
*   **Source Path:** `system/libhwbinder/vts/performance/Benchmark_binder.cpp`
*   **Build & Run:**
    ```bash
    # Setup environment
    source build/envsetup.sh && lunch <your_target>
    
    # Build module
    mmm system/libhwbinder/vts/performance/
    
    # Push and execute
    adb root && adb remount
    adb push \$OUT/data/nativetest64/binderBenchmark/binderBenchmark /data/local/tmp/
    adb shell chmod +x /data/local/tmp/binderBenchmark
    adb shell /data/local/tmp/binderBenchmark
    ```

### 2. Binder Latency
*   **Source Path:** `frameworks/native/libs/binder/tests/schd-dbg.cpp`
*   **Build & Run:**
    ```bash
    # Build module
    mmm frameworks/native/libs/binder/tests/
    
    # Push to device
    adb push \$OUT/data/nativetest64/schd-dbg/schd-dbg /data/local/tmp/
    adb shell chmod +x /data/local/tmp/schd-dbg
    
    # Run with options (e.g., 10000 iterations, 4 process pairs)
    adb shell /data/local/tmp/schd-dbg -i 10000 -p 4
    ```

### 3. HwBinder Throughput
*   **Source Path:** `system/libhwbinder/vts/performance/Benchmark.cpp`
*   **Build & Run:**
    ```bash
    # Build module
    mmm system/libhwbinder/vts/performance/
    
    # Push and execute
    adb push \$OUT/data/nativetest64/hwbinderBenchmark/hwbinderBenchmark /data/local/tmp/
    adb shell chmod +x /data/local/tmp/hwbinderBenchmark
    adb shell /data/local/tmp/hwbinderBenchmark
    ```

### 4. HwBinder Latency
*   **Source Path:** `system/libhwbinder/vts/performance/Latency.cpp`
*   **Build & Run:**
    ```bash
    # Build module
    mmm system/libhwbinder/vts/performance/
    
    # Push and execute
    adb push \$OUT/data/nativetest64/hwbinderLatency/hwbinderLatency /data/local/tmp/
    adb shell chmod +x /data/local/tmp/hwbinderLatency
    adb shell /data/local/tmp/hwbinderLatency
    ```

---

## Reference
https://source.android.com/docs/core/tests/vts/performance
