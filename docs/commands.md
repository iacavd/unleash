---
layout: default
title: Commands Reference — unleash
---

# Commands Reference

Flags go after the command (`./unleash apply --unattended`). CLI is English.

## Bypass & Suppress

| Command | Description | Recovery | Booted |
|---------|-------------|----------|--------|
| `apply` | Apply MDM suppression (hosts + daemons + DEP wipe) | ✓ | ✓ |
| `recovery` | Apply suppression from Recovery (no admin user) | ✓ | ✗ |
| `wipe-dep` | Alias of apply (hosts + daemons + DEP wipe) | ✓ | ✓ |
| `bypass` | Apply and create a local admin | ✓ | ✗ |
| `suppress` | Alias of apply (no admin user) | ✓ | ✓ |
| `heal` | Re-apply suppression after macOS updates | ✓ | ✓ |
| `persist` | Install heal LaunchDaemon (boot + every 300s) | ✓ | ✓ |
| `unpersist` | Remove the heal LaunchDaemon | ✗ | ✓ |
| `auto-all` | Unattended apply (requires intent sidecar) | ✓ | ✓ |

### `apply` / `recovery` / `suppress` / `wipe-dep`
Same pipeline: wipe on-disk `.cloudConfig*` records, disable 10 enrollment daemons, block 14 MDM domains in hosts, persist heal. `wipe-dep` is **not** a hosts-free path.
**`recovery` must run from Recovery.**
```bash
./unleash apply
./unleash recovery
./unleash suppress
./unleash wipe-dep
```

### `bypass`
Creates a local admin (`--username` + `--password-file`; min 8; no default `1234`) and applies suppression.
**Must run from Recovery.**
```bash
./unleash bypass --username NAME --password-file FILE
```

### `heal`
Re-applies suppression after macOS updates re-enable enrollment daemons.
On booted systems, needs sudo. With `persist`, runs automatically on each boot and every 300 seconds.
```bash
sudo ./unleash heal
```

### `persist`
Installs a LaunchDaemon that runs `heal` on every boot and every 300 seconds.
Logs: `/Library/Unleash/logs/heal.log`.
```bash
sudo ./unleash persist
```

### `unpersist`
Removes the persistence LaunchDaemon.
```bash
sudo ./unleash unpersist
```

---

## Firewall & Network

| Command | Description | Privilege |
|---------|-------------|-----------|
| `firewall` | Block resolved MDM IPs via pf (selective, iCloud-safe) | sudo |
| `firewall-broad` | Block Apple's entire `17.0.0.0/8` range (breaks iCloud) | sudo |
| `firewall-off` | Remove pf firewall MDM block | sudo |
| `whitelist` | Alias of `firewall` (same selective engine) | sudo |

### `firewall`
Kernel-level packet filtering. **Selective** — resolves MDM domains to IPs and blocks those.
Default is iCloud/App Store-safe. DoH-proof — cannot be bypassed by DNS-over-HTTPS.
`whitelist` is the same command (one anchor: `com.unleash/mdm`).
```bash
sudo ./unleash firewall
```

### `firewall-broad`
Blocks Apple's entire IP range (`17.0.0.0/8`).
**Warning:** Breaks iCloud, App Store, and system updates. Opt-in only.
```bash
sudo ./unleash firewall-broad
```

### `firewall-off`
Removes pf firewall rules added by `firewall`.
```bash
sudo ./unleash firewall-off
```

### `whitelist`
Alias of `firewall`. Same selective engine, same anchor.
```bash
sudo ./unleash whitelist
```

---

## Live OS

| Command | Description | Privilege |
|---------|-------------|-----------|
| `harden` | Kill MDM processes + flush DNS (`profiles -D -F` only with `--remove-all-profiles`) | sudo |
| `audit` | Alias of `status` (never kills processes) | — |
| `check` | Pre-format / pre-upgrade safety report | sudo |

