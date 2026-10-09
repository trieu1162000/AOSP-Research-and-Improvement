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
DELAY=3
QUICK=0
OUT_DIR=""
DEVICE_TMP="/data/local/tmp"
MODE=""
SYNC_ONLY=""
HANDOFF=""
GUARD=""
REPLY_POLICY=""
SIS_CURRENT=""
MUSCHED_LITE=""
HANDOFF_EXTRAS=""
HANDOFF_DEFER=""
DEFER_WINDOW_US=""
NODRAG=""
ELECT_RAND=""
ELECT_COST=""
AGE_MS=""
SCORE_LOCAL=""
SCORE_CLUSTER=""
SCORE_STEP=""
SCORE_DECAY=""
CLUSTER_LOC=""
CTABS_DBG="/sys/kernel/debug/binder/ctabs"
SCHED_DBG="/sys/kernel/debug/sched"

# Binaries on device
BIN_CTABS="$DEVICE_TMP/schd-dbg"
BIN_BINDER_THRU="$DEVICE_TMP/binderThroughputTest"
BIN_BINDER_BENCH="$DEVICE_TMP/libbinder_benchmark"

# binderThroughputTest histogram sizing.  Its default is 128 buckets over
# 50 ms = 390 us per bucket, which is 3-8x coarser than binder latency, so
# every percentile lands in bucket 0 and prints the same number
# (0.1953125 = 0.5 * 50ms/128).  -m N is the expected max latency in
# microseconds; 1000 us gives 7.8 us buckets and still covers p99.
#
# ALWAYS passed.  Without it every percentile lands in bucket 0 and prints the
# same number (0.1953125 = 0.5 * 50ms/128).  1000 us -> 7.8 us buckets and
# still covers p99.  Raise the value if the tool warns that transactions
# exceeded it.
BTT_MAX_US="${BTT_MAX_US:-1000}"
BTT_M="-m $BTT_MAX_US"

# Simpleperf event groups — each ≤2 events to avoid HW counter multiplexing.
# Generic events like cache-references/cache-misses expand to multiple raw PMU
# events on ARM (one per cache level), exceeding available counters.
#
# A-trio: split the original 6-event group into 3 pairs, mixing HW + SW so
#         each group stays ≤2 HW events when expanded.
# B: cache hierarchy (raw PMU events — 1-to-1, no expansion)
# C: memory pipeline (raw PMU events)
PERF_GROUP_A1="cpu-cycles,instructions"
PERF_GROUP_A2="cache-references,cpu-migrations"
PERF_GROUP_A3="cache-misses,context-switches"
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
        --delay) DELAY="$2"; shift 2 ;;
        --iter)  ITER="$2"; shift 2 ;;
        --mode)  MODE="$2"; shift 2 ;;
        --sync-only) SYNC_ONLY="$2"; shift 2 ;;
        --handoff) HANDOFF="$2"; shift 2 ;;
        --guard) GUARD="$2"; shift 2 ;;
        --reply-policy) REPLY_POLICY="$2"; shift 2 ;;
        --sis-current) SIS_CURRENT="$2"; shift 2 ;;
        --musched-lite) MUSCHED_LITE="$2"; shift 2 ;;
        --handoff-extras) HANDOFF_EXTRAS="$2"; shift 2 ;;
        --handoff-defer) HANDOFF_DEFER="$2"; shift 2 ;;
        --defer-window-us) DEFER_WINDOW_US="$2"; shift 2 ;;
        --nodrag) NODRAG="$2"; shift 2 ;;
        --elect-rand) ELECT_RAND="$2"; shift 2 ;;
        --elect-cost) ELECT_COST="$2"; shift 2 ;;
        --age-ms) AGE_MS="$2"; shift 2 ;;
        --score-local) SCORE_LOCAL="$2"; shift 2 ;;
        --score-cluster) SCORE_CLUSTER="$2"; shift 2 ;;
        --score-step) SCORE_STEP="$2"; shift 2 ;;
        --score-decay) SCORE_DECAY="$2"; shift 2 ;;
        --cluster-locality) CLUSTER_LOC="$2"; shift 2 ;;
        --quick) QUICK=1; shift ;;
        *) echo "Usage: $0 [--push] [--out DIR] [--label LABEL] [--gov schedutil|performance] [--delay N] [--iter N] [--mode 0..14] [--sync-only 0|1] [--handoff 0..3] [--guard 1|5|9|11|13|15] [--reply-policy 0|1|2] [--sis-current 0|1] [--musched-lite 0|1] [--handoff-extras N] [--handoff-defer 0|1] [--defer-window-us N] [--age-ms N] [--score-local N] [--score-cluster N] [--score-step N] [--score-decay N] [--cluster-locality 0|1] [--nodrag 0|1] [--elect-rand 0|1] [--elect-cost 0|1] [--quick]"; exit 1 ;;
    esac
