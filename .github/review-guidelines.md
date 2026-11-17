# Review guidelines for the Bynk registry

These are the maintainers' notes for reviewing a pull request here. The
repository is the first-party Bynk package registry: a hosted instance of the
registry protocol, written in Bynk and deployed on Cloudflare Workers with
R2, the edge cache, rate limiting and agents. Every organisation not routed
elsewhere resolves packages here, so a mistake can reach every Bynk user.
The README is the service's specification and operator manual. Issue and pull
request numbers in comments are `bynk-lang/bynk`'s unless they say otherwise.

Skip what CI already enforces: `bynk check`, the unit tests in `tests/`, the
end-to-end scripts (`scripts/check-*.sh`), the deploy guard's tests and the
no-registry-dependencies check, all on the pinned toolchain.

## What matters most

- **The extraction rules, E1–E5** (README). The project reaches only
  `bynk-std`, its own files and lock-pinned git dependencies (E1). No Rust in
  the service; the shared rules come as the pinned release's wasm module (E2).
  No account ids, secrets or keys in git (E3). Deploys come only from the
  manual workflow (E4). **Never a registry dependency (E5)**, so a broken
  registry can always be redeployed. A change that bends one is blocking.
- **Integrity.** Clients verify each index line's signature and each
  archive's checksum, and the service must never undermine that:
  - an archive at `dl/sha256/<hex>` never changes once stored, and only a
    takedown removes it;
  - a published index line is never rewritten, except as the README describes
    for a yank or a takedown;
  - the service signs only with a delegate key it has checked against
    `config.json` first, and the root key never reaches it;
  - every registry dependency of an upload resolves here (the publication
    rule).
- **Names and keys.** An organisation, package or digest is checked against
  the manifest's rules (`paths.bynk`) before it reaches the bucket. Flag a new
  path to the bucket that skips them.
- **Authentication and authorisation.** Publish tokens are checked by their
  sha256, and are shown once, never stored or logged in the clear. Each route
  checks the token's organisations and capabilities (`publish`, `yank`,
  `operate`, `withdraw`) before acting. Trusted publishing checks the OIDC
  token's issuer, audience and claims against the registered publisher before
  any exchange. `REGISTRY_OIDC_TRUST` is never for production. Flag a route
  that acts before these checks, or a capability granted more widely than the
  README says.
- **The edge cache.** The edge keys a response by its URL alone and shares a
  `public` response even when the request carried a token. So a `public`
  route answers the same bytes to everyone (`by Visitor`), and anything that
  depends on who is asking, every error and the account API are `no-store`.
  A yank, an un-yank or a takedown purges what it changes. Flag a cacheable
  response that could differ by caller, or a change that leaves a stale copy
  past the README's bounds.
- **Limits and quotas.** Writes and the account API are rate-limited, and
  uploads count against the organisation's quota, as the README's "Limits"
  table says. A new write route needs a limit; changing a limit changes that
  table.
- **Restores and takedowns** never overwrite a name held otherwise, and an
  interrupted one can be finished by repeating it.

## Bynk

- Typed reads and records over hand-built JSON. Results that can fail are
  `Result`, and a failure is answered with the protocol's error, never
  dropped.
- One context, `registry.store`, owns the bucket and the edge cache; code that
  needs them lives there.
- Experimental modules are listed under `[unstable] allow` in `bynk.toml`,
  with the comment saying why.
- A capability the service needs lands in `bynk-lang/bynk` first and ships in
  a release. Bumping `bynk-toolchain` is a pull request changing that one
  line, and nothing else.

## Tests

- A change of behaviour gets a unit test in `tests/`, with the bucket,
  secrets, crypto and admission stubbed. A change to a route also belongs in
  its end-to-end script, which runs the real router, crypto and module.
- Look for missing cases: a bad or expired token, a token for another
  organisation, a malformed name, a retry of the same tree, a conflicting
  version, a quota or limit reached, and a purge Cloudflare refuses.

## Documentation and style

- The README is the specification. A change to a route, an answer, a header,
  a limit, a secret or an operator step updates its section in the same pull
  request, and a new file gets its row in the Layout table.
- British English throughout: in comments, the README and the service's
  messages ("organisation", "behaviour", "authorise"; "licence" as a noun).
- Comments explain why, in plain sentences, and name the decision or issue
  behind them.

## Severity here

- **Blocking:** a security hole (authentication, authorisation, a name that
  reaches the bucket unchecked, a secret exposed), an integrity break, a
  shared cache answer that differs by caller, a bent extraction rule, lost
  data, or a deploy that would fail.
- **Should fix:** a missing test or end-to-end check for changed behaviour, a
  failure answered wrongly, a missing limit, or a README out of step with the
  code.
- **Nit:** wording, naming and small style points. Keep these few.
