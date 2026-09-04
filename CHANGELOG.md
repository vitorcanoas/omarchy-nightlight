# Changelog

All notable changes to Omarchy Night Light are documented here.

## [Unreleased]

### Fixed

- Harden configuration persistence against symlinks, special files, oversized
  input and concurrent replacement, with bounded atomic writes.
- Bound DBus/process output and terminate the complete CLI process group when a
  panel operation times out.

## [1.0.1] - 2026-09-03

### Fixed

- Keep read-only CLI commands from starting `wl-gammarelay-rs`.
- Drain queued QML operations correctly and retry schedule transitions after a
  failed apply.
- Refuse to use shared predictable `/tmp` lock files and report lock failures.
- Reject extra CLI arguments instead of silently ignoring them.
- Make `qmllint` failures block the quality gate.

### Added

- Add read-only `doctor [--json]`, `status` and `version` commands.
- Add Model.js and CLI smoke tests plus GitHub Actions CI.

### Documentation

- Clarify that `install.sh` is optional and does not install or start the daemon.
- Use the plugin's absolute CLI path in autostart and keybinding examples.
- Document the exact `nightPercent` behaviour for outputs saved at `0%`.
- Add contributor, security-reporting and pull-request guidance.

## [1.0.0] - 2026-09-03

### Added

- Per-monitor colour temperature through `wl-gammarelay-rs`.
- Per-monitor software brightness, pause and clock-based scheduling.
- Omarchy bar widget and command-line interface.
