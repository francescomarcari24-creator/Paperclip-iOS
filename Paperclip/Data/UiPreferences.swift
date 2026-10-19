import Foundation
import Combine

enum ThemeMode: String, Codable, CaseIterable, Identifiable {
    case LIGHT
    case SYSTEM
    case DARK

    var id: String { rawValue }

    var label: String {
        switch self {
        case .LIGHT: return "Chiaro"
        case .SYSTEM: return "Sistema"
        case .DARK: return "Scuro"
        }
    }

    var systemIcon: String {
        switch self {
        case .LIGHT: return "sun.max.fill"
        case .SYSTEM: return "circle.lefthalf.filled"
        case .DARK: return "moon.fill"
        }
    }
}

enum AccentColor: String, Codable, CaseIterable, Identifiable {
    case SYSTEM
    case RED
    case ORANGE
    case LIGHT_ORANGE
    case YELLOW
    case GREEN
    case TEAL
    case LIGHT_BLUE
    case BLUE
    case PURPLE
    case FUCHSIA
    case PINK

    var id: String { rawValue }

    var label: String {
        switch self {
        case .SYSTEM: return "Automatico"
        case .RED: return "Rosso"
        case .ORANGE: return "Arancione"
        case .LIGHT_ORANGE: return "Arancione chiaro"
        case .YELLOW: return "Giallo"
        case .GREEN: return "Verde"
        case .TEAL: return "Verde acqua"
        case .LIGHT_BLUE: return "Celeste"
        case .BLUE: return "Blu"
        case .PURPLE: return "Viola"
        case .FUCHSIA: return "Fucsia"
        case .PINK: return "Rosa"
        }
    }

    var seedHex: UInt32? {
        switch self {
        case .SYSTEM: return nil
        case .RED: return 0xE53935
        case .ORANGE: return 0xF57C00
        case .LIGHT_ORANGE: return 0xFFB870
        case .YELLOW: return 0xFDD835
        case .GREEN: return 0x43A047
        case .TEAL: return 0x00897B
        case .LIGHT_BLUE: return 0x4FC3F7
        case .BLUE: return 0x1E5BD8
        case .PURPLE: return 0x7B3FC4
        case .FUCHSIA: return 0xD500C8
        case .PINK: return 0xF48FB1
        }
    }
}

enum SortOrder: String, Codable, CaseIterable, Identifiable {
    case NEWEST
    case OLDEST
    case UPDATED
    case TITLE
    case TYPE

    var id: String { rawValue }

    var label: String {
        switch self {
        case .NEWEST: return "Più recenti"
        case .OLDEST: return "Meno recenti"
        case .UPDATED: return "Modificati di recente"
        case .TITLE: return "Titolo (A-Z)"
        case .TYPE: return "Tipo"
        }
    }
}

final class UiPreferences: ObservableObject {
    static let shared = UiPreferences()

    private let defaults = UserDefaults.standard
    private let keyShowFeedFilters = "show_feed_filters"
    private let keyThemeMode = "theme_mode"
    private let keyAccentColor = "accent_color"
    private let keySortOrder = "sort_order"
    private let keyResurfaceEnabled = "resurface_enabled"
    private let keyResurfaceCount = "resurface_count"
    private let keyResurfaceMinDays = "resurface_min_days"

    @Published var showFeedFilters: Bool {
        didSet { defaults.set(showFeedFilters, forKey: keyShowFeedFilters) }
    }

    @Published var themeMode: ThemeMode {
        didSet { defaults.set(themeMode.rawValue, forKey: keyThemeMode) }
    }

    @Published var accentColor: AccentColor {
        didSet { defaults.set(accentColor.rawValue, forKey: keyAccentColor) }
    }

    @Published var sortOrder: SortOrder {
        didSet { defaults.set(sortOrder.rawValue, forKey: keySortOrder) }
    }

    @Published var resurfaceEnabled: Bool {
        didSet { defaults.set(resurfaceEnabled, forKey: keyResurfaceEnabled) }
    }

    @Published var resurfaceCount: Int {
        didSet { defaults.set(resurfaceCount, forKey: keyResurfaceCount) }
    }

    @Published var resurfaceMinDays: Int {
        didSet { defaults.set(resurfaceMinDays, forKey: keyResurfaceMinDays) }
    }

    init() {
        if defaults.object(forKey: keyShowFeedFilters) == nil {
            self.showFeedFilters = true
        } else {
            self.showFeedFilters = defaults.bool(forKey: keyShowFeedFilters)
        }

        if let rawTheme = defaults.string(forKey: keyThemeMode),
           let mode = ThemeMode(rawValue: rawTheme) {
            self.themeMode = mode
        } else {
            self.themeMode = .SYSTEM
        }

        if let rawAccent = defaults.string(forKey: keyAccentColor),
           let color = AccentColor(rawValue: rawAccent) {
            self.accentColor = color
        } else {
            self.accentColor = .SYSTEM
        }

        if let rawSort = defaults.string(forKey: keySortOrder),
           let order = SortOrder(rawValue: rawSort) {
            self.sortOrder = order
        } else {
            self.sortOrder = .NEWEST
        }

        self.resurfaceEnabled = defaults.bool(forKey: keyResurfaceEnabled)
        let storedCount = defaults.integer(forKey: keyResurfaceCount)
        self.resurfaceCount = storedCount > 0 ? storedCount : 3
        let storedMinDays = defaults.integer(forKey: keyResurfaceMinDays)
        self.resurfaceMinDays = storedMinDays > 0 ? storedMinDays : 30
    }
}
