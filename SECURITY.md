# Security Policy

## Supported Versions

| Version | Supported          |
|---------|--------------------|
| 2.1.x   | Currently supported |
| 2.0.x   | Unsupported |
| 1.x     | Unsupported |

## Reporting a Vulnerability

This tool modifies system configuration to suppress MDM enrollment. While designed to be safe (SSV-safe, reversible via backup/restore), please report any security concerns.

To report a vulnerability:

1. **Do NOT** open a public issue
2. Open a [security advisory](https://github.com/iacavd/unleash/security/advisories) privately
3. Or email the maintainer directly

## Safety Guarantees

- **No system volume writes**: All operations target the Data volume only
- **Reversible**: `unleash backup`/`restore` saves and reverts all changes
- **No data loss by default**: Never runs `profiles renew`. `profiles -D -F` only with `--remove-all-profiles`
- **No ABM modification**: Does not touch Apple Business Manager records

## Known Limitations

- Serial numbers remain in ABM after bypass
- macOS updates may reset suppression (use `unleash heal`)
- Profile enrollment status may still show as active (cosmetic, from SSV)
