# unleash — Quick Reference

Keep this on your SSD alongside the script. CLI is English.

## From Recovery Mode

1. Boot to Recovery (Apple Silicon: hold Power until startup options appear; Intel: Cmd+R)
2. Open Terminal (Utilities → Terminal)
3. Run Unleash:
   `"/Volumes/Macintosh HD - Data/Users/Shared/unleash/unleash" recovery`
   *(or run `./unleash` without arguments and accept the auto-wipe prompt)*
4. Unleash mounts the Data volume, unlocks FileVault if needed, wipes `.cloudConfigRecordFound` and DEP markers, disables 10 enrollment daemons, and can reboot.

USB autorun is `payloads/autorun.sh` → `unleash apply --unattended` (intent sidecar required; no default password).

## Common scenarios

| You want... | Command |
|---|---|
| Wipe DEP and suppress in Recovery (keep existing users) | `./unleash recovery` |
| Apply the same pipeline (hosts + daemons + DEP wipe) | `./unleash apply` |
| Full bypass (create a local admin) | `./unleash bypass --username NAME --password-file FILE` |
| Suppress MDM without creating a user | `./unleash suppress` |
| Repair after a macOS update | `sudo ./unleash heal` |
| Persist heal across reboots | `sudo ./unleash persist` |
| Selective pf block (iCloud-safe) | `sudo ./unleash firewall` |
| Broad Apple `17.0.0.0/8` block (breaks iCloud) | `sudo ./unleash firewall-broad` |
| Check if a wipe will lock the Mac | `sudo ./unleash check` |
| Live-OS process kill (no `profiles -D -F`) | `sudo ./unleash harden` |
| Status (live or Recovery) | `./unleash status` |
| Remove Unleash persist/pf/hosts/overrides | `sudo ./unleash uninstall` |

`uninstall` does **not** restore DEP/ABM or original MDM state.

## Aliases

`rec` = recovery, `wipe` = wipe-dep, `by` = bypass, `sv` = suppress, `fw` = firewall, `wl` = whitelist,
`st` = status, `mn` = monitor (alias of persist), `doc` = doctor, `uni` = uninstall

## Warnings

- **Do not** run `profiles renew` — that re-enrolls MDM
- **Do not** use Erase All Content and Settings — that clears suppression
- After a wipe, run apply/bypass again from Recovery
- Migration Assistant brings MDM back — always run `suppress` afterward
- `profiles -D -F` is not default; pass `--remove-all-profiles` only if you intend to delete every profile
