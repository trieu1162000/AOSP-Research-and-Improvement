#!/bin/sh
# Apply the final_v2 series (frozen 11 patches + B-arm 0012) on a clean tree
# based at 266f523db5be (android14-6.1.145_r00).
# Canonical order (verified: `git am` clean):
#   0001-0005 -> baselines -> 0006 -> 0007 -> 0008 -> 0012
# Tree of record after 11 patches: 462dc3f163170769211ea644f6d164ddfa7e4985
# Tree of record after 12 patches: 85b746eb39a762507635c70e871481b2be5515a6
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
for p in 0006-*.patch 0007-*.patch 0008-*.patch 0012-*.patch; do
    echo "== apply $p"
    git am "$p"
done
echo "done. Rebuild the kernel; set knobs explicitly per arm (default guard = 11)."
echo "B-arm arm = mode=3,elect_load=1 (sweep token i)."
