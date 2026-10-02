#!/bin/bash
# Simulator gate for parallel agents. Only one test run or app session may use
# a simulator at a time, or runs cancel each other out; everything else waits.
#
# Usage (from anywhere in a checkout or worktree):
#   dev/scripts/sim-test.sh <iosN|any> [extra xcodebuild args, e.g. -only-testing:ActualiTests/FooTests]
#     (UI tests only run when named: -only-testing:ActualiUITests/FooUITests)
#   dev/scripts/sim-test.sh run <iosN|any> [driver command...]
#
# Candidates are every available iPhone simulator on iOS major N (e.g. ios18
# for the deployment floor), or on any iOS for `any`; booted ones come first,
# then newest OS, and the first free one wins.
# Test mode builds in one of BUILD_SLOTS (default 3) CPU slots, then holds a
# simulator only for test-without-building.
# Run mode builds Debug, installs, and launches the app with -loadDemoData (a
# fresh demo budget), then runs the driver command with UDID and BUNDLE_ID
# exported, holding the simulator until the driver exits. With no driver the
# simulator is released straight after launch, for handing it to a human.
# Only one invocation per checkout runs at a time, since they share its
# DerivedData.
# Exit codes: xcodebuild's or the driver's own, 2 for bad usage, or 75 if a lock
# didn't free within WAIT seconds (default 420) — just re-run it.
set -u
LOCKROOT=/tmp/actuali-sim-locks
WAIT=${WAIT:-420}
BUILD_SLOTS=${BUILD_SLOTS:-3}
mkdir -p "$LOCKROOT"

mode=test
[ "${1:-}" = run ] && { mode=run; shift; }
want=${1:?usage: sim-test.sh [run] <iosN|any> [xcodebuild args | driver command]}
shift
case $want in
  ios[0-9]* | any) ;;
  *) echo "unknown target $want: use iosN (e.g. ios18) or any" >&2; exit 2 ;;
