#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
CLI="$ROOT_DIR/bin/omarchy-nightlight"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
FAKE_BUSCTL="$ROOT_DIR/tests/fixtures/busctl"

mkdir -p "$TEST_DIR/home" "$TEST_DIR/config" "$TEST_DIR/runtime" "$TEST_DIR/bin"

run_cli() {
  env -i \
    HOME="$TEST_DIR/home" \
    XDG_CONFIG_HOME="$TEST_DIR/config" \
    XDG_RUNTIME_DIR="$TEST_DIR/runtime" \
    PATH="$TEST_DIR/bin:/usr/bin:/bin" \
    "$CLI" "$@"
}

run_cli_fake_bus_without_runtime() {
  env -i \
    HOME="$TEST_DIR/home" \
    XDG_CONFIG_HOME="$TEST_DIR/config" \
    PATH="$(dirname "$FAKE_BUSCTL"):/usr/bin:/bin" \
    "$CLI" "$@"
}

help_output=$(run_cli --help)
[[ $help_output == *"Usage:"* ]]
[[ $help_output == *"--json"* ]]

json_output=$(run_cli --json --no-start)
printf '%s\n' "$json_output" | node -e '
  let input = ""
  process.stdin.setEncoding("utf8")
  process.stdin.on("data", chunk => { input += chunk })
  process.stdin.on("end", () => {
    const state = JSON.parse(input)
    if (state.daemon !== false) process.exit(1)
    if (!Array.isArray(state.outputs)) process.exit(1)
  })
'

status_output=$(run_cli status)
[[ $status_output == *"wl-gammarelay-rs"* ]]
[[ ! -e "$TEST_DIR/runtime/omarchy-nightlight-$(id -u)" ]]

if doctor_json=$(run_cli doctor --json); then
  :
fi
printf '%s\n' "$doctor_json" | node -e '
  let input = ""
  process.stdin.setEncoding("utf8")
  process.stdin.on("data", chunk => { input += chunk })
  process.stdin.on("end", () => {
    const report = JSON.parse(input)
    if (typeof report.ok !== "boolean") process.exit(1)
    if (!report.checks || typeof report.checks !== "object") process.exit(1)
  })
'

version_json=$(run_cli version --json)
printf '%s\n' "$version_json" | node -e '
  let input = ""
  process.stdin.setEncoding("utf8")
  process.stdin.on("data", chunk => { input += chunk })
  process.stdin.on("end", () => {
    const report = JSON.parse(input)
    if (typeof report.version !== "string" || report.version.length === 0) process.exit(1)
  })
'

if run_cli --no-start status unexpected >"$TEST_DIR/stdout" 2>"$TEST_DIR/stderr"; then
  echo 'status unexpectedly accepted an extra argument' >&2
  exit 1
fi
grep -q 'status accepts no arguments' "$TEST_DIR/stderr"

if run_cli brightness 80 unexpected >"$TEST_DIR/stdout" 2>"$TEST_DIR/stderr"; then
  echo 'brightness unexpectedly accepted an extra argument' >&2
  exit 1
fi
grep -q 'brightness requires exactly one percentage argument' "$TEST_DIR/stderr"

if run_cli --no-start unknown >"$TEST_DIR/stdout" 2>"$TEST_DIR/stderr"; then
  echo 'unknown command unexpectedly succeeded' >&2
  exit 1
fi
grep -q 'omarchy-nightlight:' "$TEST_DIR/stderr"

fallback_lock="/tmp/omarchy-nightlight-$(id -u)"
if [[ ! -e "$fallback_lock" && ! -L "$fallback_lock" ]]; then
  foreign_target="$TEST_DIR/foreign-target"
  : > "$foreign_target"
  ln -s "$foreign_target" "$fallback_lock"
  if run_cli_fake_bus_without_runtime brightness 80 >"$TEST_DIR/stdout" 2>"$TEST_DIR/stderr"; then
    echo 'brightness unexpectedly succeeded through a fallback lock symlink' >&2
    exit 1
  fi
  [[ ! -e "$TEST_DIR/config/omarchy/nightlight.conf" ]]
  unlink "$fallback_lock"
fi

echo 'CLI tests passed'
