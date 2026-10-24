#!/usr/bin/env bash
# The pinned toolchain (R7, bynk-lang/bynk#2415, decision C): the `bynk`
# release this service builds, tests and deploys with, as `bynk-toolchain`
# names it. Bumping it is a one-line PR; that PR's CI is the proof.
#
#   scripts/toolchain.sh [<repository root>]     # prints e.g. v0.403.2
set -euo pipefail
root="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
tag="$(tr -d '[:space:]' < "$root/bynk-toolchain")"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "toolchain: \`bynk-toolchain\` must name one final bynk release (vX.Y.Z), not \`$tag\`" >&2
  exit 1
}
echo "$tag"
