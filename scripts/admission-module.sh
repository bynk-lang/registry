#!/usr/bin/env bash
# Install the admission module (bynk-lang/bynk#2336, decision A; R7,
# bynk-lang/bynk#2415, decision C): `bynk-registry-core` as a standalone wasm32
# module, beside the adapter that includes it. The module is never committed
# (src/registry/bynk_registry_core.wasm is git-ignored). By default it is the
# pinned toolchain release's own module, checked against that release's
# SHA256SUMS; run this once after a clone, and again after bumping
# `bynk-toolchain`.
#
#   GH_TOKEN=… scripts/admission-module.sh
#   BYNK_REGISTRY_CORE_SRC=<a bynk-lang/bynk checkout> scripts/admission-module.sh
#
# The second form builds it from source instead, for trying an unreleased change
# to the admission rules (it needs the `wasm32-unknown-unknown` Rust target).
# CI and deploys never use it.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -n "${BYNK_REGISTRY_CORE_SRC:-}" ]]; then
  BYNK_REGISTRY_CORE_OUT_DIR="$here/src/registry" "$BYNK_REGISTRY_CORE_SRC/scripts/build-registry-core.sh"
  exit 0
fi
tag="$("$here/scripts/toolchain.sh")"
repo="${BYNK_TOOLCHAIN_REPO:-bynk-lang/bynk}"
module="bynk_registry_core-$tag.wasm"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
gh release download "$tag" --repo "$repo" --dir "$work" --pattern "$module" --pattern SHA256SUMS
want="$(awk -v name="$module" '$2 == name { print $1; found = 1 } END { exit !found }' "$work/SHA256SUMS")" || {
  echo "admission-module: \`$tag\`'s SHA256SUMS doesn't list \`$module\`" >&2
  exit 1
}
got="$(sha256sum "$work/$module" | cut -d' ' -f1)"
[[ "$got" == "$want" ]] || { echo "admission-module: \`$module\` is $got, not the $want SHA256SUMS lists" >&2; exit 1; }
install -m 0644 "$work/$module" "$here/src/registry/bynk_registry_core.wasm"
echo "admission-module: $module, checked"
