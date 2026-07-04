#!/bin/bash
# ctabs_validation_runner.sh
#
# Runs all 7 standard VTS binder/hwbinder performance test binaries plus the
# CTABS-specific schd-dbg-ctabs variant under several CPU-affinity scenarios:
#   1. schd-dbg              — binder latency baseline
#   2-4. schd-dbg-ctabs      — CTABS binder latency (organic/same-cluster/cross-cluster)
#   5. libhwbinder_latency   — hwbinder latency (+ same/cross-cluster variants)
#   6. binderThroughputTest + libbinder_benchmark   — binder throughput (multi-proc + payload sweep)
#   7. hwbinderThroughputTest + libhwbinder_benchmark — hwbinder throughput (multi-proc + payload sweep)
# Collects JSON results, optional perfetto traces, and optional simpleperf
# cache-miss stats.
#
# Requirements:
#   - adb device connected
#   - Built binaries pushed to device (see --push section)
#   - Root (adb root) recommended for simpleperf + cpufreq + affinity
#
# Usage:
#   ./ctabs_validation_runner.sh [--push] [--perf] [--trace] [--out DIR]
#
# Options:
#   --push          Push pre-built binaries to device before running
#   --perf          Collect simpleperf cache-miss stats per scenario
#   --trace         Start perfetto tracing during CTABS scenarios
#   --out DIR       Output directory on host (default: ./ctabs_results_<ts>)
#   --iter N        Iterations per pair (default: 10000)
#   --pair N        Number of process pairs (default: 4)
#
# Examples:
#   # Basic validation (no simpleperf, no trace)
#   ./ctabs_validation_runner.sh --out /tmp/ctabs_out
#
#   # Full validation with simpleperf and perfetto trace
#   ./ctabs_validation_runner.sh --push --perf --trace --iter 20000 --pair 4

set -euo pipefail

# ------------------------------------------------------------------ #
# Defaults                                                             #
# ------------------------------------------------------------------ #
PUSH=0
PERF=0
TRACE=0
ITER=10000
PAIR=4
OUT_DIR="./ctabs_results_$(date +%s)"
DEVICE_TMP="/data/local/tmp"
PERFETTO_CFG="$DEVICE_TMP/perfetto-config.txt"

# Binaries on device
BIN_CTABS="$DEVICE_TMP/schd-dbg-ctabs"
BIN_SCHD_DBG="$DEVICE_TMP/schd-dbg"
BIN_HW_LAT="$DEVICE_TMP/libhwbinder_latency"
BIN_BINDER_THRU="$DEVICE_TMP/binderThroughputTest"       # frameworks/native binder throughput (multi-process)
BIN_BINDER_BENCH="$DEVICE_TMP/libbinder_benchmark"        # system/libhwbinder/vts Benchmark_binder.cpp (payload sweep)
BIN_HW_THRU="$DEVICE_TMP/hwbinderThroughputTest"          # Benchmark_throughput.cpp (multi-process contention)
BIN_HW_BENCH="$DEVICE_TMP/libhwbinder_benchmark"          # Benchmark.cpp (google-benchmark payload sweep)

# ------------------------------------------------------------------ #
# Arg parsing                                                          #
# ------------------------------------------------------------------ #
while [[ $# -gt 0 ]]; do
    case "$1" in
        --push)  PUSH=1; shift ;;
        --perf)  PERF=1; shift ;;
        --trace) TRACE=1; shift ;;
        --out)   OUT_DIR="$2"; shift 2 ;;
        --iter)  ITER="$2"; shift 2 ;;
        --pair)  PAIR="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

mkdir -p "$OUT_DIR"
LOG="$OUT_DIR/runner.log"
exec > >(tee -a "$LOG") 2>&1
echo "=== CTABS Validation Runner: $(date) ==="
echo "ITER=$ITER PAIR=$PAIR PUSH=$PUSH PERF=$PERF TRACE=$TRACE OUT=$OUT_DIR"

# ------------------------------------------------------------------ #
# Helper: run adb shell and save output                               #
# ------------------------------------------------------------------ #
run_adb() {
    local label="$1"; shift
    local out_file="$OUT_DIR/${label}.json"
    echo ""
    echo "--- Running: $label ---"
    adb shell "$@" | tee "$out_file" || true
    echo "Saved: $out_file"
}

