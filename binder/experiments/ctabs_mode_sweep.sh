#!/bin/bash
# ctabs_mode_sweep.sh
#
# Sweeps CTABS modes with a REBOOT before every single run, so that each
# measurement starts from the same thermal / DVFS / page-cache / background
# state.  This is the protocol for the paper's mode sweep.
#
# Per run it does, in order:
#   1. randomise the order of modes within each repeat (not fixed round-robin)
#   2. adb reboot; wait for sys.boot_completed
#   3. quiesce for --min-quiesce seconds (boot leaves the system busy)
#   4. env probe "before"  (thermal, cpufreq time_in_state, /proc/stat, mem)
#   5. start the schedstat sampler, run the benchmark, stop it
#   6. env probe "after"
#
# Thermal gate is OFF by default: the reboot is used to reset *state*, not to
# normalise temperature.  Temperature is still recorded on both sides of every
# run so it can be reported and used as a post-hoc covariate.  Pass
# --settle-temp C to additionally wait for the hottest zone to drop below C.
#
# Output layout:
#   <out>/repeatR/modeM/{runner output..., env_before.txt, env_after.txt, schedstat.txt}
#   <out>/summary.csv
#
# Usage:
#   ./ctabs_mode_sweep.sh --label SA6155P --modes "0 1 2 3 4 6 9 10 11 12 13" --repeats 5
#   ./ctabs_mode_sweep.sh --label SA8155P --modes "0 2 10" --repeats 9 --caller-cg none
#   ./ctabs_mode_sweep.sh --label SA8155P --repeats 5 \
#       --modes "0 2 0h1 2h1 2h2p0 2h2p2 2h3p0 2h3p1 2h3p2 2h1g1 2h1g3 2h1g7 2h1g15"
#
# Options:
#   --label L        board label (required)
#   --modes "..."    space separated mode list (default: 0 2 10);
#                    token grammar: M | MhH | MhHgG | MhHpP | MhHgGpP |
#                    MhH...sS | MhH...lL | MhH...eE | MhH...nN | MhH...oO |
#                    MhH...cC | MhH...dD | MhH...wW
#                    (suffix order left->right: gG pP sS lL eE nN oO cC dD wW;
#                     n = nodrag P-arm, o = random victim O-arm,
#                     c = cost election C-arm -- election v2, patch 0007)
#                    where M = selection mode, H = handoff bitmask,
#                    G = handoff_guard mask, P = reply_policy (0/1/2),
#                    S = sis_current (0/1), L = musched_lite (0/1),
#                    E = handoff_extras (P6 bitmask: 1 = EAS_SYNC,
#                    2 = FALLBACK), D = handoff_defer (0/1, BCH patch 0006),
#                    W = defer_window_us (BCH).  Omitted suffixes keep the
#                    kernel defaults (11 / 2 / 0 / 0 / 0 / 0 / 100).  Examples:
#                      "2h1g9d1w100 3h1g9d1w100"           BCH request-only
#                      "2h1g9d1w10 2h1g9d1w200"            BCH W sweep
#                      "2h1g9d0w100"                       BCH off (speculative)
#                      "0 2 0h1 2h1"                       principal matrix
#                      "2h2p0 2h2p2 2h3p0 2h3p1 2h3p2"    reply ablation
#                      "2h1g1 2h1g5 2h1g9 2h1g13 2h1g15"  guard ablation
#                      "h0s1 h0l1"                         baseline arms
#                      "h0e1 h1g9e1 2h3g9p2e3"             P6 extensions
#                      "3h1g9n1 3h1g9o1 3h1g9c1 3h1g9n1c1" P/O/C arms (0007)
#                    (a token must contain 'h' for suffixes to be parsed,
#                     so use "0h0e1" / "h0e1" for B+P6)
#   --repeats N      repeats per mode (default: 5)
#   --gov G          governor, default schedutil (the device default)
#   --iter N         benchmark iterations, default 100000
#   --settle-temp C  OPT-IN: wait until max thermal zone < C before measuring
#                    (default 0 = no gate; temperature is still recorded)
#   --settle-max S   give up waiting after S seconds (default 300)
#   --min-quiesce S  minimum wait after boot before measuring (default 40)
#   --out DIR        output root
#   --quick          skip simpleperf.  Default is to RUN it (like the old
#                    runner: 5 groups x workers 2/4/8, ~10 min extra per run)
#   --no-reboot      skip the reboot stage (debugging only; numbers are not valid)
#   --no-settle      skip the thermal gate (debugging only)

