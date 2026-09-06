# Changelog

## [2.1.0] — 2026-09-06

Minimum viable autonomy core (MVAC).

### Changed
- Version `2.1.0`. English CLI. Error template: `ERROR <reason>: <what>. <why>. Next: <command>`.
- `harden` no longer runs `profiles -D -F` by default (D17). Opt in with `--remove-all-profiles`.
- `uninstall` is honest: removes Unleash persist, pf anchors, hosts blocks we added, and the 10 launchd labels we disabled. Does not restore DEP/ABM or claim "original state". Deletes `rc.unleash-update.local` (D18).
- Dispatcher sources the Recovery/core set (~15 plus thin aliases). Overlay libs and matching tests moved to `graveyard/`.
- Overlay commands (`init`, `suggest`, `remediate`, `predict`, `telemetry`, `discord-bot`, `tui`, `web`, `simulate`, `upgrade-os`, `vpn-kill`, `test`, `reinstall`, `quarantine`, `demo`, `history`, `fleet-apply`) print a one-line "removed".
- `firewall` is selective (not `17.0.0.0/8`). `firewall-broad` is the aggressive opt-in. Daemon suppress list is 10 labels.
- Docs: README, `docs/commands.md`, `QUICKSTART.md` (English only), `SECURITY.md` (supported 2.1.x).

### Removed
- Overlay modules from the live `lib/` source list (still in `graveyard/` for reference).

## [2.0.0] — 2026-06-20

### Added
- **init** wizard: interactive setup with MA scan, firewall, monitor, persist prompts
- **suggest** command: risk-based recommendations (analyzes system, suggests commands)
- **remediate** command: per-org MDM cleanup (JAMF, Mosyle, Addigy, Kandji, VMware)
- **predict** command: serial number lookup (predicts org enrollment from prefix)
- **telemetry** command: opt-in anonymous usage stats
- **discord-bot** command: Discord DM alerts when MDM is detected
- Jekyll docs config (_config.yml, Gemfile)
- Nix package (default.nix)
- Dockerfile for testing
- GPG signature verification in self-update
- GPG signing script for releases
- Per-command `--help` / `-h` flag
- CircleCI config as free CI alternative
- CI.md with local CI docs

### Changed
- GPG verification added to self-update flow
- Version bumped to 2.0.0

## [1.6.1] — 2026-06-20

### Added
- Per-command `--help` / `-h` flag (`unleash bypass --help`, etc.)
- CI rewritten to use zero-cost actions only (no Docker-based actions)
- LICENSE added to standalone binary header

### Fixed
- demo.svg typo (`xml:place` → `xml:space`) fixed
- wiki/Home.md removed from main repo (belongs in wiki)
- Per-command help integrated into dispatch

## [1.6.0] — 2026-06-20

### Added
- **Homebrew tap**: `brew install iacavd/unleash/unleash`
- **GitHub Pages**: full command reference at https://iacavd.github.io/unleash/
- **README.pt-BR.md**: Brazilian Portuguese translation
- **Bats tests**: doctor, whitelist, config, check, history, uninstall modules
- **docs/index.md**: landing page for GitHub Pages

### Changed
- Version bumped to 1.6.0
- Homebrew formula in separate tap repository

## [1.5.0] — 2026-06-20

### Added
- **report**: Human-readable or JSON-format system audit report
- **demo**: Simulated MDM bypass flow (no real changes)
- **vpn-kill**: pf kill-switch that blocks MDM outside VPN tunnel
- Third-party firewall detection (Little Snitch, LuLu, Radio Silence)

### Fixed
- Migration Assistant artifact cleanup now covers all users

## [1.4.0] — 2026-06-20

### Added
- **doctor**: Pre-flight diagnostics (root, Recovery, libs, disk, dependencies)
- **update**: Self-update from GitHub releases
- **uninstall**: Complete removal with 4 safety prompts
- **reinstall**: Atomic update (uninstall + install)

## [1.3.0] — 2026-06-20

### Added
- **config**: Persistent settings in ~/.unleash.conf
- **test** command / `--dry-run` global flag
- **history / history-clear**: Event log viewer
- Structured logging (levels, timestamps, color, file output)
- CLI aliases for every command

### Changed
- README rewritten (140 → 489 lines) — comprehensive command reference

## [1.2.0] — 2026-06-20

### Added
- **check**: Pre-format / pre-upgrade assessment (will this Mac lock after wipe?)
- **monitor**: Background daemon that watches MDM every 5 minutes and auto-heals
- **monitor-stop**: Stop the background monitor
- **monitor-status**: Check if monitor is running
- GitHub repo About section updated with description and topics

## [1.1.0] — 2026-06-20

### Added
- Project files: CONTRIBUTING.md, CODE_OF_CONDUCT.md, SECURITY.md, CHANGELOG.md
- GitHub issue templates (bug, feature, compatibility)
- GitHub Actions CI (ShellCheck, syntax check, markdown lint)
- Badges and professional README layout

### Changed
- Humanized code: removed AI artifacts, file headers, section comments
- README rewritten from scratch (625 → 140 lines)

## [1.0.0] — 2026-06-20

### Added
- Initial release of unleash — Unified MDM Bypass for macOS
- **bypass**: Full MDM bypass with admin user creation (Recovery mode)
- **suppress**: Suppress MDM enrollment without creating a user
- **heal**: Auto-heal — check and re-apply suppression after macOS updates
- **persist**: Install LaunchDaemon for boot-time auto-heal
- **unpersist**: Remove the persistence LaunchDaemon
- **firewall**: Block Apple MDM IP ranges via pf (DoH-proof)
- **firewall-off**: Remove pf firewall MDM block
- **harden**: Live-OS hardening (kill MDM, remove profiles, flush DNS)
- **audit**: Deep MDM audit (profiles, certs, agents, risk scoring)
- **whitelist**: Selective block (block MDM only, keep iCloud/App Store)
- **backup/restore**: Save and revert all changes
- **dualboot**: Target external or dual-boot volumes
- **status**: MDM status check with deep audit mode
- User-level MDM artifact cleanup (Preferences, Caches, LaunchAgents)
- Expanded domain blocking (13 Apple MDM domains + org MDM host)
- 4 enrollment daemon overrides (launchd disabled.plist)
- Intel T2 and Apple Silicon support
- DFU/IPSW restore guide in documentation
- macOS Tahoe 26.x compatibility
