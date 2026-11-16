#!/usr/bin/env bash
# Configure and deploy one environment of the registry from a maintainer's
# machine, end to end (R6, bynk-lang/bynk#2413): the first deploy of each
# environment is local (see README, "Deploying"), and this script is that
# deploy.
#
#   scripts/go-live.sh staging            # or: production
#   scripts/go-live.sh staging --plan     # everything up to the deploy plan; changes nothing remote
#   scripts/go-live.sh staging --only verify,orgs
#
# Every key, token and setting is generated once into a state directory
# outside the repository (`~/.bynk-registry/<env>`, mode 0700) and reused on
# every later run. The Worker's secrets and the GitHub environment's secrets
# are both written from those files, never typed or pasted, and each copy is
# checked after it is written. Every phase can be run again: a rerun repairs,
# it doesn't duplicate.
#
# Phases, in order (`--only` takes a comma-separated subset):
#
#   toolchain    the pinned `bynk` (bynk-toolchain) for this machine, and its
#                admission module, each checked against the release's SHA256SUMS
#   keys         the registry directory, its root key and online delegate;
#                in production, the probe package the read checks verify
#   tokens       the operator and conformance tokens, and REGISTRY_TOKENS
#   deploy       the deploy plan, then `bynk deploy --force` with every secret
#   seed         the registry directory into the bucket, then reads it back
#   verify       the live Worker accepts the operator token (REGISTRY_TOKENS parsed)
#   orgs         claims the conformance (staging) or probe (production)
#                organisation; in staging, registers the trusted publisher
#   conformance  staging: a full conformance run; production: the read checks
#   github       the GitHub environment's secrets and variables, read back
#
# It never commits, tags, releases or dispatches: the summary at the end says
# what to do next.
#
# Needs: bash, curl, python3, node/npx, gh (signed in). Runs on macOS (the
# system bash 3.2 included) and Linux.
set -euo pipefail
umask 077

here="$(cd "$(dirname "$0")/.." && pwd)"
repo_slug="bynk-lang/registry"
all_phases="toolchain keys tokens deploy seed verify orgs conformance github"

