#!/bin/zsh
# Run-to-run variance campaign on the POCO X6 Pro (paper item 3).
# Waits for the device on adb, keeps the screen awake, then runs the
# Sparks tier ladder (fx 1/2/4/8) twice and pulls the perf CSVs.
set -u
ADB=~/Library/Android/sdk/platform-tools/adb
PKG=com.smoketest.snake
DIR=/sdcard/Android/data/$PKG/files
OUT="$(cd "$(dirname "$0")/.." && pwd)/data/device/variance/poco"
mkdir -p "$OUT"
LOG="$OUT/runner.log"
say() { echo "[$(date +%H:%M:%S)] $*" >> "$LOG" }

list_files() { $ADB shell ls $DIR 2>/dev/null | grep -o 'perf_[0-9]*_fx[0-9]*\.csv' }

say "=== POCO variance runner started; waiting for device ==="
polls=0
until $ADB get-state 2>/dev/null | grep -q device; do
  (( polls++ )); (( polls >= 720 )) && { say "gave up after 6 h"; exit 1 }
  sleep 30
done
say "device attached (poll #$polls)"

# keep the screen on while on USB; wake + dismiss keyguard (works if no PIN
# is pending; if the user unlocked once, stayon prevents it from re-locking)
$ADB shell svc power stayon usb
$ADB shell input keyevent 224
$ADB shell wm dismiss-keyguard 2>/dev/null
sleep 2

BASELINE=$(list_files)
say "baseline: $(echo $BASELINE | grep -c .) existing logs"
count=$(list_files | wc -l | tr -d ' ')

run_tier() {  # $1 = tier; returns when the run's CSV lands
  $ADB shell am force-stop $PKG
  sleep 2
  $ADB shell input keyevent 224; $ADB shell wm dismiss-keyguard 2>/dev/null
  $ADB shell am start -n $PKG/.MainActivity --ei fx $1 >/dev/null 2>&1
  say "launched fx$1"
  local waited=0
  while (( waited < 480 )); do
    sleep 15; (( waited += 15 ))
    local now=$(list_files | wc -l | tr -d ' ')
    if (( now > count )); then count=$now; say "run complete ($now logs)"; return 0; fi
  done
  say "TIMEOUT on fx$1"; return 1
}

for ladder in A B; do
  for tier in 1 2 4 8; do
    run_tier $tier || run_tier $tier || { say "fx$tier failed twice, aborting"; exit 1 }
  done
  say "ladder $ladder complete"
done
$ADB shell am force-stop $PKG
$ADB shell svc power stayon false

NEW=$(list_files | grep -Fxv -f <(echo "$BASELINE") || true)
say "pulling $(echo $NEW | grep -c .) new logs"
echo "$NEW" | while read -r f; do
  [[ -z "$f" ]] && continue
  $ADB pull "$DIR/$f" "$OUT/$f" >/dev/null 2>&1 \
    && say "pulled $f" || say "FAILED to pull $f"
done
say "=== done ==="
