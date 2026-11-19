import Foundation
import SwiftData

enum AppearancePreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

enum DashboardPeriod: String, Codable, CaseIterable, Sendable { case month, year }

/// Single-row settings model (created on first launch by PersistenceService).
@Model
final class AppSettings {
    var preferredCurrencyCode: String
    var firstDayOfWeek: Int
    var selectedDashboardPeriodRaw: String
    var requireBiometricUnlock: Bool
    var preferredAppearanceRaw: String

    init() {
        preferredCurrencyCode = CurrencyMath.defaultCode
        firstDayOfWeek = Calendar.current.firstWeekday
        selectedDashboardPeriodRaw = DashboardPeriod.month.rawValue
        requireBiometricUnlock = false
        preferredAppearanceRaw = AppearancePreference.system.rawValue
    }

    var preferredAppearance: AppearancePreference {
        get { AppearancePreference(rawValue: preferredAppearanceRaw) ?? .system }
        set { preferredAppearanceRaw = newValue.rawValue }
    }
}
