# final_v3 — addendum: patches 0013 (guard strip) and 0014 (elect_load=2/3)

`patches/final_v3/` = `patches/final_v2/` (frozen 11 patches + 0012) + `0013` + `0014`.
Everything copied from final_v2 (0001–0008, baselines, 0012, README.md,
V2_ADDENDUM_0012.md, ctabs-final-v2-combined.patch, ...) is byte-identical; only
`apply.sh` was replaced and this file was added. The copied README/ADDENDUM
still mention `handoff_guard`; **this file supersedes those references** for the
two new patches.

## Commits (branch `sel-b-load2`, based on `sel-b-load` = 4a6ac55)

| # | Commit | Subject | Tree |
|---|---|---|---|
| 13 | `b8fa06bc52f12b0215c0e92c792d8dbeee43699d` | sched: strip the handoff admission guard (upstream predicate only) | `60e1855f1e5e539530be9906b3ca1ea796b72939` |
| 14 | `c1fdc4573b326e2c33fbb006d9e87cbb759685f1` | binder: extend load-aware election (elect_load=2/3) | `2623307fbc69f556c48a7bd2308c8c8d8918b975` |

## What changed

### 0013 — strip the guard (`kernel/sched/fair.c`, `drivers/android/binder.c`)
- `handoff_admit()` is now the upstream predicate only:
  `WF_TTWU|WF_SYNC|WF_CURRENT_CPU` flag set + target CPU in `p->cpus_ptr`.
  The EXITING / OCCUPANCY / FITS / WIDE checks are gone.
- `sched_handoff_local_ok()` (mirror used by the elect_cost arm) is reduced to
  online + affinity, so election feasibility and wake-path admission agree.
- `handoff_guard` is removed entirely: extern declaration, definition,
  `HANDOFF_GUARD_*` bitmask, debugfs knob
  (`/sys/kernel/debug/binder/ctabs/handoff_guard`) and the `stats` line.
- Diffstat: `kernel/sched/fair.c` 13+/63-, `drivers/android/binder.c` 0+/5-.

### 0014 — elect_load=2/3 (`drivers/android/binder.c` only)
- `elect_load=1` unchanged: idle-first scan, any cluster, same-cluster wins ties.
- `elect_load=2`: only idle waiters whose last CPU is in the caller's cluster
  (`topology_cluster_id(wcpu) == caller_cluster`).
- `elect_load=3`: 2 + `sched_handoff_target_ok()` — the binder-visible predicate
  wrapping `task_fits_cpu()` (plus online + affinity). **`task_fits_cpu` itself
  is not callable from binder.c** (static inline in fair.c), so 3 uses the
  existing helper; this keeps 0014 confined to binder.c.
- New counter `elect_load_idle_near` in `stats` and `reset`.
- Diffstat: `drivers/android/binder.c` 31+/5-.

## Apply-test (index-only; Windows NTFS worktree)

`git apply --cached --check` + `git apply --cached` + commit on a temp branch
from `sel-b-load`, then tree-hash compare:

| Step | Tree hash | Result |
|---|---|---|
| before (12 patches, 4a6ac55) | `85b746eb39a762507635c70e871481b2be5515a6` | — |
| +0013 | `60e1855f1e5e539530be9906b3ca1ea796b72939` | == commit tree; `--check` rc 0 |
| +0014 | `2623307fbc69f556c48a7bd2308c8c8d8918b975` | == commit tree; `--check` rc 0 |
| `git diff-tree sel-b-load2 HEAD` | — | empty |

SHA256 of the staging copies:
- `0013-sched-strip-handoff-admission-guard.patch` =
  `3AA301E5493758C4B953705835016CC297E9CC045DD6AF10A66414C436988B52`
- `0014-binder-elect-load-2-3.patch` =
  `CAD52D673A977DD54CF880659260CB04E319B7564FC644497EB5F54FA2B56A5D`

## Verify at build time

- Kernel build **not run here** (no toolchain on this box).
- `scripts/checkpatch.pl` on 0013/0014 (no perl on the Windows box).
- Post-boot `stats` must show `elect_load_idle`, `elect_load_idle_near`,
  `elect_load_used` and **no** `handoff_guard` line; the debugfs knob is gone.
- Scripts that still write `handoff_guard`
  (`scripts/appstart_bench.sh`, `lab/pi/patch_load_arm.py`) must drop that write.
- B-arm on target: `mode=3 elect_load=1|2|3`; compare `elect_load_idle_near`
  share plus p99/throughput against B0/B1/A.
