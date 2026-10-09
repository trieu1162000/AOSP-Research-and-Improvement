#!/system/bin/sh
# HoB app-start benchmark (device side, run as root or with su).
#
# One invocation = one config x one scenario.  Output is CSV:
#   RESULT,<label>,<scenario>,<cache>,<app>,<trial>,<total_ms>,<wait_ms>
# plus '#' comment lines (knobs, stats dump).
#
# Usage (example):
#   LABEL=HS MODE=2 HANDOFF=1 GUARD=15 REPLY_POLICY=2 \
#   SCENARIO=idle CACHE=cold N=30 OUT=/data/local/tmp/appstart_HS_idle.csv \
#   ./appstart_bench.sh
#
# Scenarios:
#   idle       - start each app once per trial (no background load)
#   concurrent - start all apps in parallel each trial
#   load       - idle pattern with a CPU load generator running
# Cache modes:
#   cold = force-stop + drop_caches, warm = force-stop only
#
# Randomize the order of configs at the invoker level; this script keeps the
# per-trial sequence stable.

set -u

CTABS_DIR=${CTABS_DIR:-/sys/kernel/debug/binder/ctabs}
LABEL=${LABEL:-manual}
MODE=${MODE:-0}
HANDOFF=${HANDOFF:-0}
GUARD=${GUARD:-15}
REPLY_POLICY=${REPLY_POLICY:-2}
SIS_CURRENT=${SIS_CURRENT:-0}
MUSCHED_LITE=${MUSCHED_LITE:-0}
HANDOFF_DEFER=${HANDOFF_DEFER:-0}
DEFER_WINDOW_US=${DEFER_WINDOW_US:-100}
NODRAG=${NODRAG:-0}
ELECT_RAND=${ELECT_RAND:-0}
ELECT_COST=${ELECT_COST:-0}
SCENARIO=${SCENARIO:-idle}
CACHE=${CACHE:-cold}
APPS=${APPS:-"com.android.settings com.android.contacts com.android.calendar"}
N=${N:-30}
WARMUP=${WARMUP:-3}
LOAD_PROCS=${LOAD_PROCS:-4}
OUT=${OUT:-}
TMP=${TMP:-/data/local/tmp/appstart_tmp}

log() { echo "$@"; [ -n "$OUT" ] && echo "$@" >> "$OUT"; }

w() {
	[ -w "$CTABS_DIR/$1" ] && echo "$2" > "$CTABS_DIR/$1" 2>/dev/null && return 0
	su -c "echo '$2' > $CTABS_DIR/$1" 2>/dev/null && return 0
	echo "$2" > "$CTABS_DIR/$1"
}

setup_knobs() {
	for k in mode handoff handoff_guard reply_policy sis_current musched_lite handoff_defer defer_window_us nodrag elect_rand elect_cost sync_only; do
		[ -e "$CTABS_DIR/$k" ] || continue
		case "$k" in
		mode)          w mode "$MODE" ;;
		handoff)       w handoff "$HANDOFF" ;;
		handoff_guard) w handoff_guard "$GUARD" ;;
		reply_policy)  w reply_policy "$REPLY_POLICY" ;;
		sis_current)   w sis_current "$SIS_CURRENT" ;;
		musched_lite)  w musched_lite "$MUSCHED_LITE" ;;
		handoff_defer) w handoff_defer "$HANDOFF_DEFER" ;;
		defer_window_us) w defer_window_us "$DEFER_WINDOW_US" ;;
		nodrag)        w nodrag "$NODRAG" ;;
		elect_rand)    w elect_rand "$ELECT_RAND" ;;
		elect_cost)    w elect_cost "$ELECT_COST" ;;
		sync_only)     w sync_only 1 ;;
		esac
	done
	[ -e "$CTABS_DIR/reset" ] && w reset 1
	return 0
}

drop_caches() {
	sync
	if [ -w /proc/sys/vm/drop_caches ]; then
		echo 3 > /proc/sys/vm/drop_caches
	else
		su -c 'echo 3 > /proc/sys/vm/drop_caches'
	fi
	sleep 1
}

