#!/bin/zsh
# Per-run finale stats for the run-to-run variance campaign (paper item 3).
# Metric matches Table IV: average frame/GPU ms over finale frames
# (instances > 1500), plus peak instances. Run 1 = the original tier
# ladder in zenodo/data/device; runs 2..N = perf_*_fxN.csv in
# data/device/variance/.
set -u
cd "$(dirname "$0")/.."
stat() {  # $1 = csv, $2 = label
  awk -F, -v lbl="$2" 'NR>1 && $7>1500 {n++; f+=$2; g+=$6; if($7>p)p=$7}
    END{if(n) printf "%-28s frames=%-5d avgFrame=%5.1f  avgGpu=%5.1f  peak=%d\n",
        lbl,n,f/n,g/n,p; else printf "%-28s NO FINALE FRAMES\n",lbl}' "$1"
}
for fx in 1 2 4 8; do
  echo "--- fx$fx ---"
  stat "zenodo/data/device/iphone12_fx$fx.csv" "run1 (original)"
  i=2
  for f in $(ls -1 data/device/variance/perf_*_fx$fx.csv 2>/dev/null | sort); do
    stat "$f" "run$i ($(basename $f))"
    (( i++ ))
  done
done
