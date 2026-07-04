# Android Binder & HwBinder Performance Testing

## 1. Setup Environment
```bash
source build/envsetup.sh
lunch <your_target>
```

---

## 2. Build and Run

### 2.1 Binder Throughput
*   **Source Path:** `system/libhwbinder/vts/performance/Benchmark_binder.cpp`
*   **Android.bp:** 
  ```bp
  cc_benchmark {
      name: "libbinder_benchmark",
      srcs: ["Benchmark_binder.cpp"],
      cflags: [
          "-Wall",
          "-Werror",
      ],
      shared_libs: [
          "libbinder",
          "libutils",
      ],
      static_libs: [
          "android.hardware.tests.libbinder",
      ],
      require_root: true,
  }
  ``` 
*   **Execution:**
    ```bash
    # Build module
    m libbinder_benchmark
    
    # Push and execute
    adb root && adb remount
    adb push \$OUT/data/benchmarktest64/libbinder_benchmark/libbinder_benchmark /data/local/tmp/
    adb shell chmod +x /data/local/tmp/libbinder_benchmark
    adb shell /data/local/tmp/libbinder_benchmark
    ```

### 2.2 Binder Latency
*   **Source Path:** `frameworks/native/libs/binder/tests/schd-dbg.cpp`
*   **Android.bp:** 
  ```bp
  cc_test {
      name: "schd-dbg",
      defaults: ["binder_test_defaults"],
      srcs: ["schd-dbg.cpp"],
      shared_libs: [
          "libbinder",
          "libutils",
          "libbase",
      ],
  }
  ``` 
*   **Execution:**
    ```bash
    # Build module
    m schd-dbg
    m schd-dbg-ctabs (ours)
    
    # Push to device
    adb push \$OUT/data/nativetest64/schd-dbg/schd-dbg /data/local/tmp/
    adb shell chmod +x /data/local/tmp/schd-dbg
    
    # Run with options (e.g., 10000 iterations, 4 process pairs)
    adb shell /data/local/tmp/schd-dbg -i 10000 -p 4
    ```

### 2.3 HwBinder Throughput
*   **Source Path:** `system/libhwbinder/vts/performance/Benchmark.cpp`
*   **Android.bp:** 
  ```bp
  cc_benchmark {
      name: "libhwbinder_benchmark",
      defaults: ["libhwbinder_test_defaults"],
      srcs: ["Benchmark.cpp"],
  }
  ``` 
*   **Execution:**
    ```bash
    # Build module
    m libhwbinder_benchmark
    
    # Push and execute
    adb push \$OUT/data/benchmarktest64/libhwbinder_benchmark/libhwbinder_benchmark /data/local/tmp/
    adb shell chmod +x /data/local/tmp/libhwbinder_benchmark
    adb shell /data/local/tmp/libhwbinder_benchmark
    ```

#### Optional Alternative (Stress Test)
*   **Source Path:** `system/libhwbinder/vts/performance/Benchmark_throughput.cpp`
*   **Android.bp:**
  ```bp
  cc_test {
      name: "hwbinderThroughputTest",
      defaults: ["libhwbinder_test_defaults"],
      srcs: ["Benchmark_throughput.cpp"],
  }
  ```
*   **Execution:**
    ```bash
    # Build alternative tool
    m hwbinderThroughputTest
    
    # Push and execute (cc_test outputs to nativetest64)
    adb push \$OUT/data/nativetest64/hwbinderThroughputTest/hwbinderThroughputTest /data/local/tmp/
    adb shell chmod +x /data/local/tmp/hwbinderThroughputTest
    adb shell /data/local/tmp/hwbinderThroughputTest
    ```

### 2.4 HwBinder Latency
*   **Source Path:** `system/libhwbinder/vts/performance/Latency.cpp`
*   **Android.bp:** 
  ```bp
  cc_test {
      name: "libhwbinder_latency",
      defaults: ["libhwbinder_test_defaults"],
      srcs: [
          "Latency.cpp",
          "PerfTest.cpp",
      ],
  }
  ``` 
*   **Execution:**
    ```bash
    # Build module
    m libhwbinder_latency
    
    # Push and execute
    adb push \$OUT/data/nativetest64/libhwbinder_latency/libhwbinder_latency /data/local/tmp/
    adb shell chmod +x /data/local/tmp/libhwbinder_latency
    adb shell /data/local/tmp/libhwbinder_latency
    ```

---

## Reference
* [1] [AOSP Performance Testing](https://source.android.com/docs/core/tests/vts/performance)