usage() {
  sed -n '6,9p' "$0" | sed 's/^# \{0,1\}//' >&2
  echo "options: --plan, --only <phases>, --yes (no confirmation before deploying), --state <dir>," >&2
  echo "         --url <origin> (another origin, such as a local \`bynk dev\`, for verify/orgs/conformance)" >&2
  echo "phases: $all_phases" >&2
  exit 2
}

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok() { printf '   ok  %s\n' "$*"; }
note() { printf '   ..  %s\n' "$*"; }
die() { printf '\n\033[31mgo-live: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Arguments.

[[ $# -ge 1 ]] || usage
env_name="$1"; shift
case "$env_name" in
  staging|production) ;;
  *) usage ;;
esac
plan=0; yes=0; only=""; url_override=""; state_root="${BYNK_REGISTRY_STATE:-$HOME/.bynk-registry}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan) plan=1; shift ;;
    --yes) yes=1; shift ;;
    --only) [[ $# -ge 2 ]] || usage; only="$2"; shift 2 ;;
    --state) [[ $# -ge 2 ]] || usage; state_root="$2"; shift 2 ;;
    --url) [[ $# -ge 2 ]] || usage; url_override="$2"; shift 2 ;;
    *) usage ;;
  esac
done
for p in $(tr ',' ' ' <<<"$only"); do
  [[ " $all_phases " == *" $p "* ]] || die "no phase \`$p\` (phases: $all_phases)"
done
wants() { [[ -z "$only" || ",$only," == *",$1,"* ]]; }

state="$state_root/$env_name"
mkdir -p "$state/tokens"
chmod 700 "$state_root" "$state" "$state/tokens"
settings="$state/settings"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

[[ -z "${CI:-}" ]] || die "this is the maintainer's local deploy; \`CI\` is set, and bynk refuses to record new ids under CI"

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
# A file's contents as one line of base64 (macOS `base64` has no `-w0`).
b64() { base64 <"$1" | tr -d '\n'; }

# ---------------------------------------------------------------------------
# Settings: asked once, kept in $state/settings. Nothing here is a secret.

setting() { # setting <NAME>: its value, or empty
  [[ -f "$settings" ]] || return 0
  awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$settings"
}
ask() { # ask <NAME> <question> [default]: a setting, asked for once
  local name="$1" question="$2" default="${3:-}" value
  value="$(setting "$name")"
  if [[ -z "$value" ]]; then
    [[ -t 0 ]] || die "setting $name isn't in $settings, and there's no terminal to ask"
    if [[ -n "$default" ]]; then
      read -r -p "   ?   $question [$default]: " value
      value="${value:-$default}"
    else
      while [[ -z "$value" ]]; do read -r -p "   ?   $question: " value; done
    fi
    [[ "$value" != *$'\n'* && "$value" != *=* ]] || die "a $name can't contain \`=\` or a newline"
    printf '%s=%s\n' "$name" "$value" >>"$settings"
  fi
  printf '%s' "$value"
}
secret_file() { # secret_file <file> <question> <optional 0|1>: a secret, asked for once, never echoed
  local file="$state/$1" value=""
  if [[ ! -s "$file" ]]; then
    [[ -t 0 ]] || die "$file is missing, and there's no terminal to ask"
    read -r -s -p "   ?   $2: " value; echo >&2
    [[ -n "$value" || "$3" == 1 ]] || die "$1 is required"
    printf '%s' "$value" >"$file"
  fi
  tr -d '\r\n' <"$file"
}

say "Settings for $env_name ($settings)"
if [[ $env_name == staging ]]; then default_host=registry-staging.bynk-lang.dev; default_id="bynk-lang-staging"
else default_host=registry.bynk-lang.dev; default_id="bynk-lang"; fi
account_id="$(ask CLOUDFLARE_ACCOUNT_ID "Cloudflare account id")"
host="$(ask HOST "The registry's hostname (its custom domain)" "$default_host")"
registry_id="$(ask REGISTRY_ID "The registry's id (bound into every signed line)" "$default_id")"
client_id="$(ask GITHUB_CLIENT_ID "The client id of $env_name's GitHub OAuth app (device flow)")"
owner="$(ask OWNER "Your GitHub login (the owner of the organisations claimed below)" "$(gh api user -q .login 2>/dev/null || true)")"
repository="$(ask REPOSITORY "The repository whose deploy workflow publishes conformance packages" "$repo_slug")"
if [[ $env_name == staging ]]; then
  conformance_org="$(ask CONFORMANCE_ORG "The organisation conformance publishes to" bynk-conformance)"
  narrow_org="$(ask NARROW_ORG "Another organisation, for the narrow token" bynk-narrow)"
else
  probe_package="$(ask PROBE_PACKAGE "The package the read checks verify (org/package)" bynk-probe/hello)"
fi
url="${url_override:-https://$host}"
ok "url $url, account ${account_id:0:6}…, owner $owner"

worker="registry-store-$env_name"
bucket="registry-store-store-$env_name"
github_env="registry-$env_name"
toolchain="$(tr -d '[:space:]' <"$here/bynk-toolchain")"

cloudflare_env() { # the Cloudflare account, for one command's environment only
  CLOUDFLARE_API_TOKEN="$(secret_file cloudflare-api-token "Cloudflare API token for $env_name (Workers, R2, rate limiting)" 0)"
  export CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID="$account_id"
}

# ---------------------------------------------------------------------------
# toolchain: the pinned release, for this machine.

bin="$state_root/toolchain/$toolchain"
bynk="$bin/bynk"
if wants toolchain || [[ ! -x "$bynk" ]]; then
  say "Toolchain: bynk $toolchain"
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) target=aarch64-apple-darwin ;;
    Darwin-x86_64) target=x86_64-apple-darwin ;;
    Linux-x86_64) target=x86_64-unknown-linux-gnu ;;
    Linux-aarch64) target=aarch64-unknown-linux-gnu ;;
    *) die "no bynk release for $(uname -s) $(uname -m)" ;;
  esac
  module="bynk_registry_core-$toolchain.wasm"
  installed="$here/src/registry/bynk_registry_core.wasm"
  listed() { awk -v name="$1" '$2 == name { print $1; found = 1 } END { exit !found }' "$work/SHA256SUMS"; }
  gh release download "$toolchain" --repo bynk-lang/bynk --dir "$work" --pattern SHA256SUMS
  want_bynk="$(listed "bynk-$toolchain-$target.tar.gz")" || die "$toolchain lists no archive for $target"
  want_module="$(listed "$module")" || die "$toolchain lists no $module"
  if [[ -x "$bynk" && "$("$bynk" --version 2>/dev/null)" == "bynk ${toolchain#v}" && -f "$bin/.archive-sha256" &&
        "$(cat "$bin/.archive-sha256")" == "$want_bynk" ]]; then
    ok "bynk ${toolchain#v} already installed in $bin"
  else
    gh release download "$toolchain" --repo bynk-lang/bynk --dir "$work" --pattern "bynk-$toolchain-$target.tar.gz"
    got="$(sha256 "$work/bynk-$toolchain-$target.tar.gz" | cut -d' ' -f1)"
    [[ "$got" == "$want_bynk" ]] || die "bynk-$toolchain-$target.tar.gz is $got, not the $want_bynk SHA256SUMS lists"
    tar -xzf "$work/bynk-$toolchain-$target.tar.gz" -C "$work"
    mkdir -p "$bin"
    install -m 0755 "$work/bynk-$toolchain-$target/bynk" "$bin/bynk"
    printf '%s' "$want_bynk" >"$bin/.archive-sha256"
    ok "installed bynk ${toolchain#v} ($target) in $bin, checked"
  fi
  if [[ -f "$installed" && "$(sha256 "$installed" | cut -d' ' -f1)" == "$want_module" ]]; then
    ok "admission module $module already in place"
  else
    gh release download "$toolchain" --repo bynk-lang/bynk --dir "$work" --pattern "$module"
    got="$(sha256 "$work/$module" | cut -d' ' -f1)"
    [[ "$got" == "$want_module" ]] || die "$module is $got, not the $want_module SHA256SUMS lists"
    install -m 0644 "$work/$module" "$installed"
    ok "installed $module, checked"
  fi
