# The first-party Bynk registry

The hosted instance of the [registry protocol](https://bynk-lang.org/docs/registry-protocol/):
the registry every organisation not routed elsewhere resolves on. It is
written in Bynk and built with a pinned `bynk` release (see "Building"). The
design is the first-party registry track,
[`design/tracks/first-party-registry.md`](https://github.com/bynk-lang/bynk/blob/main/design/tracks/first-party-registry.md)
(spine [bynk-lang/bynk#2308](https://github.com/bynk-lang/bynk/issues/2308)).

It was built inside [`bynk-lang/bynk`](https://github.com/bynk-lang/bynk), at
`services/registry/`, and moved here before going live (R7,
[bynk-lang/bynk#2415](https://github.com/bynk-lang/bynk/issues/2415)) with its
history. Issue and PR numbers in that history, and in the comments here, are
`bynk-lang/bynk`'s unless they say otherwise.

**Its rules** (the track's extraction rules, E1–E5, now this repository's):

- **E1.** A self-contained Bynk project. It reaches only `bynk-std`, its own
  files and git dependencies pinned by its lock, never a path outside this
  repository.
- **E2.** No Rust inside the service. The shared admission rules cross an
  adapter boundary as a wasm module from the pinned release.
- **E3.** No account-specific configuration in git. Account ids, secrets and
  the signing key come from the deploy's GitHub environments.
- **E4.** CI checks every PR; deploys come only from the manual workflow.
- **E5, kept forever.** No registry dependencies, so a broken registry, or a
  bad toolchain release, can never stop the fix from being redeployed. CI
  checks it (`scripts/check-no-registry-deps.py`).

## Building

`bynk-toolchain` names the one `bynk` release this service builds, tests and
deploys with. Install it, and its admission module, with:

```bash
scripts/install-release.sh "$(scripts/toolchain.sh)" ~/.local/bin   # needs gh, signed in
```

Each asset is checked against that release's `SHA256SUMS`. `bynk-std` ships
inside the toolchain, so the pin fixes it too. **Bumping the toolchain** is a
PR that changes that one line; its CI is the proof. A capability the service
needs lands in `bynk-lang/bynk` first, ships in a release, and the service then
bumps its pin.

`bynk-lang/bynk` runs this repository's checks daily against its own `main`
(its `registry-canary` workflow), so a compiler change that would break the
service is seen there before it is released.

## Layout

| Path | What |
|---|---|
| `src/registry/store/files.bynk` | `context registry.store`: owns the registry's bucket (`capability Store = R2`) and its edge cache (`capability Edge = EdgeCache`), and serves the protocol's read paths |
| `src/registry/store/publish.bynk` | The publish API: the `api` service, the per-package `PackageIndex` agent, the token check and delegate signing |
| `src/registry/store/publication.bynk` | The publication rule: every registry dependency of an upload resolves here |
| `src/registry/ranges.bynk` | `commons registry.ranges`: whether a dependency's range admits a version, as Cargo reads ranges |
| `src/registry/store/trusted.bynk` | Trusted publishing: the `Workload` actor (GitHub Actions OIDC), trusted publishers, and the exchange |
| `src/registry/store/accounts.bynk` | Accounts: the `account` service, GitHub's device flow, and the `Organisation`, `PublishToken` and `Session` agents |
| `src/registry/store/operator.bynk` | The operator routes: the takedown, its `Takedowns` log, and restoring an organisation |
| `src/registry/admission.bynk` | `adapter registry.admission`: the shared rules (`bynk-registry-core`) as a wasm module |
| `scripts/admission-module.sh` | Install the pinned release's module into `src/registry/` (git-ignored) |
| `bynk-toolchain`, `scripts/toolchain.sh` | The pinned `bynk` release, and the script that reads it |
| `scripts/check-no-registry-deps.py` | E5: no registry dependencies |
| `.github/workflows/ci.yml` | CI: the checks below, on the pinned release; `CI green` is the required check |
| `src/registry/paths.bynk` | `commons registry.paths`: the object keys, and the name rules that guard them |
| `tests/` | Unit tests: the key rules, and the read paths against a stubbed bucket |
| `seed/seed.sh` | Upload a `bynk registry` directory into the bucket |
| `scripts/check-read-path.sh` | The read path end to end, and its caching headers, as CI runs it |
| `scripts/check-publish.sh` | The publish API end to end, as CI runs it |
| `scripts/check-publication.sh` | The publication rule end to end, as CI runs it |
| `scripts/check-accounts.sh` | Accounts end to end, against `scripts/fake-github.py`, as CI runs it |
| `scripts/check-trusted.sh` | Trusted publishing end to end, against `scripts/fake-oidc.mjs`, as CI runs it |
| `scripts/check-limits.sh` | The rate limits and the quota end to end, as CI runs it |
| `scripts/check-export.sh` | The export and a restore drill end to end, as CI runs it |
| `scripts/check-withdraw.sh` | A takedown and an organisation restore end to end, as CI runs it |
| `scripts/deploy-guard.sh`, `scripts/test-deploy-guard.sh` | The deploy workflow's ref guard, and its tests |
| `scripts/install-release.sh` | Installs a release's `bynk` and admission module for a deploy, checked against its `SHA256SUMS` |

**One context owns the bucket.** Under the standard library's resource model a
bucket belongs to the context that declares it, so the read service, the
publish service and the per-package index writers all live in `registry.store`.

**The bucket mirrors a static registry.** Its keys are exactly a
`bynk registry` directory's paths: `config.json`, `<org>/<package>` (index
files) and `dl/sha256/<hex>` (archives). A seed is a copy of such a directory,
and an export is the reverse.

## Reading

| Request | Serves | Content type |
|---|---|---|
| `GET /config.json` | `config.json` | `application/json` |
| `GET /<org>/<package>` | the package's index file | `application/x-ndjson` |
| `GET /dl/sha256/<hex>` | an archive | `application/vnd.bynk.tree-v1` |

A missing object, or a name outside the manifest's rules (a malformed
organisation, package or digest), is `404`; a malformed name never reaches the
bucket. Nothing here signs or decides anything: clients verify every line's
signature and every archive's checksum.

**Cached at Cloudflare's edge** (R6.1, [bynk-lang/bynk#2413](https://github.com/bynk-lang/bynk/issues/2413)).
The context declares `capability Edge = EdgeCache`, which turns Workers Cache
on for its Worker (L7, ADR 0613). The edge answers a cached read without running
the Worker:

| Request | `Cache-Control` | Validator |
|---|---|---|
| `GET /config.json`, `GET /<org>/<package>` | `public, max-age=60` | a weak `ETag`; a matching `If-None-Match` is `304` |
| `GET /dl/sha256/<hex>` | `public, max-age=31536000, immutable` | the strong `ETag` `"<hex>"`, whatever the archive's size |
| anything else (every `404`, a fault, `/_status/export`, the account API) | `no-store` | — |

- **60 seconds is the bound on a stale read.** `config.json` and the index
  files change in place: a delegation or a revocation, a yank, a withdrawal.
  Anyone reading through the edge sees such a change within a minute.
- **A yank, an un-yank or a takedown purges the package's index file**
  (`/<org>/<package>`), so the change is seen at once. This deliberately
  relaxes #2413's "purge only on takedown": a yank is rare, and the people it
  is for should not install the version for another minute. A publish doesn't
  purge: a stale read only lacks the new line for up to a minute, and purging
  on every publish would run into the purge rate limit. If Cloudflare refuses
  a yank's purge, the yank still stands and the 60-second bound still holds.
  Staging conformance relies on it too: it reads an index, yanks, and reads it
  again within seconds, with its token, which doesn't bypass a `public` copy
  (below).
- **`config.json` is never purged.** Nothing in the service writes it: a
  delegation or revocation reaches it by seeding (`seed/seed.sh`), and is seen
  within 60 seconds.
- **An archive never changes,** so it is kept for good. Only a takedown purges
  it (see "Takedowns").
- **Everyone gets the same answer.** The edge keys a response by its URL alone,
  and a `public` response is shared even when the request carried a token
  (ADR 0613 G). So these routes are `by Visitor`, and answer the same bytes to
  everyone.
- **`bynk dev` has no edge cache.** It sends the same headers, and a purge
  there is a logged no-op that succeeds. Staging is where the cache is checked
  (see "Deploying").

## Publishing

The publish API is the protocol's ("Publish API"), answered as
`bynk registry serve` answers it, so `bynk publish` and `bynk yank` work
against it unchanged:

| Request | Does | Answers |
|---|---|---|
| `PUT /api/<org>/<package>/<version>` | admit the archive, store it, sign and append its line | `201` and the line; `200` and the existing line for the same tree again |
| `POST /api/<org>/<package>/<version>/yank` | mark the version yanked | `200` `{"ok": true}` |
| `POST /api/<org>/<package>/<version>/unyank` | clear it | `200` `{"ok": true}` |

Every refusal is JSON `{"error", "message"}` with the reference server's status:
`400 invalid_package` for an archive the rules refuse (or one naming another
package or version), `401 unauthorised`, `403 forbidden`, `404 not_found`,
`409 version_exists` for another tree under a published version, `410 withdrawn`
for a version taken down (and `409 withdrawn` to un-yank one),
`413 too_large` past the 64 MiB cap, and `400 unpublishable_dependency` for a
dependency that doesn't resolve here (below). The router's own refusals are
rendered by `on rejected`.

**The publication rule** (packaging §6.2; bynk-lang/bynk#2413, decision D): a
package published here may depend only on what resolves here. Before an upload
is stored, each of its registry dependencies is checked:

- its organisation is claimed here and isn't blocked (a blocked name is held
  for a private registry, so nothing in it resolves here);
- its package has a version that isn't withdrawn and that the range admits.
  Ranges are read as Cargo reads them, as the manifest does
  (`src/registry/ranges.bynk`). A yanked version counts: yanking keeps a version
  resolvable for existing locks.

The first dependency that fails is refused as `400 unpublishable_dependency`,
naming it and why. Publish the dependency here first. A retry of a tree already
published passes whatever its dependencies' state now: it was admitted once
(D10). The rule is this service's, not the protocol's: a private registry may
accept dependencies on this one, so the shared rules stay neutral.

**The rules are the shared crate's.** Admission, the bytes a line's signature
covers, and what `config.json` says about a key all come from
`bynk-registry-core`, the code the client and the reference server use, run as a
wasm module through `adapter registry.admission`. The module is the pinned
release's, never committed: `scripts/install-release.sh` (or
`scripts/admission-module.sh` alone) installs it after a clone, and again after
bumping `bynk-toolchain`. To try an unreleased change to the rules, build it
from a `bynk-lang/bynk` checkout instead:
`BYNK_REGISTRY_CORE_SRC=<checkout> scripts/admission-module.sh` (it needs the
`wasm32-unknown-unknown` Rust target).

**One writer per package.** `PackageIndex[<org>/<package>]` holds the package's
lines and decides each append: new, a retry of the same tree, or a conflict. The
index file in the bucket is its projection, rewritten by the agent inside the
call that made the change, so concurrent changes never land out of order. A
package that was seeded before the agent existed is adopted from its index file
on the first call; a line there that doesn't parse is refused, never dropped.

### Secrets

| Secret | What |
|---|---|
| `REGISTRY_SIGNING_KEY` | The online delegate's private key: the PKCS#8 file `bynk registry delegate --delegate-out` writes, base64-encoded |
| `REGISTRY_SIGNING_PUBLIC` | Its public half, `ed25519:…` (what `delegate` prints) |
| `REGISTRY_TOKENS` | The operator tokens, as JSON: `[{"sha256", "organisations", "can"}]` (optional) |
| `GITHUB_CLIENT_ID` | The registry's GitHub OAuth app (see "Accounts") |
| `GITHUB_BASE`, `GITHUB_API_BASE` | GitHub's sign-in and API origins; default `https://github.com` and `https://api.github.com` (tests point them at a fake) |
| `REGISTRY_OIDC_TRUST` | Optional, never in production: another OIDC issuer for the `Workload` actor (see "Trusted publishing") |
| `GITHUB_API_TOKEN` | Optional: a GitHub token for looking members up, to lift GitHub's anonymous rate limit |
| `REGISTRY_QUOTAS` | Optional: raised storage quotas, as JSON `[{"org", "bytes"}]`; an organisation not listed has 1 GiB (see "Limits") |

**The root key never reaches the service.** Before every signature the service
checks its key against the bucket's `config.json`: a delegation from the newest
chain key names it and verifies, and no revocation names it; and a signature it
makes verifies. A key that fails is never used, and the publish is refused
(`500 internal`, naming the misconfiguration).

**Operator tokens** are the bootstrap and CI path, beside the tokens people
mint through accounts. They don't expire, and an operator manages them by
updating the secret. A token whose `can` includes `operate` may also use the
account API as any organisation's owner: that is how a reserved name is claimed
for its rightful owner, and how a dispute is settled. Mint each with
`bynk registry token <file> --org <org> [--can publish,yank]`, which prints the
token once and writes only its sha256; convert the file to the secret's JSON
(`python3 -c 'import json,sys,tomllib; print(json.dumps(tomllib.load(open(sys.argv[1],"rb"))["token"]))' tokens.toml`).
Changing a token is updating the secret.

Two capabilities exist only on operator tokens, and `bynk registry token`
doesn't mint them: `operate` (above) and `withdraw` (see "Takedowns"). Add such
an entry to the JSON by hand, with `"organisations": []`:

```bash
python3 -c 'import hashlib,json,sys; print(json.dumps({"sha256": hashlib.sha256(sys.argv[1].encode()).hexdigest(), "organisations": [], "can": ["withdraw"]}))' "$TOKEN"
```

Keep them apart: the token that settles disputes needn't delete archives, and
neither belongs in CI. The one exception is a separate `withdraw` token that only
staging holds, for the deploy's purge check (see "Deploying").

## Accounts

People sign in with GitHub (the OAuth **device flow**: no password, no
cookie, no GitHub credential kept), claim organisations, add members, and mint
the publish tokens `bynk publish` uses. The `bynk` client drives it (R3.1,
bynk-lang/bynk#2378; see the CLI reference for `bynk login` and `bynk org`):

```bash
bynk login --registry <name>                # prints a code to approve at GitHub, then waits
bynk org claim acme                         # first come; --block holds the name
bynk org member add acme <github-login>
bynk org token mint acme --days 90 --save   # into acme's slot in the credentials file, for bynk publish
bynk org show acme
```

The API underneath is JSON, so `curl` drives it too:

```bash
# Sign in: open verificationUri, enter userCode, then poll every `interval` seconds.
curl -X POST https://<registry>/account/login
curl -X POST https://<registry>/account/login/poll -H 'content-type: application/json' -d '{"poll":"<poll>"}'
#   400 authorization_pending — not yet; 429 slow_down — poll less often; 200 — {"token": "bynka_…"}

# Claim an organisation (first come), add a member, mint a publish token.
curl -X POST https://<registry>/account/orgs/acme -H "authorization: Bearer $ACCOUNT" -H 'content-type: application/json' -d '{"block":false}'
curl -X PUT  https://<registry>/account/orgs/acme/members/<github-login> -H "authorization: Bearer $ACCOUNT"
curl -X POST https://<registry>/account/orgs/acme/tokens -H "authorization: Bearer $ACCOUNT" -H 'content-type: application/json' \
  -d '{"can":["publish","yank"],"days":90,"note":"laptop"}'
#   201 — {"token": "bynk_…" (shown once), "info": {"id": …, "expiresAt": …}}
```

| Request | Who | Does |
|---|---|---|
| `POST /account/login`, `POST /account/login/poll` | anyone | sign in; the account token lasts 30 days |
| `DELETE /account/session` | the session | sign out |
| `POST /account/orgs/<org>` `{"block", "owner"?}` | a person; an operator for someone (`owner`) | claim a free name; `block: true` holds it without publishing |
| `GET /account/orgs/<org>` | members | the owner, members, whether it is blocked, and its tokens (never the tokens themselves) |
| `PUT /account/orgs/<org>/blocked` `{"blocked"}` | the owner | block or unblock |
| `PUT /account/orgs/<org>/members/<login>` | the owner | add a member (stored by GitHub's numeric id) |
| `DELETE /account/orgs/<org>/members/<id>` | the owner | remove a member (the owner stays) |
| `POST /account/orgs/<org>/tokens` `{"can", "days", "note"}` | members | mint a publish token for 1 to 365 days |
| `DELETE /account/orgs/<org>/tokens/<id>` | the owner; the member who minted it | revoke it |

**Names.** An organisation follows the manifest rule. A short list is reserved
(`bynk` and `bynk-*`, `cloudflare`, `workers`, `npm`, `node`, `deno` and
impersonations of them; `registry.paths.isReserved`); ask the operators for
one. A **blocked** organisation refuses every publish. Block a name before
anything is seeded into it: a block refuses publishes, and doesn't hide an
index file already in the bucket.

**Two kinds of token, never interchangeable.** An account token (`bynka_…`)
manages organisations and can't publish; a publish token (`bynk_…`) publishes
and/or yanks for one organisation, and can't manage anything. Both are stored
only as their sha256, and both expire. A publish token works only while its
organisation lists it: removing a member ends every token they minted, and
adding them back doesn't revive those tokens.

**Never enter a code you didn't request.** The device flow's page is GitHub's
own and names the app; someone who persuades you to approve their code signs in
as you.

**The GitHub OAuth app.** Create one under the organisation that runs the
registry, enable **device flow**, and leave the callback URL empty. The device
flow needs no client secret, so none is created; set its client id as
`GITHUB_CLIENT_ID`.

## Trusted publishing

A GitHub Actions job can publish with **no stored secret**. It asks GitHub for
an OIDC token for this registry, exchanges it here for a publish token that
lasts 15 minutes, and runs `bynk publish`. An organisation's owner says which
repository, which workflow file and, optionally, which GitHub environment may:

```bash
curl -X POST https://<registry>/account/orgs/acme/trusted -H "authorization: Bearer $ACCOUNT" \
  -H 'content-type: application/json' \
  -d '{"repository":"acme/money","workflow":".github/workflows/release.yml","environment":"release","can":["publish"]}'
```

The repository is stored by **GitHub's numeric id**, which is what an exchange
matches, so a repository renamed, deleted and recreated, or transferred, doesn't
inherit the trust. `DELETE /account/orgs/<org>/trusted/<id>` removes one (the
publish tokens it already minted run out within 15 minutes); the organisation's
view lists them. When several publishers match a job, one bound to its
environment is used before one that takes any. Each OIDC token is exchanged
once: its `jti` is remembered for a day.

The workflow side:

```yaml
jobs:
  release:
    environment: release            # recommended: a protected environment
    permissions:
      id-token: write
      contents: read
    steps:
      - uses: actions/checkout@v4
      - name: Publish
        run: |
          oidc=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
            "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=bynk-registry" | jq -r .value)
          token=$(curl -sS -X POST https://<registry>/account/trusted/exchange \
            -H "authorization: Bearer $oidc" -H 'content-type: application/json' \
            -d '{"org":"acme"}' | jq -r .token)
          BYNK_REGISTRY_<NAME>_TOKEN="$token" bynk publish
```

An exchange is refused (`403 not_trusted`) unless a trusted publisher of the
organisation matches the token's `repository_id`, the workflow file in its
`job_workflow_ref`, and its `environment` (when one is registered); a token for
another audience, or an expired one, is `401`; a blocked organisation is `403
blocked`. **Use a protected environment** (required reviewers, restricted
branches): it is what keeps an arbitrary branch of the repository from
publishing through the release workflow.

`REGISTRY_OIDC_TRUST` (optional) points the `Workload` actor at another issuer —
JSON `{"issuer", "jwks"}` — for tests and staging. **Leave it unset in
production**, where GitHub's own issuer applies.

## Limits

Cloudflare's rate limiting (`src/registry/store/limits.bynk`) counts, per
Cloudflare location and approximately:

| Limit | Per | Applies to |
|---|---|---|
| 60 a minute | publish token (by its sha256) | `PUT`, yank and unyank |
| 600 a minute | IP (`CF-Connecting-IP`) | the same: a flood guard only, since GitHub-hosted runners share addresses |
| 60 a minute | IP | the account API: sign-in, polling, organisations, tokens |
| 10 a minute | repository (the token's `repository_id`) | the trusted-publishing exchange |

Past one, a request is `429 rate_limited`. Reads aren't limited by the service.
The edge serves most of them from its cache (see "Reading"), and read abuse is a
matter for Cloudflare's WAF.
The limits are in the source, so changing one is a release; `bynk deploy`
allocates each limiter's namespace id into `bynk.deploy.lock`.

Each organisation has a **storage quota**: the bytes of its uploads, 1 GiB
unless `REGISTRY_QUOTAS` raises it. An upload past it is `413 quota_exceeded`,
naming the usage. A retry of a tree already published passes whatever the
usage. The count is kept in an `OrgUsage` agent, checked before an archive is
stored and added after the line commits, so concurrent publishes to different
packages can overshoot it by one upload each.

## Takedowns

A legal takedown or confirmed malware is the only reason a version leaves the
registry (track D8). Yanking never deletes; a **withdrawal** does, and it is
final. An operator token that can `withdraw` does it:

```bash
curl -X POST https://<registry>/_operator/withdraw/acme/money/1.4.2 -H "authorization: Bearer $WITHDRAW" \
  -H 'content-type: application/json' -d '{"reason":"Removed after a confirmed malware report"}'
#   200 — {"package", "version", "reason", "archive": "deleted", "edge": "purged"}
```

It:

- marks the line `yanked`, with the reason as its unsigned `withdrawn`. Nothing
  is re-signed;
- deletes the archive from the store and the backup;
- purges `/dl/sha256/<hex>` and the package's index file from the edge, in
  one purge. A content address has a fixed length, so the purge names no other
  archive. A shared archive stays, so then only the index file is purged;
- gives the organisation its bytes back on the quota;
- logs who (the token's sha256), when, what, why, and what became of the
  archive and of the edge's copy.

Every client then fails on the version as `bynk.registry.withdrawn`, quoting
the reason and pointing at `bynk update`. The version can't come back: a `PUT`
of it, even the same tree, is `410 withdrawn`, and an un-yank `409 withdrawn`.
**What it can't do:** reach a tree already in a user's store (`$BYNK_HOME`),
which keeps building, or a copy of the backup outside the account. Apply the
takedown to such a copy by hand. Nor can it reach a downstream cache that kept
the archive under `immutable`: a corporate proxy, a mirror or a browser. A
client reads `withdrawn` from the index before it fetches, so such a copy only
matters to someone who fetches by digest and ignores the index.

The reason is what every client prints: one line, at most 500 characters,
written for the people whose builds stop (`400 invalid_reason` otherwise). Check
the `org/package/version` before sending: there is no undo, and a wrong
takedown is recovered as the protocol says, with a new version.

**`"edge"`** is `purged`, `kept` (another live version shares the archive, so
it is still served), or `purge_failed`. Cloudflare refuses purges past its rate
limit (about 25 in a burst, recovered within a minute). A `purge_failed`
takedown has done everything else, but the edge may serve the archive until it
is purged, so it counts as interrupted.

A repeat is `409 withdrawn`, unless it finishes an interrupted takedown, which
answers `200` with `"archive": "finished"`. Finishing deletes what's left,
refunds the quota if the first attempt didn't, logs the takedown if it wasn't
logged, and purges the edge unless a takedown is logged as having purged that
archive. **Run it again whenever a takedown didn't answer `200`, or
answered `"edge": "purge_failed"`,** until it answers `409` or
`"edge": "purged"`.

```bash
curl https://<registry>/_operator/takedowns -H "authorization: Bearer $WITHDRAW"
#   {"takedowns": [{"at", "tokenId", "package", "version", "checksum", "reason", "archive", "edge"}, …]}, newest first
```

The log is for operators only; the public sees the reason on the index line.
The export copies it to `agents/takedowns.json`.

**The purge comes only from the Worker's `fetch`.** It is made by the
operator route's own request, never from the export's cron, an agent or a queue
consumer, and the compiler refuses one from any of those (ADR 0613 D). A cron
run's purge reports success and clears nothing from the cache that requests
are served from.

## Export and restore

An hourly cron (`17 * * * *`, `src/registry/store/export.bynk`) copies
everything to a second bucket, the `Backup` capability's. A pass starts a day
after the last one began, and each tick does one step: a page of the store
bucket (up to 1000 objects), or a batch of 200 organisations. A pass copies:

- every object in the store bucket: `config.json`, the index files and the
  archives. A copy records its source's etag in its metadata, so an unchanged
  object isn't copied again;
- `agents/packages/<org>/<package>.json`: each package's lines as its
  `PackageIndex` holds them (the authority the index file projects);
- `agents/orgs/<org>.json`: each organisation's owner, members, block and
  trusted publishers, found through the `Directory` agent that every claim
  writes to. Token digests aren't exported: tokens are short-lived;
- `agents/takedowns.json`: the takedown log. A pass ends by deleting every
  archive the log names from the backup, in case a tick copied one back while a
  takedown ran.

`GET /_status/export` reports the pass in progress and the last one finished
(times and counts only), for an operator or an uptime monitor.

**Restoring packages.** Copy the backup's objects (everything but `agents/`)
into an empty store bucket, as `seed/seed.sh` does from a directory. Each
`PackageIndex` adopts its index file on its first call, so the packages come
back with no agent state. Compare `agents/packages/` with the index files to
check nothing was lost between the last write and the export.

**Restoring organisations.** `PUT` each `agents/orgs/<org>.json`, as it is,
with an operator token that can `operate`:

```bash
curl -X PUT https://<registry>/_operator/orgs/acme -H "authorization: Bearer $OPERATE" \
  -H 'content-type: application/json' --data-binary @agents/orgs/acme.json
#   201 — restored; 200 — already restored to this very state (a repeat finishes an interrupted restore);
#   409 claimed — the name is held otherwise, and a restore never overwrites
```

It restores the owner, members, block and trusted publishers, and lists the
name for the next export. Members mint new publish tokens: none were exported.

**The backup is never pruned.** An object deleted from the store stays in the
backup, and a restore brings back everything the backup has ever held.
Archives and index files are never deleted in normal operation. A takedown
deletes an archive from both buckets (see "Takedowns").

The backup bucket is in the same account: it protects against bugs and
mistakes, not against losing the account. Copy it elsewhere as well (for
example with `rclone`, from R2's S3-compatible API).

## Deploying

Only `.github/workflows/deploy-registry.yml` deploys the service, run by hand
from `main` with one of **this repository's** release tags (Actions, "Deploy
registry", Run workflow). A release is a tag on `main` with a published GitHub
release, and it carries no assets:

```bash
gh release create v0.1.0 --target main --title v0.1.0 --notes "…"
```

1. **The guard** (`scripts/deploy-guard.sh`, taken from `main`):
   - refuses a dispatch from any branch but `main`;
   - refuses anything but a `v<semver>` tag with a published GitHub release on
     `main`. A release candidate (`vX.Y.Z-rc.N`) may go to staging, never to
     production;
   - reads the `bynk-toolchain` that the tag's commit pins, and refuses it
     unless it names a published, final `bynk` release;
   - **pins what it checked**: the commit the tag names, that toolchain, and the
     digests its `SHA256SUMS` lists for the toolchain archive and admission
     module.
2. **Staging** (GitHub environment `registry-staging`): checks out the pinned
   commit (not the tag, which could have moved), and installs the pinned
   toolchain's `bynk` and admission module only if they match the pinned
   digests. Nothing
   is built from source. Then it runs:
   - `bynk deploy --env staging`;
   - a full `bynk registry conformance` run;
   - **the edge cache, with anonymous reads:** a repeated fetch of the archive
     conformance just published must be `cf-cache-status: HIT`. Then a takedown
     of that version must answer `"edge": "purged"`, and the next fetch must be
     the origin's `404`. Conformance can't show this: it checks what is served,
     never whether the edge served it, and `bynk dev` has no cache;
   - a trusted-publishing exchange with the workflow's own OIDC token.
3. **Production** (environment `registry-production`, with required reviewers:
   the approval) does the same with `--env production`, then runs the
   conformance read checks.

**Rollback** is running the workflow with the previous tag.

**What keeps this honest** (set up on this repository with the environments, in R6, bynk-lang/bynk#2413):

- **Both environments allow deployments from `main` only** (a deployment
  branch rule). A dispatch runs the workflow file *of the branch it names*, so
  an edited copy on another branch could skip the guard; the environments'
  rule is what keeps it from their secrets. The guard's own branch check is a
  second line, not the first.
- **Release tags are protected** (a tag ruleset on `v*`: no moving or deleting)
  and **releases are immutable** (the repository setting), so a tag and its
  assets can't change after they're published. The guard's pins catch a change
  between the check and the deploy (for example, while production waits for
  approval); protection and immutability stop one before the check.

**Each environment holds** (nothing of this is in git):

| Kind | Name | What |
|---|---|---|
| secret | `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID` | The account `bynk deploy` deploys into |
| secret | `REGISTRY_SIGNING_KEY`, `REGISTRY_SIGNING_PUBLIC` | That environment's online delegate (see "Secrets") |
| secret | `REGISTRY_TOKENS`, `REGISTRY_QUOTAS` | Operator tokens and raised quotas (optional) |
| secret | `REGISTRY_GITHUB_CLIENT_ID`, `REGISTRY_GITHUB_API_TOKEN` | The environment's GitHub OAuth app, and an optional API token; deployed as `GITHUB_CLIENT_ID` and `GITHUB_API_TOKEN` |
| secret | `REGISTRY_CONFORMANCE_TOKEN`, `REGISTRY_NARROW_TOKEN` | Staging only: publish tokens for the conformance organisation, and a narrow one for another |
| secret | `REGISTRY_WITHDRAW_TOKEN` | Staging only: an operator token that can `withdraw` and nothing else, listed in staging's `REGISTRY_TOKENS`, for the purge check. Never production's |
| variable | `REGISTRY_URL` | The environment's registry origin |
| variable | `REGISTRY_ROOT_KEY` | The registry's root public key, `ed25519:…` |
| variable | `REGISTRY_CONFORMANCE_ORG` | Staging only: the organisation conformance publishes throwaway packages to, with this repository's `deploy-registry.yml` (environment `registry-staging`) registered as its trusted publisher |
| variable | `REGISTRY_PROBE_PACKAGE` | Production only: a published package the read checks verify |

`REGISTRY_OIDC_TRUST` is never set by the workflow: both environments trust
GitHub's own issuer.

**The first deploy of each environment is local**, as part of going live (R6):
`bynk deploy --env staging` and `--env production` allocate the buckets' names
and the rate limiters' namespace ids into `bynk.deploy.lock`. That file holds
no account ids or secrets, and is committed; the workflow refuses a limiter it
doesn't list.

## Seeding

The bucket starts as a registry built offline with the `bynk registry` tooling:
at least its `config.json`, with `"api": "api"` so clients find the publish API.
The root key stays offline; a delegate signs:

```bash
bynk registry init ./reg --id bynk --key-out ~/secrets/root.key
bynk registry delegate ./reg --key ~/secrets/root.key --delegate-out ~/secrets/online.key
bynk registry add ./reg ./packages/hello --key ~/secrets/online.key
seed/seed.sh ./reg --bucket <bucket-name>
```

`seed.sh` copies every file (skipping dot-directories) to an object keyed by
its relative path. It carries no keys: the directory arrives signed.
`WRANGLER` may name the command to run (`npx -y wrangler@4`).

## Running it locally

```bash
BYNK=$(command -v bynk) scripts/check-read-path.sh
BYNK=$(command -v bynk) scripts/check-publish.sh
BYNK=$(command -v bynk) scripts/check-publication.sh
BYNK=$(command -v bynk) scripts/check-accounts.sh
BYNK=$(command -v bynk) scripts/check-trusted.sh
BYNK=$(command -v bynk) scripts/check-limits.sh
BYNK=$(command -v bynk) scripts/check-export.sh
BYNK=$(command -v bynk) scripts/check-withdraw.sh
```

builds a fixture registry (`conformance-fixture/hello`, two versions, one
yanked), seeds `bynk dev`'s local bucket, serves the service, and runs
`bynk registry conformance --read-only` against it, then checks the caching
headers each read path sends. To explore by hand, run
`bynk dev . -- --persist-to <dir>` and seed with
`seed/seed.sh <reg> --bucket registry-store-store --local --persist-to <dir>`.

`check-publish.sh` builds an empty registry with a delegate and an `api`,
serves it with two tokens, and runs the full `bynk registry conformance`; then
publishes, yanks and resolves a package with the real client; then restarts the
service with a key that isn't a delegate and checks it refuses to sign.
`BYNK_HOLD=1` leaves the service up after it starts, for exploring by hand.

`check-publication.sh` publishes a dependency's versions, yanks one and
withdraws another. It then uploads packages whose dependencies don't resolve
and checks each refusal, and checks that a yanked version in range and a
same-tree retry are accepted.

`check-accounts.sh` serves the same empty registry with `scripts/fake-github.py`
standing in for GitHub. It signs two people in through the device flow, claims
organisations, adds a member, mints publish tokens, runs the full conformance
with an account-minted token, and checks that revoked tokens, blocked names,
reserved names and signed-out sessions are refused.

`check-withdraw.sh` publishes two versions and exports them, takes one down
with a `withdraw` token (its purge is `bynk dev`'s no-op, so the refused purge
and its retry are unit tests), and checks the read checks (`read.withdrawn`), a fresh
client failing as `bynk.registry.withdrawn`, a stored tree still building, the
`410` and `409`, the backup without the archive, and the log; then exports an
organisation and restores it, from those exported bytes, into a fresh registry.

R2, `bynk.crypto`, rate limiting and the edge cache are experimental in the
standard library, so `bynk.toml` opts in under `[unstable] allow`; this service
is the workload they graduate on.