set -uo pipefail

LABEL=""
MODES="0 1 2 3 4 5 6 7 8 9 10 11 12 13"
REPEATS=5
GOV="schedutil"
ITER=100000
SETTLE_TEMP=0
SETTLE_MAX=300
MIN_QUIESCE=40
OUT=""
QUICK=0
REBOOT=1
SETTLE=1
SCHEDSTAT=0
DEV_TMP="/data/local/tmp"
HERE="$(cd "$(dirname "$0")" && pwd)"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --label)       LABEL="$2"; shift 2 ;;
        --modes)       MODES="$2"; shift 2 ;;
        --repeats)     REPEATS="$2"; shift 2 ;;
        --gov)         GOV="$2"; shift 2 ;;
        --iter)        ITER="$2"; shift 2 ;;
        --settle-temp) SETTLE_TEMP="$2"; shift 2 ;;
        --settle-max)  SETTLE_MAX="$2"; shift 2 ;;
        --min-quiesce) MIN_QUIESCE="$2"; shift 2 ;;
        --out)         OUT="$2"; shift 2 ;;
        --quick)       QUICK=1; shift ;;
        --schedstat)   SCHEDSTAT=1; shift ;;
        --no-reboot)   REBOOT=0; shift ;;
        --no-settle)   SETTLE=0; shift ;;
        *) echo "unknown option: $1"; exit 1 ;;
    esac
done

[[ -n "$LABEL" ]] || { echo "--label is required"; exit 1; }
[[ -n "$OUT" ]] || OUT="./ctabs_sweep_${LABEL}_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT" || { echo "FATAL: cannot create output dir '$OUT'"; exit 1; }
[[ -d "$OUT" ]] || { echo "FATAL: '$OUT' is not a directory"; exit 1; }
LOG="$OUT/sweep.log"
exec > >(tee -a "$LOG") 2>&1

dsh() { adb shell "$@" 2>&1 | tr -d '\r'; }

echo "=== CTABS mode sweep: label=$LABEL ==="
echo "modes=[$MODES] repeats=$REPEATS gov=$GOV iter=$ITER"
echo "reboot=$REBOOT settle=$SETTLE temp<${SETTLE_TEMP}C maxwait=${SETTLE_MAX}s quiesce=${MIN_QUIESCE}s"
echo "out=$OUT  simpleperf=$([[ $QUICK -eq 1 ]] && echo off || echo ON)  $(date)"
echo "pwd=$(pwd)   free-on-dot=$(df -h . 2>/dev/null | awk 'NR==2{print $4}')"

adb root >/dev/null 2>&1; adb wait-for-device

# ---- preflight: a missing/empty/corrupt helper silently produced "rc=0 and
#      no output" once already, which looks exactly like a kernel problem.
#      CRLF is the same class of trap: on Linux bash a trailing \r turns
#      `then` into an unknown word and the script dies in bizarre places.
for f in "$HERE/ctabs_validation_runner.sh" "$HERE/device/ctabs_env_probe.sh" \
         "$HERE/device/ctabs_schedstat_sampler.sh"; do
    [[ -f "$f" ]] || { echo "FATAL: missing helper '$f'"; exit 1; }
    if grep -q $'\r' "$f" 2>/dev/null; then
        echo "FATAL: '$f' has CRLF line endings -- run: dos2unix '$f'"; exit 1
    fi
done
[[ -s "$HERE/ctabs_validation_runner.sh" ]] || {
    echo "FATAL: '$HERE/ctabs_validation_runner.sh' is missing or EMPTY"; exit 1; }