fi
[[ "$("$bynk" --version)" == "bynk ${toolchain#v}" ]] || die "$bynk isn't bynk ${toolchain#v}; run the toolchain phase"

# ---------------------------------------------------------------------------
# keys: the registry directory and its keys. A root key is never regenerated.

reg="$state/registry"
root_key="$state/root.key"
delegate_key="$state/delegate.key"
pub_of() { printf 'ed25519:%s' "$(tail -c 32 "$1" | base64 | tr -d '\n')"; } # the public half of a PKCS#8 v2 Ed25519 key

if wants keys; then
  say "Keys and the registry directory ($reg)"
  if [[ ! -f "$reg/config.json" ]]; then
    [[ ! -f "$root_key" ]] || die "$root_key exists but $reg/config.json doesn't: restore the directory it was made with"
    "$bynk" registry init "$reg" --id "$registry_id" --key-out "$root_key" >/dev/null
    ok "created registry \`$registry_id\` and its root key, $root_key"
  else
    ok "registry directory already exists"
  fi
  if [[ ! -f "$delegate_key" ]]; then
    [[ -f "$root_key" ]] || die "no $delegate_key, and no $root_key to delegate with: put the root key back for this run"
    "$bynk" registry delegate "$reg" --key "$root_key" --delegate-out "$delegate_key" >/dev/null
    ok "delegated signing to a new online key, $delegate_key"
  else
    ok "online delegate already exists"
  fi
  # The publish API, which `registry init` doesn't add; clients find it here.
  python3 - "$reg/config.json" <<'PY'
import json, sys
p = sys.argv[1]
c = json.load(open(p))
if c.get("api") != "api":
    c["api"] = "api"
    open(p, "w").write(json.dumps(c, indent=2) + "\n")
    print("   ok  added \"api\": \"api\" to config.json")
PY
  if [[ $env_name == production && ! -f "$reg/$probe_package" ]]; then
    pkg="$work/probe"
    mkdir -p "$pkg/src"
    printf '[package]\nname = "%s"\nversion = "0.1.0"\n' "$probe_package" >"$pkg/bynk.toml"
    printf 'commons probe\n\nfn hello() -> String {\n  "hello from the registry"\n}\n' >"$pkg/src/probe.bynk"
    "$bynk" registry add "$reg" "$pkg" --key "$delegate_key" >/dev/null
    ok "added $probe_package 0.1.0, signed by the delegate"
  fi
