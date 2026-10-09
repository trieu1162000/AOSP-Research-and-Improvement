#!/bin/bash
# ctabs_appstart_sweep.sh
#
# Host-side driver for app-start measurements (adb).  For every config token
# and every scenario it runs device/appstart_bench.sh once, pulls the CSV and
# records the state.  Token grammar is shared with ctabs_mode_sweep.sh:
#   M | MhH | MhHgG | MhHpP | MhHgGpP | MhH...sS | MhH...lL
#     | MhH...dD | MhH...wW   (suffix order left->right gG pP sS lL nN oO cC dD wW;
#                               n/o/c = nodrag/elect_rand/elect_cost, patch 0007)
#     M = selection mode, H = handoff bitmask,
#     G = handoff_guard mask, P = reply_policy (0/1/2),
#     S = sis_current (0/1), L = musched_lite (0/1),
#     D = handoff_defer (0/1), W = defer_window_us
#
# Recommended matrix: configs "0 h1g1 2h1g9 2h1g9d1w100 3h1g9d1w100 h0s1 h0l1"
# x scenarios "idle concurrent load", N=30, schedutil only.
#
# Usage:
#   ./ctabs_appstart_sweep.sh --label SA8155P \
#       --configs "0 h1g1 h1g15 h3g15p2 2h3g15p2 h0s1 h0l1" \
#       --scenarios "idle concurrent load" \
#       --apps "com.android.settings com.android.contacts com.android.calendar" \
#       --n 30 --out ./appstart_SA8155P
#
# Options:
#   --label L        board label (required)
#   --gov G          governor (default schedutil)
#   --configs "..."  config tokens (default "0 2 2h1 2h3p2")
#   --scenarios "..." (default "idle concurrent load")
#   --apps "..."     package or pkg/activity list
#   --n N            cold starts per app per run (default 30)
#   --warmup N       discarded starts (default 3)
#   --cache cold|warm (default cold)
#   --out DIR        output root
#   --no-settle      skip the temperature gate
#   --settle-temp C  gate temperature (default 36)
#   --settle-max S   give up after S seconds (default 300)

set -uo pipefail

LABEL=""
GOV="schedutil"
CONFIGS="0 2 2h1 2h3p2"
SCENARIOS="idle concurrent load"
APPS="com.android.settings com.android.contacts com.android.calendar"
N=30
WARMUP=3
CACHE=cold
OUT=""
SETTLE=1
SETTLE_TEMP=36
SETTLE_MAX=300
DEV_TMP="/data/local/tmp"
HERE="$(cd "$(dirname "$0")" && pwd)"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --label) LABEL="$2"; shift 2 ;;
        --gov) GOV="$2"; shift 2 ;;
        --configs) CONFIGS="$2"; shift 2 ;;
        --scenarios) SCENARIOS="$2"; shift 2 ;;
        --apps) APPS="$2"; shift 2 ;;
        --n) N="$2"; shift 2 ;;
        --warmup) WARMUP="$2"; shift 2 ;;
        --cache) CACHE="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --no-settle) SETTLE=0; shift ;;
        --settle-temp) SETTLE_TEMP="$2"; shift 2 ;;
        --settle-max) SETTLE_MAX="$2"; shift 2 ;;
        *) echo "unknown option: $1"; exit 1 ;;
    esac
done

[[ -n "$LABEL" ]] || { echo "--label is required"; exit 1; }
[[ -n "$OUT" ]] || OUT="./appstart_${LABEL}_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT"
LOG="$OUT/appstart.log"
exec > >(tee -a "$LOG") 2>&1

dsh() { adb shell "$@" 2>&1 | tr -d '\r'; }

max_temp() {
    dsh 'for z in /sys/class/thermal/thermal_zone*/temp; do cat $z 2>/dev/null; done' \
        | sort -n | tail -1
}

settle_thermal() {
    local waited=0 t
    [[ "$SETTLE" -eq 0 ]] && return
    while :; do
        t=$(max_temp)
        t=${t:-0}
        [[ "$t" -lt $((SETTLE_TEMP * 1000)) ]] && break
        [[ "$waited" -ge "$SETTLE_MAX" ]] && { echo "  [settle] TIMEOUT - continuing"; break; }
        echo "  [settle] max_temp=$((t / 1000))C (target <${SETTLE_TEMP}C, waited ${waited}s)"
        sleep 10
        waited=$((waited + 10))
    done
}

set_governor() {
    dsh "for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo $GOV > \$c 2>/dev/null; done; true"
    echo "  [gov] $(dsh 'cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor')"
}

