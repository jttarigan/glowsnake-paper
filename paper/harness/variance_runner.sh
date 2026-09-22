#!/bin/zsh
# Run-to-run variance campaign on the iPhone 12 (paper item 3).
# Polls until the phone is unlocked, then runs the full Sparks tier ladder
# (fx 1/2/4/8) TWICE back-to-back and pulls the perf CSVs. The app stamps
# each log perf_<unixtime>_fxN.csv, so runs never clobber each other.
set -u
DEV=<DEVICE_UDID>   # xcrun devicectl list devices
BID=com.smoketest.snake
OUT="$(cd "$(dirname "$0")/.." && pwd)/data/device/variance"
mkdir -p "$OUT"
LOG="$OUT/runner.log"
say() { echo "[$(date +%H:%M:%S)] $*" >> "$LOG" }

list_files() {
  xcrun devicectl device info files --device $DEV \
    --domain-type appDataContainer --domain-identifier $BID \
    --subdirectory Documents 2>/dev/null | grep -o 'perf_[0-9]*_fx[0-9]*\.csv'
}

launch_tier() {  # $1 = fx tier; retries until success or 20 min elapse
  local tries=0
  while (( tries < 20 )); do
    if xcrun devicectl device process launch --terminate-existing \
         --device $DEV $BID -- -fxScale $1 >/dev/null 2>&1; then
      say "launched fx$1"; return 0
    fi
    (( tries++ )); sleep 60
  done
  say "GAVE UP launching fx$1 (phone locked for 20 min mid-ladder)"; return 1
}

wait_run_done() {  # waits until the file count grows past $1; timeout 8 min
  local before=$1 waited=0
  while (( waited < 480 )); do
    sleep 15; (( waited += 15 ))
    local now=$(list_files | wc -l | tr -d ' ')
    if (( now > before )); then say "run complete ($now logs on device)"; return 0; fi
  done
  say "TIMEOUT waiting for run to finish"; return 1
}

say "=== variance runner started; polling for unlock ==="
BASELINE=$(list_files)
say "baseline: $(echo $BASELINE | wc -l | tr -d ' ') existing logs"

# Phase 1: poll until the phone is unlocked (first successful launch = ladder start)
polls=0
until xcrun devicectl device process launch --terminate-existing \
        --device $DEV $BID -- -fxScale 1 >/dev/null 2>&1; do
  (( polls++ ))
  if (( polls >= 240 )); then say "gave up after 6 h of polling"; exit 1; fi
  sleep 90
done
say "phone unlocked — ladder A fx1 launched (poll #$polls)"

# Phase 2: ladders (default "A B"; pass e.g. "B" to run one); fx1 of the
# first ladder is already running from the unlock poll
count=$(list_files | wc -l | tr -d ' ')
first=1
for ladder in ${LADDERS:-A B}; do
  for tier in 1 2 4 8; do
    if (( first )); then first=0; else
      launch_tier $tier || exit 1
    fi
    if ! wait_run_done $count; then
      # a played/stalled run: relaunch this tier once and wait again
      say "retrying fx$tier after timeout"
      launch_tier $tier || exit 1
      wait_run_done $count || exit 1
    fi
    count=$(list_files | wc -l | tr -d ' ')
  done
  say "ladder $ladder complete"
done
xcrun devicectl device process terminate --device $DEV $BID >/dev/null 2>&1 || true

# Phase 3: pull every log that wasn't in the baseline
NEW=$(list_files | grep -Fxv -f <(echo "$BASELINE") || true)
say "pulling $(echo $NEW | grep -c . ) new logs"
echo "$NEW" | while read -r f; do
  [[ -z "$f" ]] && continue
  xcrun devicectl device copy from --device $DEV \
    --domain-type appDataContainer --domain-identifier $BID \
    --source "Documents/$f" --destination "$OUT/$f" >/dev/null 2>&1 \
    && say "pulled $f" || say "FAILED to pull $f"
done
say "=== done ==="