### `harden`
Kills running MDM processes and flushes DNS cache. Live-OS only (skipped in Recovery).
Does **not** run `profiles -D -F` unless you pass `--remove-all-profiles` (that deletes every profile).
```bash
sudo ./unleash harden
sudo ./unleash harden --remove-all-profiles
```

### `audit`
Alias of `status`. Never kills processes. Risk is LOW / MEDIUM / HIGH / CRITICAL (not 0–100).
```bash
./unleash audit
./unleash status --json
```

### `check`
Returns **SAFE TO FORMAT** (no MDM) or **MDM DETECTED** (will lock after wipe).
```bash
sudo ./unleash check
```

---

## Monitoring

| Command | Description |
|---------|-------------|
| `monitor` | Alias of `persist` (heal daemon) |
| `monitor-install` | Alias of `persist` |
| `monitor-uninstall` | Alias of `unpersist` |

There is no separate KeepAlive watcher and no Discord webhook loop.

```bash
sudo ./unleash persist
sudo ./unleash monitor
```

---

## State Management

| Command | Description |
|---------|-------------|
| `backup` | Save current state (hosts, profiles, launchd, pf.conf) |
| `restore` | Restore from a snapshot (`--snapshot ID`) |
| `backup-list` | List snapshots |
| `dualboot` | Apply to an external macOS install (same pipeline as apply) |
| `uninstall` | Remove Unleash persist, pf anchors, hosts blocks, launchd overrides |

### `backup` / `restore`
```bash
sudo ./unleash backup
sudo ./unleash restore --snapshot ID
sudo ./unleash backup-list
```

### `dualboot`
Same pipeline as `apply`, targeted at an external volume (`--volume`).
```bash
sudo ./unleash dualboot --volume "/Volumes/External - Data"
```

### `uninstall`
Removes Unleash persist, pf anchors, hosts blocks we added, and launchd overrides we set.
Does **not** restore DEP/ABM enrollment or original MDM state. No safety prompts.
```bash
sudo ./unleash uninstall
```

---

## Diagnostics

| Command | Description |
|---------|-------------|
| `doctor` | Pre-flight diagnostics (`--gate` fail-closed) |
| `status` | MDM enrollment status (live and Recovery) |
| `report` | Status report (markdown or `--json`) |
| `config` | Persistent settings |
| `update` | Self-update from GitHub releases |
| `webhook-test` | Optional webhook POST (not used by heal) |

### `doctor`
Checks tools, volume, secrets, disk space. `--gate` exits 0 or 2.
```bash
./unleash doctor
./unleash doctor --gate
```

### `status`
Shows DEP markers, hosts block, daemon overrides, and probes. Works live and from Recovery. Never kills processes.
```bash
./unleash status
./unleash status --json
```

### `report`
```bash
sudo ./unleash report
sudo ./unleash report --json
```

---

## Removed in 2.1

Overlay commands print a one-line "removed" and are not sourced:

`init` `suggest` `remediate` `predict` `telemetry` `discord-bot` `tui` `web` `simulate` `upgrade-os` `vpn-kill` `test` `reinstall` `quarantine` `demo` `history` `history-clear` `fleet-apply` `apns-block` `apns-unblock`

---

## Aliases

```
by  = bypass         sv  = suppress        st  = status
ls  = status         fw  = firewall        fw-off = firewall-off
wl  = whitelist      mn  = monitor (persist)
mn-install = persist mn-uninstall = unpersist
doc = doctor         up  = update          uni = uninstall
wipe = wipe-dep      rec = recovery
```

---

## Options (after the command)

| Option | Effect |
|--------|--------|
| `--unattended` | No prompts (auto-all implies this) |
| `--verbose` | Show debug messages |
| `--dry-run` | Simulate without making changes |
| `--json` | Machine-readable stdout |
| `--log-file <path>` | Write logs to file (appended) |
| `--volume <path>` | Target Data volume |
| `--password-file <f>` | Admin password from file |
| `--remove-all-profiles` | Harden: run `profiles -D -F` (deletes every profile) |
| `--harden` | Live-OS harden during apply |
| `--snapshot <id>` | Restore snapshot ID |
