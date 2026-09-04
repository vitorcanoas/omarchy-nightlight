# Security policy

Omarchy Night Light is a local Omarchy plugin. It runs with the user's session
permissions, reads user configuration, starts user-session processes and sends
commands to `wl-gammarelay-rs` over the user's DBus. It does not provide a
network service.

## Supported versions

Security fixes target the latest release and the current `main` branch. Older
releases may not receive fixes; update to the latest version before reporting a
problem that may already be resolved.

## Reporting a vulnerability

Please do not open a public issue for a suspected vulnerability. Use GitHub's
private vulnerability reporting for this repository when it is available. If
that option is not available, contact the maintainer privately through the
repository owner's GitHub profile before disclosing details publicly.

Include, when safe:

- a clear description of the impact;
- affected version or commit;
- the relevant operating-system and Omarchy versions;
- reproducible steps or a minimal proof of concept;
- any proposed mitigation.

Do not include passwords, access tokens, private configuration or personal data
in a report. Please allow time for triage and a coordinated fix before public
disclosure.

## Scope and limitations

The plugin is intended for a single user's local desktop. Reports involving a
malicious local user, shared runtime directories, symlink races, shell command
construction, DBus/Wayland ownership or persistence files are relevant even if
the impact is limited to the user's session. A report should explain the
required preconditions and whether it affects confidentiality, integrity or
availability.

`wl-gammarelay-rs` and Omarchy are separate projects. Vulnerabilities in those
projects should be reported to their respective maintainers, but integration
impact in this plugin is still useful to document here.
