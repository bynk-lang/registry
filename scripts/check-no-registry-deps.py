"""E5, kept forever (R7, bynk-lang/bynk#2415, decision H): the service never
depends on a registry, so a broken registry, or a bad toolchain release, can
never stop the fix from being redeployed. Every dependency is a git dependency
(pinned by the lock) or a path inside this repository.

    python3 scripts/check-no-registry-deps.py bynk.toml
"""
import pathlib
import sys
import tomllib

manifest = pathlib.Path(sys.argv[1]).resolve()
root = manifest.parent
doc = tomllib.loads(manifest.read_text())
bad = []
for table in ("dependencies", "dev-dependencies"):
    for alias, spec in doc.get(table, {}).items():
        if not isinstance(spec, dict):
            bad.append(f"[{table}] {alias}: not a git or path dependency")
        elif "git" in spec:
            continue
        elif "path" in spec:
            target = (root / spec["path"]).resolve()
            if root not in (target, *target.parents):
                bad.append(f"[{table}] {alias}: the path `{spec['path']}` leaves this repository")
        else:
            bad.append(f"[{table}] {alias}: a registry dependency")
if bad:
    print("E5: the service never depends on a registry:", *bad, sep="\n  ", file=sys.stderr)
    sys.exit(1)
print("E5: no registry dependencies")
