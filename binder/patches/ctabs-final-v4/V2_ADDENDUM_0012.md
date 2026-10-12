# final_v2 — addendum: patch 0012 (B-arm load-aware election)

`patches/final_v2/` = `patches/final/` (11 patch frozen, **không đổi**) + `0012-binder-load-aware-election.patch`
(staging, đã review độc lập — `results/verify_0012_patch.md`, VERDICT: APPROVED).

## Thứ tự apply

```
0001–0005 → baselines → 0006 → 0007 → 0008 → 0012
```

- Nếu cây build đang ở **v6 (11 patch)** với tree-hash `462dc3f163170769211ea644f6d164ddfa7e4985`:
  chỉ cần `git am 0012-binder-load-aware-election.patch`.
- Tree-hash của series 12 patch (sel-b-load): `85b746eb39a762507635c70e871481b2be5515a6`
  (apply-test index-only đã pass, khớp hash).

## Cái gì mới trong 0012

- Chỉ sửa `drivers/android/binder.c` (+52 dòng).
- Knob mới: `elect_load` (u32, 0644) tại `/sys/kernel/debug/binder/ctabs/elect_load`.
- Counters mới trong `stats`: `elect_load_idle`, `elect_load_used`.
- Logic: trong `vwh_elect_thread()`, chèn nhánh **idle-first** ngay sau nhánh cost và trước same-CPU:
  nếu `elect_load=1`, chọn waiter có `available_idle_cpu(last_cpu)` (ưu tiên cùng cluster; rand-aware
  nếu `elect_rand=1`); nếu không có → rơi xuống same-CPU → cluster → FIFO như cũ. `load_used` đếm ở
  tất cả các nhánh giải quyết (idle/same-CPU/cluster/fallback).

## Arm trên device

| Arm | Knobs | Ý nghĩa |
|---|---|---|
| B0 | `mode=0` | stock FIFO (baseline) |
| B1 | `mode=2,handoff=1,guard=1` | upstream-parity: current-CPU handoff (affinity-only = upstream predicate) |
| A | `mode=3` | naive same-CPU election |
| **B** | `mode=3,elect_load=1` | **B-arm (load-aware, idle-first)** |
| O | `mode=3,elect_rand=1` | order-only (random victim trong tier) |
| P | `mode=3,nodrag=1` | no-drag fallback |
| C | `mode=3,elect_cost=1` | cost (CLE) |

Kỳ vọng (từ kết quả general đã verify, Pi4 bare-metal n=10): **B ≥ max(B0, B1, A)** ở mọi chế độ;
trên target 8 core bận, kỳ vọng B ≈ A (hoặc hơn nếu có core rảnh); counters `elect_load_idle/used`
phải khớp số txn để chứng minh cơ chế. B1 (handoff) là mốc so sánh "upstream-parity" chính.

## Kiểm tra sau build (trên device)

```sh
cat /sys/kernel/debug/binder/ctabs/stats | head -12   # phải thấy elect_load + elect_load_idle/used
echo 1 > /sys/kernel/debug/binder/ctabs/reset
```

## Tham chiếu

- Kết quả general (verified): `docs/e4_decision.md`, `results/pi612/e4_verify.md`
- Review patch 0012: `results/verify_0012_patch.md`
- Lưu ý: `available_idle_cpu()` có sẵn ở 6.1 (`include/linux/sched.h`, EXPORT_SYMBOL_GPL); binder
  built-in nên không cần thêm export.

> Guard standard: `g1` = upstream predicate; các bit thêm (exiting/occupancy/fits) không thêm throughput (claims_sheet 2026-10-08: mh1g1 52,015 vs mh1g9 51,876).