fi
[[ -f "$reg/config.json" && -f "$delegate_key" ]] || die "no keys yet: run the keys phase"
# What the files say, checked against each other every run.
delegate_public="$(pub_of "$delegate_key")"
python3 - "$reg/config.json" "$delegate_public" "$registry_id" >"$work/root.pub" <<'PY' || die "$reg/config.json doesn't match the keys beside it"
import json, sys
c = json.load(open(sys.argv[1]))
assert c.get("api") == "api", "config.json has no \"api\": \"api\""
assert sys.argv[2] in [d["key"] for d in c.get("delegations", [])], f"config.json doesn't delegate to {sys.argv[2]}"
if c["id"] != sys.argv[3]:
    print(f"   ..  the registry's id is {c['id']!r}, not the REGISTRY_ID setting {sys.argv[3]!r}; the directory wins", file=sys.stderr)
print(c["keys"][0]["key"])
PY
root_public="$(cat "$work/root.pub")"
[[ ! -f "$root_key" ]] || [[ "$(pub_of "$root_key")" == "$root_public" ]] || die "$root_key isn't config.json's root key"
ok "root $root_public"
ok "delegate $delegate_public (listed in config.json)"

# ---------------------------------------------------------------------------
# tokens: plaintext in $state/tokens (never in GitHub unless the workflow
# needs it), and REGISTRY_TOKENS built from them.

token() { # token <name>: a token, minted once
  local file="$state/tokens/$1"
  [[ -s "$file" ]] || printf 'bynk_%s' "$(python3 -c 'import secrets; print(secrets.token_hex(32))')" >"$file"
  tr -d '\r\n' <"$file"
}
tokens_json="$state/registry-tokens.json"
if wants tokens || [[ ! -f "$tokens_json" ]]; then
  say "Tokens"
  # name, organisations, capabilities. `operate` and `withdraw` are operator
  # tokens, kept apart (README, "Secrets"); the CI ones are staging's alone.
  entries=("operate||operate" "withdraw||withdraw")
  if [[ $env_name == staging ]]; then
    entries+=("conformance|$conformance_org|publish,yank" "narrow|$narrow_org|publish,yank")
  fi
  : >"$work/entries"
  for e in "${entries[@]}"; do
    IFS='|' read -r name orgs can <<<"$e"
    printf '%s\t%s\t%s\n' "$(token "$name")" "$orgs" "$can" >>"$work/entries"
    ok "$name token ($state/tokens/$name)"
  done
  python3 - "$work/entries" "$tokens_json" <<'PY'
import hashlib, json, sys
out = []
for line in open(sys.argv[1]):
    tok, orgs, can = line.rstrip("\n").split("\t")
    out.append({
        "sha256": hashlib.sha256(tok.encode()).hexdigest(),
        "organisations": [o for o in orgs.split(",") if o],
        "can": can.split(","),
    })
open(sys.argv[2], "w").write(json.dumps(out, separators=(",", ":")))
PY
fi
python3 - "$tokens_json" "$state/tokens" <<'PY' || die "$tokens_json isn't a valid REGISTRY_TOKENS"
import hashlib, json, os, re, sys
v = json.load(open(sys.argv[1]))
assert isinstance(v, list) and v, "not a non-empty list"
for e in v:
    assert set(e) == {"sha256", "organisations", "can"}, f"fields {sorted(e)}"
    assert re.fullmatch(r"[0-9a-f]{64}", e["sha256"]), "sha256 isn't 64 hex digits"
    assert isinstance(e["organisations"], list) and isinstance(e["can"], list) and e["can"]
hashes = {e["sha256"]: e for e in v}
for name in os.listdir(sys.argv[2]):
    tok = open(os.path.join(sys.argv[2], name)).read().strip()
    assert hashlib.sha256(tok.encode()).hexdigest() in hashes, f"tokens/{name} isn't listed"
operate = [e for e in v if e["can"] == ["operate"]]
assert len(operate) == 1, "no single operate entry"
print(f"   ok  REGISTRY_TOKENS parses: {len(v)} entries, every token file listed")
PY

# ---------------------------------------------------------------------------
# deploy: every secret from the files above, overwriting what is there.

