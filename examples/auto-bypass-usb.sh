#!/bin/bash
# auto-bypass-usb.sh
# Drop this on an external SSD. Boot to Recovery, run it.
# Intent is I_OWN_THIS_DEVICE next to unleash (or unleash.conf), not a flag.
#
# Usage from Recovery Terminal:
#   chmod +x "/Volumes/YourSSD/auto-bypass-usb.sh"
#   "/Volumes/YourSSD/auto-bypass-usb.sh"

UNLEASH_DIR="$(cd "$(dirname "$0")" && pwd)"
UNLEASH="$UNLEASH_DIR/unleash"

if [ ! -f "$UNLEASH" ]; then
  echo "unleash not found at $UNLEASH"
  echo "Copy the entire unleash/ folder alongside this script."
  exit 1
fi

"$UNLEASH" apply --unattended "$@"
