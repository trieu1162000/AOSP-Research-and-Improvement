#!/bin/bash
# ctabs_validation_runner.sh
#
# Runs 3 benchmarks for CTABS paper data collection:
#   1. schd-dbg-ctabs        — latency by topology tier (same-core/same-cluster/cross-cluster)
#   2. binderThroughputTest  — throughput + latency percentiles (with simpleperf)
#   3. libbinder_benchmark   — latency vs payload size sweep (4B–64KB)
#
# Requirements:
#   - adb device connected, rooted (adb root)
#   - Built binaries pushed to device (see --push)
#   - Kernel flashed with the target config (Baseline / CTABS v1 / CTABS v2)
#
# Usage:
#   ./ctabs_validation_runner.sh [--push] [--out DIR] [--label LABEL]
#
# Options:
#   --push           Push pre-built binaries to device before running
#   --out DIR        Output directory on host (default: ./ctabs_results_<label>_<ts>)
#   --label LABEL    Kernel config label: baseline | ctabs_v1 | ctabs_v2 (default: unknown)
#   --gov GOVERNOR   CPU governor: schedutil | performance (default: schedutil)
#   --iter N         Iterations (default: 100000)
#
# Examples:
#   # Single run with schedutil governor
#   ./ctabs_validation_runner.sh --label ctabs_v1 --gov schedutil
#
#   # Run with performance governor
#   ./ctabs_validation_runner.sh --label baseline --gov performance
#
#   # Full sweep across 3 configs (flash kernel manually between runs)
#   for cfg in baseline ctabs_v1 ctabs_v2; do
#     echo "Flash $cfg kernel, then press Enter..."
#     read -r
#     ./ctabs_validation_runner.sh --push --label "$cfg" --gov schedutil
#   done

set -euo pipefail

# ------------------------------------------------------------------ #
# Defaults                                                             #
# ------------------------------------------------------------------ #
PUSH=0
ITER=100000
LABEL="unknown"
GOV="schedutil"
OUT_DIR=""
DEVICE_TMP="/data/local/tmp"

# Binaries on device
BIN_CTABS="$DEVICE_TMP/schd-dbg"
BIN_BINDER_THRU="$DEVICE_TMP/binderThroughputTest"
BIN_BINDER_BENCH="$DEVICE_TMP/libbinder_benchmark"

# Simpleperf event groups — each ≤6 events for precise non-multiplexed counting.
# Three groups cover general perf, cache hierarchy, and memory pipeline.
# binderThroughputTest runs 3×, one per group.
PERF_GROUP_A="cpu-cycles,instructions,cpu-migrations,cache-references,cache-misses,context-switches"
PERF_GROUP_B="armv8_pmuv3/l1d_cache_refill/,armv8_pmuv3/l2d_cache_refill/,armv8_pmuv3/l3d_cache_refill/,armv8_pmuv3/l1d_cache/,armv8_pmuv3/l2d_cache/,armv8_pmuv3/l3d_cache/"
PERF_GROUP_C="armv8_pmuv3/stall_backend/,armv8_pmuv3/stall_frontend/,armv8_pmuv3/mem_access/,armv8_pmuv3/bus_access/,armv8_pmuv3/l1d_tlb_refill/,armv8_pmuv3/l2d_tlb_refill/"

# ------------------------------------------------------------------ #
# Arg parsing                                                          #
# ------------------------------------------------------------------ #
while [[ $# -gt 0 ]]; do
    case "$1" in
        --push)  PUSH=1; shift ;;
        --out)   OUT_DIR="$2"; shift 2 ;;
        --label) LABEL="$2"; shift 2 ;;
        --gov)   GOV="$2"; shift 2 ;;
        --iter)  ITER="$2"; shift 2 ;;
        *) echo "Usage: $0 [--push] [--out DIR] [--label LABEL] [--gov schedutil|performance] [--iter N]"; exit 1 ;;
    esac
done

