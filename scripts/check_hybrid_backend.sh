#!/usr/bin/env bash
# Pure policy tests. This does not execute a sandbox backend or patch files.
set -euo pipefail
cd "$(dirname "$0")/.."
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
cat > "$scratch/main.swift" <<'SWIFT'
import Foundation

typealias Candidate = HybridBackendCandidate
let samples: [(String, Int, Int, Int, String, Candidate, Candidate)] = [
    ("17.6", 17, 6, 0, "", .legacy3105, .legacy3105),
    ("18.7.1", 18, 7, 1, "", .legacy3105, .legacy3105),
    ("18.7.2", 18, 7, 2, "", .unavailable, .unavailable),
    ("26.6.1", 26, 6, 1, "", .legacy3105, .legacy3105),
    ("26.7.2", 26, 7, 2, "", .worseQuery, .unavailable),
    ("27.0 beta 1 (legacy)", 27, 0, 0, "24A5355q", .worseQuery, .legacy3105),
    ("27.0", 27, 0, 0, "", .worseQuery, .unavailable),
    ("27.2", 27, 2, 0, "", .worseQuery, .unavailable),
    ("27.3 beta 1", 27, 3, 0, "24C5037i", .worseQuery, .unavailable),
    ("27.3 beta 2", 27, 3, 0, "24C5049d", .unavailable, .unavailable),
]
precondition(!HybridBackendAdvisor.worseQueryImplemented, "Experimental backend must not be marked integrated")
for (label, major, minor, patch, build, expectedProposal, expectedIntegrated) in samples {
    let proposal = HybridBackendAdvisor.proposedBackend(
        major: major, minor: minor, patch: patch, build: build
    )
    let integrated = HybridBackendAdvisor.integratedBackend(
        major: major, minor: minor, patch: patch, build: build
    )
    precondition(proposal == expectedProposal, "\(label) proposed \(proposal), expected \(expectedProposal)")
    precondition(integrated == expectedIntegrated, "\(label) integrated \(integrated), expected \(expectedIntegrated)")
    print("PASS \(label): proposed=\(proposal.rawValue) integrated=\(integrated.rawValue)")
}
print("HYBRID_POLICY_TESTS_PASS")
SWIFT
swiftc ThreeOneOSFive/helpers/SupportPolicy.swift "$scratch/main.swift" -o "$scratch/check_hybrid"
"$scratch/check_hybrid"
