# Helpers for scripts/release/release.sh. Sourced, never executed. Tested by KeyloomTests/Release.

typeset -ga RELEASE_REQUIRED_ENV=(KEYLOOM_SIGN_IDENTITY KEYLOOM_NOTARY_PROFILE)
typeset -g RELEASE_EXPECTED_MINOS=26.0

release_usage() {
  print -r -- "usage: scripts/release/release.sh [--dry-run | --check-env] [--sync-state TEXT] [--help]"
}

# Sets MODE (release, dry-run, check-env, help) and SYNC_STATE. Returns 2 on a usage error.
release_parse_args() {
  MODE=release SYNC_STATE=unknown
  local mode_set=""
  while (( $# )); do
    case "$1" in
      --dry-run|--check-env|--help)
        [[ -z "$mode_set" ]] || { print -u2 "release: $1 conflicts with --$mode_set"; return 2 }
        mode_set="${1#--}"; MODE="$mode_set"; shift ;;
      --sync-state)
        (( $# > 1 )) || { print -u2 "release: --sync-state needs a value"; return 2 }
        [[ "$2" =~ ^[A-Za-z0-9._-]+$ ]] || { print -u2 "release: --sync-state: letters, digits, . _ - only"; return 2 }
        SYNC_STATE="$2"; shift 2 ;;
      *) print -u2 "release: unknown option $1"; release_usage >&2; return 2 ;;
    esac
  done
}

# Prints the names (never values) of required variables that are unset or empty.
release_missing_env() {
  local name
  for name in $RELEASE_REQUIRED_ENV; do
    [[ -n "${(P)name:-}" ]] || print -r -- "$name"
  done
  return 0
}

# Clean means no staged or unstaged change to a tracked file. Untracked files are ignored.
release_tree_is_clean() {
  [[ -e "$1/.git" ]] && git -C "$1" diff --quiet HEAD -- 2>/dev/null
}

# Reads `vtool -show-build` output on stdin, prints the minos value.
release_parse_minos() {
  awk '$1 == "minos" { print $2; found = 1; exit } END { exit !found }'
}

# Prints FAIL if any argument is FAIL, else NOT VERIFIED if any is not PASS, else PASS.
release_overall_verdict() {
  local item verdict=PASS
  for item in "$@"; do
    case "$item" in
      PASS) ;;
      FAIL) print FAIL; return 0 ;;
      *) verdict="NOT VERIFIED" ;;
    esac
  done
  print -r -- "$verdict"
}

# Renders the release evidence (markdown) from EV_* variables. Paths under $HOME are shown as ~. Credentials are
# never read here, so they cannot leak. Publication is a separate manual item and not part of Overall.
release_render_evidence() {
  local overall text
  overall="$(release_overall_verdict "${EV_BUILD_STATUS:-NOT VERIFIED}" "${EV_SIGN_STATUS:-NOT VERIFIED}" \
    "${EV_NOTARY_STATUS:-NOT VERIFIED}" "${EV_STAPLE_STATUS:-NOT VERIFIED}" "${EV_GATEKEEPER_STATUS:-NOT VERIFIED}")"
  text="$(cat <<EOF
# Keyloom release evidence

- Mode: ${EV_MODE:-unknown}
- Git commit: ${EV_GIT_SHA:-unknown} (tracked tree clean)
- Version: ${EV_VERSION:-unknown} (build ${EV_BUILD:-unknown})

## Environment
- macOS: ${EV_MACOS:-unknown} (${EV_MACOS_BUILD:-unknown})
- Xcode: ${EV_XCODE:-unknown}
- SDK: ${EV_SDK:-unknown}
- Hardware: ${EV_HW_MODEL:-unknown}, ${EV_CHIP:-unknown}, ${EV_MEM_GIB:-unknown} GiB
- Sync state: ${EV_SYNC_STATE:-unknown}

## Artifact
- Architecture: ${EV_ARCH:-unknown}
- minos: ${EV_MINOS:-unknown}
- Bundle minimum system version: ${EV_BUNDLE_MIN:-unknown}
- File: ${EV_ARTIFACT:-none (not produced in this mode)}
- SHA256: ${EV_SHA256:-none}

## Verdicts
- Build and artifact checks: ${EV_BUILD_STATUS:-NOT VERIFIED}
- Signing: ${EV_SIGN_STATUS:-NOT VERIFIED}
- Notarization: ${EV_NOTARY_STATUS:-NOT VERIFIED}
- Stapling: ${EV_STAPLE_STATUS:-NOT VERIFIED}
- Gatekeeper: ${EV_GATEKEEPER_STATUS:-NOT VERIFIED}
- Overall: ${overall}
- GitHub release: NOT VERIFIED (manual step, not performed by this script)
EOF
)"
  [[ -z "${HOME:-}" || "$HOME" == / ]] || text="${text//$HOME/~}"
  print -r -- "$text"
}
