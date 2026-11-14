#!/bin/zsh
# Turns the screenshots attached by KeyloomUITests into <root>/<journey>/<NN>-<step>-<light|dark>.png (text attachments,
# such as a failure's accessibility tree and the keyboard walk's tab order, become .txt beside them).
# The UI-test runner is sandboxed and cannot write into the repo, so the tests attach (name:
# "<journey>__<NN>-<step>-<light|dark>") and this script exports them from the .xcresult.
# Usage: scripts/export-ui-screenshots.sh <result.xcresult> [root]   (root defaults to $KEYLOOM_SCREENSHOT_DIR, then ./screenshots)
set -euo pipefail

result=${1:?usage: export-ui-screenshots.sh <result.xcresult> [root]}
root=${2:-${KEYLOOM_SCREENSHOT_DIR:-$PWD/screenshots}}
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT

xcrun xcresulttool export attachments --path "$result" --output-path "$staging" > /dev/null

python3 -I - "$staging" "$root" <<'PY'
import json, os, re, shutil, sys

staging, root = sys.argv[1:3]
name_pattern = re.compile(r"^(?P<journey>.+?)__(?P<shot>.+?)_\d+_[0-9A-F-]{36}\.(?P<ext>png|txt)$")
exported = 0
with open(os.path.join(staging, "manifest.json")) as manifest:
    for test in json.load(manifest):
        for attachment in test["attachments"]:
            match = name_pattern.match(attachment["suggestedHumanReadableName"])
            if not match:
                continue
            target = os.path.join(root, match["journey"])
            os.makedirs(target, exist_ok=True)
            shutil.copyfile(os.path.join(staging, attachment["exportedFileName"]), os.path.join(target, match["shot"] + "." + match["ext"]))
            exported += 1
print(f"exported {exported} screenshots to {root}")
PY
