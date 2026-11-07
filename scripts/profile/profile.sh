#!/bin/zsh
# Idle profile of the Release Keyloom.app over the synthetic 1,000-snippet (~1 MiB) library, UI closed.
#
# Usage: scripts/profile/profile.sh [options]
#   --duration SEC       sampling window after settling (default 300 = five quiet minutes)
#   --interval SEC       seconds between samples (default 5)
#   --settle SEC         wait after launch before the window starts (default 15)
#   --short              CI smoke mode: --duration 20 --interval 2 --settle 2. Measures and records, but can
#                        never PASS (FAIL on an over-budget sample, otherwise NOT VERIFIED)
#   --assistance on|off  label only: writing assistance enabled-but-unused vs off (default off)
#   --active-ai          label only: profile of active AI use, kept separate from the idle profiles. The script
#                        does not drive the app; the operator exercises it during the window
#   --sync-state TEXT    label only: sync state of this run, for example off, on-idle, signed-out (default unknown)
#   --fixture-dir DIR    use an existing library (DIR/keyloom.sqlite) instead of generating one
#   --out DIR            report directory (default <repo>/traces/profile/<UTC timestamp>); must be git-ignored
#   --app PATH           profile this Keyloom.app instead of building Release with scripts/build.sh
#   --ui-closed          operator asserts the app shows no window when launched (see below)
#
# Flow: build Release (scripts/build.sh) -> write the fixture via the KeyloomTests XCTest FixtureWriterTests
# (xcodebuild test with TEST_RUNNER_KEYLOOM_FIXTURE_DIR; SyntheticLibrary writes it through the real
# SnippetLibrary/SnippetStore) -> launch the app with `--keyloom-data-dir <fixture>` -> sample physical
# footprint (`footprint`) and CPU time (`ps`) -> write report.json and report.md -> print the verdict.
#
# Budgets: physical footprint <= 50 MiB (max sample); mean CPU < 0.1% over the window.
# Verdict per budget: FAIL when exceeded; PASS only for a full run (duration >= 300 s, not --short) with the
# fixture confirmed open in the app (lsof) and no window on screen (or --ui-closed); otherwise NOT VERIFIED
# with the reason. Overall: FAIL if any FAIL, else NOT VERIFIED if any, else PASS.
# Exit status: 0 PASS, 1 FAIL, 3 NOT VERIFIED, 2 usage or setup error.
#
# NOT VERIFIED until WP4 ships `--keyloom-data-dir`: until then the app ignores the argument, opens its own
# library, and the lsof check marks the fixture as not loaded. Measurements are still recorded.
#
# Recorded: hardware model, chip, memory size, CPU count, macOS version and build, Xcode and SDK versions,
# app version and git commit, the labels above, sample counts, window count. Never recorded: serial number,
# hardware UUID, host or user name, environment variables, snippet content. Paths use ~ for the home folder.
# Same procedure also on macOS 26 and 27 physical Macs: run it once per machine, keep each report.
set -euo pipefail

ROOT="${0:A:h:h:h}"
SCRIPT_DIR="${0:A:h}"
zmodload zsh/datetime

DURATION=300 INTERVAL=5 SETTLE=15 SHORT=0
ASSISTANCE=off ACTIVE_AI=0 SYNC_STATE=unknown UI_CLOSED_ASSERTED=0
FIXTURE="" OUT="" APP=""
FOOTPRINT_BUDGET_MIB=50
CPU_BUDGET_PERCENT=0.1
FULL_RUN_SECONDS=300
PID="" WORK=""

die() { print -u2 "profile: $*"; exit 2 }

cleanup() {
  [[ -n "$PID" ]] && kill "$PID" 2>/dev/null || true
  [[ -n "$WORK" ]] && rm -rf "$WORK"
}
trap cleanup EXIT

number() { [[ "$2" == <-> || "$2" == <->.<-> ]] || die "$1 needs a positive number, got '$2'"; }

