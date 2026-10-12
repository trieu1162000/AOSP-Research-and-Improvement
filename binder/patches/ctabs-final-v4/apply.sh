#!/bin/sh
# Apply the final_v4 series (frozen 11 patches + B-arm 0012/0013/0014/0015) on a
# clean tree based at 266f523db5be (android14-6.1.145_r00).
# Canonical order (verified: `git am` clean on a fresh tree; 0013/0014/0015 also
# verified index-only on the dirty NTFS worktree):
#   0001-0005 -> baselines -> 0006 -> 0007 -> 0008 -> 0012 -> 0013 -> 0014
#   -> 0015
# Tree of record after 11 patches: 462dc3f163170769211ea644f6d164ddfa7e4985
# Tree of record after 12 patches: 85b746eb39a762507635c70e871481b2be5515a6
# Tree of record after 13 patches: 60e1855f1e5e539530be9906b3ca1ea796b72939
# Tree of record after 14 patches: 725ba6e311b979fe2e8b898860a9e2b1e8e5a0cf
# Tree of record after 15 patches: 11c074ed1eea7b937cd9de32c64465477c10f76f
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
for p in 0006-*.patch 0007-*.patch 0008-*.patch 0012-*.patch 0013-*.patch \
         0014-*.patch 0015-*.patch; do
    echo "== apply $p"
    git am "$p"
done
echo "done. Rebuild the kernel; the handoff_guard knob no longer exists --"
echo "handoff admission is the upstream predicate only (flags + affinity)."
echo "B-arm: mode=3,elect_load in {1,2,3,4}; elect_load=2 = same-cluster only,"
echo "elect_load=3 = same-cluster + fits, elect_load=4 = adaptive cost-aware"
echo "election (EWMA of election-to-run latency, 32768-decision latch window)."
