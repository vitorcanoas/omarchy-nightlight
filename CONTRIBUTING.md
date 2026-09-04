# Contributing

Thank you for contributing to Omarchy Night Light. Keep changes focused,
reviewable and compatible with Omarchy 4.

## Before you start

Read the [quick-start README](README.md) and the [complete guide](readme/guide.md),
especially the sections on gamma-control ownership, installation and
development. This plugin runs inside the user's Omarchy shell and its CLI
controls user-session Wayland state, so changes to startup, IPC, persistence or
process handling need extra care.

## Development setup

Install Omarchy 4, Quickshell and `wl-gammarelay-rs`, then add the plugin to
your local Omarchy setup. From the repository root:

```bash
make validate
make lint
```

For local iteration, `make dev` synchronizes the tree into
`~/.config/omarchy/plugins/vitorcanoas.nightlight` and asks the shell to rescan
plugins. Review the value of `PLUGIN_DIR` before using it; the command updates
the installed plugin directory.

Do not edit `/usr/share/omarchy`. Test changes through the user plugin copy and
restore any display state before removing the plugin.

## Changes and commits

- Keep one concern per commit when practical.
- Use concise, imperative commit subjects, for example
  `docs: clarify optional CLI installation`.
- Do not include generated files, local configuration, compiled QML or machine-
  specific screenshots.
- Update the README or changelog when user-visible behaviour or commands
  change.

## Pull requests

Open a pull request against `main` with a short explanation of the problem and
the chosen solution. Include:

- the user-visible impact;
- files and interfaces affected;
- commands used to validate the change;
- Omarchy version and environment details when behaviour depends on them;
- screenshots or terminal output when they make a UI or integration change
  easier to review.

Keep unrelated cleanup out of feature or bug-fix pull requests. Maintainers may
ask for a smaller split if a pull request mixes code, release and documentation
changes.

## Review expectations

Reviewers should check correctness, lifecycle behaviour, compatibility with
Omarchy conventions, user-facing documentation and unintended display changes.
Changes that affect process startup, DBus, file writes or shell integration
should include a focused test or a reproducible manual verification.

## License

By contributing, you agree that your contribution is provided under the
repository's [MIT license](LICENSE).