# Default output directory (uses label after parsing)
TS=$(date +%Y%m%d_%H%M%S)
if [[ -z "$OUT_DIR" ]]; then
    OUT_DIR="./ctabs_results_${LABEL}_${TS}"
fi

mkdir -p "$OUT_DIR"
LOG="$OUT_DIR/runner.log"
exec > >(tee -a "$LOG") 2>&1
echo "=== CTABS Validation Runner: $(date) ==="
echo "LABEL=$LABEL GOV=$GOV ITER=$ITER PUSH=$PUSH OUT=$OUT_DIR"

# ------------------------------------------------------------------ #
# Helper: run adb shell and save output                               #
# ------------------------------------------------------------------ #
run_adb() {
    local label="$1"; shift
    local out_file="$OUT_DIR/${label}.json"
    echo ""
    echo "--- $label ---"
    adb shell "$@" | tee "$out_file" || true
    echo "Saved: $out_file"
}

# ------------------------------------------------------------------ #
# Helper: run command with simpleperf stat                            #
# Usage: run_with_perf <events> <label> <command...>
# ------------------------------------------------------------------ #
run_with_perf() {
    local events="$1"; shift
    local label="$1"; shift
    local out_file="$OUT_DIR/${label}_perf.txt"
    echo "--- Simpleperf: $label ---"
    echo "  Events: $events"
    adb shell simpleperf stat -e "$events" "$@" 2>&1 | tee "$out_file" || true
    echo "Saved: $out_file"
}

# ------------------------------------------------------------------ #
# Push binaries (optional)                                            #
# ------------------------------------------------------------------ #
if [[ $PUSH -eq 1 ]]; then
    echo "=== Pushing binaries ==="
    # Adjust AOSP_BIN to match your build output path
    AOSP_BIN="${AOSP_BIN:-out/target/product/generic/system/bin}"
    for bin in schd-dbg binderThroughputTest libbinder_benchmark; do
        # Search common locations
        src=""
        for dir in "$AOSP_BIN" \
                   "${AOSP_BIN%/system/bin}/data/nativetest/$bin" \
                   "${AOSP_BIN%/system/bin}/data/benchmarktest/$bin"; do
            if [[ -f "$dir/$bin" ]]; then
                src="$dir/$bin"
                break
            fi
        done
        if [[ -n "$src" ]]; then
            adb push "$src" "$DEVICE_TMP/"
            adb shell "chmod 755 $DEVICE_TMP/$bin"
            echo "  Pushed: $bin"
        else
            echo "  WARNING: $bin not found, skip"
        fi
    done
fi

# ------------------------------------------------------------------ #
# Ensure root access + set CPU governor                               #
# ------------------------------------------------------------------ #
echo "=== Setting CPU governor: $GOV ==="
adb root || true
adb shell "for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do \
    echo $GOV > \$f 2>/dev/null; done" || true

# Verify governor + check frequencies
echo "=== CPU governor verification ==="
GOV_FILE="$OUT_DIR/cpu_governor.txt"
adb shell "echo '--- Governor ---' && \
    cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort -u && \
    echo '' && \
    echo '--- Frequencies ---' && \
    for cpu in \$(ls /sys/devices/system/cpu/ | grep '^cpu[0-9]'); do \
        cur=\$(cat /sys/devices/system/cpu/\${cpu}/cpufreq/scaling_cur_freq 2>/dev/null || echo '?'); \
        min=\$(cat /sys/devices/system/cpu/\${cpu}/cpufreq/scaling_min_freq 2>/dev/null || echo '?'); \
        max=\$(cat /sys/devices/system/cpu/\${cpu}/cpufreq/scaling_max_freq 2>/dev/null || echo '?'); \
        gov=\$(cat /sys/devices/system/cpu/\${cpu}/cpufreq/scaling_governor 2>/dev/null || echo '?'); \
        echo \"\${cpu}: \${cur} kHz (gov=\${gov}, min=\${min}, max=\${max})\"; \
    done" | tee "$GOV_FILE"