# Echo "<total_ms> <wait_ms>"; -1 when the am output could not be parsed.
start_app() {
	pkg="$1"
	comp="$pkg"
	case "$pkg" in
	*/*) pkg=${pkg%%/*} ;;
	esac
	am force-stop "$pkg"
	if [ "$CACHE" = cold ]; then
		drop_caches
	else
		sleep 0.5
	fi
	case "$comp" in
	*/*) out=$(am start -W -n "$comp" 2>&1) ;;
	*)   out=$(am start -W -a android.intent.action.MAIN \
			-c android.intent.category.LAUNCHER -p "$pkg" 2>&1) ;;
	esac
	total=$(echo "$out" | sed -n 's/.*TotalTime: *\([0-9][0-9]*\).*/\1/p' | head -1)
	wait=$(echo "$out" | sed -n 's/.*WaitTime: *\([0-9][0-9]*\).*/\1/p' | head -1)
	[ -z "$total" ] && total=-1
	[ -z "$wait" ] && wait=-1
	echo "$total $wait"
}

emit() { # app trial total wait
	[ "$2" -le "$WARMUP" ] && return 0
	log "RESULT,$LABEL,$SCENARIO,$CACHE,$1,$2,$3,$4"
}

load_start() {
	LOAD_PIDS=""
	if command -v stress-ng >/dev/null 2>&1; then
		stress-ng --cpu "$LOAD_PROCS" --timeout 3600 >/dev/null 2>&1 &
		LOAD_PIDS=$!
		LOAD_DESC="stress-ng:$LOAD_PROCS"
		return
	fi
	LOAD_DESC="busy:$LOAD_PROCS"
	i=0
	while [ "$i" -lt "$LOAD_PROCS" ]; do
		i=$((i + 1))
		( while :; do :; done ) &
		LOAD_PIDS="$LOAD_PIDS $!"
	done
}

load_stop() {
	[ -n "${LOAD_PIDS:-}" ] || return 0
	for p in $LOAD_PIDS; do
		kill "$p" 2>/dev/null
	done
	LOAD_PIDS=
}

run_idle() {
	trial=0
	while [ "$trial" -lt "$N" ]; do
		trial=$((trial + 1))
		for app in $APPS; do
			set -- $(start_app "$app")
			emit "$app" "$trial" "$1" "$2"
		done
	done
}

run_concurrent() {
	mkdir -p "$TMP"
	trial=0
	while [ "$trial" -lt "$N" ]; do
		trial=$((trial + 1))
		i=0
		for app in $APPS; do
			pkg=${app%%/*}
			am force-stop "$pkg"
			i=$((i + 1))
		done
		[ "$CACHE" = cold ] && drop_caches || sleep 0.5
		i=0
		for app in $APPS; do
			i=$((i + 1))
			(
				comp="$app"
				case "$comp" in
				*/*) am start -W -n "$comp" >"$TMP/$i.out" 2>&1 ;;
				*) am start -W -a android.intent.action.MAIN \
					-c android.intent.category.LAUNCHER -p "$comp" \
					>"$TMP/$i.out" 2>&1 ;;
				esac
			) &
		done
		wait
		i=0
		for app in $APPS; do
			i=$((i + 1))
			total=$(sed -n 's/.*TotalTime: *\([0-9][0-9]*\).*/\1/p' "$TMP/$i.out" | head -1)
			waitms=$(sed -n 's/.*WaitTime: *\([0-9][0-9]*\).*/\1/p' "$TMP/$i.out" | head -1)
			[ -z "$total" ] && total=-1
			[ -z "$waitms" ] && waitms=-1
			emit "$app" "$trial" "$total" "$waitms"
		done
	done
	rm -rf "$TMP"
}

run_load() {
	load_start
	trap 'load_stop' EXIT INT TERM
	run_idle
	load_stop
}

main() {
	[ -n "$OUT" ] && : > "$OUT"
	setup_knobs
	log "# LABEL=$LABEL MODE=$MODE HANDOFF=$HANDOFF GUARD=$GUARD REPLY_POLICY=$REPLY_POLICY SIS_CURRENT=$SIS_CURRENT MUSCHED_LITE=$MUSCHED_LITE HANDOFF_DEFER=$HANDOFF_DEFER DEFER_WINDOW_US=$DEFER_WINDOW_US NODRAG=$NODRAG ELECT_RAND=$ELECT_RAND ELECT_COST=$ELECT_COST SCENARIO=$SCENARIO CACHE=$CACHE N=$N WARMUP=$WARMUP"
	log "# DATE=$(date) LOAD=${LOAD_DESC:-none} APPS=[$APPS]"
	case "$SCENARIO" in
	idle) run_idle ;;
	concurrent) run_concurrent ;;
	load) run_load ;;
	*) log "# unknown SCENARIO=$SCENARIO"; exit 2 ;;
	esac
	log "# STATS_BEGIN"
	[ -r "$CTABS_DIR/stats" ] && sed 's/^/# /' "$CTABS_DIR/stats" | while read -r l; do log "$l"; done
	log "# STATS_END"
}

main
