import Foundation

/// Rider preferences used by calorie estimates and similar.
enum RiderSettings {
    private static let weightPoundsKey = "riderWeightPounds"
    static let defaultWeightPounds: Double = 154
    static let kilogramsPerPound = 0.45359237

    static var weightPounds: Double {
        get {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: weightPoundsKey) == nil {
                return defaultWeightPounds
            }
            let value = defaults.double(forKey: weightPoundsKey)
            return value > 0 ? value : defaultWeightPounds
        }
        set {
            UserDefaults.standard.set(max(newValue, 1), forKey: weightPoundsKey)
        }
    }

    static var weightKilograms: Double {
        weightPounds * kilogramsPerPound
    }

    static func setWeightPounds(_ pounds: Double) {
        weightPounds = pounds
    }
}