# ------------------------------------------------------------------ #
# Helper: simpleperf cache-miss stats                                 #
# ------------------------------------------------------------------ #
run_with_perf() {
    local label="$1"; shift
    local out_file="$OUT_DIR/${label}_perf.txt"
    echo "--- Simpleperf: $label ---"
    # Run simpleperf stat wrapping the command; collect cache metrics
    adb shell simpleperf stat \
        -e L1-dcache-load-misses,L1-dcache-loads,LLC-load-misses,LLC-loads,cache-misses,context-switches \
        "$@" 2>&1 | tee "$out_file" || true
    echo "Saved: $out_file"
}

# ------------------------------------------------------------------ #
# Helper: perfetto trace for one scenario                             #
# ------------------------------------------------------------------ #
start_perfetto() {
    local label="$1"
    adb shell "perfetto -c $PERFETTO_CFG -o $DEVICE_TMP/trace_${label}.pb &"
    sleep 1
    echo "Perfetto started for $label"
}

stop_perfetto() {
    local label="$1"
    adb shell "kill -INT \$(pidof perfetto) 2>/dev/null || true"
    sleep 1
    adb pull "$DEVICE_TMP/trace_${label}.pb" "$OUT_DIR/trace_${label}.pb" 2>/dev/null || true
    echo "Perfetto trace: $OUT_DIR/trace_${label}.pb"
}

# ------------------------------------------------------------------ #
# Push binaries (optional)                                            #
# ------------------------------------------------------------------ #
if [[ $PUSH -eq 1 ]]; then
    echo "=== Pushing binaries ==="
    # Adjust paths to match your AOSP out/target/product/<device>/system/bin/
    # Note: cc_test modules (schd-dbg*, libhwbinder_latency, hwbinderThroughputTest)
    # may instead install under out/target/product/<device>/data/nativetest/<module>/<module>
    # cc_benchmark modules (libbinder_benchmark, libhwbinder_benchmark) follow the same pattern.
    # Adjust AOSP_BIN or use `find out -name '<module>'` if binaries are not found here.
    AOSP_BIN="${AOSP_BIN:-out/target/product/generic/system/bin}"
    for bin in schd-dbg-ctabs schd-dbg libhwbinder_latency \
               binderThroughputTest libbinder_benchmark \
               hwbinderThroughputTest libhwbinder_benchmark; do
        src="$AOSP_BIN/$bin"
        if [[ -f "$src" ]]; then
            adb push "$src" "$DEVICE_TMP/"
            adb shell "chmod 755 $DEVICE_TMP/$bin"
            echo "Pushed: $bin"
        else
            echo "WARNING: $src not found, skip"
        fi
    done
fi

# Push perfetto config if trace mode
if [[ $TRACE -eq 1 ]]; then
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    if [[ -f "$SCRIPT_DIR/perfetto-config.txt" ]]; then
        adb push "$SCRIPT_DIR/perfetto-config.txt" "$PERFETTO_CFG"
    else
        echo "WARNING: perfetto-config.txt not found next to script, trace may fail"
    fi
fi

# ------------------------------------------------------------------ #
# Ensure CPU governor = performance (requires root)                   #
# ------------------------------------------------------------------ #
echo "=== Setting CPU governor to performance ==="
adb root || true
adb shell "for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > \$f 2>/dev/null; done" || true