done

# Default output directory (uses label + mode after parsing)
TS=$(date +%Y%m%d_%H%M%S)
if [[ -z "$OUT_DIR" ]]; then
    MODE_TAG="${MODE:-nomode}"
    OUT_DIR="./ctabs_results_${LABEL}_m${MODE_TAG}_${TS}"
fi

mkdir -p "$OUT_DIR"
LOG="$OUT_DIR/runner.log"
exec > >(tee -a "$LOG") 2>&1
echo "=== CTABS Validation Runner: $(date) ==="
echo "LABEL=$LABEL GOV=$GOV ITER=$ITER DELAY=$DELAY PUSH=$PUSH OUT=$OUT_DIR MODE=${MODE:-unchanged} SYNC_ONLY=${SYNC_ONLY:-unchanged} HANDOFF=${HANDOFF:-unchanged} GUARD=${GUARD:-default} REPLY_POLICY=${REPLY_POLICY:-default} SIS_CURRENT=${SIS_CURRENT:-default} MUSCHED_LITE=${MUSCHED_LITE:-default} HANDOFF_EXTRAS=${HANDOFF_EXTRAS:-default} HANDOFF_DEFER=${HANDOFF_DEFER:-default} DEFER_WINDOW_US=${DEFER_WINDOW_US:-default} AGE_MS=${AGE_MS:-default} SCORE_LOCAL=${SCORE_LOCAL:-default} SCORE_CLUSTER=${SCORE_CLUSTER:-default} SCORE_STEP=${SCORE_STEP:-default} SCORE_DECAY=${SCORE_DECAY:-default} CLUSTER_LOC=${CLUSTER_LOC:-unchanged} NODRAG=${NODRAG:-default} ELECT_RAND=${ELECT_RAND:-default} ELECT_COST=${ELECT_COST:-default}"

# ------------------------------------------------------------------ #
# Helper: cooldown — simple delay to drain pending Binder txns        #
# ------------------------------------------------------------------ #
cooldown() {
    echo "  [cooldown ${DELAY}s] ..."
    sleep "$DELAY"
}

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
# Record scheduler EAS state (affects whether CPU hints are honoured) #
# ------------------------------------------------------------------ #
echo "=== Scheduler EAS state ==="
adb shell "cat /proc/sys/kernel/sched_energy_aware 2>/dev/null || echo NA" \
    | tee "$OUT_DIR/sched_energy_aware.txt" || true

# ------------------------------------------------------------------ #
# CLASP: cluster-locality scheduler knob (optional set + record)      #
# ------------------------------------------------------------------ #
if [[ -n "$CLUSTER_LOC" ]]; then
    adb shell "echo $CLUSTER_LOC > /proc/sys/kernel/sched_cluster_locality" || true
fi
echo "=== sched_cluster_locality ==="
adb shell "cat /proc/sys/kernel/sched_cluster_locality 2>/dev/null || echo NA" \
    | tee "$OUT_DIR/sched_cluster_locality.txt" || true