deploy_secrets="$work/deploy-secrets.env"
write_deploy_secrets() {
  {
    printf 'REGISTRY_SIGNING_KEY=%s\n' "$(b64 "$delegate_key")"
    printf 'REGISTRY_SIGNING_PUBLIC=%s\n' "$delegate_public"
    printf 'REGISTRY_TOKENS=%s\n' "$(cat "$tokens_json")"
    printf 'REGISTRY_QUOTAS=%s\n' "$(cat "$state/registry-quotas.json" 2>/dev/null || echo '[]')"
    printf 'GITHUB_CLIENT_ID=%s\n' "$client_id"
    local api_token; api_token="$(secret_file github-api-token "A GitHub token for user and repository lookups (a fine-grained token with no permissions is enough)" 0)"
    # Required in practice: GitHub refuses the deployed Worker's anonymous
    # lookups (Workers share Cloudflare's addresses, and so the anonymous rate
    # limit), and then an operator's claim and a trusted publisher both fail.
    printf 'GITHUB_API_TOKEN=%s\n' "$api_token"
  } >"$deploy_secrets"
}

if wants deploy; then
  say "Deploy $worker"
  grep -Eq '^[[:space:]]*workers_dev[[:space:]]*=[[:space:]]*false' "$here/bynk.toml" ||
    die "bynk.toml doesn't set \`workers_dev = false\` under [workers]: a deploy would put the service back on workers.dev"
  [[ -z "$(git -C "$here" status --porcelain -- src bynk.toml)" ]] ||
    note "src/ or bynk.toml has uncommitted changes: they will be deployed"
  write_deploy_secrets
  cloudflare_env
  (cd "$here" && "$bynk" deploy --env "$env_name" --dry-run)
  if [[ $plan == 1 ]]; then
    ok "--plan: stopping before anything is changed"
    exit 0
  fi
  if [[ $yes == 0 ]]; then
    read -r -p "   ?   Deploy this to $env_name, overwriting every secret? [y/N] " answer
    [[ "$answer" == [yY]* ]] || die "not deployed"
  fi
  # No terminal: an optional secret left out of the file (
  # GITHUB_BASE, GITHUB_API_BASE) is then a warning, not a prompt.
  (cd "$here" && "$bynk" deploy --env "$env_name" --secrets-file "$deploy_secrets" --force --yes </dev/null)
  rm -f "$deploy_secrets"
  ok "deployed; bynk.deploy.lock records $env_name's ids (commit it: see the summary)"
fi

# ---------------------------------------------------------------------------
# seed: the directory into the bucket, then the live config.json read back.

served() { # served <path>: the live body, past the edge's 60-second copy
  curl -sS --max-time 20 "$url$1?go-live=$RANDOM$RANDOM"
}
if wants seed; then
  say "Seed $bucket"
  cloudflare_env
  if [[ -z "${WRANGLER:-}" ]]; then
    if command -v wrangler >/dev/null; then WRANGLER=wrangler
    elif command -v npx >/dev/null; then WRANGLER="npx -y wrangler@4"
    else die "seeding needs wrangler: install it, put npx on PATH, or set WRANGLER"; fi
  fi
  [[ "$($WRANGLER --version 2>/dev/null | grep -o '[0-9][0-9.]*' | head -1)" == 4.* ]] ||
    die "\`$WRANGLER\` isn't wrangler 4 (set WRANGLER to one that is)"
  WRANGLER="$WRANGLER" "$here/seed/seed.sh" "$reg" --bucket "$bucket"
  status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$url/config.json?go-live=$RANDOM")" || status=000
  if [[ "$status" != 200 ]]; then
    die "$url/config.json answered $status. If the domain isn't attached yet: Cloudflare dashboard, Workers & Pages,
   $worker, Settings, Domains & Routes, Add, Custom domain: $host. Then rerun with --only seed,verify,orgs,conformance,github"
  fi
  served /config.json >"$work/live-config.json"
  python3 -c 'import json,sys; a,b=(json.load(open(f)) for f in sys.argv[1:]); sys.exit(a != b)' \
    "$work/live-config.json" "$reg/config.json" || die "$url/config.json isn't the seeded config.json"
  ok "$url/config.json is the seeded one"
fi

# ---------------------------------------------------------------------------
# verify: the Worker parsed REGISTRY_TOKENS. An operator sees any organisation,
# so an unclaimed one is a 404; a token the Worker doesn't know is a 401.

