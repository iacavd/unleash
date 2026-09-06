#!/usr/bin/env bash
# Unleash — Auto-Exec USB AutoRun Payload
# Designed to be launched directly from a USB drive in macOS Recovery or Normal Mode.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
UNLEASH_BIN="$SCRIPT_DIR/unleash"

if [ ! -x "$UNLEASH_BIN" ]; then
  chmod +x "$UNLEASH_BIN" 2>/dev/null || true
fi

echo "=========================================================="
echo " 🚀 UNLEASH AUTOMATED USB AUTORUN PAYLOAD"
echo "=========================================================="
echo ""

# Source detection libraries if available
if [ -f "$SCRIPT_DIR/lib/colors.sh" ]; then source "$SCRIPT_DIR/lib/colors.sh"; fi
if [ -f "$SCRIPT_DIR/lib/detect.sh" ]; then source "$SCRIPT_DIR/lib/detect.sh"; fi

BOOT_MODE="unknown"
if command -v detect_boot_mode >/dev/null 2>&1; then
  BOOT_MODE=$(detect_boot_mode)
fi

echo "Detected Environment Boot Mode: $BOOT_MODE"
echo "Initiating automated deployment sequence..."
echo ""

# Execute non-interactive auto-all mode
if [ -x "$UNLEASH_BIN" ]; then
  "$UNLEASH_BIN" auto-all "$@"
else
  echo "ERROR: Unleash executable not found at $UNLEASH_BIN" >&2
  exit 1
fi
