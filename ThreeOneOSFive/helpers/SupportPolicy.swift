import Foundation

enum ExploitSupportPolicy {
    static let verifiedIOS17Range = "17.0–17.7.x"
    static let verifiedIOS18Range = "18.0–18.7.1"
    static let verifiedIOS26Range = "26.0–26.6.1"

    static let verifiedIOS27Builds: [(beta: Int, publicBeta: Int?, build: String)] = [
        (1, nil, "24A5355q"),
        (2, nil, "24A5370h"),
        (3, 1, "24A5380h"),
        (4, 2, "24A5390f")
    ]

    static func iOS27BetaNumber(for build: String) -> Int? {
        verifiedIOS27Builds.first { $0.build == build }?.beta
    }

    static func iOS27PublicBetaNumber(for build: String) -> Int? {
        verifiedIOS27Builds.first { $0.build == build }?.publicBeta
    }

    static func supportsKernelExploit(major: Int, minor: Int, patch: Int) -> Bool {
        guard minor >= 0, patch >= 0 else { return false }

        if major == 17 {
            return minor <= 7
        }

        if major == 18 {
            return minor < 7 || (minor == 7 && patch <= 1)
        }

        return false
    }

    static func isSupported(major: Int, minor: Int, patch: Int, build: String) -> Bool {
        if supportsKernelExploit(major: major, minor: minor, patch: patch) {
            return true
        }

        if major == 26 {
            guard minor >= 0, patch >= 0 else { return false }
            return minor < 6 || (minor == 6 && patch <= 1)
        }

        guard major == 27, minor == 0, patch == 0 else { return false }
        return iOS27BetaNumber(for: build) != nil
    }
}


// MARK: - Hybrid backend compatibility (diagnostic only)
//
// This is a roadmap, NOT an implementation of worse_query. Do not use
// proposedBackend() to authorize filesystem access or report patch success.
// The existing ExploitSupportPolicy / KernelExploit implementation is unchanged.
enum HybridBackendCandidate: String {
    case legacy3105 = "legacy_3105"
    case worseQuery = "worse_query"
    case unavailable = "unavailable"
}

enum HybridBackendAdvisor {
    // Must only become true when a separate, signed-on-device, write/restore
    // verified integration exists. Currently there is NO such adapter.
    static let worseQueryImplemented = false

    static func proposedBackend(
        major: Int, minor: Int, patch: Int, build: String
    ) -> HybridBackendCandidate {
        guard minor >= 0, patch >= 0 else { return .unavailable }

        // Based on the 3106 3.2.8 published compatibility policy, NOT
        // independently verified on this GooHan build.
        if major == 26, minor == 7, patch <= 2 {
            return .worseQuery
        }
        if major == 27 {
            if minor <= 2 { return .worseQuery }
            if minor == 3, patch == 0, build == "24C5037i" {
                return .worseQuery
            }
        }

        if ExploitSupportPolicy.isSupported(
            major: major, minor: minor, patch: patch, build: build
        ) {
            return .legacy3105
        }
        return .unavailable
    }

    // The *actual* usable route, unlike the proposed route above.
    // Never announce iOS 27.2 as supported just because the policy maps it.
    static func integratedBackend(
        major: Int, minor: Int, patch: Int, build: String
    ) -> HybridBackendCandidate {
        if ExploitSupportPolicy.isSupported(
            major: major, minor: minor, patch: patch, build: build
        ) {
            return .legacy3105
        }
        return .unavailable
    }

    static func diagnostic(
        major: Int, minor: Int, patch: Int, build: String
    ) -> String {
        let candidate = proposedBackend(
            major: major, minor: minor, patch: patch, build: build
        )
        let active = integratedBackend(
            major: major, minor: minor, patch: patch, build: build
        )
        let needsAppGroup = candidate == .worseQuery
        return "hybrid: integrated=\(active.rawValue) proposed=\(candidate.rawValue) " +
               "worse_query_ready=\(worseQueryImplemented) app_group_required=\(needsAppGroup)"
    }
}


// MARK: - User-selectable package format preference
//
// This controls which package FORMAT is shown by the Admin catalog.
// It does NOT select or enable a sandbox backend or make .3106 patches
// executable. The effective selection never bypasses write verification.
enum GooHanPackagePreference: String, CaseIterable {
    case automatic = "auto"
    case legacy3105 = "3105"
    case modern3106 = "3106"

    static let storageKey = "gohan.hybrid.package-format"

    static func effectiveFormat(
        rawValue: String, major: Int, minor: Int
    ) -> String {
        switch GooHanPackagePreference(rawValue: rawValue) ?? .automatic {
        case .legacy3105: return "3105"
        case .modern3106: return "3106"
        case .automatic:
            // 3106's proposed backend starts at 26.7; older supported OS
            // versions continue to prefer the 3105 package workflow.
            if major >= 27 || (major == 26 && minor >= 7) {
                return "3106"
            }
            return "3105"
        }
    }

    // Until a real decoder/verified write backend is integrated, the
    // experimental mode remains view-only. Restore is handled separately.
    static func canApply(format: String) -> Bool {
        format == "3105"
    }
}
