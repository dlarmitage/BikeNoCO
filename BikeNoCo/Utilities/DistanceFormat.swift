import Foundation

enum DistanceFormat {
    /// Formats meters as feet under 0.1 mi, otherwise miles.
    static func imperial(_ meters: Double) -> String {
        let miles = meters / 1609.344
        if miles < 0.1 {
            let feet = meters * 3.28084
            if feet < 10 {
                return String(format: "%.0f ft", feet)
            }
            return String(format: "%.0f ft", (feet / 10).rounded() * 10)
        }
        if miles < 10 {
            return String(format: "%.1f mi", miles)
        }
        return String(format: "%.0f mi", miles)
    }

    /// Spoken form: "500 feet" under 0.1 mi, otherwise tenths of a mile ("0.2 miles").
    static func spoken(_ meters: Double) -> String {
        let miles = meters / 1609.344
        if miles < 0.1 {
            let feet = meters * 3.28084
            let rounded: Double
            if feet < 10 {
                rounded = feet.rounded()
            } else {
                rounded = (feet / 10).rounded() * 10
            }
            let value = Int(rounded)
            return value == 1 ? "1 foot" : "\(value) feet"
        }
        let tenths = (miles * 10).rounded() / 10
        if abs(tenths - 1.0) < 0.05 {
            return "1 mile"
        }
        return String(format: "%.1f miles", tenths)
    }
}
