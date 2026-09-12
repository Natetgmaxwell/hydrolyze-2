import Foundation

/// Bundle extensions for the "Copy Debug Info" button in
/// TimingView's .saving view. The button copies a multi-line string
/// to the system clipboard so the user can paste it back into a
/// chat for support / debugging. These helpers surface the build
/// version + iOS version in a friendly format.
///
/// Phase 2.6 v1.8.
extension Bundle {
    /// CFBundleShortVersionString, e.g. "0.1.0"
    var appVersion: String {
        (object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "unknown"
    }

    /// CFBundleVersion, e.g. "42"
    var buildNumber: String {
        (object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "unknown"
    }

    /// A friendly iOS version string, e.g. "iOS 17.5.1 (21F79)".
    /// Falls back to the raw systemVersion if the localized strings
    /// aren't available.
    var osVersion: String {
        let ver = ProcessInfo.processInfo.operatingSystemVersion
        let verStr = "\(ver.majorVersion).\(ver.minorVersion).\(ver.patchVersion)"
        return "iOS \(verStr)"
    }
}
