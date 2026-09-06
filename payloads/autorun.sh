#!/usr/bin/env bash
# USB autorun. Ownership intent is the sidecar next to unleash, not a flag.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "$ROOT/unleash" apply --unattended "$@"
