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
}
