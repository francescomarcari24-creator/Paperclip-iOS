import SwiftUI

struct PaperclipPalette: Equatable {
    let primary: Color
    let onPrimary: Color
    let primaryContainer: Color
    let onPrimaryContainer: Color
    let secondary: Color
    let secondaryContainer: Color
    let background: Color
    let onBackground: Color
    let surface: Color
    let surfaceContainer: Color
    let surfaceVariant: Color
    let onSurface: Color
    let onSurfaceVariant: Color
    let outline: Color
    let error: Color
    let isDark: Bool

    static func build(accent: AccentColor, isDark: Bool) -> PaperclipPalette {
        let baseHex = accent.seedHex ?? (isDark ? 0xD0BCFF : 0x6650A4)
        let primaryColor = Color(hex: baseHex)
        let adjustedPrimary = isDark ? primaryColor.lightened(by: 0.22) : primaryColor
        let container = isDark ? primaryColor.darkened(by: 0.45) : primaryColor.lightened(by: 0.78)
        let onContainer = isDark ? primaryColor.lightened(by: 0.80) : primaryColor.darkened(by: 0.55)

        if isDark {
            return PaperclipPalette(
                primary: adjustedPrimary,
                onPrimary: Color(hex: 0x1C1B1F),
                primaryContainer: container,
                onPrimaryContainer: onContainer,
                secondary: adjustedPrimary.opacity(0.85),
                secondaryContainer: Color(hex: 0x2B2930),
                background: Color(hex: 0x141218),
                onBackground: Color(hex: 0xE6E0E9),
                surface: Color(hex: 0x1D1B20),
                surfaceContainer: Color(hex: 0x242228),
                surfaceVariant: Color(hex: 0x49454F),
                onSurface: Color(hex: 0xE6E0E9),
                onSurfaceVariant: Color(hex: 0xCAC4D0),
                outline: Color(hex: 0x938F99),
                error: Color(hex: 0xF2B8B5),
                isDark: true
            )
        } else {
            return PaperclipPalette(
                primary: adjustedPrimary,
                onPrimary: .white,
                primaryContainer: container,
                onPrimaryContainer: onContainer,
                secondary: adjustedPrimary.opacity(0.85),
                secondaryContainer: Color(hex: 0xE8DEF8),
                background: Color(hex: 0xFEF7FF),
                onBackground: Color(hex: 0x1D1B20),
                surface: Color(hex: 0xFFFFFF),
                surfaceContainer: Color(hex: 0xF3EDF7),
                surfaceVariant: Color(hex: 0xE7E0EC),
                onSurface: Color(hex: 0x1D1B20),
                onSurfaceVariant: Color(hex: 0x49454F),
                outline: Color(hex: 0x79747E),
                error: Color(hex: 0xB3261E),
                isDark: false
            )
        }
    }
}

private struct PaperclipPaletteKey: EnvironmentKey {
    static let defaultValue = PaperclipPalette.build(accent: .SYSTEM, isDark: false)
}

extension EnvironmentValues {
    var paperclipPalette: PaperclipPalette {
        get { self[PaperclipPaletteKey.self] }
        set { self[PaperclipPaletteKey.self] = newValue }
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }

    init(hexString: String) {
        var cleaned = hexString.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        var rgb: UInt64 = 0x6200EE
        Scanner(string: cleaned).scanHexInt64(&rgb)
        if cleaned.count == 8 {
            let r = Double((rgb >> 16) & 0xFF) / 255.0
            let g = Double((rgb >> 8) & 0xFF) / 255.0
            let b = Double(rgb & 0xFF) / 255.0
            self.init(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
        } else {
            self.init(hex: UInt32(rgb & 0xFFFFFF))
        }
    }

    func lightened(by amount: Double) -> Color {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return self }
        return Color(
            .sRGB,
            red: Double(r) + (1.0 - Double(r)) * amount,
            green: Double(g) + (1.0 - Double(g)) * amount,
            blue: Double(b) + (1.0 - Double(b)) * amount,
            opacity: Double(a)
        )
    }

    func darkened(by amount: Double) -> Color {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return self }
        return Color(
            .sRGB,
            red: Double(r) * (1.0 - amount),
            green: Double(g) * (1.0 - amount),
            blue: Double(b) * (1.0 - amount),
            opacity: Double(a)
        )
    }
}

struct PaperclipThemeContainer<Content: View>: View {
    @ObservedObject var preferences: UiPreferences
    @Environment(\.colorScheme) private var systemColorScheme
    let content: Content

    init(preferences: UiPreferences, @ViewBuilder content: () -> Content) {
        self.preferences = preferences
        self.content = content()
    }

    private var effectiveDark: Bool {
        switch preferences.themeMode {
        case .LIGHT: return false
        case .DARK: return true
        case .SYSTEM: return systemColorScheme == .dark
        }
    }

    private var preferredScheme: ColorScheme? {
        switch preferences.themeMode {
        case .LIGHT: return .light
        case .DARK: return .dark
        case .SYSTEM: return nil
        }
    }

    var body: some View {
        let palette = PaperclipPalette.build(accent: preferences.accentColor, isDark: effectiveDark)
        content
            .environment(\.paperclipPalette, palette)
            .tint(palette.primary)
            .preferredColorScheme(preferredScheme)
            // 450 ms theme cross-fade matching Android Theme.kt (THEME_ANIM_MS = 450)
            .animation(.easeInOut(duration: 0.45), value: preferences.themeMode)
            .animation(.easeInOut(duration: 0.45), value: preferences.accentColor)
            .animation(.easeInOut(duration: 0.45), value: effectiveDark)
    }
}