# ------------------------------------------------------------------ #
# Discover CPU topology on device                                     #
# ------------------------------------------------------------------ #
echo "=== CPU Topology ==="
TOPO_FILE="$OUT_DIR/topology.txt"
adb shell "for cpu in \$(ls /sys/devices/system/cpu/ | grep '^cpu[0-9]'); do
    id=\${cpu#cpu}
    core=\$(cat /sys/devices/system/cpu/\${cpu}/topology/core_id 2>/dev/null || echo '?')
    cluster=\$(cat /sys/devices/system/cpu/\${cpu}/topology/cluster_id 2>/dev/null || echo '?')
    maxfreq=\$(cat /sys/devices/system/cpu/\${cpu}/cpufreq/cpuinfo_max_freq 2>/dev/null || echo '?')
    echo \"cpu\${id}: core=\${core} cluster=\${cluster} max_freq=\${maxfreq}\"
done" | tee "$TOPO_FILE"

# ------------------------------------------------------------------ #
# Read topology to build cluster masks                                #
# ------------------------------------------------------------------ #
# Auto-detect cluster masks from sysfs (heuristic based on cluster_id)
echo "=== Computing cluster CPU masks ==="
CLUSTER_MASKS=$(adb shell python3 -c "
import os, sys
cpus = {}
for cpu in sorted(os.listdir('/sys/devices/system/cpu')):
    if not cpu.startswith('cpu') or not cpu[3:].isdigit():
        continue
    n = int(cpu[3:])
    try:
        with open(f'/sys/devices/system/cpu/{cpu}/topology/cluster_id') as f:
            c = int(f.read().strip())
    except:
        c = 0
    cpus.setdefault(c, []).append(n)
for cid, cpulist in sorted(cpus.items()):
    mask = sum(1 << c for c in cpulist)
    print(f'cluster{cid}=0x{mask:x}')
" 2>/dev/null) || CLUSTER_MASKS=""
echo "Cluster masks: $CLUSTER_MASKS"
echo "$CLUSTER_MASKS" > "$OUT_DIR/cluster_masks.txt"

# Parse up to 3 clusters
MASK_C0=$(echo "$CLUSTER_MASKS" | grep 'cluster0=' | cut -d= -f2 || echo "")
MASK_C1=$(echo "$CLUSTER_MASKS" | grep 'cluster1=' | cut -d= -f2 || echo "")
MASK_C2=$(echo "$CLUSTER_MASKS" | grep 'cluster2=' | cut -d= -f2 || echo "")

# ------------------------------------------------------------------ #
# Section 1 — Binder latency: schd-dbg (baseline, standard VTS)      #
# ------------------------------------------------------------------ #
echo ""
echo "=== [1/7] Binder latency — baseline schd-dbg (standard VTS) ==="
run_adb "1_binder_latency_baseline" \
    "$BIN_SCHD_DBG -i $ITER -pair $PAIR" || true

# ------------------------------------------------------------------ #
# Section 2 — Binder latency: schd-dbg-ctabs (no pin, organic)       #
# ------------------------------------------------------------------ #
echo ""
echo "=== [2/7] Binder latency — CTABS organic (no affinity pin) ==="
[[ $TRACE -eq 1 ]] && start_perfetto "ctabs_organic"
run_adb "2_ctabs_binder_latency_organic" \
    "$BIN_CTABS -i $ITER -pair $PAIR -csv $DEVICE_TMP/ctabs_organic" || true
[[ $TRACE -eq 1 ]] && stop_perfetto "ctabs_organic"
[[ $PERF -eq 1 ]] && run_with_perf "2_ctabs_organic" \
    "$BIN_CTABS -i $ITER -pair $PAIR" || true

# Pull CSVs
adb shell "ls $DEVICE_TMP/ctabs_organic_pair*.csv 2>/dev/null" | while read f; do
    adb pull "$f" "$OUT_DIR/" 2>/dev/null || true
done

# ------------------------------------------------------------------ #
# Section 3 — CTABS same-cluster (servers & clients on same cluster)  #
# ------------------------------------------------------------------ #
if [[ -n "$MASK_C0" ]]; then
    echo ""
    echo "=== [3/7] CTABS same-cluster: all on cluster0 ($MASK_C0) ==="
    [[ $TRACE -eq 1 ]] && start_perfetto "ctabs_same_cluster"
    run_adb "3_ctabs_same_cluster" \
        "$BIN_CTABS -i $ITER -pair $PAIR -pin $MASK_C0 -csv $DEVICE_TMP/ctabs_same" || true
    [[ $TRACE -eq 1 ]] && stop_perfetto "ctabs_same_cluster"
    [[ $PERF -eq 1 ]] && run_with_perf "3_ctabs_same" \
        "$BIN_CTABS -i $ITER -pair $PAIR -pin $MASK_C0" || true
    adb shell "ls $DEVICE_TMP/ctabs_same_pair*.csv 2>/dev/null" | while read f; do
        adb pull "$f" "$OUT_DIR/" 2>/dev/null || true
    done
fi

# ------------------------------------------------------------------ #
# Section 4 — CTABS cross-cluster (servers on C0, clients on C1)     #
# ------------------------------------------------------------------ #
if [[ -n "$MASK_C0" && -n "$MASK_C1" ]]; then
    echo ""
    echo "=== [4/7] CTABS cross-cluster: servers=$MASK_C0 clients=$MASK_C1 ==="
    [[ $TRACE -eq 1 ]] && start_perfetto "ctabs_cross_cluster"
    run_adb "4_ctabs_cross_cluster" \
        "$BIN_CTABS -i $ITER -pair $PAIR -pin-servers $MASK_C0 -pin-clients $MASK_C1 \
         -csv $DEVICE_TMP/ctabs_cross" || true
    [[ $TRACE -eq 1 ]] && stop_perfetto "ctabs_cross_cluster"
    [[ $PERF -eq 1 ]] && run_with_perf "4_ctabs_cross" \
        "$BIN_CTABS -i $ITER -pair $PAIR -pin-servers $MASK_C0 -pin-clients $MASK_C1" || true
    adb shell "ls $DEVICE_TMP/ctabs_cross_pair*.csv 2>/dev/null" | while read f; do
        adb pull "$f" "$OUT_DIR/" 2>/dev/null || true
    done
fi

# ------------------------------------------------------------------ #
# Section 5 — HW-binder latency (standard VTS, with topology output) #
# ------------------------------------------------------------------ #
echo ""
echo "=== [5/7] HW-binder latency — standard VTS ==="
run_adb "5_hwbinder_latency_baseline" \
    "$BIN_HW_LAT -i $ITER -pair $PAIR" || true

# Same-cluster variant if topology available
if [[ -n "$MASK_C0" ]]; then
    echo ""
    echo "    [5b] HW-binder latency — same-cluster ($MASK_C0) ==="
    run_adb "5b_hwbinder_latency_same_cluster" \
        "$BIN_HW_LAT -i $ITER -pair $PAIR -pin $MASK_C0" || true
fi
if [[ -n "$MASK_C0" && -n "$MASK_C1" ]]; then
    echo ""
    echo "    [5c] HW-binder latency — cross-cluster servers=$MASK_C0 clients=$MASK_C1 ==="
    run_adb "5c_hwbinder_latency_cross_cluster" \
        "$BIN_HW_LAT -i $ITER -pair $PAIR -pin-servers $MASK_C0 -pin-clients $MASK_C1" || true
fi

# ------------------------------------------------------------------ #
# Section 6 — Binder throughput (2 variants, standard VTS)            #
# ------------------------------------------------------------------ #
echo ""
echo "=== [6/7] Binder throughput tests ==="
run_adb "6a_binder_throughput_multiproc" \
    "$BIN_BINDER_THRU -i $ITER" || true
run_adb "6b_binder_throughput_payload_sweep" \
    "$BIN_BINDER_BENCH" || true

# ------------------------------------------------------------------ #
# Section 7 — HW-binder throughput (2 variants, standard VTS)         #
# ------------------------------------------------------------------ #
echo ""
echo "=== [7/7] HW-binder throughput tests ==="
run_adb "7a_hwbinder_throughput_multiproc" \
    "$BIN_HW_THRU -i $ITER" || true
run_adb "7b_hwbinder_throughput_payload_sweep" \
    "$BIN_HW_BENCH" || true

# ------------------------------------------------------------------ #
# Collect logs                                                         #
# ------------------------------------------------------------------ #
echo ""
echo "=== Collecting dmesg + logcat ==="
adb shell "dmesg | tail -500" > "$OUT_DIR/dmesg.txt" || true
adb logcat -d -b all > "$OUT_DIR/logcat.txt" 2>/dev/null || true

# ------------------------------------------------------------------ #
# Summary                                                              #
# ------------------------------------------------------------------ #
echo ""
echo "=== DONE ==="
echo "Results in: $OUT_DIR"
ls -lh "$OUT_DIR"

echo ""
echo "=== Quick latency summary (avg_ms from JSON) ==="
for f in "$OUT_DIR"/*.json; do
    label=$(basename "$f" .json)
    avg=$(grep -o '"avg":[0-9.]*' "$f" 2>/dev/null | head -1 | cut -d: -f2 || echo "N/A")
    echo "  $label => avg_ms=$avg"
done

echo ""
echo "=== Next steps ==="
echo "  1. Compare baseline vs CTABS avg/p99 for same-cluster and cross-cluster scenarios."
echo "  2. If PERF was enabled, check *_perf.txt for L1/LLC miss counts."
echo "  3. If TRACE was enabled, open trace*.pb in Perfetto UI (ui.perfetto.dev)"
echo "     SQL: SELECT ts, name, cpu FROM ftrace WHERE name LIKE 'binder%' ORDER BY ts LIMIT 200;"
echo "  4. Run analyze_ctabs.py (if available) on CSV files for per-tier p50/p90/p99 plots."
