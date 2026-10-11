#!/bin/sh
# Apply the final_v3 series (frozen 11 patches + B-arm 0012/0013/0014) on a
# clean tree based at 266f523db5be (android14-6.1.145_r00).
# Canonical order (verified: `git am` clean on a fresh tree; 0013/0014 also
# verified index-only on the dirty NTFS worktree):
#   0001-0005 -> baselines -> 0006 -> 0007 -> 0008 -> 0012 -> 0013 -> 0014
# Tree of record after 11 patches: 462dc3f163170769211ea644f6d164ddfa7e4985
# Tree of record after 12 patches: 85b746eb39a762507635c70e871481b2be5515a6
# Tree of record after 13 patches: 60e1855f1e5e539530be9906b3ca1ea796b72939
# Tree of record after 14 patches: 2623307fbc69f556c48a7bd2308c8c8d8918b975
set -e
dir=$(dirname "$0")
cd "$dir"
for p in 0001-*.patch 0002-*.patch 0003-*.patch 0004-*.patch 0005-*.patch; do
    echo "== apply $p"
    git am "$p"
done
for p in baselines/0001-*.patch baselines/0002-*.patch baselines/0003-*.patch; do
    echo "== apply $p"
    git am "$p"
done
for p in 0006-*.patch 0007-*.patch 0008-*.patch 0012-*.patch 0013-*.patch 0014-*.patch; do
    echo "== apply $p"
    git am "$p"
done
echo "done. Rebuild the kernel; the handoff_guard knob no longer exists --"
echo "handoff admission is the upstream predicate only (flags + affinity)."
echo "B-arm: mode=3,elect_load in {1,2,3}; elect_load=2 = same-cluster only,"
echo "elect_load=3 = same-cluster + fits (sched_handoff_target_ok())."
