#!/usr/bin/env python3
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
"""Adapt the pinned upstream clients to MIPS32 and musl."""

import re
import sys
from pathlib import Path

client = Path(sys.argv[1])
wide_atomics = {"AtomicI64", "AtomicU64"}
qualified = re.compile(r"std::sync::atomic::(Atomic[IU]64)\b")
atomic_group = re.compile(r"\batomic::\{([\w, ]+)\}")
changed = False

for path in client.glob("*.rs"):
    original = path.read_text(encoding="utf-8")
    imports = set()

    def split_import(match):
        names = match[1].split(", ")
        imports.update(wide_atomics.intersection(names))
        return "atomic::{" + ", ".join(name for name in names if name not in wide_atomics) + "}"

    source = qualified.sub(r"portable_atomic::\1", original)
    source = atomic_group.sub(split_import, source)
    if imports:
        source += "\nuse portable_atomic::{" + ", ".join(sorted(imports)) + "};\n"
    if source != original:
        path.write_text(source, encoding="utf-8")
        changed = True

assert changed, f"No upstream atomic imports found in {client}"

# musl socket ABI fixes are applied by musl-core-portability.py.
manifest = client / "Cargo.toml"
text = manifest.read_text(encoding="utf-8")
assert "[dependencies]\n" in text and "portable-atomic" not in text
manifest.write_text(
    text.replace("[dependencies]\n", '[dependencies]\nportable-atomic = "=1.15.0"\n', 1),
    encoding="utf-8",
)

# Preserve all upstream dependency versions and extend the lock with this one crate.
lock = client / "Cargo.lock"
text = lock.read_text(encoding="utf-8")
package = "\n[[package]]\n"
client_package = package + 'name = "csqtt-client"\n'
before, client_and_rest = text.split(client_package, 1)
upstream_client, after = client_and_rest.split(package, 1)
assert '\n "primp",\n' in upstream_client
upstream_client = upstream_client.replace('\n "primp",\n', '\n "portable-atomic",\n "primp",\n', 1)
marker = package + 'name = "powerfmt"'
assert marker in after and 'name = "portable-atomic"' not in text
portable_atomic = """
[[package]]
name = "portable-atomic"
version = "1.15.0"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "05c8b63e8d9609db387f0324918f81d68fe27748f084ef092fb35954d0539a85"
"""
lock.write_text(
    before + client_package + upstream_client + package + after.replace(marker, portable_atomic + marker, 1),
    encoding="utf-8",
)
