import UIKit

/// Type of a hardpoint slot. Used for filtering drag-to-assign drops so
/// the player can't put a gun in a turret socket (or vice versa) and to
/// pick the right colour for the marker dot + inventory row outline.
enum HardpointKind: String {
    case turret, gun, engine

    /// Derives the kind from a mount slot key like `"turret_3"`,
    /// `"gun_0"`, `"engine_1"`. Returns `nil` for an unknown prefix.
    init?(slotKey: String) {
        if slotKey.hasPrefix("turret_") { self = .turret }
        else if slotKey.hasPrefix("gun_")    { self = .gun }
        else if slotKey.hasPrefix("engine_") { self = .engine }
        else { return nil }
    }

    /// Whether an outfit's `category` is compatible with this kind of
    /// mount. Accepts the singular/plural spellings the JSON files have
    /// shipped with so existing data stays valid.
    func accepts(category rawCategory: String?) -> Bool {
        let cat = (rawCategory ?? "").lowercased()
        switch self {
        case .turret: return cat == "turret" || cat == "turrets"
        case .gun:    return cat == "gun"    || cat == "guns"
        case .engine: return cat == "thruster" || cat == "steering" || cat == "engine" || cat == "engines"
        }
    }

    /// Theme colour for the marker dot, inventory outline, and any
    /// highlight indicating "you can drop here / this is equipped here".
    var color: UIColor {
        switch self {
        case .turret: return UIColor(red: 0.95, green: 0.65, blue: 0.20, alpha: 0.9)   // amber
        case .gun:    return UIColor(red: 1.00, green: 0.40, blue: 0.40, alpha: 0.9)   // red
        case .engine: return UIColor(red: 0.30, green: 0.85, blue: 0.45, alpha: 0.9)   // green
        }
    }

    /// Category prefix used in the inventory list's category headers. We
    /// derive these from the outfit's own `category` field; this helper
    /// just resolves a raw string into a single bucket.
    static func bucket(forCategory rawCategory: String?) -> String {
        let cat = (rawCategory ?? "").lowercased()
        if HardpointKind.turret.accepts(category: cat) { return "turret" }
        if HardpointKind.gun.accepts(category: cat)    { return "gun" }
        if HardpointKind.engine.accepts(category: cat) { return "engine" }
        return cat.isEmpty ? "other" : cat
    }
}