call() { # call <method> <path> <token> [json]: the status, then the body, on two lines
  local data=()
  [[ $# -ge 4 ]] && data=(-H 'content-type: application/json' --data "$4")
  curl -s -o "$work/body" -w '%{http_code}' --max-time 30 -X "$1" -H "authorization: Bearer $3" ${data[@]+"${data[@]}"} "$url$2" || true
  echo
  cat "$work/body" 2>/dev/null || true
}
status_of() { head -1 <<<"$1"; }
body_of() { tail -n +2 <<<"$1"; }
operate="$(token operate)"
if [[ $env_name == staging ]]; then org="$conformance_org"; else org="${probe_package%%/*}"; fi

if wants verify; then
  say "Verify the live Worker's REGISTRY_TOKENS"
  got="$(call GET "/account/orgs/$org" "$operate")"
  case "$(status_of "$got")" in
    200|404) ok "the operate token is accepted (GET /account/orgs/$org: $(status_of "$got"))" ;;
    401) die "the Worker refused the operate token: its REGISTRY_TOKENS isn't this one. Rerun the deploy phase (it overwrites)" ;;
    *) die "GET /account/orgs/$org answered $got" ;;
  esac
fi

# ---------------------------------------------------------------------------
# orgs: the organisation claimed for its owner, and staging's trusted publisher.

if wants orgs; then
  say "Organisations"
  got="$(call POST "/account/orgs/$org" "$operate" "{\"block\":false,\"owner\":\"$owner\"}")"
  case "$(status_of "$got")" in
    201) ok "claimed $org for $owner" ;;
    200) ok "$org was already claimed for $owner" ;;
    409) die "$org is claimed by someone else: $(body_of "$got")" ;;
    400) die "the Worker couldn't look $owner up on GitHub: check the login, and that GITHUB_API_TOKEN ($state/github-api-token) is a valid token, then rerun from the deploy phase" ;;
    *) die "claiming $org answered $got" ;;
  esac
  if [[ $env_name == staging ]]; then
    workflow=.github/workflows/deploy-registry.yml
    got="$(call GET "/account/orgs/$org" "$operate")"
    [[ "$(status_of "$got")" == 200 ]] || die "GET /account/orgs/$org answered $got"
    if python3 - "$(body_of "$got")" "$repository" "$workflow" "$github_env" <<'PY'
import json, sys
view, repo, wf, env = json.loads(sys.argv[1]), *sys.argv[2:]
def environment(t):  # an Option: `{"kind": "Some", "value": …}`, or a plain string
    e = t.get("environment")
    return e.get("value") if isinstance(e, dict) else e
sys.exit(0 if any(t["repository"].lower() == repo.lower() and t["workflow"] == wf and environment(t) == env
                  for t in view["trusted"]) else 1)
PY
    then
      ok "$repository's $workflow ($github_env) is already a trusted publisher of $org"
    else
      got="$(call POST "/account/orgs/$org/trusted" "$operate" \
        "{\"repository\":\"$repository\",\"workflow\":\"$workflow\",\"environment\":\"$github_env\",\"can\":[\"publish\"]}")"
      [[ "$(status_of "$got")" == 201 ]] || die "registering the trusted publisher answered $got"
      ok "registered $repository's $workflow ($github_env) as a trusted publisher of $org"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# conformance: what the workflow will run, run now.

if wants conformance; then
  say "Conformance against $url"
  if [[ $env_name == staging ]]; then
    BYNK_REGISTRY_CONFORMANCE_TOKEN="$(token conformance)" NARROW="$(token narrow)" \
      "$bynk" registry conformance "$url" --org "$org" --key "$root_public" --narrow-token-env NARROW
  else
    "$bynk" registry conformance "$url" --read-only --package "$probe_package" --key "$root_public"
  fi
  ok "conformance passed"
fi

# ---------------------------------------------------------------------------
# github: the environment's secrets (through stdin, never argv) and variables,
# then read back: names for the secrets, values for the variables.

