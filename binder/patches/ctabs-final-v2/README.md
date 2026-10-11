# final — bộ patch artifact (frozen, clean)

Status: 2026-10-10. Đây là **bộ patch chính thức cho paper/artifact** — 11 patch, tái sinh trực tiếp
từ cây đã đo `E:\workspace\aosp_research\ktmp_ctabs` (branch `sel-b`, HEAD `afc5c09` = + target-idle recheck).
Verify tree-level: `git diff-tree` giữa cây apply-và `sel-b` = rỗng; tree hash khớp byte-for-byte
(`eedb297c…`). Lưu ý: trên Windows, các cặp file đổi hoa–thường (`xt_DSCP.h`/`xt_dscp.h`…) làm
`git status`/`git diff` nhiễu (case-insensitive checkout) — **không phải** sai khác thật.

- **Base**: `266f523db5be` (`android14-6.1.145_r00`)
- **Sinh bởi**: `00_generate.ps1` (`git format-patch --no-numbered --no-signature`)
- **Verify**: `00_VERIFY.txt` — contamination scan (0 hit) + SHA256 từng file. Kết quả: **clean**
- **Provenance**: `BASE.txt` (log + diffstat)

## Cấu trúc

| File | Nội dung | Vai trò |
|---|---|---|
| `0001-sched-backport-current-CPU-wakeup...` | `WF_CURRENT_CPU 0x40` + helper `wake_up_interruptible_sync_on_current_cpu()` + producer Binder (request) + landing counters | enabler / upstream-parity |
| `0002-sched-admit-current-CPU-handoff-requests...` | `handoff_admit()`: affinity bắt buộc; bit exiting/occupancy/fits/wide; knobs | safety envelope |
| `0003-sched-binder-election-aware-Binder-wakeup-VWH-C` | `mode` + election same-CPU (VWH-C) | identity |
| `0004-sched-binder-topology-aware-waiter-election-VWH-C+` | `mode 3`: same-CPU → same-cluster → FIFO | identity + domain |
| `0005-sched-binder-selection-ladder-modes-4-7...` | sticky / MRU / aging / learned | **optional ablation** |
| `0006-sched-binder-defer-two-way-request-wake-until-commit` | **BCH**: defer two-way request wake; commit trong `binder_wait_for_work()` ("about to block"); hrtimer expire `defer_window_us`; cleanup khi thread release; tìm target theo id (không cần ref) | cơ chế cũ (negative result v5) |
| `0007-sched-binder-election-v2-experimental-arms-nodrag-random-cost` | **Election v2 (v2.1)**: **P** no-drag fallback (không có waiter local → wake waiter remote tốt nhất trên CPU của nó qua `WF_TARGET_CPU`, chỉ khi idle+fits), **O** random victim trong tier, **C** lexicographic cost election với local–feasible `sched_handoff_local_ok()` mirror đúng `handoff_admit` (affinity ∧ exiting ∧ fits theo `handoff_guard`, **không idle** — bug bản đầu đã fix sau v6 smoke); counters `nodrag_used/ordinary`, `elect_rand_used`, `elect_cost_used/local/any`; safety fix sticky theo `pid` + MRU stock path | arms thực nghiệm (off by default) |
| `0008-sched-require-an-idle-target-at-wake-time-for-WF_TARGET_CPU` | **No-drag race fix**: `WF_TARGET_CPU` re-check `available_idle_cpu(t)` lúc wake (không chỉ lúc elect); nếu target đã bận → fall through placement thường thay vì xếp wakee sau CPU bận. Lab Pi/KVM đo được P-arm p99 +12 µs, tput −2% khi thiếu check này (mode 2, fallback ~10%) | fix từ lab (tier B) |
| `baselines/0001-sched-adapt-SIS_SHORT-SIS_CURRENT...` | SIS_CURRENT-adapted (eval trước vendor hook/EAS) | baseline SoA |
| `baselines/0002-sched-scheduler-side-handoff-extensions...` | EAS_SYNC / FALLBACK (sched-only) | baseline |
| `baselines/0003-sched-binder-capacity-first-target-selection-MUSched` | MUSched-style capacity-first **approximation** (placement-only; không phải bản faithful) | baseline SoA |

## Apply

```sh
# Canonical order trên cây sạch tại 266f523db5be (đã verify sạch + khớp sel-b):
git am 0001-*.patch 0002-*.patch 0003-*.patch 0004-*.patch 0005-*.patch   # mechanism + ladder
git am baselines/0001-*.patch baselines/0002-*.patch baselines/0003-*.patch  # SoA baselines
git am 0006-*.patch                                                      # BCH — PHẢI áp sau baselines
git am 0007-*.patch                                                      # election v2 (gồm fix v2.1) — sau 0006
git am 0008-*.patch                                                      # WF_TARGET_CPU idle recheck — sau 0007
```

Lý do `0006` áp sau baselines: patch context của BCH dựa trên các dòng `sis_*/musched_lite` (stats,
reset, debugfs) do baselines thêm vào — áp trước sẽ conflict kể cả `git am -3`.

Script: `apply.sh` (đúng thứ tự trên). Full series ⇒ **default `handoff_guard=11`**
(AFFINITY|EXITING|FITS — đúng chủ ý: occupancy tắt vì tốn ~3% w8); các arm phải **set guard tường minh**.

## Mapping arm ↔ patch ↔ knob

