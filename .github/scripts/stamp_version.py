#!/usr/bin/env python3
"""Synchronize the LaLune release version across source/UI/platform metadata.

Intended for GitHub Actions workflow_dispatch releases.  The script only
touches fields that represent LaLune's own application version; dependency
versions and protocol/core versions are deliberately left untouched.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CHANGED_FILES: set[str] = set()


def fail(message: str) -> "None":
    raise SystemExit(message)


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def write(path: str, value: str) -> None:
    target = ROOT / path
    previous = target.read_text(encoding="utf-8") if target.exists() else None
    if previous != value:
        target.write_text(value, encoding="utf-8")
        CHANGED_FILES.add(path)


def replace_regex(path: str, pattern: str, replacement, *, count: int = 0, expected: int | None = None, flags: int = 0) -> None:
    source = read(path)
    updated, changed = re.subn(pattern, replacement, source, count=count, flags=flags)
    if expected is not None and changed != expected:
        fail(f"{path}: expected {expected} replacement(s), got {changed}")
    if updated != source:
        write(path, updated)


def set_pubspec_version(path: str, version: str) -> None:
    replace_regex(
        path,
        r"(?m)^version:\s*[^\s#]+(\s*(?:#.*)?)$",
        lambda m: f"version: {version}{m.group(1)}",
        count=1,
        expected=1,
    )


def set_package_version(path: str, version: str) -> None:
    # The first top-level version field is the package's version. Dependency
    # versions later in Cargo.toml must not be touched.
    replace_regex(
        path,
        r'(?m)^version\s*=\s*"[^"]+"\s*$',
        f'version = "{version}"',
        count=1,
        expected=1,
    )


def set_cargo_lock_package(path: str, package_name: str, version: str) -> None:
    lock_path = ROOT / path
    if not lock_path.exists():
        return
    source = lock_path.read_text(encoding="utf-8")
    pattern = (
        r'(\[\[package\]\]\s*\n'
        + rf'name = "{re.escape(package_name)}"\s*\nversion = ")[^"]+(")'
    )
    updated, changed = re.subn(pattern, rf"\g<1>{version}\g<2>", source, count=1)
    if changed != 1:
        fail(f"{path}: could not update package {package_name}")
    if updated != source:
        write(path, updated)


def set_plist_bundle_versions(path: str, version: str, build_number: int) -> None:
    source = read(path)

    def set_after_key(text: str, key: str, value: str) -> str:
        pattern = rf"(<key>{re.escape(key)}</key>\s*<string>)[^<]*(</string>)"
        updated, changed = re.subn(pattern, rf"\g<1>{value}\2", text, count=1)
        if changed != 1:
            fail(f"{path}: could not set {key}")
        return updated

    source = set_after_key(source, "CFBundleShortVersionString", version)
    source = set_after_key(source, "CFBundleVersion", str(build_number))
    write(path, source)


def set_android_manifest_versions(path: str, version: str, build_number: int) -> None:
    """Stamp Android versionName/versionCode even when attributes are absent.

    Flutter/Gradle remains the build authority, but keeping the manifests stamped
    makes every checked-in platform manifest agree with the manually selected
    release version and avoids stale version text in source.
    """
    source = read(path)
    match = re.search(r"<manifest\b[^>]*>", source, flags=re.DOTALL)
    if not match:
        fail(f"{path}: <manifest> root tag not found")

    tag = match.group(0)
    if 'xmlns:android=' not in tag:
        fail(f"{path}: android namespace is missing")

    def set_or_insert(attribute: str, value: str) -> None:
        nonlocal tag
        pattern = rf'(android:{re.escape(attribute)}=")[^"]*(")'
        if re.search(pattern, tag):
            tag = re.sub(pattern, rf'\g<1>{value}\2', tag, count=1)
            return

        # Put version attributes immediately after the android namespace line
        # where possible; otherwise append before the closing angle bracket.
        ns = re.search(r'xmlns:android="[^"]+"', tag)
        if not ns:
            fail(f"{path}: android namespace is missing")
        insertion = f'\n    android:{attribute}="{value}"'
        tag = tag[:ns.end()] + insertion + tag[ns.end():]

    set_or_insert("versionName", version)
    set_or_insert("versionCode", str(build_number))
    updated = source[:match.start()] + tag + source[match.end():]
    if updated != source:
        write(path, updated)


def set_project_yml(version: str, build_number: int) -> None:
    path = "Frontend/ios/project.yml"
    source = read(path)

    if re.search(r"(?m)^\s+MARKETING_VERSION:\s*", source):
        source, count = re.subn(
            r'(?m)^(\s+MARKETING_VERSION:\s*).*$',
            rf'\g<1>"{version}"',
            source,
        )
        if count < 1:
            fail(f"{path}: failed to update MARKETING_VERSION")
    else:
        anchor = '    ALWAYS_SEARCH_USER_PATHS: NO\n'
        if anchor not in source:
            fail(f"{path}: insertion anchor not found for MARKETING_VERSION")
        source = source.replace(
            anchor,
            anchor + f'    MARKETING_VERSION: "{version}"\n',
            1,
        )

    if re.search(r"(?m)^\s+CURRENT_PROJECT_VERSION:\s*", source):
        source, count = re.subn(
            r'(?m)^(\s+CURRENT_PROJECT_VERSION:\s*).*$',
            rf'\g<1>"{build_number}"',
            source,
        )
        if count < 1:
            fail(f"{path}: failed to update CURRENT_PROJECT_VERSION")
    else:
        anchor = f'    MARKETING_VERSION: "{version}"\n'
        if anchor not in source:
            fail(f"{path}: insertion anchor not found for CURRENT_PROJECT_VERSION")
        source = source.replace(
            anchor,
            anchor + f'    CURRENT_PROJECT_VERSION: "{build_number}"\n',
            1,
        )

    write(path, source)


def set_xcode_project(version: str, build_number: int) -> None:
    path = "Frontend/ios/Runner.xcodeproj/project.pbxproj"
    source = read(path)
    source, marketing_count = re.subn(
        r"(?m)^(\s*MARKETING_VERSION = )[^;]+;",
        rf"\g<1>{version};",
        source,
    )
    if marketing_count < 1:
        fail(f"{path}: no MARKETING_VERSION entries found")

    # Keep Flutter variable-based Runner build numbers intact; only replace
    # literal CURRENT_PROJECT_VERSION values (used by the extension targets).
    source, current_count = re.subn(
        r"(?m)^(\s*CURRENT_PROJECT_VERSION = )[0-9]+;",
        rf"\g<1>{build_number};",
        source,
    )
    if current_count < 1:
        fail(f"{path}: no literal CURRENT_PROJECT_VERSION entries found")

    write(path, source)


def verify_stamped_version(version: str, build_number: int, windows_version: str) -> None:
    """Fail CI if any checked-in LaLune version field escaped stamping."""

    def require_text(path: str, needle: str) -> None:
        if needle not in read(path):
            fail(f"{path}: expected stamped value not found: {needle!r}")

    # Canonical/UI-visible version sources.
    if read("STABLE").strip() != version:
        fail("STABLE: version did not persist")
    require_text("Frontend/pubspec.yaml", f"version: {version}")
    require_text("Site/pubspec.yaml", f"version: {version}")
    require_text("Site/lib/constants.dart", f"latestVersion    = '{version}'")

    # Android manifests must explicitly carry the selected manual version.
    for manifest in (
        "Frontend/android/app/src/main/AndroidManifest.xml",
        "Frontend/android/app/src/debug/AndroidManifest.xml",
        "Frontend/android/app/src/profile/AndroidManifest.xml",
    ):
        require_text(manifest, f'android:versionName="{version}"')
        require_text(manifest, f'android:versionCode="{build_number}"')

    # Platform manifests/resources.
    require_text("Frontend/windows/runner/runner.exe.manifest", f'version="{windows_version}"')
    require_text("Frontend/windows/runner/Runner.rc", f'#define VERSION_AS_STRING "{version}"')
    for plist in (
        "Frontend/ios/Tunnel/Info.plist",
        "Frontend/ios/Flutter/AppFrameworkInfo.plist",
        "Frontend/ios/Runner/Info.plist",
    ):
        require_text(plist, f"<string>{version}</string>")
        require_text(plist, f"<string>{build_number}</string>")

    # Backend/API sources that are shown to the UI.
    require_text("Backend/Android/Backend.kt", f'const val VERSION = "{version}"')
    require_text("Backend/iOS/Backend.swift", f'private let VERSION = "{version}"')
    require_text("Frontend/ios/Runner/Backend.swift", f'private let VERSION = "{version}"')
    require_text("Backend/Desktop/Cargo.toml", f'version = "{version}"')
    require_text("Backend/OpenWRT/Cargo.toml", f'version = "{version}"')
    require_text("Installer/launcher/Cargo.toml", f'version = "{version}"')
    require_text("Backend/Desktop/src/api.rs", f'"version": "{version}"')
    require_text("Backend/OpenWRT/src/api.rs", f'let local = "{version}"')
    require_text("Backend/OpenWRT/src/api.rs", f'"backend": "{version}"')
    require_text("Backend/OpenWRT/src/api.rs", f'"ui": "{version}"')
    require_text("Frontend/ios/project.yml", f'MARKETING_VERSION: "{version}"')
    require_text("Frontend/ios/project.yml", f'CURRENT_PROJECT_VERSION: "{build_number}"')
    require_text("Frontend/ios/Runner.xcodeproj/project.pbxproj", f'MARKETING_VERSION = {version};')
    require_text("Backend/iOS/Info-patch.md", f'<string>{version}</string>')
    # README-OPENWRT.md is intentionally versionless; do not couple release stamping to docs.

    for lock_path, package_name in (
        ("Backend/Desktop/Cargo.lock", "lalune-backend"),
        ("Backend/OpenWRT/Cargo.lock", "lalune-openwrt-backend"),
        ("Installer/launcher/Cargo.lock", "lalune-installer"),
    ):
        path = ROOT / lock_path
        if not path.exists():
            continue
        package_pattern = (
            r'\[\[package\]\]\s*\n'
            + rf'name = "{re.escape(package_name)}"\s*\nversion = "{re.escape(version)}"'
        )
        if not re.search(package_pattern, path.read_text(encoding="utf-8")):
            fail(f"{lock_path}: package {package_name} is not stamped to {version}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("version", help="Release version in X.Y.Z format, e.g. 0.9.4")
    args = parser.parse_args()

    version = args.version.strip()
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        fail("Version must be exactly X.Y.Z using digits only, e.g. 0.9.4")

    major, minor, patch = map(int, version.split("."))
    if any(part > 65535 for part in (major, minor, patch)):
        fail("Each version component must be <= 65535 (Windows version resource limit)")

    # Stable numeric build identifier suitable for CFBundleVersion and future
    # platform build-number use. Public/versionName remains exactly X.Y.Z.
    build_number = major * 1_000_000 + minor * 1_000 + patch
    windows_version = f"{major}.{minor}.{patch}.0"

    # Canonical release marker and Flutter/UI metadata.
    write("STABLE", version + "\n")
    set_pubspec_version("Frontend/pubspec.yaml", version)
    set_pubspec_version("Site/pubspec.yaml", version)
    for manifest in (
        "Frontend/android/app/src/main/AndroidManifest.xml",
        "Frontend/android/app/src/debug/AndroidManifest.xml",
        "Frontend/android/app/src/profile/AndroidManifest.xml",
    ):
        set_android_manifest_versions(manifest, version, build_number)
    replace_regex(
        "Site/lib/constants.dart",
        r"(static const String latestVersion\s*=\s*')[^']+(';\s*)",
        rf"\g<1>{version}\2",
        count=1,
        expected=1,
    )

    # App/backend package versions.
    set_package_version("Backend/Desktop/Cargo.toml", version)
    set_package_version("Backend/OpenWRT/Cargo.toml", version)
    set_package_version("Installer/launcher/Cargo.toml", version)

    set_cargo_lock_package("Backend/Desktop/Cargo.lock", "lalune-backend", version)
    set_cargo_lock_package("Backend/OpenWRT/Cargo.lock", "lalune-openwrt-backend", version)
    set_cargo_lock_package("Installer/launcher/Cargo.lock", "lalune-installer", version)

    # Platform backend versions shown by the UI/API.
    replace_regex(
        "Backend/Android/Backend.kt",
        r'(const val VERSION\s*=\s*")[^"]+(")',
        rf"\g<1>{version}\2",
        count=1,
        expected=1,
    )
    replace_regex(
        "Backend/iOS/Backend.swift",
        r'(private let VERSION\s*=\s*")[^"]+(")',
        rf"\g<1>{version}\2",
        count=1,
        expected=1,
    )
    replace_regex(
        "Frontend/ios/Runner/Backend.swift",
        r'(private let VERSION\s*=\s*")[^"]+(")',
        rf"\g<1>{version}\2",
        count=1,
        expected=1,
    )

    # Desktop Rust: /version is build-time injected, but /ping also exposes a
    # literal version and must agree with the rest of the app.
    replace_regex(
        "Backend/Desktop/src/api.rs",
        r'("ok": true,\s*\n\s*"version": ")[^"]+(")',
        rf"\g<1>{version}\2",
        count=1,
        expected=1,
    )

    # OpenWRT currently has no build.rs injection, so stamp every LaLune API
    # version field explicitly while leaving protocol/dependency versions alone.
    replace_regex(
        "Backend/OpenWRT/src/api.rs",
        r'("ok": true,\s*"version": ")[^"]+(")',
        rf"\g<1>{version}\2",
        count=1,
        expected=1,
    )
    replace_regex(
        "Backend/OpenWRT/src/api.rs",
        r'("backend": ")[^"]+(",\s*"core": "unknown",\s*"ui": ")[^"]+(")',
        rf"\g<1>{version}\g<2>{version}\g<3>",
        count=1,
        expected=1,
    )
    replace_regex(
        "Backend/OpenWRT/src/api.rs",
        r'(let local = ")[^"]+(";\s*)',
        rf"\g<1>{version}\2",
        count=1,
        expected=1,
    )

    # Windows resource fallbacks are used if Flutter compile definitions are
    # unavailable; keep them in sync too.
    replace_regex(
        "Frontend/windows/runner/Runner.rc",
        r"(?m)^#define VERSION_AS_NUMBER [0-9]+,[0-9]+,[0-9]+,[0-9]+$",
        f"#define VERSION_AS_NUMBER {major},{minor},{patch},0",
        count=1,
        expected=1,
    )
    replace_regex(
        "Frontend/windows/runner/Runner.rc",
        r'(?m)^#define VERSION_AS_STRING "[^"]+"$',
        f'#define VERSION_AS_STRING "{version}"',
        count=1,
        expected=1,
    )

    # Windows manifest and iOS bundle metadata.
    replace_regex(
        "Frontend/windows/runner/runner.exe.manifest",
        r'(<assemblyIdentity\s*\n\s*version=")[^"]+(")',
        rf"\g<1>{windows_version}\2",
        count=1,
        expected=1,
    )
    set_plist_bundle_versions("Frontend/ios/Tunnel/Info.plist", version, build_number)
    set_plist_bundle_versions("Frontend/ios/Flutter/AppFrameworkInfo.plist", version, build_number)
    set_plist_bundle_versions("Frontend/ios/Runner/Info.plist", version, build_number)

    # XcodeGen config is stamped as well so regenerated iOS projects retain the
    # requested marketing/build versions instead of falling back to 1.0 / 1.
    set_project_yml(version, build_number)
    set_xcode_project(version, build_number)

    # Keep version-bearing deployment/documentation snippets from lying about
    # the current release when somebody follows them manually.
    replace_regex(
        "Backend/iOS/Info-patch.md",
        r'(<key>CFBundleShortVersionString</key>\s*\n<string>)[^<]+(</string>)',
        rf"\g<1>{version}\g<2>",
        count=1,
        expected=1,
    )
    replace_regex(
        "Backend/iOS/Info-patch.md",
        r'(<key>CFBundleVersion</key>\s*\n<string>)[^<]+(</string>)',
        rf"\g<1>{build_number}\g<2>",
        count=1,
        expected=1,
    )
    # Installer/README-OPENWRT.md no longer embeds a literal JSON version.
    # Keeping the README out of release stamping makes workflow_dispatch idempotent
    # and prevents documentation wording changes from breaking the whole build.

    verify_stamped_version(version, build_number, windows_version)

    if CHANGED_FILES:
        print("Changed version files:")
        for path in sorted(CHANGED_FILES):
            print(f"  - {path}")
    else:
        print("All version files were already synchronized.")
    print(f"LaLune version synchronized to {version} (build {build_number})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
