#!/usr/bin/env bash
# The publication rule, end to end (R6.1, bynk-lang/bynk#2413, decision D): a
# package published here may depend only on what resolves here. Publish a
# dependency's versions, withdraw one and yank another, then upload packages
# whose dependencies don't resolve (an unclaimed organisation, a blocked one,
# an unpublished package, nothing in range, only a withdrawn version in range)
# and check each is `400 unpublishable_dependency`, naming it; and that a
# yanked version in range, and a same-tree retry after its dependency was
# withdrawn, are accepted. It is this service's policy, not the protocol's, so
# the conformance suite doesn't hold it.
#
#   BYNK=<path to bynk> scripts/check-publication.sh
#
# Needs the admission module (scripts/admission-module.sh) and python3.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
bynk="${BYNK:-bynk}"
work="$(mktemp -d)"
trap 'kill "${dev_pid:-}" 2>/dev/null || true; wait "${dev_pid:-}" 2>/dev/null || true; rm -rf "$work"' EXIT
export BYNK_HOME="$work/home"

[[ -f "$here/src/registry/bynk_registry_core.wasm" ]] || {
  echo "the admission module isn't built: run scripts/admission-module.sh" >&2
  exit 1
}

fail() {
  echo "check-publication: $*" >&2
  echo "--- bynk dev log ---" >&2
  tail -60 "$work/dev.log" >&2
  exit 1
}

# 1. An empty registry, and operator tokens: one that publishes and yanks for
# every organisation here, one that can `operate` (to claim them) and one that
# can `withdraw`.
"$bynk" registry init "$work/reg" --id bynk-fixture --key-out "$work/root.key" >/dev/null
public="$("$bynk" registry delegate "$work/reg" --key "$work/root.key" --delegate-out "$work/online.key" 2>&1 | grep -o 'ed25519:[A-Za-z0-9+/=]*' | head -1)"
python3 - "$work/reg/config.json" <<'PY'
import json, sys
p = sys.argv[1]
c = json.load(open(p))
c["api"] = "api"
open(p, "w").write(json.dumps(c, indent=2) + "\n")
PY
publisher="op_publish_$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
operator="op_operate_$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
withdrawer="op_withdraw_$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
tokens="$(python3 - "$publisher" "$operator" "$withdrawer" <<'PY'
import hashlib, json, sys
digest = lambda t: hashlib.sha256(t.encode()).hexdigest()
print(json.dumps([
    {"sha256": digest(sys.argv[1]), "organisations": ["deps", "app", "held", "ghost"], "can": ["publish", "yank"]},
    {"sha256": digest(sys.argv[2]), "organisations": [], "can": ["operate"]},
    {"sha256": digest(sys.argv[3]), "organisations": [], "can": ["withdraw"]},
], separators=(",", ":")))
PY
)"
persist="$work/persist"
(cd "$work" && "$here/seed/seed.sh" "$work/reg" --bucket registry-store-store --local --persist-to "$persist") >/dev/null

rm -f "$work/ready.json"
"$bynk" dev "$here" --ready-json "$work/ready.json" -- \
  --persist-to "$persist" \
  --var "REGISTRY_SIGNING_KEY:$(base64 -w0 <"$work/online.key")" \
  --var "REGISTRY_SIGNING_PUBLIC:$public" \
  --var "REGISTRY_TOKENS:$tokens" \
  >"$work/dev.log" 2>&1 &
dev_pid=$!
for _ in $(seq 1 120); do
  [[ -s "$work/ready.json" ]] && break
  kill -0 "$dev_pid" 2>/dev/null || { cat "$work/dev.log" >&2; exit 1; }
  sleep 1
done
[[ -s "$work/ready.json" ]] || fail "bynk dev never became ready"
url="$(grep -o 'http://[^"]*' "$work/ready.json" | head -1)"

# 2. Claim `deps` and `app`, and `held` blocked, through the operator restore
# (no GitHub needed). `ghost` stays unclaimed.
claim() { # claim <org> <blocked>
  local status
  status="$(curl -s -o "$work/claim.json" -w '%{http_code}' -X PUT "$url/_operator/orgs/$1" \
    -H "authorization: Bearer $operator" -H 'content-type: application/json' \
    --data "{\"name\":\"$1\",\"owner\":{\"id\":1,\"login\":\"ann\"},\"members\":[{\"id\":1,\"login\":\"ann\"}],\"blocked\":$2,\"trusted\":[]}")"
  [[ "$status" == 201 ]] || fail "claiming $1 answered $status: $(cat "$work/claim.json")"
}
claim deps false
claim app false
claim held true