Toàn bộ cơ chế **mặc định OFF** (`vwh_handoff=0`, `mode=0`); bật bằng debugfs khi chạy.

| Arm | Patch cần | Knob (`/sys/kernel/debug/binder/ctabs/`) |
|---|---|---|
| `h1g1` upstream-parity | 0001+0002 | `handoff=1 handoff_guard=1` |
| `h1g9` guarded | 0001+0002 | `handoff=1 handoff_guard=9` |
| `2h1g9` election same-CPU | +0003 | `mode=2` |
| `3h1g9` election + domain | +0004 | `mode=3` |
| **BCH** (request-only) | 0001..0004 + 0006 | `handoff=1 mode=2/3 handoff_guard=9 handoff_defer=1 defer_window_us=100` |
| BCH W-sweep | 0006 | `defer_window_us ∈ {0,10,50,200}` (0 = speculative như cũ) |
| BCH counters | 0006 | `stats`: `bch_armed/bch_commit/bch_expire/bch_gone` |
| `h3` — legacy both-direction | 0001 (bit1 reply, **không gating**) | `handoff=3` — **chỉ để tái hiện negative result F5**; cơ chế chính dùng `handoff=1` |
| `p2` / `reply_policy` (RA v2) | ✘ không có trong bộ này (nằm ở `clean/0003`, superseded) | — |
| ladder | +0005 | `mode=4..7`, `age_ms`, `score_*` |
| SIS baseline | +baselines/0001 | `sis_current=1` |
| extras | +baselines/0002 | `/sys/kernel/debug/sched/handoff_extras` |
| MUSched-lite | +baselines/0003 | `musched_lite=1` |
| `n1` — **P** no-drag fallback | +0007 | `nodrag=1` (trên mode 2/3; khi không có waiter local/cluster hợp lệ) |
| `o1` — **O** random victim | +0007 | `elect_rand=1` (random trong tier được chọn; placement giữ nguyên) |
| `c1` — **C** cost election | +0007 | `elect_cost=1`; `n1c1` = no-drag + cost (đúng thứ tự suffix) |
| counters C-arm (v2.1) | +0007 | `stats`: `elect_cost_local`, `elect_cost_any` (cạnh `elect_cost_used`) |

## Những gì **KHÔNG** có trong bộ này (quan trọng)

1. **Reply policy/RA (`reply_policy`) — không có.** Producer reply handoff legacy (bit1, unconditional)
   *có* trong 0001 (`handoff=2/3`) nhưng chỉ là arm tái hiện **negative result F5**; cơ chế chính dùng
   `handoff=1` (request-only). RA v2 (local-only + home-return) chỉ nằm ở `patches/clean/0003`
   (superseded) và archive.
2. **BCH giờ CÓ trong `0006`** (defer → commit/expire/cancel). Bật bằng `handoff=1 handoff_defer=1`
   (`defer_window_us` mặc định 100). Chưa đo — cần build + chạy G0–G2 (`docs/literature_review_v2.md` §7).
   `0006` **phải áp sau baselines** (context dependency, xem mục Apply).
3. **Election v2 (`0007`, gồm fix v2.1) + `0008`** — P/O/C arms là code thực nghiệm (off by default);
   `0007` sau `0006`, `0008` sau `0007`. Sticky safety fix: `vwh_sticky` con trỏ → `vwh_sticky_pid`;
   MRU cập nhật cả stock path.
   - v6 smoke (1 run/arm, bản trước fix) cho thấy **C-arm sai gate local** (đòi idle) ⇒ C tụt −5.5%;
     fix đã gộp trong `0007` (`sched_handoff_local_ok()`), các số c1/n1c1 của v6 **không dùng cho kết luận CLE**.
   - Lab Pi4/QEMU-KVM (2026-10-10, 5 paired run): P-arm thiếu wake-time idle recheck ⇒ **p99 +12 µs
     (39 vs 26), tput −2%** so với drag (mode 2, fallback ~10%); `elect_cost_local` xác nhận fix v2.1.
     `0008` sửa race đó — **cần rerun A/B trên lab rồi mới chốt P**.
3. **CTABS selection-only đời cũ** — chỉ còn dưới dạng các `mode` ablation trong 0003–0005.

## Caveats trước khi dùng số cho paper

- Các số v4 (`m2h3g9p2` = 82,606) có thể được build từ cây trộn `clean+sel` (log v4 readback có
  `reply_policy`) → **bắt buộc re-run trên bộ `final/`** với arm freeze (F1 của red-team).
- `baselines/0001` (SIS) là bản **adapted** (early-return thay vì last-resort gốc);
  `baselines/0003` là **approximation** của MUSched — xem `docs/port_audit_sis_musched.md`.
- **BCH code chưa compile/test trong môi trường tạo patch** (không có toolchain GKI/board): cần build
  arm64 GKI + chạy correctness gate G0 (10^7 txn, random W, signal/freeze/exit/affinity/hotplug,
  KCSAN/lockdep, so wake-count) **trước khi** dùng bất kỳ số BCH nào.
- `checkpatch`: bộ `sel` gốc ghi 0 errors lúc tạo; môi trường hiện tại không có `perl` nên chưa chạy lại
  — chạy `scripts/checkpatch.pl` trước khi submit.
- Single-blind (MobiSys): giữ nguyên author line.

Xem thêm: `patches/README.md` (index toàn bộ patch folders), `docs/literature_review_v2.md` §7 (arms).