bash -n "$HERE/ctabs_validation_runner.sh" || {
    echo "FATAL: '$HERE/ctabs_validation_runner.sh' has a syntax error"; exit 1; }
echo "runner preflight: $(wc -l < "$HERE/ctabs_validation_runner.sh") lines, $(wc -c < "$HERE/ctabs_validation_runner.sh") bytes, LF-ok"

# ---------------------------------------------------------------- device bits
adb push "$HERE/device/ctabs_env_probe.sh"        "$DEV_TMP/" >/dev/null
adb push "$HERE/device/ctabs_schedstat_sampler.sh" "$DEV_TMP/" >/dev/null
dsh "chmod 755 $DEV_TMP/ctabs_env_probe.sh $DEV_TMP/ctabs_schedstat_sampler.sh"
dsh "mount -t debugfs none /sys/kernel/debug 2>/dev/null; true"

# ---------------------------------------------------------------------- helpers
max_temp() {   # -> millidegC, or 0
    dsh "$DEV_TMP/ctabs_env_probe.sh probe" | awk -F= '/^MAX_TEMP_MILLI=/ {print $2}' | tail -1
}

reboot_and_wait() {
    echo "  [reboot] $(date +%T)"
    adb reboot >/dev/null 2>&1
    adb wait-for-device
    for _ in $(seq 1 120); do
        [[ "$(dsh 'getprop sys.boot_completed' )" == "1" ]] && break
        sleep 2
    done
    adb root >/dev/null 2>&1
    # Android does NOT mount debugfs by default, and `adb root` restarts adbd,
    # so retry until the CTABS knob is really reachable. Without this the
    # runner exits 1 on its own debugfs check and the whole run is lost.
    for _ in $(seq 1 15); do
        dsh "mount -t debugfs none /sys/kernel/debug 2>/dev/null; true" >/dev/null
        [[ "$(dsh 'test -d /sys/kernel/debug/binder/ctabs && echo yes')" == "yes" ]] && break
        sleep 2
    done
    echo "  [debugfs] $(dsh 'test -d /sys/kernel/debug/binder/ctabs && echo ctabs-OK || echo ctabs-MISSING')"
    echo "  [booted] $(date +%T), quiesce ${MIN_QUIESCE}s"
    sleep "$MIN_QUIESCE"
}

settle_thermal() {
    local waited=0 t
    if [[ "${SETTLE_TEMP:-0}" -le 0 ]]; then
        echo "  [settle] gate disabled (temp is recorded, not gated)"
        return
    fi
    while :; do
        t=$(max_temp)
        t=${t:-0}
        echo "  [settle] max_temp=$((t/1000))C (target <${SETTLE_TEMP}C, waited ${waited}s)"
        [[ "$t" -lt $((SETTLE_TEMP * 1000)) ]] && break
        [[ "$waited" -ge "$SETTLE_MAX" ]] && { echo "  [settle] TIMEOUT - continuing anyway"; break; }
        sleep 10; waited=$((waited + 10))
    done
}

shuffle() {   # portable shuffle
    if command -v shuf >/dev/null 2>&1; then echo "$1" | tr ' ' '\n' | shuf | tr '\n' ' '
    else echo "$1" | tr ' ' '\n' | awk 'BEGIN{srand()} {print rand(), $0}' | sort -n | cut -d' ' -f2- | tr '\n' ' '
    fi
}

# ------------------------------------------------------------------ the sweep
: > "$OUT/summary.csv"
echo "repeat,mode,throughput_w8,l1_avg_ms,pick_same_core,pick_same_cluster,pick_fallback,base_same_core,base_same_cluster,base_cross,rejected_capacity,upgraded_capacity,max_temp_before,guard,reply_policy,sis_current,musched_lite,handoff_extras,handoff_fallback_hits,handoff_defer,defer_window_us,nodrag,elect_rand,elect_cost,nodrag_used,nodrag_ordinary,elect_rand_used,elect_cost_used" >> "$OUT/summary.csv"

