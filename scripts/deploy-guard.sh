#!/usr/bin/env bash
# The deploy workflow's ref guard (first-party registry R5.3,
# bynk-lang/bynk#2392; track D11, re-targeted by R7, bynk-lang/bynk#2415,
# decision E): production deploys only a published release of this repository,
# from a tag on `main`; a release candidate may go to staging, never to
# production. The toolchain is the `bynk` release that the tag's commit pins in
# `bynk-toolchain`, which must itself be a published, final release.
#
#   scripts/deploy-guard.sh check <tag>
#       Checks the tag's shape, then gathers the facts from GitHub with `gh`
#       (GH_TOKEN; the repository is GITHUB_REPOSITORY, default
#       bynk-lang/registry; the toolchain's is BYNK_TOOLCHAIN_REPO, default
#       bynk-lang/bynk) and decides. Prints, for $GITHUB_OUTPUT:
#         production=true|false   whether the tag may also go to production
#         sha=<commit>            the commit the tag named when checked: the
#                                 jobs deploy this, not the tag, which can move
#         toolchain=<bynk tag>    the `bynk` release that commit pins
#         archive_sha256=<hex>    that release's toolchain archive and
#         module_sha256=<hex>     admission module, as SHA256SUMS listed them
#                                 when checked: a later replaced asset fails
#   scripts/deploy-guard.sh decide <tag> <release> <on-main>
#       The decision alone, on given facts (scripts/test-deploy-guard.sh):
#       <release> is `published`, `prerelease`, `draft` or `missing`;
#       <on-main> is `yes` or `no`.
#   scripts/deploy-guard.sh pinned <bynk tag> <release>
#       Whether a pinned toolchain may be deployed with, on given facts:
#       <release> as above, for the `bynk` release.
#
# A refusal exits 1 and says why on stderr.
set -euo pipefail

target=x86_64-unknown-linux-gnu

refuse() {
  echo "deploy-guard: $*" >&2
  exit 1
}

# `shape <tag>`: `final` or `candidate`, or a refusal.
shape() {
  if [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo final
  elif [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-rc(\.?[0-9]+)?$ ]]; then
    echo candidate
  else
    refuse "\`$1\` isn't a release tag (vX.Y.Z, or vX.Y.Z-rc.N for staging)"
  fi
}

decide() {
  local tag="$1" release="$2" on_main="$3" kind
  kind="$(shape "$tag")" || exit 1
  case "$release" in
    published) ;;
    prerelease) [[ "$kind" == candidate ]] || refuse "\`$tag\`'s release is marked a pre-release, but its tag isn't a candidate" ;;
    draft) refuse "\`$tag\`'s release is still a draft" ;;
    missing) refuse "\`$tag\` has no GitHub release" ;;
    *) refuse "unknown release state \`$release\`" ;;
  esac
  [[ "$on_main" == yes ]] || refuse "\`$tag\` isn't on \`main\` (D11: releases tag main)"
  if [[ "$kind" == candidate ]]; then echo "production=false"; else echo "production=true"; fi
}

# `pinned <bynk tag> <release>`: the pinned toolchain must be a final,
# published `bynk` release: a candidate or a draft is never deployed with.
pinned() {
  local tag="$1" release="$2"
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || refuse "\`bynk-toolchain\` names \`$tag\`, which isn't a final bynk release (vX.Y.Z)"
  [[ "$release" == published ]] || refuse "the pinned toolchain \`$tag\` is $release, not a published bynk release"
}

# `sum <SHA256SUMS file> <asset>`: the asset's listed digest, exactly matched.
sum() {
  awk -v name="$2" '$2 == name { print $1; found = 1 } END { exit !found }' "$1" ||
    refuse "SHA256SUMS doesn't list \`$2\`"
}

check() {
  local tag="$1" repo="${GITHUB_REPOSITORY:-bynk-lang/registry}" tools="${BYNK_TOOLCHAIN_REPO:-bynk-lang/bynk}"
  local release sha status on_main=no sums toolchain toolchain_release
  shape "$tag" >/dev/null || exit 1
  release="$(gh release view "$tag" --repo "$repo" --json isDraft,isPrerelease \
    --jq 'if .isDraft then "draft" elif .isPrerelease then "prerelease" else "published" end' 2>/dev/null)" ||
    release=missing
  # Pin the commit now: everything after is checked, and deployed, by SHA.
  sha="$(gh api "repos/$repo/commits/refs/tags/$tag" --jq .sha 2>/dev/null)" || refuse "no tag \`$tag\`"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || refuse "\`$tag\` didn't resolve to a commit"
  # On main: main is that commit, or ahead of it and behind it by nothing.
  status="$(gh api "repos/$repo/compare/$sha...main" --jq .status 2>/dev/null)" || status=missing
  [[ "$status" == ahead || "$status" == identical ]] && on_main=yes
  decide "$tag" "$release" "$on_main"
  # The toolchain that commit pins, read at the pinned commit, not at the tag.
  toolchain="$(gh api "repos/$repo/contents/bynk-toolchain?ref=$sha" --jq .content 2>/dev/null | base64 -d | tr -d '[:space:]')" ||
    refuse "\`$tag\` has no \`bynk-toolchain\`"
  toolchain_release="$(gh release view "$toolchain" --repo "$tools" --json isDraft,isPrerelease \
    --jq 'if .isDraft then "draft" elif .isPrerelease then "prerelease" else "published" end' 2>/dev/null)" ||
    toolchain_release=missing
  pinned "$toolchain" "$toolchain_release"
  sums="$(mktemp)"
  gh release download "$toolchain" --repo "$tools" --pattern SHA256SUMS --output "$sums" --clobber 2>/dev/null ||
    refuse "the pinned toolchain \`$toolchain\`'s release has no SHA256SUMS"
  # A refusal inside $(…) exits only the subshell: each is checked here.
  local archive module
  archive="$(sum "$sums" "bynk-$toolchain-$target.tar.gz")" || exit 1
  module="$(sum "$sums" "bynk_registry_core-$toolchain.wasm")" || exit 1
  rm -f "$sums"
  echo "sha=$sha"
  echo "toolchain=$toolchain"
  echo "archive_sha256=$archive"
  echo "module_sha256=$module"
}

case "${1:-}" in
  check) [[ $# == 2 ]] || refuse "usage: deploy-guard.sh check <tag>"; check "$2" ;;
  decide) [[ $# == 4 ]] || refuse "usage: deploy-guard.sh decide <tag> <release> <on-main>"; decide "$2" "$3" "$4" ;;
  pinned) [[ $# == 3 ]] || refuse "usage: deploy-guard.sh pinned <bynk tag> <release>"; pinned "$2" "$3" && echo "pinned=ok" ;;
  *) refuse "usage: deploy-guard.sh check <tag> | decide <tag> <release> <on-main> | pinned <bynk tag> <release>" ;;
esac
