import Foundation

/// Human-readable names for FIT values.
public enum FITNames {
    /// "indoor_cycling" → "Indoor cycling" (or "Indoor Cycling" with `titleCase`).
    public static func humanize(_ name: String, titleCase: Bool = false) -> String {
        let words = name.split(separator: "_").map(String.init)
        guard !words.isEmpty else { return name }
        return words.enumerated().map { index, word in
            if titleCase || index == 0 {
                return word.prefix(1).uppercased() + word.dropFirst()
            }
            return word
        }.joined(separator: " ")
    }

    public static func manufacturer(_ value: Double?) -> String? {
        guard let value else { return nil }
        let id = Int(value)
        switch id {
        case 1: return "Garmin"
        case 32: return "Wahoo"
        case 255: return "Development"
        case 260: return "Zwift"
        case 263: return "Favero"
        default:
            return FITProfile.typeValueName("manufacturer", id).map { humanize($0, titleCase: true) } ?? "Manufacturer \(id)"
        }
    }

    /// Product name, using the product tables for Garmin (and Garmin-owned brands) and Favero.
    public static func product(manufacturer: Double?, product: Double?, productName: String?) -> String? {
        if let productName, !productName.isEmpty { return productName }
        guard let product else { return nil }
        let id = Int(product)
        switch manufacturer.map(Int.init) {
        case 1, 13, 15, 89:
            if let name = FITProfile.typeValueName("garmin_product", id) { return productDisplayName(name) }
        case 263:
            if let name = FITProfile.typeValueName("favero_product", id) { return productDisplayName(name) }
        default:
            break
        }
        return "Product \(id)"
    }

    /// "edge_840" → "Edge 840", "fr965" → "FR965", "hrm_pro" → "HRM Pro".
    static func productDisplayName(_ name: String) -> String {
        let acronyms: Set<String> = ["hrm", "gps", "ant", "usb", "hr", "vo2"]
        return name.split(separator: "_").map { word -> String in
            let text = String(word)
            let letters = text.filter(\.isLetter).count
            if acronyms.contains(text) || (letters <= 3 && letters < text.count) {
                return text.uppercased()
            }
            return text.prefix(1).uppercased() + text.dropFirst()
        }.joined(separator: " ")
    }

    public static func sport(_ sport: Double?, subSport: Double?) -> String? {
        let main = sport.flatMap { FITProfile.typeValueName("sport", Int($0)) }
        let sub = subSport.flatMap { $0 == 0 ? nil : FITProfile.typeValueName("sub_sport", Int($0)) }
        switch (main, sub) {
        case let (main?, sub?) where sub != "generic":
            return "\(humanize(main)) · \(humanize(sub))"
        case let (main?, _):
            return humanize(main)
        case let (nil, sub?):
            return humanize(sub)
        default:
            return nil
        }
    }

    /// Display units for a profile unit string.
    public static func units(_ profileUnits: String) -> String {
        switch profileUnits {
        case "watts": return "W"
        case "C": return "°C"
        case "percent": return "%"
        case "Breaths/min": return "br/min"
        case "cycles", "semicircles": return ""
        default: return profileUnits
        }
    }
}
