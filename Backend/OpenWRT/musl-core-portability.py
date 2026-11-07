#!/usr/bin/env python3
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
"""Patch pinned CSQTT/CSQTTR Rust clients for current libc musl bindings.

libc 0.2.189 changed the musl recvmmsg/sendmmsg flags argument to c_uint
and made padding fields of msghdr private. Older pinned clients still use
c_int and struct-literal construction, so patch the extracted source before
cross-compiling for OpenWRT.
"""

from pathlib import Path
import sys

client = Path(sys.argv[1])
udp_batch = client / "udp_batch.rs"

if not udp_batch.is_file():
    print(f"[musl-portability] no udp_batch.rs in {client}; nothing to patch")
    raise SystemExit(0)

text = udp_batch.read_text(encoding="utf-8")
original = text

replacements = {
    "libc::recvmmsg(fd, messages, count, flags, timeout)":
        "libc::recvmmsg(fd, messages, count, flags as libc::c_uint, timeout)",
    "libc::sendmmsg(fd, messages, count, flags)":
        "libc::sendmmsg(fd, messages, count, flags as libc::c_uint)",
}
for old, new in replacements.items():
    if old in text:
        text = text.replace(old, new)

signature = "fn mmsg_header(iovec: *mut libc::iovec) -> libc::mmsghdr {"
start = text.find(signature)
if start != -1:
    brace = text.find("{", start)
    depth = 0
    end = None
    for pos in range(brace, len(text)):
        ch = text[pos]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                end = pos + 1
                break
    if end is None:
        raise SystemExit("unterminated mmsg_header function")

    current = text[start:end]
    if "libc::msghdr {" in current:
        indent = text[text.rfind("\n", 0, start) + 1:start]
        replacement_lines = [
            "fn mmsg_header(iovec: *mut libc::iovec) -> libc::mmsghdr {",
            "    // libc's musl msghdr contains private padding fields. Zero-initialize",
            "    // the C structs and assign only their public ABI fields instead of",
            "    // using a struct literal.",
            "    let mut message: libc::mmsghdr = unsafe { std::mem::zeroed() };",
            "    message.msg_hdr.msg_iov = iovec;",
            "    message.msg_hdr.msg_iovlen = 1;",
            "    message",
            "}",
        ]
        replacement = ("\n" + indent).join(replacement_lines)
        text = text[:start] + replacement + text[end:]

bad = [
    "libc::recvmmsg(fd, messages, count, flags, timeout)",
    "libc::sendmmsg(fd, messages, count, flags)",
    "msg_hdr: libc::msghdr {",
]
remaining = [needle for needle in bad if needle in text]
if remaining:
    raise SystemExit(f"musl portability patch incomplete: {remaining}")

if text != original:
    udp_batch.write_text(text, encoding="utf-8")
    print(f"[musl-portability] patched {udp_batch}")
else:
    print(f"[musl-portability] {udp_batch} already compatible")
