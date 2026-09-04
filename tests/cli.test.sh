#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
CLI="$ROOT_DIR/bin/omarchy-nightlight"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
FAKE_BUSCTL="$ROOT_DIR/tests/fixtures/busctl"

mkdir -p "$TEST_DIR/home" "$TEST_DIR/config" "$TEST_DIR/runtime" "$TEST_DIR/bin"
chmod 700 "$TEST_DIR/runtime"

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

run_cli_fake_bus_with_runtime() {
  local runtime=$1
  shift
  env -i \
    HOME="$TEST_DIR/home" \
    XDG_CONFIG_HOME="$TEST_DIR/config" \
    XDG_RUNTIME_DIR="$runtime" \
    FAKE_BUSCTL_NO_DAEMON=1 \
    PATH="$(dirname "$FAKE_BUSCTL"):/usr/bin:/bin" \
    "$CLI" "$@"
}

run_cli_fake_bus() {
  env -i \
    HOME="$TEST_DIR/home" \
    XDG_CONFIG_HOME="$TEST_DIR/config" \
    XDG_RUNTIME_DIR="$TEST_DIR/runtime" \
    PATH="$(dirname "$FAKE_BUSCTL"):/usr/bin:/bin" \
    "$CLI" "$@"
}

run_cli_fake_bus_huge() {
  env -i \
    HOME="$TEST_DIR/home" \
    XDG_CONFIG_HOME="$TEST_DIR/config" \
    XDG_RUNTIME_DIR="$TEST_DIR/runtime" \
    FAKE_BUSCTL_HUGE=1 \
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

config_file="$TEST_DIR/config/omarchy/nightlight.conf"
run_cli_fake_bus brightness 80 >"$TEST_DIR/stdout" 2>"$TEST_DIR/stderr"
grep -q '^DP-2.brightness=80$' "$config_file"

foreign_config_target="$TEST_DIR/config/foreign-target"
printf 'DP-2.brightness=55\n' >"$foreign_config_target"
rm -f "$config_file"
ln -s "$foreign_config_target" "$config_file"
if run_cli_fake_bus brightness 70 >"$TEST_DIR/stdout" 2>"$TEST_DIR/stderr"; then
  echo 'brightness unexpectedly followed a configuration symlink' >&2
  exit 1
fi
[[ -L "$config_file" ]]
grep -q '^DP-2.brightness=55$' "$foreign_config_target"

rm -f "$config_file"
mkfifo "$config_file"
if run_cli_fake_bus brightness 70 >"$TEST_DIR/stdout" 2>"$TEST_DIR/stderr"; then
  echo 'brightness unexpectedly accepted a configuration FIFO' >&2
  exit 1
fi
[[ -p "$config_file" ]]

rm -f "$config_file"
dd if=/dev/zero of="$config_file" bs=1024 count=65 status=none
if run_cli_fake_bus brightness 70 >"$TEST_DIR/stdout" 2>"$TEST_DIR/stderr"; then
  echo 'brightness unexpectedly accepted an oversized configuration' >&2
  exit 1
fi
[[ $(wc -c <"$config_file") -eq $((65 * 1024)) ]]
rm -f "$config_file"

if run_cli_fake_bus_huge --json --no-start >"$TEST_DIR/stdout" 2>"$TEST_DIR/stderr"; then
  echo 'CLI unexpectedly accepted an oversized DBus tree' >&2
  exit 1
fi
grep -q 'safely enumerate' "$TEST_DIR/stderr"

hang_pid_file="$TEST_DIR/hang.pid"
env -i \
  HOME="$TEST_DIR/home" \
  XDG_CONFIG_HOME="$TEST_DIR/config" \
  XDG_RUNTIME_DIR="$TEST_DIR/runtime" \
  FAKE_BUSCTL_HANG=1 \
  FAKE_BUSCTL_HANG_PID="$hang_pid_file" \
  PATH="$(dirname "$FAKE_BUSCTL"):/usr/bin:/bin" \
  "$CLI" --json --no-start >"$TEST_DIR/stdout" 2>"$TEST_DIR/stderr" &
cli_pid=$!
for _ in {1..100}; do
  [[ -s "$hang_pid_file" ]] && break
  sleep 0.02
done
[[ -s "$hang_pid_file" ]]
kill -TERM "$cli_pid" 2>/dev/null || true
wait "$cli_pid" 2>/dev/null || true
hang_pid=$(cat "$hang_pid_file")
if kill -0 "$hang_pid" 2>/dev/null; then
  echo 'CLI supervisor left the DBus child alive after termination' >&2
  exit 1
fi

fallback_runtime="$TEST_DIR/fallback-runtime"
mkdir -p "$fallback_runtime"
chmod 700 "$fallback_runtime"
foreign_target="$TEST_DIR/foreign-target"
: > "$foreign_target"
fallback_lock="$fallback_runtime/omarchy-nightlight.daemon.lock.d"
ln -s "$foreign_target" "$fallback_lock"
if run_cli_fake_bus_with_runtime "$fallback_runtime" brightness 80 >"$TEST_DIR/stdout" 2>"$TEST_DIR/stderr"; then
  echo 'brightness unexpectedly succeeded through a runtime lock symlink' >&2
  exit 1
fi
[[ ! -e "$TEST_DIR/config/omarchy/nightlight.conf" ]]
[[ -L "$fallback_lock" ]]

echo 'CLI tests passed'