if wants github; then
  say "GitHub environment $github_env ($repo_slug)"
  gh api "repos/$repo_slug/environments/$github_env" >/dev/null 2>&1 ||
    die "$repo_slug has no environment $github_env: create it (Settings, Environments), with a main-only branch rule"
  put_secret() { printf '%s' "$2" | gh secret set "$1" --env "$github_env" --repo "$repo_slug" >/dev/null; ok "secret $1"; }
  put_var() { gh variable set "$1" --env "$github_env" --repo "$repo_slug" --body "$2" >/dev/null; ok "variable $1 = $2"; }
  want_secrets="CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID REGISTRY_SIGNING_KEY REGISTRY_SIGNING_PUBLIC REGISTRY_TOKENS REGISTRY_QUOTAS REGISTRY_GITHUB_CLIENT_ID"
  put_secret CLOUDFLARE_API_TOKEN "$(secret_file cloudflare-api-token "Cloudflare API token for $env_name (Workers, R2, rate limiting)" 0)"
  put_secret CLOUDFLARE_ACCOUNT_ID "$account_id"
  put_secret REGISTRY_SIGNING_KEY "$(b64 "$delegate_key")"
  put_secret REGISTRY_SIGNING_PUBLIC "$delegate_public"
  put_secret REGISTRY_TOKENS "$(cat "$tokens_json")"
  put_secret REGISTRY_QUOTAS "$(cat "$state/registry-quotas.json" 2>/dev/null || echo '[]')"
  put_secret REGISTRY_GITHUB_CLIENT_ID "$client_id"
  api_token="$(secret_file github-api-token "A GitHub token for user and repository lookups (a fine-grained token with no permissions is enough)" 0)"
  if [[ -n "$api_token" ]]; then
    put_secret REGISTRY_GITHUB_API_TOKEN "$api_token"; want_secrets="$want_secrets REGISTRY_GITHUB_API_TOKEN"
  fi
  put_var REGISTRY_URL "$url"
  put_var REGISTRY_ROOT_KEY "$root_public"
  if [[ $env_name == staging ]]; then
    put_secret REGISTRY_CONFORMANCE_TOKEN "$(token conformance)"
    put_secret REGISTRY_NARROW_TOKEN "$(token narrow)"
    put_secret REGISTRY_WITHDRAW_TOKEN "$(token withdraw)"
    want_secrets="$want_secrets REGISTRY_CONFORMANCE_TOKEN REGISTRY_NARROW_TOKEN REGISTRY_WITHDRAW_TOKEN"
    put_var REGISTRY_CONFORMANCE_ORG "$org"
    want_vars="REGISTRY_URL=$url REGISTRY_ROOT_KEY=$root_public REGISTRY_CONFORMANCE_ORG=$org"
  else
    put_var REGISTRY_PROBE_PACKAGE "$probe_package"
    want_vars="REGISTRY_URL=$url REGISTRY_ROOT_KEY=$root_public REGISTRY_PROBE_PACKAGE=$probe_package"
  fi
  have_secrets=" $(gh secret list --env "$github_env" --repo "$repo_slug" --json name -q '.[].name' | tr '\n' ' ') "
  for s in $want_secrets; do [[ "$have_secrets" == *" $s "* ]] || die "secret $s didn't arrive in $github_env"; done
  for s in $have_secrets; do
    [[ " $want_secrets " == *" $s "* ]] || note "$github_env also has a secret $s, which this script doesn't set (remove it if it's stale)"
  done
  have_vars="$(gh variable list --env "$github_env" --repo "$repo_slug" --json name,value -q '.[] | "\(.name)=\(.value)"')"
  for v in $want_vars; do grep -qxF "$v" <<<"$have_vars" || die "variable ${v%%=*} in $github_env isn't ${v#*=}"; done
  ok "every secret is present and every variable reads back as set"
fi

# ---------------------------------------------------------------------------

say "Done: $env_name"
withdraw_note=""
[[ $env_name == production ]] || withdraw_note=" (but staging's withdraw token is, for the purge check)"
cat <<EOF
   State (keys, tokens, settings): $state
     - Back it up offline. The root key ($root_key) is needed only to make a
       new delegate: once backed up, move it off this machine.
     - The operate and withdraw tokens are in $state/tokens; they are never
       given to GitHub$withdraw_note.

   Next:
     1. Commit bynk.deploy.lock (and workers_dev, if it isn't on main yet) in a PR:
          git switch -c deploy-lock-$env_name && git add bynk.deploy.lock && git commit -m "Record $env_name's deploy ids"
     2. Release and dispatch (you cut releases):
EOF
if [[ $env_name == staging ]]; then
  echo "          gh release create v0.1.0-rc.1 --target main --prerelease --title v0.1.0-rc.1 --notes 'Staging'"
  echo "          gh workflow run deploy-registry.yml --repo $repo_slug --ref main -f tag=v0.1.0-rc.1"
else
  echo "          gh release create v0.1.0 --target main --title v0.1.0 --notes '…'"
  echo "          gh workflow run deploy-registry.yml --repo $repo_slug --ref main -f tag=v0.1.0   # then approve production"
fi
