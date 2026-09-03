import AppKit
import Foundation

/// Light / Dark / follow the system.
///
/// The app adapts on its own - every colour it draws is either semantic or a
/// dynamic `NSColor` - so `.system` is both the default and the honest answer for
/// most people. The override exists because judging an image is different from
/// using an app: a white surround makes a dark photo look washed out and a dark
/// surround does the reverse, so being able to pin the appearance while comparing
/// is a real need rather than a preference-panel ornament.
enum AppearanceSetting: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    var displayName: String {
        switch self {
        case .system: return "Match System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// `nil` means "inherit", which is what makes the app follow the system again.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

enum OutputBehavior: String, CaseIterable, Sendable {
    case alongside   // alongside original, with suffix
    case folder      // into a chosen folder
    case inplace     // overwrite original

    var displayName: String {
        switch self {
        case .alongside: return "Alongside original (with suffix)"
        case .folder: return "Into a chosen folder"
        case .inplace: return "In place (overwrite)"
        }
    }
}

/// Thin wrapper around `UserDefaults.standard`.
/// Every property reads/writes straight through - no caching, so multiple
/// windows (main + settings) always agree. Marked `@unchecked Sendable` because
/// UserDefaults is documented thread-safe and this type holds no other state.
///
/// This used to be `UserDefaults(suiteName: "com.fxreza.squish")`, which is the
/// app's own bundle identifier. Apple documents that as invalid - a suite name
/// must not be your own bundle id - and AppKit logs "does not make sense and
/// will not work". `UserDefaults.standard` already resolves to exactly that
/// domain, so the suite was both redundant and broken, and settings did not
/// reliably survive a relaunch.
///
/// **Quality is deliberately absent.** It used to live here, and be duplicated
/// between the Settings window's three sliders and the main window. There is now
/// exactly one quality control - the slider in the main window - and it is
/// session-only state that resets to 75 on every launch, by request. Settings
/// keeps only what genuinely should persist: where output goes and how it is named.
final class Preferences: @unchecked Sendable {
    static let shared = Preferences()

    /// The slider's launch value. Not persisted - this is the value on every launch.
    static let defaultQuality = 75
    /// The vlossless metric target's launch value. Also session-only, so the one
    /// slider in the window behaves the same way whichever mode it is showing.
    static let defaultTarget = 90

    let defaults: UserDefaults

    private enum Key {
        static let defaultMode = "defaultMode"
        static let outputBehavior = "outputBehavior"
        static let outputFolderPath = "outputFolderPath"
        static let suffix = "suffix"
        static let keepMetadata = "keepMetadata"
        static let maxDimensionEnabled = "maxDimensionEnabled"
        static let maxDimension = "maxDimension"
        static let appearance = "appearance"
    }

    init() {
        self.defaults = .standard
        registerDefaults()
        // Earlier builds persisted quality here; drop the stale keys so nothing
        // can quietly disagree with the window's slider.
        for legacy in ["qualityWeb", "qualityWebp", "vlosslessTarget"] {
            defaults.removeObject(forKey: legacy)
        }
    }

    private func registerDefaults() {
        defaults.register(defaults: [
            Key.defaultMode: SquishMode.jpeg.rawValue,
            Key.outputBehavior: OutputBehavior.alongside.rawValue,
            Key.outputFolderPath: "",
            Key.suffix: "-squish",
            Key.keepMetadata: false,
            Key.maxDimensionEnabled: false,
            Key.maxDimension: 2048,
            Key.appearance: AppearanceSetting.system.rawValue
        ])
    }

    var defaultMode: SquishMode {
        get { SquishMode.parse(defaults.string(forKey: Key.defaultMode)) ?? .jpeg }
        set { defaults.set(newValue.rawValue, forKey: Key.defaultMode) }
    }

    var outputBehavior: OutputBehavior {
        get { OutputBehavior(rawValue: defaults.string(forKey: Key.outputBehavior) ?? "") ?? .alongside }
        set { defaults.set(newValue.rawValue, forKey: Key.outputBehavior) }
    }

    var outputFolderPath: String {
        get { defaults.string(forKey: Key.outputFolderPath) ?? "" }
        set { defaults.set(newValue, forKey: Key.outputFolderPath) }
    }

    var suffix: String {
        get { defaults.string(forKey: Key.suffix) ?? "-squish" }
        set { defaults.set(newValue, forKey: Key.suffix) }
    }

    var keepMetadata: Bool {
        get { defaults.bool(forKey: Key.keepMetadata) }
        set { defaults.set(newValue, forKey: Key.keepMetadata) }
    }

    var maxDimensionEnabled: Bool {
        get { defaults.bool(forKey: Key.maxDimensionEnabled) }
        set { defaults.set(newValue, forKey: Key.maxDimensionEnabled) }
    }

    var maxDimension: Int {
        get { defaults.integer(forKey: Key.maxDimension) }
        set { defaults.set(newValue, forKey: Key.maxDimension) }
    }

    var appearance: AppearanceSetting {
        get { AppearanceSetting(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system }
        set {
            defaults.set(newValue.rawValue, forKey: Key.appearance)
            // The setter is nonisolated but NSApp is main-actor only, so hop rather
            // than assume: this is also called from the Settings window's handler.
            Task { @MainActor in Preferences.shared.applyAppearance() }
        }
    }

    /// Applying `nil` clears any override, which is what returns the app to
    /// following the system - including live, when the system flips at sunset.
    @MainActor
    func applyAppearance() {
        NSApp.appearance = appearance.nsAppearance
    }

    /// The half of the settings that affects the produced bytes, folded into the
    /// preview cache key alongside the window's mode and quality.
    func encodeSettings(mode: SquishMode, quality: Int, target: Int) -> EncodeSettings {
        EncodeSettings(mode: mode,
                       quality: quality,
                       target: target,
                       keepMetadata: keepMetadata,
                       maxDimension: maxDimensionEnabled && maxDimension > 0 ? maxDimension : nil)
    }

    /// The half that decides where the produced bytes land.
    var placement: Exporter.Placement {
        Exporter.Placement(
            behavior: outputBehavior,
            folder: outputFolderPath.isEmpty ? nil : URL(fileURLWithPath: outputFolderPath),
            suffix: suffix
        )
    }
}

/// Posted whenever a settings change invalidates existing previews (metadata,
/// max dimension) or their destinations (output behaviour, suffix, folder).
extension Notification.Name {
    static let squishPreferencesChanged = Notification.Name("com.fxreza.squish.preferencesChanged")
}