# ------------------------------------------------------------------ #
# Check simpleperf available events                                   #
# ------------------------------------------------------------------ #
echo "=== Simpleperf available events ==="
PERF_LIST_FILE="$OUT_DIR/simpleperf_list.txt"
adb shell simpleperf list 2>/dev/null | head -80 | tee "$PERF_LIST_FILE" || true

# ------------------------------------------------------------------ #
# Discover CPU topology                                               #
# ------------------------------------------------------------------ #
echo "=== CPU Topology ==="
TOPO_FILE="$OUT_DIR/topology.txt"
adb shell "for cpu in \$(ls /sys/devices/system/cpu/ | grep '^cpu[0-9]'); do
    id=\${cpu#cpu}
    core=\$(cat /sys/devices/system/cpu/\${cpu}/topology/core_id 2>/dev/null || echo '?')
    cluster=\$(cat /sys/devices/system/cpu/\${cpu}/topology/cluster_id 2>/dev/null || echo '?')
    echo \"cpu\${id}: core=\${core} cluster=\${cluster}\"
done" | tee "$TOPO_FILE"

# ------------------------------------------------------------------ #
# Benchmark 1: schd-dbg-ctabs — latency by topology tier              #
# ------------------------------------------------------------------ #
echo ""
echo "================================================================"
echo "[1/3] schd-dbg-ctabs — latency by topology tier"
echo "      concurrency=1, ${ITER} iterations, 16B payload"
echo "================================================================"
run_adb "01_schd_dbg_tiered" \
    "$BIN_CTABS -i $ITER -pair 1 -payload 16"

# ------------------------------------------------------------------ #
# Benchmark 2: binderThroughputTest — throughput + latency             #
#             (with simpleperf hardware counters, 3 event groups)     #
# ------------------------------------------------------------------ #
echo ""
echo "================================================================"
echo "[2/3] binderThroughputTest — throughput + latency percentiles"
echo "      8 workers × ${ITER} iterations, 16B payload"
echo "      3 simpleperf groups (A: general, B: cache, C: mem pipeline)"
echo "================================================================"
run_with_perf "$PERF_GROUP_A" "02a_binder_throughput" \
    "$BIN_BINDER_THRU -i $ITER -s 16"
run_with_perf "$PERF_GROUP_B" "02b_binder_throughput" \
    "$BIN_BINDER_THRU -i $ITER -s 16"
run_with_perf "$PERF_GROUP_C" "02c_binder_throughput" \
    "$BIN_BINDER_THRU -i $ITER -s 16"

# ------------------------------------------------------------------ #
# Benchmark 3: libbinder_benchmark — payload sweep                     #
# ------------------------------------------------------------------ #
echo ""
echo "================================================================"
echo "[3/3] libbinder_benchmark — latency vs payload size"
echo "      4B / 64B / 512B / 4KB / 16KB / 64KB"
echo "================================================================"
run_adb "03_libbinder_payload_sweep" \
    "$BIN_BINDER_BENCH"

# ------------------------------------------------------------------ #
# Backup: read CTABS debugfs counters if available                   #
# ------------------------------------------------------------------ #
echo ""
echo "=== CTABS debugfs counters ==="
adb shell "cat /sys/kernel/debug/binder/ctabs/stats 2>/dev/null || \
           echo 'debugfs not available (baseline kernel or module not loaded)'" \
    | tee "$OUT_DIR/ctabs_stats.txt"

# ------------------------------------------------------------------ #
# Collect kernel messages                                             #
# ------------------------------------------------------------------ #
echo ""
echo "=== Kernel messages ==="
adb shell "dmesg | tail -100" > "$OUT_DIR/dmesg.txt" 2>/dev/null || true

# ------------------------------------------------------------------ #
# Summary                                                             #
# ------------------------------------------------------------------ #
echo ""
echo "================================================================"
echo "=== DONE: $LABEL ==="
echo "=== Results in: $OUT_DIR ==="
echo "================================================================"
ls -lh "$OUT_DIR"
echo ""
echo "Files:"
for f in "$OUT_DIR"/*; do
    echo "  $(basename "$f")"
done
