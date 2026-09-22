// SPDX-FileCopyrightText: 2026 luminescq
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

package libs

import (
	"fmt"
	"runtime"
	"strings"
)

// ProtocolSpec describes a downloadable VPN core hosted on GitHub Releases.
//
// LaLune follows the same pattern for every protocol: read the repo's LATEST
// file to discover the newest tag, then download the platform asset from the
// matching release. CSQTT is the original implementation; the others were added
// so the client can also drive FreeTurnProxy, OlcRTC, OpenFlux and ToTS.
type ProtocolSpec struct {
	// ID is the lowercase protocol identifier persisted in the DB and used in
	// link schemes / UI.
	ID string
	// DisplayName is shown in the UI.
	DisplayName string
	// Repo is the GitHub "owner/name" the core is published from.
	Repo string
	// LatestURL points at the repo's LATEST file (raw).
	LatestURL string
	// AssetTemplate is the release asset URL with two %s placeholders:
	// the version tag and the asset file name.
	AssetTemplate string
	// Realtime reports whether the transport is media-like (VK calls, Telemost)
	// as opposed to document/messaging based.
	Realtime bool
	// Description is a short human summary.
	Description string
}

// csqttSpec preserves the original, already-shipping behaviour.
var csqttSpec = ProtocolSpec{
	ID:            "CSQTT",
	DisplayName:   "CSQTT (VK Calls)",
	Repo:          "Endlad2/csqtt-core",
	LatestURL:     "https://raw.githubusercontent.com/Endlad2/csqtt-core/refs/heads/main/LATEST",
	AssetTemplate: "https://github.com/Endlad2/csqtt-core/releases/download/%s/%s",
	Realtime:      true,
	Description:   "Оригинальный протокол на базе VK Calls, TURN и WRAP.",
}

// freeturnSpec maps to github.com/Endlad2/free-turn-proxy-core.
var freeturnSpec = ProtocolSpec{
	ID:            "FREETURN",
	DisplayName:   "FreeTurnProxy",
	Repo:          "Endlad2/free-turn-proxy-core",
	LatestURL:     "https://raw.githubusercontent.com/Endlad2/free-turn-proxy-core/refs/heads/master/LATEST",
	AssetTemplate: "https://github.com/Endlad2/free-turn-proxy-core/releases/download/%s/%s",
	Realtime:      true,
	Description:   "WireGuard поверх VK/TURN, шифрование WRAP как в FreeTurnProxy.",
}

// olcrtcSpec maps to github.com/Endlad2/olcrtc-core (Telemost, VK Stream).
var olcrtcSpec = ProtocolSpec{
	ID:            "OLCRTC",
	DisplayName:   "OlcRTC (Telemost / VK Stream)",
	Repo:          "Endlad2/olcrtc-core",
	LatestURL:     "https://raw.githubusercontent.com/Endlad2/olcrtc-core/refs/heads/master/LATEST",
	AssetTemplate: "https://github.com/Endlad2/olcrtc-core/releases/download/%s/%s",
	Realtime:      true,
	Description:   "Риалтайм-транспорты Яндекс.Телемост и VK Stream (LiveKit/WebRTC).",
}

// openfluxSpec maps to github.com/Endlad2/OpenFlux-core.
var openfluxSpec = ProtocolSpec{
	ID:            "OPENFLUX",
	DisplayName:   "OpenFlux (Docs / Max / OneME)",
	Repo:          "Endlad2/OpenFlux-core",
	LatestURL:     "https://raw.githubusercontent.com/Endlad2/OpenFlux-core/refs/heads/main/LATEST",
	AssetTemplate: "https://github.com/Endlad2/OpenFlux-core/releases/download/%s/%s",
	Realtime:      false,
	Description:   "Документные транспорты: Яндекс.Документы, Mail Docs, MAX, OneME.",
}

// totsSpec maps to github.com/Endlad2/ToTS — the unified Rust core.
var totsSpec = ProtocolSpec{
	ID:            "TOTS",
	DisplayName:   "ToTS (все транспорты)",
	Repo:          "Endlad2/ToTS",
	LatestURL:     "https://raw.githubusercontent.com/Endlad2/ToTS/refs/heads/main/LATEST",
	AssetTemplate: "https://github.com/Endlad2/ToTS/releases/download/%s/%s",
	Realtime:      true,
	Description:   "Rust-ядро: VK, Telemost, VK Stream, Docs, Mail Docs, MAX, OneME поверх WireGuard/Xray.",
}

// SupportedProtocols lists every protocol the client can download a core for.
var SupportedProtocols = []ProtocolSpec{
	csqttSpec,
	freeturnSpec,
	olcrtcSpec,
	openfluxSpec,
	totsSpec,
}

// ProtocolByID returns the spec for a protocol id (case-insensitive).
func ProtocolByID(id string) (ProtocolSpec, bool) {
	up := strings.ToUpper(strings.TrimSpace(id))
	for _, p := range SupportedProtocols {
		if p.ID == up {
			return p, true
		}
	}
	return ProtocolSpec{}, false
}

// CoreAssetName returns the release asset file name for a protocol on the
// current OS/arch, matching the naming used by each repo's CI:
//
//	csqtt     -> client-{windows-x86_64.exe|macos-x86_64|linux-x86_64}
//	freeturn  -> freeturn-{os}-{arch}.tar.gz / .zip
//	olcrtc    -> olcrtc-{os}-{arch}.tar.gz
//	openflux  -> openflux-{os}-{arch}.tar.gz
//	tots      -> tots-{os}-{arch}.tar.gz / .zip
//
// When a platform is not published the function returns the best-effort name so
// callers can surface a clear error instead of panicking.
func CoreAssetName(spec ProtocolSpec, goos, goarch string) string {
	if spec.ID == csqttSpec.ID {
		switch goos {
		case "windows":
			return "client-windows-x86_64.exe"
		case "darwin":
			return "client-macos-x86_64"
		default:
			return "client-linux-x86_64"
		}
	}

	osName := mapOS(goos)
	archName := mapArch(goarch)
	base := fmt.Sprintf("%s-%s-%s", strings.ToLower(spec.ID), osName, archName)

	// Desktop releases are archived; Windows uses .zip, the rest use .tar.gz.
	if goos == "windows" {
		return base + ".zip"
	}
	return base + ".tar.gz"
}

func mapOS(goos string) string {
	switch goos {
	case "windows":
		return "windows"
	case "darwin":
		return "macos"
	default:
		return "linux"
	}
}

func mapArch(goarch string) string {
	switch goarch {
	case "arm64":
		return "arm64"
	default:
		return "amd64"
	}
}

// CurrentCoreAssetName returns the asset name for the running platform.
func CurrentCoreAssetName(spec ProtocolSpec) string {
	return CoreAssetName(spec, runtime.GOOS, runtime.GOARCH)
}
