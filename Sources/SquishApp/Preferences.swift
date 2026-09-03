import Foundation

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

/// Thin wrapper around UserDefaults(suiteName: "com.fxreza.squish").
/// Every property reads/writes straight through - no caching, so multiple
/// windows (main + settings) always agree. Marked `@unchecked Sendable` because
/// UserDefaults is documented thread-safe and this type holds no other state.
///
/// **Quality is deliberately absent.** It used to live here, and be duplicated
/// between the Settings window's three sliders and the main window. There is now
/// exactly one quality control - the slider in the main window - and it is
/// session-only state that resets to 75 on every launch, by request. Settings
/// keeps only what genuinely should persist: where output goes and how it is named.
final class Preferences: @unchecked Sendable {
    static let suiteName = "com.fxreza.squish"
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
    }

    init() {
        self.defaults = UserDefaults(suiteName: Preferences.suiteName) ?? .standard
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
            Key.maxDimension: 2048
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