for r in $(seq 1 "$REPEATS"); do
    ORDER=$(shuffle "$MODES")
    echo ""
    echo "################ repeat $r order: $ORDER ################"

    for m in $ORDER; do
        run_dir="$OUT/repeat${r}/mode${m}"
        if ! mkdir -p "$run_dir"; then
            echo "FATAL: cannot create '$run_dir'"
            echo "       pwd=$(pwd)  free=$(df -h . 2>/dev/null | awk 'NR==2{print $4}')"
            echo "       ls -ld . : $(ls -ld . 2>&1)"
            exit 1
        fi
        echo ""
        echo "======== repeat=$r mode=$m ========"

        if [[ $REBOOT -eq 1 ]]; then reboot_and_wait; fi
        if [[ $SETTLE -eq 1 ]]; then settle_thermal; fi

        dsh "$DEV_TMP/ctabs_env_probe.sh before" > "$run_dir/env_before.txt"
        TEMP_BEFORE=$(awk -F= '/^MAX_TEMP_MILLI=/ {print $2}' "$run_dir/env_before.txt" | tail -1)

        # schedstat sampler. `adb shell 'cmd &'` is NOT enough: when that shell
        # exits adbd tears the session down and the child dies, which is why
        # the log file got created but stayed empty. setsid + </dev/null
        # detaches it; the sampler writes its own pid so we can check liveness
        # (pgrep -f would match this very adb shell command line).
        if [[ ${SCHEDSTAT:-0} -eq 1 ]]; then
        SSLOG="$DEV_TMP/ss_${r}_${m}.log"
        dsh "rm -f $SSLOG $SSLOG.pid" >/dev/null
        dsh "setsid sh $DEV_TMP/ctabs_schedstat_sampler.sh $SSLOG </dev/null >/dev/null 2>&1 &"
        sleep 1
        alive=$(dsh "p=\$(cat $SSLOG.pid 2>/dev/null); [ -n \"\$p\" ] && kill -0 \$p 2>/dev/null && echo 1 || echo 0")
        echo "  [schedstat] sampler alive=${alive:-0} (pid $(dsh "cat $SSLOG.pid 2>/dev/null"))"
        fi

        # token "M" = ctabs mode M; "MhH" = mode M + handoff bitmask H;
        # optional suffixes (left->right): gG (handoff_guard), pP (reply_policy),
        # sS (sis_current), lL (musched_lite), eE (handoff_extras),
        # dD (handoff_defer), wW (defer_window_us, BCH).
        # e.g. 2h3g15p2s1l1e1d1w100.
        ctabs_m=${m%%h*}
        hoff=""; guard=""; reply=""; sis=""; lite=""; extras=""
        defer=""; window=""; nodrag=""; erand=""; ecost=""
        if [[ "$m" == *h* ]]; then
            rest=${m#*h}
            # parse right-to-left: wW dD eE lL sS pP gG
            if [[ "$rest" == *w* ]]; then
                window=${rest##*w}; rest=${rest%%w*}
            fi
            if [[ "$rest" == *d* ]]; then
                defer=${rest##*d}; rest=${rest%%d*}
            fi
            # election v2 (patch 0007): cC oO nN, parsed right-to-left
            if [[ "$rest" == *c* ]]; then
                ecost=${rest##*c}; rest=${rest%%c*}
            fi
            if [[ "$rest" == *o* ]]; then
                erand=${rest##*o}; rest=${rest%%o*}
            fi
            if [[ "$rest" == *n* ]]; then
                nodrag=${rest##*n}; rest=${rest%%n*}
            fi
            if [[ "$rest" == *e* ]]; then
                extras=${rest##*e}; rest=${rest%%e*}
            fi
            if [[ "$rest" == *l* ]]; then
                lite=${rest##*l}; rest=${rest%%l*}
            fi
            if [[ "$rest" == *s* ]]; then
                sis=${rest##*s}; rest=${rest%%s*}
            fi
            if [[ "$rest" == *p* ]]; then
                reply=${rest##*p}; rest=${rest%%p*}
            fi
            if [[ "$rest" == *g* ]]; then
                guard=${rest#*g}; rest=${rest%%g*}
            fi
            hoff=$rest
        fi
        runner_args=(--label "${LABEL}_r${r}_m${m}" --gov "$GOV" --iter "$ITER"
                     --mode "$ctabs_m" --out "$run_dir/runner")
        [[ -n "$hoff" ]] && runner_args+=(--handoff "$hoff")
        [[ -n "$guard" ]] && runner_args+=(--guard "$guard")
        [[ -n "$reply" ]] && runner_args+=(--reply-policy "$reply")
        [[ -n "$sis" ]] && runner_args+=(--sis-current "$sis")
        [[ -n "$lite" ]] && runner_args+=(--musched-lite "$lite")
        [[ -n "$extras" ]] && runner_args+=(--handoff-extras "$extras")
        [[ -n "$defer" ]] && runner_args+=(--handoff-defer "$defer")
        [[ -n "$window" ]] && runner_args+=(--defer-window-us "$window")
        [[ -n "$nodrag" ]] && runner_args+=(--nodrag "$nodrag")
        [[ -n "$erand" ]] && runner_args+=(--elect-rand "$erand")
        [[ -n "$ecost" ]] && runner_args+=(--elect-cost "$ecost")
        [[ $QUICK -eq 1 ]] && runner_args+=(--quick)

        # Run via bash (do not rely on the exec bit) and NEVER swallow the
        # output: a silent runner failure shows up as throughput=NA otherwise.
        runner_rc=0
        bash "$HERE/ctabs_validation_runner.sh" "${runner_args[@]}" \
             > "$run_dir/runner_stdout.txt" 2>&1 || runner_rc=$?
        if [[ $runner_rc -ne 0 || ! -f "$run_dir/runner/02_btt_w8_throughput.json" ]]; then
            echo "  !! runner failed (rc=$runner_rc) or did not finish"
            echo "     -- runner.log (real output: the runner exec's into tee) --"
            tail -30 "$run_dir/runner/runner.log" 2>/dev/null | sed 's/^/     /'
            echo "     -- direct stdout/stderr (usually empty, see above) --"
            tail -10 "$run_dir/runner_stdout.txt" 2>/dev/null | sed 's/^/     /'
            echo "     -- files under $run_dir --"
            find "$run_dir" -maxdepth 2 2>/dev/null | head -25 | sed 's/^/     /'
        fi

        if [[ ${SCHEDSTAT:-0} -eq 1 ]]; then
        alive2=$(dsh "p=\$(cat $SSLOG.pid 2>/dev/null); [ -n \"\$p\" ] && kill -0 \$p 2>/dev/null && echo alive || echo died")
        lines=$(dsh "wc -l < $SSLOG 2>/dev/null || echo 0")
        echo "  [schedstat] after run: $alive2, ${lines:-0} lines"
        dsh "kill \$(cat $SSLOG.pid 2>/dev/null) 2>/dev/null; true" >/dev/null
        # Use adb pull, not `adb shell cat`: shell round-trips silently produced
        # an empty local file while the remote file had 578 lines.
        rm -f "$run_dir/schedstat.txt"
        adb pull "$SSLOG" "$run_dir/schedstat.txt" >/dev/null 2>&1 || true
        if [[ ! -s "$run_dir/schedstat.txt" ]]; then
            echo "  [schedstat] EMPTY (remote had ${lines:-0} lines)"
        else
            echo "  [schedstat] saved $(wc -l < "$run_dir/schedstat.txt") lines"
        fi
        fi
        dsh "$DEV_TMP/ctabs_env_probe.sh after" > "$run_dir/env_after.txt"

        # ---- extract the headline numbers
        throughput=$(grep -aoE 'iterations per sec: *[0-9.]+' "$run_dir"/runner/02_btt_w8_throughput.json 2>/dev/null \
                     | grep -oE '[0-9.]+$' | tail -1)
        l1=$(grep -aoE '"avg":[0-9.]+' "$run_dir"/runner/01a_schd_dbg_pair1.json 2>/dev/null | head -1 | cut -d: -f2)
        stats="$run_dir/runner/ctabs_stats.txt"
        sc=$(awk '/^base_same_core:/    {print $2}' "$stats" 2>/dev/null)
        scl=$(awk '/^base_same_cluster:/ {print $2}' "$stats" 2>/dev/null)
        scr=$(awk '/^base_cross:/        {print $2}' "$stats" 2>/dev/null)
        rej=$(awk '/^rejected_capacity:/ {print $2}' "$stats" 2>/dev/null)
        upg=$(awk '/^upgraded_capacity:/ {print $2}' "$stats" 2>/dev/null)
        # what the topology selector actually did (mode 0 leaves these at 0)
        pc=$(awk '/^same_core:/    {print $2}' "$stats" 2>/dev/null)
        pcl=$(awk '/^same_cluster:/ {print $2}' "$stats" 2>/dev/null)
        fb=$(awk '/^fallback:/     {print $2}' "$stats" 2>/dev/null)
        # guard / reply policy actually in effect (NA on older kernels)
        hg=$(awk '/^handoff_guard:/ {print $2}' "$stats" 2>/dev/null)
        rp=$(awk '/^reply_policy:/  {print $2}' "$stats" 2>/dev/null)
        sisv=$(awk '/^sis_current:/ {print $2}' "$stats" 2>/dev/null)
        mlv=$(awk '/^musched_lite:/ {print $2}' "$stats" 2>/dev/null)
        hev=$(awk '/^handoff_extras:/ {print $2}' "$stats" 2>/dev/null)
        fbh=$(awk '/^handoff_fallback_hits:/ {print $2}' "$stats" 2>/dev/null)
        hdf=$(awk '/^handoff_defer:/ {print $2}' "$stats" 2>/dev/null)
        dwu=$(awk '/^defer_window_us:/ {print $2}' "$stats" 2>/dev/null)
        # election v2 (patch 0007) knobs + counters
        nrv=$(awk '/^nodrag:/ {print $2}' "$stats" 2>/dev/null)
        erv=$(awk '/^elect_rand:/ {print $2}' "$stats" 2>/dev/null)
        ecv=$(awk '/^elect_cost:/ {print $2}' "$stats" 2>/dev/null)
        nru=$(awk '/^nodrag_used:/ {print $2}' "$stats" 2>/dev/null)
        nro=$(awk '/^nodrag_ordinary:/ {print $2}' "$stats" 2>/dev/null)
        eru=$(awk '/^elect_rand_used:/ {print $2}' "$stats" 2>/dev/null)
        ecu=$(awk '/^elect_cost_used:/ {print $2}' "$stats" 2>/dev/null)

        echo "$r,$m,${throughput:-NA},${l1:-NA},${pc:-0},${pcl:-0},${fb:-0},${sc:-NA},${scl:-NA},${scr:-NA},${rej:-NA},${upg:-NA},${TEMP_BEFORE:-NA},${hg:-NA},${rp:-NA},${sisv:-NA},${mlv:-NA},${hev:-NA},${fbh:-NA},${hdf:-NA},${dwu:-NA},${nrv:-NA},${erv:-NA},${ecv:-NA},${nru:-NA},${nro:-NA},${eru:-NA},${ecu:-NA}" >> "$OUT/summary.csv"
        echo "  -> w8 throughput=${throughput:-NA}  rejected_cap=${rej:-NA} upgraded_cap=${upg:-NA} guard=${hg:-NA} reply_policy=${rp:-NA} sis_current=${sisv:-NA} musched_lite=${mlv:-NA} handoff_extras=${hev:-NA} fallback_hits=${fbh:-NA} handoff_defer=${hdf:-NA} defer_window_us=${dwu:-NA} nodrag=${nrv:-NA}/${nru:-NA} elect_rand=${erv:-NA}/${eru:-NA} elect_cost=${ecv:-NA}/${ecu:-NA} temp_before=${TEMP_BEFORE}"
    done
done

echo ""
echo "=== DONE: $LABEL ==="
echo "summary: $OUT/summary.csv"
column -s, -t "$OUT/summary.csv" 2>/dev/null || cat "$OUT/summary.csv"