while (( $# )); do
  case "$1" in
    --duration) (( $# > 1 )) || die "--duration needs a value"; number --duration "$2"; DURATION="$2"; shift 2 ;;
    --interval) (( $# > 1 )) || die "--interval needs a value"; number --interval "$2"; INTERVAL="$2"; shift 2 ;;
    --settle) (( $# > 1 )) || die "--settle needs a value"; number --settle "$2"; SETTLE="$2"; shift 2 ;;
    --short) SHORT=1; DURATION=20 INTERVAL=2 SETTLE=2; shift ;;
    --assistance) (( $# > 1 )) || die "--assistance needs on or off"; [[ "$2" == (on|off) ]] || die "--assistance needs on or off"; ASSISTANCE="$2"; shift 2 ;;
    --active-ai) ACTIVE_AI=1; shift ;;
    --sync-state) (( $# > 1 )) || die "--sync-state needs a value"; [[ "$2" =~ ^[A-Za-z0-9._-]+$ ]] || die "--sync-state: letters, digits, . _ - only"; SYNC_STATE="$2"; shift 2 ;;
    --fixture-dir) (( $# > 1 )) || die "--fixture-dir needs a value"; FIXTURE="$2"; shift 2 ;;
    --out) (( $# > 1 )) || die "--out needs a value"; OUT="$2"; shift 2 ;;
    --app) (( $# > 1 )) || die "--app needs a value"; APP="$2"; shift 2 ;;
    --ui-closed) UI_CLOSED_ASSERTED=1; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "${0:A}" | sed '$d;s/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done
[[ "$(uname -s)" == Darwin ]] || die "macOS only"
(( INTERVAL > 0 )) || die "--interval must be above 0"

# --- Output directory: must stay out of git (reports describe the machine) -----------------------------------
[[ -n "$OUT" ]] || OUT="$ROOT/traces/profile/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT"
OUT="${OUT:A}"
if [[ "$OUT" == "$ROOT"/* ]] && ! git -C "$ROOT" check-ignore -q -- "$OUT/report.json"; then
  die "output directory is inside the repo but not git-ignored: $OUT"
fi

home_relative() { print -r -- "${1/#$HOME/~}" }

# --- Fixture -------------------------------------------------------------------------------------------------
if [[ -z "$FIXTURE" ]]; then
  FIXTURE="$OUT/fixture"
  print -u2 "profile: writing synthetic fixture to $(home_relative "$FIXTURE")"
  TEST_RUNNER_KEYLOOM_FIXTURE_DIR="$FIXTURE" xcodebuild \
    -project "$ROOT/Keyloom.xcodeproj" -scheme Keyloom -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$ROOT/.derived" \
    test -only-testing:KeyloomTests/FixtureWriterTests >"$OUT/fixture-xcodebuild.log" 2>&1 \
    || die "fixture generation failed, see $(home_relative "$OUT/fixture-xcodebuild.log")"
fi
FIXTURE="${FIXTURE:A}"
[[ -f "$FIXTURE/keyloom.sqlite" ]] || die "no library at $FIXTURE/keyloom.sqlite"

# --- App -----------------------------------------------------------------------------------------------------
if [[ -z "$APP" ]]; then
  APP="$("$ROOT/scripts/build.sh" | tail -n 1)"
fi
APP="${APP:A}"
BINARY="$APP/Contents/MacOS/Keyloom"
[[ -x "$BINARY" ]] || die "no executable at $BINARY"

plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist" 2>/dev/null || print -- "unknown"; }

# --- Helpers -------------------------------------------------------------------------------------------------
# Physical footprint in bytes (and the process peak), from `footprint`'s auxiliary data.
footprint_bytes() { footprint -p "$1" -f bytes --noCategories 2>/dev/null | awk '/^ *phys_footprint:/ { print $2; exit }'; }
footprint_peak_bytes() { footprint -p "$1" -f bytes --noCategories 2>/dev/null | awk '/^ *phys_footprint_peak:/ { print $2; exit }'; }
# Cumulative CPU time in seconds (user + system) from ps's [[hh:]mm:]ss.cc field.
cpu_seconds() { ps -o time= -p "$1" 2>/dev/null | awk '{ n = split($1, p, ":"); s = 0; for (i = 1; i <= n; i++) s = s * 60 + p[i]; printf "%.2f\n", s }'; }
json_string() { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; print -rn -- "\"$s\"" }

# --- Machine (no serial number, hardware UUID, host or user name) --------------------------------------------
HW_MODEL="$(sysctl -n hw.model)"
CHIP="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || print unknown)"
MEMORY_BYTES="$(sysctl -n hw.memsize)"
CPU_COUNT="$(sysctl -n hw.ncpu)"
OS_VERSION="$(sw_vers -productVersion)"
OS_BUILD="$(sw_vers -buildVersion)"
XCODE_VERSION="$(xcodebuild -version 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
SDK_NAME="$(plist DTSDKName)"
APP_VERSION="$(plist CFBundleShortVersionString) ($(plist CFBundleVersion))"
GIT_COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || print unknown)"
MINOS="$(vtool -show-build "$BINARY" 2>/dev/null | awk '/minos/ { print $2; exit }')"
[[ -n "$MINOS" ]] || MINOS=unknown
PROFILE_NAME="idle-assistance-$ASSISTANCE"
(( ACTIVE_AI )) && PROFILE_NAME="active-ai"

# --- Launch --------------------------------------------------------------------------------------------------
"$BINARY" --keyloom-data-dir "$FIXTURE" >/dev/null 2>&1 &
PID=$!
print -u2 "profile: launched pid $PID ($PROFILE_NAME), settling ${SETTLE}s then sampling ${DURATION}s"
sleep "$SETTLE"
kill -0 "$PID" 2>/dev/null || die "app exited during settle"

NOTES=()
FIXTURE_LOADED=0
if lsof -p "$PID" 2>/dev/null | grep -qF "$FIXTURE/keyloom.sqlite"; then
  FIXTURE_LOADED=1
else
  NOTES+=("fixture library is not open in the app: it ignored --keyloom-data-dir (expected until WP4 implements it)")
fi

WINDOWS=unknown
WORK="$(mktemp -d)"
if swiftc -O -o "$WORK/window-count" "$SCRIPT_DIR/window-count.swift" >/dev/null 2>&1; then
  WINDOWS="$("$WORK/window-count" "$PID" 2>/dev/null || print unknown)"
fi
UI_CLOSED=0
if [[ "$WINDOWS" == 0 ]]; then
  UI_CLOSED=1
elif (( UI_CLOSED_ASSERTED )); then
  UI_CLOSED=1
  NOTES+=("UI closed asserted by the operator (--ui-closed); on-screen windows seen: $WINDOWS")
else
  NOTES+=("UI-closed not confirmed: on-screen windows = $WINDOWS (the stub window shows until WP4; pass --ui-closed if the menu-bar app shows none)")
fi

# --- Sample --------------------------------------------------------------------------------------------------
SAMPLES_FILE="$WORK/samples.tsv"   # elapsed-seconds footprint-bytes cpu-seconds
START=$EPOCHREALTIME
APP_EXITED=0
while true; do
  elapsed=$(( EPOCHREALTIME - START ))
  fp="$(footprint_bytes "$PID" || true)"
  cpu="$(cpu_seconds "$PID" || true)"
  if [[ -z "$fp" || -z "$cpu" ]]; then APP_EXITED=1; NOTES+=("app exited after $(printf '%.0f' "$elapsed")s"); break; fi
  printf '%.2f\t%s\t%s\n' "$elapsed" "$fp" "$cpu" >>"$SAMPLES_FILE"
  (( elapsed >= DURATION )) && break
  sleep "$INTERVAL"
done
PEAK_BYTES="$(footprint_peak_bytes "$PID" || true)"
kill "$PID" 2>/dev/null || true
PID=""

# --- Statistics ----------------------------------------------------------------------------------------------
SAMPLE_COUNT=0
[[ -f "$SAMPLES_FILE" ]] && SAMPLE_COUNT="$(wc -l <"$SAMPLES_FILE" | tr -d ' ')"
FP_MEAN=0 FP_P95=0 FP_MAX=0 CPU_MEAN=0 CPU_PEAK=0 WINDOW_SECONDS=0
if (( SAMPLE_COUNT > 0 )); then
  stats=("${(@f)$(awk -F'\t' '
    { t[NR] = $1; f[NR] = $2; c[NR] = $3; sum += $2; if ($2 > max) max = $2 }
    END {
      n = NR; for (i = 1; i <= n; i++) sorted[i] = f[i]
      for (i = 2; i <= n; i++) { v = sorted[i]; j = i - 1; while (j > 0 && sorted[j] > v) { sorted[j + 1] = sorted[j]; j-- } sorted[j + 1] = v }
      rank = int(0.95 * n); if (rank < 0.95 * n) rank++; if (rank < 1) rank = 1
      span = t[n] - t[1]; cpu = span > 0 ? (c[n] - c[1]) / span * 100 : 0
      peak = 0
      for (i = 2; i <= n; i++) { d = t[i] - t[i - 1]; if (d > 0 && (c[i] - c[i - 1]) / d * 100 > peak) peak = (c[i] - c[i - 1]) / d * 100 }
      printf "%.0f\n%.0f\n%.0f\n%.4f\n%.4f\n%.1f\n", sum / n, sorted[rank], max, cpu, peak, span
    }' "$SAMPLES_FILE")}")
  FP_MEAN="${stats[1]}" FP_P95="${stats[2]}" FP_MAX="${stats[3]}" CPU_MEAN="${stats[4]}" CPU_PEAK="${stats[5]}" WINDOW_SECONDS="${stats[6]}"
fi

# --- Verdict -------------------------------------------------------------------------------------------------
FULL_RUN=0
(( ! SHORT )) && (( WINDOW_SECONDS >= FULL_RUN_SECONDS )) && FULL_RUN=1
(( ! FULL_RUN )) && NOTES+=("not a full run: window ${WINDOW_SECONDS}s of ${FULL_RUN_SECONDS}s required, short=$SHORT")

verdict() {   # verdict <over-budget 0|1>
  if (( SAMPLE_COUNT == 0 )); then print "NOT VERIFIED"; return; fi
  if (( $1 )); then print "FAIL"; return; fi
  if (( FULL_RUN && FIXTURE_LOADED && UI_CLOSED && ! APP_EXITED )); then print "PASS"; else print "NOT VERIFIED"; fi
}
FP_BUDGET_BYTES=$(( FOOTPRINT_BUDGET_MIB * 1024 * 1024 ))
FP_OVER=$(( FP_MAX > FP_BUDGET_BYTES ))
CPU_OVER=$(( CPU_MEAN >= CPU_BUDGET_PERCENT ))
FP_VERDICT="$(verdict $FP_OVER)"
CPU_VERDICT="$(verdict $CPU_OVER)"
if [[ "$FP_VERDICT" == FAIL || "$CPU_VERDICT" == FAIL ]]; then OVERALL=FAIL
elif [[ "$FP_VERDICT" == PASS && "$CPU_VERDICT" == PASS ]]; then OVERALL=PASS
else OVERALL="NOT VERIFIED"; fi

# --- Reports -------------------------------------------------------------------------------------------------
FP_MAX_MIB="$(awk -v b="$FP_MAX" 'BEGIN { printf "%.1f", b / 1048576 }')"
FP_MEAN_MIB="$(awk -v b="$FP_MEAN" 'BEGIN { printf "%.1f", b / 1048576 }')"
FP_P95_MIB="$(awk -v b="$FP_P95" 'BEGIN { printf "%.1f", b / 1048576 }')"
FP_PEAK_MIB="$(awk -v b="${PEAK_BYTES:-0}" 'BEGIN { printf "%.1f", b / 1048576 }')"
STARTED_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

notes_json="" first=1
for note in "${NOTES[@]}"; do
  (( first )) || notes_json+=", "
  notes_json+="$(json_string "$note")"; first=0
done

{
  print "{"
  print "  \"profile\": $(json_string "$PROFILE_NAME"),"
  print "  \"verdict\": $(json_string "$OVERALL"),"
  print "  \"recorded_utc\": $(json_string "$STARTED_UTC"),"
  print "  \"labels\": { \"assistance\": $(json_string "$ASSISTANCE"), \"active_ai\": $( (( ACTIVE_AI )) && print true || print false ), \"sync_state\": $(json_string "$SYNC_STATE") },"
  print "  \"hardware\": { \"model\": $(json_string "$HW_MODEL"), \"chip\": $(json_string "$CHIP"), \"memory_bytes\": $MEMORY_BYTES, \"cpu_count\": $CPU_COUNT },"
  print "  \"software\": { \"macos\": $(json_string "$OS_VERSION"), \"macos_build\": $(json_string "$OS_BUILD"), \"xcode\": $(json_string "$XCODE_VERSION"), \"sdk\": $(json_string "$SDK_NAME"), \"binary_minos\": $(json_string "$MINOS") },"
  print "  \"app\": { \"version\": $(json_string "$APP_VERSION"), \"git_commit\": $(json_string "$GIT_COMMIT"), \"path\": $(json_string "$(home_relative "$APP")") },"
  print "  \"fixture\": { \"path\": $(json_string "$(home_relative "$FIXTURE")"), \"loaded_by_app\": $( (( FIXTURE_LOADED )) && print true || print false ) },"
  print "  \"ui\": { \"closed\": $( (( UI_CLOSED )) && print true || print false ), \"onscreen_windows\": $(json_string "$WINDOWS") },"
  print "  \"run\": { \"short\": $( (( SHORT )) && print true || print false ), \"settle_seconds\": $SETTLE, \"interval_seconds\": $INTERVAL, \"window_seconds\": $WINDOW_SECONDS, \"sample_count\": $SAMPLE_COUNT, \"app_exited_early\": $( (( APP_EXITED )) && print true || print false ) },"
  print "  \"footprint_mib\": { \"mean\": $FP_MEAN_MIB, \"p95\": $FP_P95_MIB, \"max\": $FP_MAX_MIB, \"process_peak\": $FP_PEAK_MIB, \"budget\": $FOOTPRINT_BUDGET_MIB, \"verdict\": $(json_string "$FP_VERDICT") },"
  print "  \"cpu_percent\": { \"mean\": $CPU_MEAN, \"peak_interval\": $CPU_PEAK, \"budget_below\": $CPU_BUDGET_PERCENT, \"verdict\": $(json_string "$CPU_VERDICT") },"
  print "  \"notes\": [$notes_json]"
  print "}"
} >"$OUT/report.json"

{
  print "# Keyloom idle profile: $PROFILE_NAME"
  print
  print "**Verdict: $OVERALL** (recorded $STARTED_UTC, $SAMPLE_COUNT samples over ${WINDOW_SECONDS}s, interval ${INTERVAL}s, short=$SHORT)"
  print
  print "| Metric | Result | Budget | Verdict |"
  print "|---|---|---|---|"
  print "| Physical footprint, max | $FP_MAX_MIB MiB (mean $FP_MEAN_MIB, p95 $FP_P95_MIB, process peak $FP_PEAK_MIB) | <= $FOOTPRINT_BUDGET_MIB MiB | $FP_VERDICT |"
  print "| Mean CPU | $CPU_MEAN % (peak interval $CPU_PEAK %) | < $CPU_BUDGET_PERCENT % | $CPU_VERDICT |"
  print
  print -r -- "- Labels: assistance=$ASSISTANCE, active-ai=$( (( ACTIVE_AI )) && print yes || print no ), sync state=$SYNC_STATE"
  print -r -- "- Hardware: $HW_MODEL, $CHIP, $(( MEMORY_BYTES / 1073741824 )) GiB, $CPU_COUNT CPUs"
  print -r -- "- Software: macOS $OS_VERSION ($OS_BUILD), $XCODE_VERSION, SDK $SDK_NAME, binary minos $MINOS"
  print -r -- "- App: $APP_VERSION at commit $GIT_COMMIT"
  print -r -- "- Fixture: 1,000 synthetic snippets (~1 MiB), loaded by the app: $( (( FIXTURE_LOADED )) && print yes || print no )"
  print -r -- "- UI closed: $( (( UI_CLOSED )) && print yes || print no ) (on-screen windows: $WINDOWS)"
  for note in "${NOTES[@]}"; do print -r -- "- Note: $note"; done
} >"$OUT/report.md"

print "profile: $PROFILE_NAME footprint max ${FP_MAX_MIB} MiB (budget ${FOOTPRINT_BUDGET_MIB}): $FP_VERDICT; mean CPU ${CPU_MEAN}% (budget <${CPU_BUDGET_PERCENT}): $CPU_VERDICT"
print "profile: $OVERALL, report in $(home_relative "$OUT")"
for note in "${NOTES[@]}"; do print "profile: note: $note"; done

case "$OVERALL" in
  PASS) exit 0 ;;
  FAIL) exit 1 ;;
  *) exit 3 ;;
esac
