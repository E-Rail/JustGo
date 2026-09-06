import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    /// The app's own colour, taken from the icon.
    ///
    /// Not the icon's orange exactly. `#E58216` measures 2.79:1 against white. Below the 3:1 the
    /// smallest tinted things in this app need, let alone the 4.5:1 a tab-bar label wants, so a
    /// tinted label in light mode would have been decoration rather than text. This is the same
    /// hue (31°) at the same saturation, darkened until it clears **4.51:1 on white**. #B06411
    /// shipped first and measured 4.49:1, because 8-bit rounding ate the last hundredth. Dark mode
    /// lifts it back to roughly the icon's own orange (see `legibleOnDarkBackground`), so the two
    /// appearances read as one colour and both are legible.
    case brandOrange  = "#AF6411"
    case forestGreen  = "#2D7055"
    case oceanBlue    = "#1D6FA5"
    case royalPurple  = "#6B3AC7"

    /// Four, and these four. Every remaining pair is at least 48° apart on the hue wheel and every
    /// one clears 4.5:1 on white, so no two are confusable and none is unreadable. Dropped:
    /// `skyTeal` sat 11° from `oceanBlue`. The same colour to a rider; `rubyRed` sat at hue 0°,
    /// the red this app already spends on errors, warnings and the destination pin; `roseGold` was
    /// 28° off that same red. A palette whose entries collide with each other, or with the
    /// semantics of the UI drawn on top of them, is a longer list rather than a better one.
    ///
    /// What the app uses until a rider picks something else. Declared once: this was written out
    /// as `AppTheme.default.rawValue` in eight separate `@AppStorage` defaults, which is eight
    /// places to miss when the answer changes.
    static let `default` = AppTheme.brandOrange

    var id: String { rawValue }
    var accent: Color { Color.adaptive(hex: rawValue) }

    var name: String {
        switch self {
        case .brandOrange:  return AppLocalization.text(english: "Signal", simplified: "信号橙", traditional: "訊號橙")
        case .forestGreen:  return AppLocalization.text(english: "Forest", simplified: "森林绿", traditional: "森林綠")
        case .oceanBlue:    return AppLocalization.text(english: "Ocean", simplified: "海洋蓝", traditional: "海洋藍")
        case .royalPurple:  return AppLocalization.text(english: "Purple", simplified: "紫罗兰", traditional: "紫羅蘭")
        }
    }
}

/// Light, dark, or whatever the phone is set to.
///
/// Deliberately separate from `AppTheme`. That one picks the accent *hue* and has always been
/// appearance-agnostic — `Color.adaptive(hex:)` lifts every one of its four colours for a dark
/// background already — so the two settings compose rather than multiply, and neither has to know
/// about the other.
///
/// The whole palette underneath this is either a system semantic colour
/// (`systemGroupedBackground`, `secondarySystemGroupedBackground`) or passed through
/// `Color.adaptive(hex:)`, which is why forcing an appearance needs no new colours: the app has
/// been drawing both all along and simply had no way to ask for one.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "appAppearance"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .system: return AppLocalization.text(english: "System", simplified: "跟随系统", traditional: "跟隨系統")
        case .light:  return AppLocalization.text(english: "Light", simplified: "浅色", traditional: "淺色")
        case .dark:   return AppLocalization.text(english: "Dark", simplified: "深色", traditional: "深色")
        }
    }

    /// `nil` is how SwiftUI spells "do not override", which is exactly what `.system` means.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}
