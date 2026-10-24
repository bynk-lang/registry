#!/usr/bin/env bash
# Install a released toolchain and admission module (R5.3, bynk-lang/bynk#2392;
# R7, bynk-lang/bynk#2415): the `bynk` release's `bynk` and `bynkc` for x86_64
# Linux, and its `bynk_registry_core` module. Nothing is built from source.
#
#   GH_TOKEN=… [ARCHIVE_SHA256=<hex> MODULE_SHA256=<hex>] \
#     scripts/install-release.sh <bynk tag> <bin dir>
#
# The release is `bynk-lang/bynk`'s (BYNK_TOOLCHAIN_REPO overrides it, for a
# fork). Each asset must match its digest: the deploy passes the ones its guard
# read when it checked the tag, so an asset replaced since then fails here; CI
# passes none, and the release's own SHA256SUMS is read now. The binaries go in
# <bin dir> (put it on PATH); the module goes beside the adapter that includes
# it, src/registry/bynk_registry_core.wasm.
set -euo pipefail
tag="$1"
bin="$2"
here="$(cd "$(dirname "$0")/.." && pwd)"
repo="${BYNK_TOOLCHAIN_REPO:-bynk-lang/bynk}"
target=x86_64-unknown-linux-gnu
archive="bynk-$tag-$target.tar.gz"
module="bynk_registry_core-$tag.wasm"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

gh release download "$tag" --repo "$repo" --dir "$work" --pattern "$archive" --pattern "$module" --pattern SHA256SUMS
listed() { # listed <asset>: its digest in the release's SHA256SUMS
  awk -v name="$1" '$2 == name { print $1; found = 1 } END { exit !found }' "$work/SHA256SUMS" || {
    echo "install-release: \`$tag\`'s SHA256SUMS doesn't list \`$1\`" >&2
    exit 1
  }
}
verify() { # verify <asset> <expected digest>
  [[ -f "$work/$1" ]] || { echo "install-release: \`$tag\` has no \`$1\`" >&2; exit 1; }
  local got
  got="$(sha256sum "$work/$1" | cut -d' ' -f1)"
  [[ "$got" == "$2" ]] || {
    echo "install-release: \`$1\` is $got, not the $2 expected" >&2
    exit 1
  }
}
# A refusal inside $(…) exits only the subshell: each is checked here.
archive_sha="${ARCHIVE_SHA256:-}"
[[ -n "$archive_sha" ]] || archive_sha="$(listed "$archive")" || exit 1
module_sha="${MODULE_SHA256:-}"
[[ -n "$module_sha" ]] || module_sha="$(listed "$module")" || exit 1
verify "$archive" "$archive_sha"
verify "$module" "$module_sha"
mkdir -p "$bin"
tar -xzf "$work/$archive" -C "$work"
install -m 0755 "$work/bynk-$tag-$target/bynk" "$work/bynk-$tag-$target/bynkc" "$bin/"
install -m 0644 "$work/$module" "$here/src/registry/bynk_registry_core.wasm"
echo "install-release: bynk $tag and its admission module, checked"
