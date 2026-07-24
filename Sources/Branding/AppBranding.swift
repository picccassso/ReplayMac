/// The user-facing product name, injected at launch by the app target.
///
/// The direct/GitHub build brands itself "ReplayMac"; the Mac App Store build
/// brands itself "ReplayCap" (App Review Guideline 5.2.5 forbids "Mac" in App
/// Store app names). The `APPSTORE` compilation condition only reaches
/// `Sources/App` — Xcode build settings do not propagate into SwiftPM package
/// targets — so package modules read this value at runtime instead of using
/// `#if APPSTORE` themselves.
///
/// On-disk identifiers (metadata file names, long-buffer folder names, the
/// segment file prefix) intentionally do NOT use this value: both builds must
/// read and write the same files, so those stay literal `ReplayCap` with
/// one-time migrations from the legacy `ReplayMac` names.
public enum AppBranding {
    /// Set exactly once, before the app builds any UI or touches settings.
    /// Defaults to the canonical name so tests and previews, which never run
    /// the app entry point, see stable branding.
    nonisolated(unsafe) public static var name = "ReplayCap"

    /// Whether a fresh install must begin without any proposed output folder.
    /// The App Store build sets this to `true`; the direct build sets it to
    /// `false` so it can retain its traditional Movies/ReplayMac default.
    nonisolated(unsafe) public static var requiresExplicitOutputDirectorySelection = true
}