# ------------------------------------------------------------------ #
# Set CTABS runtime knobs (mode / sync_only) if requested             #
# ------------------------------------------------------------------ #
if [[ -n "$MODE" || -n "$SYNC_ONLY" || -n "$HANDOFF" || -n "$GUARD" || -n "$REPLY_POLICY" || -n "$SIS_CURRENT" || -n "$MUSCHED_LITE" || -n "$HANDOFF_EXTRAS" || -n "$HANDOFF_DEFER" || -n "$DEFER_WINDOW_US" || -n "$AGE_MS" || -n "$SCORE_LOCAL" || -n "$SCORE_CLUSTER" || -n "$SCORE_STEP" || -n "$SCORE_DECAY" || -n "$NODRAG" || -n "$ELECT_RAND" || -n "$ELECT_COST" ]]; then
    echo "=== Setting CTABS knobs ==="
    echo "  requested: mode=${MODE:-unchanged} sync_only=${SYNC_ONLY:-unchanged} handoff=${HANDOFF:-unchanged} guard=${GUARD:-default} reply_policy=${REPLY_POLICY:-default} sis_current=${SIS_CURRENT:-default} musched_lite=${MUSCHED_LITE:-default} handoff_extras=${HANDOFF_EXTRAS:-default} handoff_defer=${HANDOFF_DEFER:-default} defer_window_us=${DEFER_WINDOW_US:-default} age_ms=${AGE_MS:-default} score_local=${SCORE_LOCAL:-default} score_cluster=${SCORE_CLUSTER:-default} score_step=${SCORE_STEP:-default} score_decay=${SCORE_DECAY:-default} nodrag=${NODRAG:-default} elect_rand=${ELECT_RAND:-default} elect_cost=${ELECT_COST:-default}"

    ctabs_ok() {
        [[ "$(adb shell "test -d $CTABS_DBG && echo yes" 2>/dev/null | tr -d '\r\n ')" == "yes" ]]
    }

    # debugfs is often NOT mounted on Android after boot - mount it if needed
    if ! ctabs_ok; then
        echo "  $CTABS_DBG not present, trying to mount debugfs..."
        adb shell "mount -t debugfs none /sys/kernel/debug" 2>&1 | sed 's/^/     mount: /'
    fi
    if ! ctabs_ok; then
        echo "ERROR: $CTABS_DBG still missing. Cannot set mode."
        echo "       debug mounts: $(adb shell 'mount | grep -i debug' 2>&1 | tr '\n' '|')"
        echo "       SELinux?     $(adb shell getenforce 2>&1)"
        exit 1
    fi
    echo "  [knob] debugfs reachable"

    # NOTE: these writes used to be unguarded. Under `set -e` a single failed
    # redirect killed the whole run with a bare rc=255 and no explanation, so
    # print the real cause (SELinux, read-only, missing file, ...) instead.
    if [[ -n "$MODE" ]]; then
        if ! adb shell "echo $MODE > $CTABS_DBG/mode"; then
            echo "ERROR: cannot write mode=$MODE to $CTABS_DBG/mode"
            echo "       ls   : $(adb shell "ls -l $CTABS_DBG/mode" 2>&1 | tr '\n' '|')"
            echo "       selinux: $(adb shell getenforce 2>&1)"
            exit 1
        fi
    fi
    if [[ -n "$SYNC_ONLY" ]]; then
        if ! adb shell "echo $SYNC_ONLY > $CTABS_DBG/sync_only"; then
            echo "ERROR: cannot write sync_only=$SYNC_ONLY to $CTABS_DBG/sync_only"
            exit 1
        fi
    fi

    if [[ -n "$HANDOFF" ]]; then
        if ! adb shell "echo $HANDOFF > $CTABS_DBG/handoff"; then
            echo "ERROR: cannot write handoff=$HANDOFF to $CTABS_DBG/handoff (kernel without handoff support?)"
            exit 1
        fi
        got_ho=$(adb shell "cat $CTABS_DBG/handoff" 2>/dev/null | tr -d '\r\n ' || true)
        echo "  readback: handoff=$got_ho"
        if [[ "$got_ho" != "$HANDOFF" ]]; then
            echo "ERROR: requested handoff=$HANDOFF but kernel reports $got_ho"; exit 1
        fi
    fi

    if [[ -n "$GUARD" ]]; then
        if ! adb shell "echo $GUARD > $CTABS_DBG/handoff_guard"; then
            echo "ERROR: cannot write handoff_guard=$GUARD to $CTABS_DBG/handoff_guard (kernel without guard support?)"
            exit 1
        fi
        got_g=$(adb shell "cat $CTABS_DBG/handoff_guard" 2>/dev/null | tr -d '\r\n ' || true)
        echo "  readback: handoff_guard=$got_g"
        if [[ "$got_g" != "$GUARD" ]]; then
            echo "ERROR: requested handoff_guard=$GUARD but kernel reports $got_g"; exit 1
        fi
    fi

    if [[ -n "$REPLY_POLICY" ]]; then
        if ! adb shell "echo $REPLY_POLICY > $CTABS_DBG/reply_policy"; then
            echo "ERROR: cannot write reply_policy=$REPLY_POLICY to $CTABS_DBG/reply_policy (kernel without reply policy support?)"
            exit 1
        fi
        got_rp=$(adb shell "cat $CTABS_DBG/reply_policy" 2>/dev/null | tr -d '\r\n ' || true)
        echo "  readback: reply_policy=$got_rp"
        if [[ "$got_rp" != "$REPLY_POLICY" ]]; then
            echo "ERROR: requested reply_policy=$REPLY_POLICY but kernel reports $got_rp"; exit 1
        fi
    fi

    if [[ -n "$SIS_CURRENT" ]]; then
        if ! adb shell "echo $SIS_CURRENT > $CTABS_DBG/sis_current"; then
            echo "ERROR: cannot write sis_current=$SIS_CURRENT to $CTABS_DBG/sis_current (kernel without SIS baseline support?)"
            exit 1
        fi
        got_sis=$(adb shell "cat $CTABS_DBG/sis_current" 2>/dev/null | tr -d '\r\n ' || true)
        echo "  readback: sis_current=$got_sis"
        if [[ "$got_sis" != "$SIS_CURRENT" ]]; then
            echo "ERROR: requested sis_current=$SIS_CURRENT but kernel reports $got_sis"; exit 1
        fi
    fi

    if [[ -n "$MUSCHED_LITE" ]]; then
        if ! adb shell "echo $MUSCHED_LITE > $CTABS_DBG/musched_lite"; then
            echo "ERROR: cannot write musched_lite=$MUSCHED_LITE to $CTABS_DBG/musched_lite (kernel without MUSched-lite baseline?)"
            exit 1
        fi
        got_ml=$(adb shell "cat $CTABS_DBG/musched_lite" 2>/dev/null | tr -d '\r\n ' || true)
        echo "  readback: musched_lite=$got_ml"
        if [[ "$got_ml" != "$MUSCHED_LITE" ]]; then
            echo "ERROR: requested musched_lite=$MUSCHED_LITE but kernel reports $got_ml"; exit 1
        fi
    fi

    if [[ -n "$HANDOFF_EXTRAS" ]]; then
        if ! adb shell "echo $HANDOFF_EXTRAS > $SCHED_DBG/handoff_extras"; then
            echo "ERROR: cannot write handoff_extras=$HANDOFF_EXTRAS to $SCHED_DBG/handoff_extras (kernel without P6 support?)"
            exit 1
        fi
        got_he=$(adb shell "cat $SCHED_DBG/handoff_extras" 2>/dev/null | tr -d '\r\n ' || true)
        echo "  readback: handoff_extras=$got_he"
        if [[ "$got_he" != "$HANDOFF_EXTRAS" ]]; then
            echo "ERROR: requested handoff_extras=$HANDOFF_EXTRAS but kernel reports $got_he"; exit 1
        fi
    fi

    # selection-ladder tuning knobs (SEL series, patch 0005)
    set_ctabs_u32() {
        local name="$1" val="$2" got

        if ! adb shell "echo $val > $CTABS_DBG/$name"; then
            echo "ERROR: cannot write $name=$val to $CTABS_DBG/$name (kernel without this knob?)"
            exit 1
        fi
        got=$(adb shell "cat $CTABS_DBG/$name" 2>/dev/null | tr -d '\r\n ' || true)
        echo "  readback: $name=$got"
        if [[ "$got" != "$val" ]]; then
            echo "ERROR: requested $name=$val but kernel reports $got"; exit 1
        fi
    }

    [[ -n "$AGE_MS" ]] && set_ctabs_u32 age_ms "$AGE_MS"
    [[ -n "$SCORE_LOCAL" ]] && set_ctabs_u32 score_local "$SCORE_LOCAL"
    [[ -n "$SCORE_CLUSTER" ]] && set_ctabs_u32 score_cluster "$SCORE_CLUSTER"
    [[ -n "$SCORE_STEP" ]] && set_ctabs_u32 score_step "$SCORE_STEP"
    [[ -n "$SCORE_DECAY" ]] && set_ctabs_u32 score_decay "$SCORE_DECAY"
    [[ -n "$HANDOFF_DEFER" ]] && set_ctabs_u32 handoff_defer "$HANDOFF_DEFER"
    [[ -n "$DEFER_WINDOW_US" ]] && set_ctabs_u32 defer_window_us "$DEFER_WINDOW_US"
    # election v2 (patch 0007): P no-drag / O random victim / C cost election
    [[ -n "$NODRAG" ]] && set_ctabs_u32 nodrag "$NODRAG"
    [[ -n "$ELECT_RAND" ]] && set_ctabs_u32 elect_rand "$ELECT_RAND"
    [[ -n "$ELECT_COST" ]] && set_ctabs_u32 elect_cost "$ELECT_COST"

    # hard-verify the knob actually took the requested value
    # (`|| true` inside $(): under set -e + pipefail an adb hiccup here would
    #  otherwise abort the run with no explanation)
    got_mode=$(adb shell "cat $CTABS_DBG/mode" 2>/dev/null | tr -d '\r\n ' || true)
    got_sync=$(adb shell "cat $CTABS_DBG/sync_only" 2>/dev/null | tr -d '\r\n ' || true)
    echo "  readback: mode=$got_mode sync_only=$got_sync"
    if [[ -n "$MODE" && "$got_mode" != "$MODE" ]]; then
        echo "ERROR: requested mode=$MODE but kernel reports mode=$got_mode."
        echo "       Refusing to continue with an invalid configuration."
        exit 1
    fi
    # 'Y'/'N' is how debugfs_create_bool prints; accept it for sync_only
    if [[ -n "$SYNC_ONLY" ]]; then
        case "$SYNC_ONLY:$got_sync" in
            1:Y|0:N) : ;;
            *) echo "ERROR: sync_only=$SYNC_ONLY readback=$got_sync"; exit 1 ;;
        esac
    fi
    echo "$got_mode" > "$OUT_DIR/ctabs_mode_readback.txt"
    if [[ -n "$GUARD" ]]; then
        adb shell "cat $CTABS_DBG/handoff_guard" 2>/dev/null | tr -d '\r\n ' > "$OUT_DIR/ctabs_guard_readback.txt" || true
    fi
    if [[ -n "$REPLY_POLICY" ]]; then
        adb shell "cat $CTABS_DBG/reply_policy" 2>/dev/null | tr -d '\r\n ' > "$OUT_DIR/ctabs_reply_policy_readback.txt" || true
    fi
    if [[ -n "$SIS_CURRENT" ]]; then
        adb shell "cat $CTABS_DBG/sis_current" 2>/dev/null | tr -d '\r\n ' > "$OUT_DIR/ctabs_sis_current_readback.txt" || true
    fi
    if [[ -n "$MUSCHED_LITE" ]]; then
        adb shell "cat $CTABS_DBG/musched_lite" 2>/dev/null | tr -d '\r\n ' > "$OUT_DIR/ctabs_musched_lite_readback.txt" || true
    fi
    if [[ -n "$HANDOFF_EXTRAS" ]]; then
        adb shell "cat $SCHED_DBG/handoff_extras" 2>/dev/null | tr -d '\r\n ' > "$OUT_DIR/ctabs_handoff_extras_readback.txt" || true
    fi

    # zero per-mode counters so the stats collected below describe THIS mode only
    adb shell "echo 1 > $CTABS_DBG/reset" 2>/dev/null || true
