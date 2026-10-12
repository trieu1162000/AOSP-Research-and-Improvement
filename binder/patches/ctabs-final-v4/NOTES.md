# final_v4 — B-arm bundle: patches 0013/0014 plus 0015 (adaptive elect_load=4)

`patches/final_v4/` = `patches/final_v3/` (frozen 11 patches + 0012 + 0013 +
0014) + `0015` (adaptive cost-aware election) + an updated `apply.sh` + a
regenerated combined patch + this file. Everything copied from final_v3
(0001–0008, baselines, 0012–0014, README.md, V2_ADDENDUM_0012.md,
00_VERIFY.txt, BASE.txt, 00_generate.ps1) is byte-identical; the 0001–0014
patch blobs also match the pushed `ctabs-final-v3` bundle. The stale
`ctabs-final-v3-combined.patch` was **not** copied — the bundle ships only
`ctabs-final-v4-combined.patch` (base `266f523db5be` → 15-patch tree).
The copied README/ADDENDUM still mention `handoff_guard`; **this file
supersedes those references** for 0013–0015.

## Commits (branch `sel-b-load2`)

| # | Commit | Subject | Tree |
|---|---|---|---|
| 13 | `b8fa06bc52f12b0215c0e92c792d8dbeee43699d` | sched: strip the handoff admission guard (upstream predicate only) | `60e1855f1e5e539530be9906b3ca1ea796b72939` |
| 14 | `d64a0b93071ef56787dc837c088c2d96ee9bf097` | binder: extend load-aware election (elect_load=2/3) | `725ba6e311b979fe2e8b898860a9e2b1e8e5a0cf` |
| 15 | `b4a032eaadfc28e040f286e40ac8cc76dd825f61` | binder: adaptive cost-aware wakee election (elect_load=4) | `11c074ed1eea7b937cd9de32c64465477c10f76f` |

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
  existing helper; this keeps the arm confined to binder.c.
- New counter `elect_load_idle_near` in `stats` and `reset`.
- Clusterless kernels (`caller_cluster < 0`): every idle candidate counts as
  near, so 2/3 keep electing instead of vetoing every pick.
- Diffstat: `drivers/android/binder.c` 33+/5-.

### 0015 — adaptive election elect_load=4 (`drivers/android/binder.c`, `drivers/android/binder_internal.h`)
Ported from the 6.12 lab kernel, where the mode was measured and tuned to a
**32768-decision** latch window.

- **Metric** — election-to-run latency. `vwh_take_thread()` records the pick
  class (`vwh_rd_class`: LOCAL = waiter last_cpu == caller, REMOTE otherwise)
  and stamps `vwh_served_ns`; the woken waiter samples
  `ktime_get_ns() - vwh_served_ns` right after `schedule()` in
  `binder_wait_for_work()` (`vwh_note_wakeup()`), dropping deltas >= 10 ms.
  Two 7/8 EWMAs (`ewma_local_ns`, `ewma_remote_ns`) plus sample counts
  (`n_local`, `n_remote`).
- **Probe/latch** — while either class has < 100 samples the election probes
  the lagging class (remote probe: accept any idle CPU; local probe: run the
  same-CPU pick first — a waiter parked on the caller CPU can never be idle,
  measured at ~0.1% of picks in the 6.12 lab). The measured winner is latched
  for `VWH_ADAPT_WINDOW = 32768` decisions: remote if
  `ewma_remote <= ewma_local * 105/100`, else local. Counts and EWMAs are then
  dropped and a fresh balanced probe re-calibrates.
- **Structure** — the same-CPU pick rules (first match, MRU from mode 5,
  random reservoir) moved into `vwh_pick_same_cpu()` so the adaptive "local"
  preference and the ladder below agree. FIFO fallback picks are tagged
  `VWH_RD_CLASS_NONE` so their latency is not charged to an EWMA (their stamp
  still feeds the MRU/nodrag rankings). `elect_load=1/2/3` are unchanged.
- **Counters** (`stats` + `reset`, reset also re-arms the EWMAs):
  `elect_adaptive_spread`, `elect_adaptive_local`, `ewma_local_ns`,
  `ewma_remote_ns`, `n_local`, `n_remote`, `adapt_pref` (-1 = not latched),
  `adapt_used`.
- Diffstat: `drivers/android/binder.c` 290+/37-, `drivers/android/binder_internal.h` 8+/0-.

## Apply-test (index-only; Windows NTFS worktree, re-run 2026-10-12 against final_v4)

`git read-tree 266f523db5be` into a temporary index, then per patch
`git apply --cached --check` (rc 0) + `git apply --cached` + `git write-tree`:

| Step | Tree hash | Result |
|---|---|---|
| after 11 patches | `462dc3f163170769211ea644f6d164ddfa7e4985` | == record |
| +0012 | `85b746eb39a762507635c70e871481b2be5515a6` | == `4a6ac55b` tree |
| +0013 | `60e1855f1e5e539530be9906b3ca1ea796b72939` | == `b8fa06bc` tree |
| +0014 | `725ba6e311b979fe2e8b898860a9e2b1e8e5a0cf` | == `d64a0b93` tree |
| +0015 | `11c074ed1eea7b937cd9de32c64465477c10f76f` | == `b4a032ea` tree; `--check` rc 0 |
| combined on 266f523 | `11c074ed1eea7b937cd9de32c64465477c10f76f` | == 15p tree |
| `git diff 11c074ed <write-tree>` | — | empty |

Note: final_v3's `apply.sh` recorded the 14-patch tree as
`725ba6e3bc69f556c48a7bd2308c8c8d8918b975` (transcription error); the actual
tree of `d64a0b93` and of the 14-patch index is
`725ba6e311b979fe2e8b898860a9e2b1e8e5a0cf`, which v4 uses.

SHA256 of the staging copies:
- `0015-binder-adaptive-election.patch` =
  `18584D2F15B12D5552BB5BE2494622EC13748AE6C3CDE5AF9A5D827CF0AA0585`
- `ctabs-final-v4-combined.patch` =
  `A4E78454FF66838BA55779958DA2A7AB8B297FCEDD602A5F8323E79DE11F4472`
- `0013`/`0014` unchanged from final_v3:
  `3AA301E5…`/`CEA951A7…` (see final_v3/00_VERIFY.txt and this bundle).

## Verify at build time

- Kernel build **not run here** (no toolchain on this box).
- `scripts/checkpatch.pl` on 0015 (no perl on the Windows box).
- Post-boot `stats` must show `elect_adaptive_spread`, `elect_adaptive_local`,
  `ewma_local_ns`, `ewma_remote_ns`, `n_local`, `n_remote`, `adapt_pref`,
  `adapt_used` (plus the existing 0012–0014 lines; **no** `handoff_guard`).
- `reset` must zero those counters and re-arm the EWMAs
  (`n_local == n_remote == 0`, `adapt_pref == -1`).
- B-arm on target: `mode=3`; compare `elect_load=1|2|3` against `elect_load=4`
  (expect `adapt_pref` to latch, `adapt_used` to cycle 0..32767, and the
  probe phases to be rare: two counts of 100 per latch window + re-probe).
- Watch `ewma_local_ns`/`ewma_remote_ns` right after a fresh `reset` while
  `elect_load=4`: both classes must pass 100 samples before `adapt_pref`
  leaves -1.