# Pack `<org>/<package>` at `<version>`, depending on `<deps>` (TOML lines for
# `[dependencies]`), without resolving them: the client would refuse what the
# server must be shown refusing. Prints the archive's path.
n=0
pack() { # pack <org/package> <version> [<deps>]
  n=$((n + 1))
  local dir="$work/pkgs/$n" scratch="$work/packs/$n"
  mkdir -p "$dir/src"
  printf '[package]\nname = "%s"\nversion = "%s"\n\n[dependencies]\n%s\n' "$1" "$2" "${3:-}" >"$dir/bynk.toml"
  printf 'commons probe\n\nfn value() -> Int {\n  %s\n}\n' "$n" >"$dir/src/probe.bynk"
  "$bynk" registry init "$scratch" --id scratch --key-out "$work/packs/$n.key" >/dev/null 2>&1
  "$bynk" registry add "$scratch" "$dir" --key "$work/packs/$n.key" >/dev/null 2>&1 || fail "couldn't pack $1 $2"
  find "$scratch/dl/sha256" -type f | head -1
}
put() { # put <org/package> <version> <archive>: the status, body in $work/put.json
  curl -s -o "$work/put.json" -w '%{http_code}' -X PUT "$url/api/$1/$2" \
    -H "authorization: Bearer $publisher" -H 'content-type: application/vnd.bynk.tree-v1' \
    --data-binary "@$3"
}
publish() { # publish <org/package> <version> [<deps>]: expects 201
  local archive status
  archive="$(pack "$1" "$2" "${3:-}")"
  status="$(put "$1" "$2" "$archive")"
  [[ "$status" == 201 ]] || fail "publishing $1 $2 answered $status: $(cat "$work/put.json")"
}
refused() { # refused <what> <org/package> <deps> <expected in the message>
  local archive status
  archive="$(pack "$2" 0.1.0 "$3")"
  status="$(put "$2" 0.1.0 "$archive")"
  [[ "$status" == 400 ]] || fail "$1: expected 400, got $status: $(cat "$work/put.json")"
  python3 - "$work/put.json" "$4" <<'PY' || fail "$1: the refusal is wrong: $(cat "$work/put.json")"
import json, sys
p = json.load(open(sys.argv[1]))
assert p["error"] == "unpublishable_dependency", p
assert sys.argv[2] in p["message"], p
PY
  echo "check-publication: refused, $1"
}
withdraw() { # withdraw <org/package> <version>
  local status
  status="$(curl -s -o "$work/withdraw.json" -w '%{http_code}' -X POST "$url/_operator/withdraw/$1/$2" \
    -H "authorization: Bearer $withdrawer" -H 'content-type: application/json' -d '{"reason":"check-publication"}')"
  [[ "$status" == 200 ]] || fail "withdrawing $1 $2 answered $status: $(cat "$work/withdraw.json")"
}

# 3. The dependency: `deps/lib` 1.0.0 (then yanked), 1.1.0, and 2.0.0 (then
# withdrawn); `deps/other` 1.0.0, which a published package depends on before
# it is withdrawn.
publish deps/lib 1.0.0
publish deps/lib 1.1.0
publish deps/lib 2.0.0
[[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$url/api/deps/lib/1.0.0/yank" -H "authorization: Bearer $publisher")" == 200 ]] ||
  fail "couldn't yank deps/lib 1.0.0"
withdraw deps/lib 2.0.0
publish deps/other 1.0.0

# 4. Each refusal names the dependency and why.
refused "an unclaimed organisation" app/a 'lib = { package = "ghost/lib", version = "^1" }' "no organisation \`ghost\`"
refused "a blocked organisation" app/b 'lib = { package = "held/lib", version = "^1" }' "\`held\` is blocked"
refused "an unpublished package" app/c 'lib = { package = "deps/nothing", version = "^1" }' "\`deps/nothing\` isn't published"
refused "nothing in range" app/d 'lib = { package = "deps/lib", version = "^3" }' "no version of \`deps/lib\` on this registry is in \`^3\`"
refused "only a withdrawn version in range" app/e 'lib = { package = "deps/lib", version = "^2" }' "every version of \`deps/lib\` in \`^2\` was withdrawn"
refused "the first of several that doesn't resolve" app/f \
  "$(printf 'lib = { package = "deps/lib", version = "^1" }\nnope = { package = "deps/nothing", version = "^1" }')" "\`deps/nothing\`"
for p in a b c d e f; do
  [[ "$(curl -s -o /dev/null -w '%{http_code}' "$url/app/$p")" == 404 ]] || fail "a refused upload left app/$p behind"
done

# 5. What passes: a yanked version in range, a live one, and a same-tree retry
# after its dependency was withdrawn (it was admitted once, D10).
publish app/yanked 0.1.0 'lib = { package = "deps/lib", version = "=1.0.0" }'
publish app/live 0.1.0 'lib = { package = "deps/lib", version = "^1.1" }'
echo "check-publication: a yanked version in range resolves, and so does a live one"
retry="$(pack app/retry 0.1.0 'other = { package = "deps/other", version = "^1" }')"
[[ "$(put app/retry 0.1.0 "$retry")" == 201 ]] || fail "app/retry 0.1.0 wasn't published: $(cat "$work/put.json")"
withdraw deps/other 1.0.0
status="$(put app/retry 0.1.0 "$retry")"
[[ "$status" == 200 ]] || fail "a same-tree retry after its dependency was withdrawn answered $status: $(cat "$work/put.json")"
next="$(pack app/retry 0.2.0 'other = { package = "deps/other", version = "^1" }')"
[[ "$(put app/retry 0.2.0 "$next")" == 400 ]] || fail "a new version depending on a withdrawn one was accepted"
echo "check-publication: a same-tree retry passes after its dependency is withdrawn; a new version doesn't"
