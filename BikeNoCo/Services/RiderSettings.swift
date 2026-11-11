import Foundation

/// Bike category used to scale calorie estimates (effort at a given speed differs a lot).
enum BikeType: String, CaseIterable, Identifiable, Sendable {
    case road
    case gravel
    case mountain
    case ebike

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .road: return "Road"
        case .gravel: return "Gravel"
        case .mountain: return "Mountain"
        case .ebike: return "E-bike"
        }
    }

    var systemImage: String {
        // `bicycle.mountain` is not in SF Symbols — use `bicycle` for all bike types.
        "bicycle"
    }

    /// Multiplier on the speed-based MET table (road = baseline).
    var calorieMultiplier: Double {
        switch self {
        case .road: return 1.0
        case .gravel: return 1.12
        case .mountain: return 1.28
        case .ebike: return 0.62
        }
    }
}

/// Rider preferences used by calorie estimates and similar.
enum RiderSettings {
    private static let weightPoundsKey = "riderWeightPounds"
    private static let bikeTypeKey = "riderBikeType"

    static let defaultWeightPounds: Double = 154
    static let kilogramsPerPound = 0.45359237
    static let defaultBikeType: BikeType = .road

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

    static var bikeType: BikeType {
        get {
            guard let raw = UserDefaults.standard.string(forKey: bikeTypeKey),
                  let type = BikeType(rawValue: raw)
            else { return defaultBikeType }
            return type
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: bikeTypeKey)
        }
    }

    static func setWeightPounds(_ pounds: Double) {
        weightPounds = pounds
    }
}