# parse token -> MODE HOFF GUARD REPLY SIS LITE DEFER WINDOW NODRAG ERAND ECOST (empty = default)
parse_token() {
    local m="$1" rest
    MODE=${m%%h*}
    HOFF=""
    GUARD=""
    REPLY=""
    SIS=""
    LITE=""
    DEFER=""
    WINDOW=""
    NODRAG=""
    ERAND=""
    ECOST=""
    if [[ "$m" == *h* ]]; then
        rest=${m#*h}
        # right-to-left: wW dD lL sS pP gG
        if [[ "$rest" == *w* ]]; then
            WINDOW=${rest##*w}
            rest=${rest%%w*}
        fi
        if [[ "$rest" == *d* ]]; then
            DEFER=${rest##*d}
            rest=${rest%%d*}
        fi
        # election v2 (patch 0007): cC oO nN, right-to-left
        if [[ "$rest" == *c* ]]; then
            ECOST=${rest##*c}
            rest=${rest%%c*}
        fi
        if [[ "$rest" == *o* ]]; then
            ERAND=${rest##*o}
            rest=${rest%%o*}
        fi
        if [[ "$rest" == *n* ]]; then
            NODRAG=${rest##*n}
            rest=${rest%%n*}
        fi
        if [[ "$rest" == *l* ]]; then
            LITE=${rest##*l}
            rest=${rest%%l*}
        fi
        if [[ "$rest" == *s* ]]; then
            SIS=${rest##*s}
            rest=${rest%%s*}
        fi
        if [[ "$rest" == *p* ]]; then
            REPLY=${rest##*p}
            rest=${rest%%p*}
        fi
        if [[ "$rest" == *g* ]]; then
            GUARD=${rest#*g}
            rest=${rest%%g*}
        fi
        HOFF=$rest
    fi
}

# shuffled config x scenario job list
JOBS=""
for c in $CONFIGS; do
    for s in $SCENARIOS; do
        JOBS="$JOBS ${c}:${s}"
    done
done
JOBS=$(echo "$JOBS" | tr ' ' '\n' | awk 'BEGIN{srand()} {print rand(), $0}' | sort -n | cut -d' ' -f2- | tr '\n' ' ')

echo "=== CTABS app-start sweep: label=$LABEL gov=$GOV ==="
echo "configs=[$CONFIGS] scenarios=[$SCENARIOS] n=$N warmup=$WARMUP cache=$CACHE"
echo "out=$OUT  $(date)"

adb root >/dev/null 2>&1
adb wait-for-device
adb push "$HERE/appstart_bench.sh" "$DEV_TMP/" >/dev/null
dsh "chmod 755 $DEV_TMP/appstart_bench.sh"
dsh "mount -t debugfs none /sys/kernel/debug 2>/dev/null; true"
set_governor

# keep the screen on and unlocked for the whole sweep
dsh "svc power stayon true" >/dev/null 2>&1 || true
dsh "input keyevent KEYCODE_WAKEUP" >/dev/null 2>&1 || true
dsh "wm dismiss-keyguard" >/dev/null 2>&1 || true

for job in $JOBS; do
    cfg=${job%%:*}
    scen=${job##*:}
    parse_token "$cfg"
    tag="${cfg}_${scen}_$(date +%H%M%S)"
    echo ""
    echo "======== config=$cfg scenario=$scen ========"
    settle_thermal

    dsh "LABEL=${LABEL}_${cfg}_${scen} MODE=$MODE HANDOFF=${HOFF:-0} GUARD=${GUARD:-} REPLY_POLICY=${REPLY:-} SIS_CURRENT=${SIS:-0} MUSCHED_LITE=${LITE:-0} HANDOFF_DEFER=${DEFER:-0} DEFER_WINDOW_US=${WINDOW:-} NODRAG=${NODRAG:-0} ELECT_RAND=${ERAND:-0} ELECT_COST=${ECOST:-0} SCENARIO=$scen CACHE=$CACHE N=$N WARMUP=$WARMUP APPS='$APPS' OUT=$DEV_TMP/appstart_run.csv sh $DEV_TMP/appstart_bench.sh" \
        > "$OUT/${tag}.stdout.txt" 2>&1 || echo "  !! device run failed (see ${tag}.stdout.txt)"

    adb pull "$DEV_TMP/appstart_run.csv" "$OUT/${tag}.csv" >/dev/null 2>&1 || true
    if [[ -s "$OUT/${tag}.csv" ]]; then
        echo "  result rows: $(grep -c '^RESULT,' "$OUT/${tag}.csv")"
    else
        echo "  !! no CSV pulled; tail of device stdout:"
        tail -15 "$OUT/${tag}.stdout.txt" | sed 's/^/     /'
    fi
done

dsh "svc power stayon false" >/dev/null 2>&1 || true
echo ""
echo "=== DONE: $LABEL ==="
echo "summary: python parse_appstart.py --baseline B '$OUT/*.csv'"