esac
# "0|1 major udid" per iPhone (0 = booted), sorted booted-first then newest OS.
cands=($(xcrun simctl list devices available | awk -v want="$want" '
  /^-- iOS / { split($3, v, "."); major = v[1]; next }
  /^-- / { major = ""; next }
  major != "" && /iPhone/ && (want == "any" || want == "ios" major) {
    for (i = 1; i <= NF; i++) if ($i ~ /^\([0-9A-F-]+\)$/ && length($i) == 38) udid = substr($i, 2, 36)
    print (/\(Booted\)/ ? 0 : 1), major, udid
  }' | sort -k1,1n -k2,2nr | awk '{ print $3 }'))
[ ${#cands[@]} -gt 0 ] || { echo "no available iPhone simulator for $want (see: xcrun simctl list devices available)" >&2; exit 2; }

cd "$(git rev-parse --show-toplevel)" && [ -d Actuali/Actuali.xcodeproj ] || { echo "run from inside an Actuali checkout" >&2; exit 2; }
# UI tests are skipped (as in CI) unless asked for by name.
skip=-skip-testing:ActualiUITests
if [ $mode = test ]; then
  for a in "$@"; do
    case $a in
      -destination) echo "don't pass -destination: the gate picks and locks the simulator" >&2; exit 2 ;;
      -only-testing:ActualiUITests*) skip= ;;
    esac
  done
fi

LOG=/tmp/actuali-$mode-$(basename "$PWD")-$(date +%Y%m%d-%H%M%S)-$$.log
FILTER='error:|warning: .*(Test|Expectation)|✘|Test .* (failed|recorded an issue)|\*\* (TEST|BUILD|TEST BUILD|TEST EXECUTE) (SUCCEEDED|FAILED) \*\*|Executed [0-9]+ tests|Test run with [0-9]+ tests'
COMMON=(-project Actuali/Actuali.xcodeproj -scheme Actuali)

# Locks are kernel flocks on an open fd (7 worktree, 8 build slot, 9 simulator),
# dropped only once every process holding the fd has exited, so no lock is ever
# stale and nothing needs reaping.
held=""
# Runs a tool with the lock fds closed, inside a subshell that keeps them open
# until the tool exits. Closed because tools leave detached daemons behind
# (xcodebuild → git fsmonitor--daemon) that would inherit the fds and pin the
# locks forever; the subshell means a SIGKILLed wrapper still can't release a
# lock while its xcodebuild or driver runs on.
guarded() { ( "$@" 7>&- 8>&- 9>&-; exit $? ); }
lock_first() { # <fd> <name...>: take the first free name, polling up to WAIT seconds
  local fd=$1 name start
  shift
  start=$(date +%s)
  while :; do
    for name in "$@"; do
      eval "exec $fd>>\"\$LOCKROOT/\$name.lock\""
      if lockf -s -t 0 "$fd"; then
        echo "pid $$ in $PWD" >"$LOCKROOT/$name.owner"
        held=$name
        return 0
      fi
      eval "exec $fd>&-"
    done
    [ $(($(date +%s) - start)) -ge "$WAIT" ] && return 1
    sleep 5
  done
}
busy() { # <what> <name...>
  local what=$1 name
  shift
  echo "$what BUSY for ${WAIT}s (held by: $(for name in "$@"; do cat "$LOCKROOT/$name.owner" 2>/dev/null; done | paste -sd ';' -)). Re-run."
  exit 75
}

wt="worktree${PWD//\//_}"
lock_first 7 "$wt" || busy WORKTREE "$wt"

slots=()
for i in $(seq 1 "$BUILD_SLOTS"); do slots+=("build-$i"); done
lock_first 8 "${slots[@]}" || busy "ALL BUILD SLOTS" "${slots[@]}"
build_dest="platform=iOS Simulator,id=${cands[0]}"
if [ $mode = test ]; then
  echo "build slot $held; build-for-testing → $LOG"
  guarded xcodebuild build-for-testing "${COMMON[@]}" ${skip:+"$skip"} -destination "$build_dest" "$@" >"$LOG" 2>&1
else
  echo "build slot $held; build → $LOG"
  guarded xcodebuild build "${COMMON[@]}" -configuration Debug -destination "$build_dest" >"$LOG" 2>&1
fi
rc=$?
exec 8>&-
grep -E "$FILTER" "$LOG" | tail -40
[ $rc -eq 0 ] || { echo "BUILD FAILED (rc=$rc), full log: $LOG"; exit $rc; }

lock_first 9 "${cands[@]}" || busy SIMULATOR "${cands[@]}"

if [ $mode = test ]; then
  echo "locked simulator $held; testing → $LOG"
  guarded xcodebuild test-without-building "${COMMON[@]}" ${skip:+"$skip"} -destination "platform=iOS Simulator,id=$held" "$@" >>"$LOG" 2>&1
  rc=$?
  grep -E "$FILTER" "$LOG" | tail -60
  echo "xcodebuild rc=$rc on $held, full log: $LOG"
  exit $rc
fi

app=$(guarded xcodebuild -showBuildSettings "${COMMON[@]}" -configuration Debug -destination "$build_dest" 2>>"$LOG" | sed -n 's/^ *BUILT_PRODUCTS_DIR = //p' | head -1)/Actuali.app
export UDID=$held
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist") || { echo "no built app at $app" >&2; exit 1; }
export BUNDLE_ID
echo "locked simulator $UDID; installing $app"
{
  guarded xcrun simctl bootstatus "$UDID" -b &&
    guarded xcrun simctl install "$UDID" "$app" &&
    guarded xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" -loadDemoData
} >>"$LOG" 2>&1 || { tail -20 "$LOG"; echo "INSTALL/LAUNCH FAILED, full log: $LOG"; exit 1; }
echo "launched $BUNDLE_ID with demo data on $UDID"
[ $# -eq 0 ] && { echo "no driver given: simulator released"; exit 0; }
guarded "$@"
rc=$?
echo "driver rc=$rc on $UDID"
exit $rc