fi

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
# Benchmark 1: schd-dbg — latency by topology tier                    #
#             3 concurrency levels: 1 / 4 / 8 pairs                  #
# ------------------------------------------------------------------ #
echo ""
echo "================================================================"
echo "[1/3] schd-dbg — latency by topology tier (pair=1)"
echo "      ${ITER} iterations, 16B payload"
echo "================================================================"
run_adb "01a_schd_dbg_pair1" \
    "$BIN_CTABS -i $ITER -pair 1 -payload 16"
cooldown
echo ""
echo "================================================================"
echo "[1/3] schd-dbg — latency by topology tier (pair=4)"
echo "      ${ITER} iterations, 16B payload"
echo "================================================================"
run_adb "01b_schd_dbg_pair4" \
    "$BIN_CTABS -i $ITER -pair 4 -payload 16"
cooldown
echo ""
echo "================================================================"
echo "[1/3] schd-dbg — latency by topology tier (pair=8)"
echo "      ${ITER} iterations, 16B payload"
echo "================================================================"
run_adb "01c_schd_dbg_pair8" \
    "$BIN_CTABS -i $ITER -pair 8 -payload 16"

# ------------------------------------------------------------------ #
# Benchmark 2: binderThroughputTest — throughput + latency             #
#             (PASS 1: no profiling — clean throughput numbers)        #
#             (PASS 2: with simpleperf hardware counters, 3 groups)   #
#              3 worker counts)                                       #
# ------------------------------------------------------------------ #
echo ""
echo "================================================================"
echo "[2/3] binderThroughputTest — PASS 1: throughput (no profiler)"
echo "      workers=2/4/8 × ${ITER} iterations"
echo "================================================================"
for w in 2 4 8; do
    run_adb "02_btt_w${w}_throughput" \
        "$BIN_BINDER_THRU -w $w -i $ITER $BTT_M"
    cooldown
