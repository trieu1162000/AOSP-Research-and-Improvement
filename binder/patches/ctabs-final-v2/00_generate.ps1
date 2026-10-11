# Regenerate the frozen, artifact-ready patch series from the MEASURED tree
# (ktmp_ctabs sel-b). Produces:
#   final/0001..0005      mechanism (plumbing, admit, election, topology election, ladder)
#   final/0006            BCH deferral (negative result / characterized)
#   final/0007            election v2 experimental arms (nodrag P, random-victim O, cost C; incl. v2.1 fix)
#   final/0008            WF_TARGET_CPU wake-time idle recheck (no-drag race fix)
#   final/baselines/      comparison baselines (SIS-adapt, sched-side extras, MUSched-lite)
#   final/00_VERIFY.txt   contamination scan + SHA256
#   final/BASE.txt        base commit + diffstat
# Usage: powershell -ExecutionPolicy Bypass -File 00_generate.ps1
$ErrorActionPreference = 'Stop'
$tree = 'E:\workspace\aosp_research\ktmp_ctabs'
$base = '266f523db5be'
$fin  = 'E:\workspace\binder-ctabs\patches\final'
$tmp  = Join-Path $fin '_regen'

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $fin, $tmp, (Join-Path $fin 'baselines') -Force | Out-Null
Get-ChildItem $fin -Filter '*.patch' -File | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem (Join-Path $fin 'baselines') -Filter '*.patch' -File | Remove-Item -Force -ErrorAction SilentlyContinue

git -C $tree format-patch --no-numbered --no-signature -o $tmp "$base..HEAD" | Out-Null
$f = Get-ChildItem $tmp -Filter '*.patch' | Sort-Object Name
if ($f.Count -ne 11) { throw "expected 11 patches, got $($f.Count)" }

# tree order: 1 backport, 2 admit, 3 election, 4 topology, 5 ladder,
#             6 SIS, 7 extras, 8 musched, 9 BCH, 10 election-v2(+fix), 11 target-idle recheck
# final mechanism: 0001-0005 = f[0..4], 0006 = BCH = f[8], 0007 = f[9], 0008 = f[10]
for ($i = 0; $i -lt 5; $i++) {
  Copy-Item $f[$i].FullName (Join-Path $fin $f[$i].Name) -Force
}
Copy-Item $f[8].FullName (Join-Path $fin ("0006-{0}" -f ($f[8].Name -replace '^\d{4}-', ''))) -Force
Copy-Item $f[9].FullName (Join-Path $fin ("0007-{0}" -f ($f[9].Name -replace '^\d{4}-', ''))) -Force
Copy-Item $f[10].FullName (Join-Path $fin ("0008-{0}" -f ($f[10].Name -replace '^\d{4}-', ''))) -Force
# baselines: f[5], f[6], f[7] -> baselines/0001-0003
$bn = 1
for ($i = 5; $i -le 7; $i++) {
  $slug = ($f[$i].Name -replace '^\d{4}-', '')
  $dest = Join-Path $fin ("baselines\{0:d4}-{1}" -f $bn, $slug)
  Copy-Item $f[$i].FullName $dest -Force
  $bn++
}

# ---- verification: contamination scan + hashes ----
$verify = Join-Path $fin '00_VERIFY.txt'
"# final series verification, generated $(Get-Date -Format s)" | Out-File -Encoding utf8 $verify
"# scan patterns: 12345 | patch1v15 | normal_prio | %pK | trace_printk | FIXME | XXX-debug" | Out-File -Append -Encoding utf8 $verify
$patterns = '12345|patch1v15|normal_prio|%pK|trace_printk|FIXME|XXX-debug'
$bad = 0
Get-ChildItem $fin -Recurse -Filter '*.patch' | Where-Object { $_.FullName -notmatch '_regen' } | ForEach-Object {
  $hits = Select-String -Path $_.FullName -Pattern $patterns
  if ($hits) {
    $bad++
    "FAIL`t$($_.Name)" | Out-File -Append -Encoding utf8 $verify
    $hits | ForEach-Object { "  $($_.LineNumber): $($_.Line.Trim())" } | Out-File -Append -Encoding utf8 $verify
  } else {
    "OK`t$($_.Name)" | Out-File -Append -Encoding utf8 $verify
  }
  $h = (Get-FileHash $_.FullName -Algorithm SHA256).Hash
  $rel = $_.FullName.Substring($fin.Length + 1)
  "SHA256`t$rel`t$h" | Out-File -Append -Encoding utf8 $verify
}
if ($bad -gt 0) { "RESULT: $bad file(s) with contamination" | Out-File -Append -Encoding utf8 $verify }
else { "RESULT: clean" | Out-File -Append -Encoding utf8 $verify }

# ---- base info ----
$baseinfo = Join-Path $fin 'BASE.txt'
"Final series base: $base (android14-6.1.145_r00)" | Out-File -Encoding utf8 $baseinfo
"Tree of record: $tree (branch sel-b)" | Out-File -Append -Encoding utf8 $baseinfo
"" | Out-File -Append -Encoding utf8 $baseinfo
"git log --oneline $base..HEAD:" | Out-File -Append -Encoding utf8 $baseinfo
git -C $tree log --oneline "$base..HEAD" | Out-File -Append -Encoding utf8 $baseinfo
"" | Out-File -Append -Encoding utf8 $baseinfo
"git diff --stat $base..HEAD:" | Out-File -Append -Encoding utf8 $baseinfo
git -C $tree diff --stat "$base..HEAD" | Out-File -Append -Encoding utf8 $baseinfo

Remove-Item $tmp -Recurse -Force
Get-ChildItem $fin -Recurse -File | Select-Object FullName, Length | Format-Table -AutoSize
Get-Content $verify | Select-Object -First 24