done

echo ""
echo "================================================================"
echo "[2/3] binderThroughputTest — PASS 2: hw counters (simpleperf)"
echo "      workers=2/4/8 × ${ITER} iterations × 5 perf groups (A1+A2+A3+B+C)"
echo "================================================================"
if [[ $QUICK -eq 1 ]]; then
    echo "  --quick: skipping all simpleperf groups"
else
for w in 2 4 8; do
    # A-trio: 3 subgroups, each 2 events (no multiplexing)
    run_with_perf "$PERF_GROUP_A1" "02_btt_w${w}_perf_a1" \
        "$BIN_BINDER_THRU -w $w -i $ITER $BTT_M"
    cooldown
    run_with_perf "$PERF_GROUP_A2" "02_btt_w${w}_perf_a2" \
        "$BIN_BINDER_THRU -w $w -i $ITER $BTT_M"
    cooldown
    run_with_perf "$PERF_GROUP_A3" "02_btt_w${w}_perf_a3" \
        "$BIN_BINDER_THRU -w $w -i $ITER $BTT_M"
    cooldown
    run_with_perf "$PERF_GROUP_B" "02_btt_w${w}_perf_b" \
        "$BIN_BINDER_THRU -w $w -i $ITER $BTT_M"
    cooldown
    run_with_perf "$PERF_GROUP_C" "02_btt_w${w}_perf_c" \
        "$BIN_BINDER_THRU -w $w -i $ITER $BTT_M"
    cooldown
done
fi

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
adb shell "echo handoff_extras: \$(cat $SCHED_DBG/handoff_extras 2>/dev/null || echo NA)" 2>/dev/null | tr -d '\r' >> "$OUT_DIR/ctabs_stats.txt" || true
adb shell "echo handoff_fallback_hits: \$(cat $SCHED_DBG/handoff_fallback_hits 2>/dev/null || echo NA)" 2>/dev/null | tr -d '\r' >> "$OUT_DIR/ctabs_stats.txt" || true

# ------------------------------------------------------------------ #
# Collect logs                                                         #
# ------------------------------------------------------------------ #
echo ""
echo "=== Collecting dmesg + logcat ==="
adb shell "dmesg | tail -500" > "$OUT_DIR/dmesg.txt" || true
adb logcat -d -b all > "$OUT_DIR/logcat.txt" 2>/dev/null || true

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
