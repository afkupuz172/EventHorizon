import Foundation

/// Gameplay-side description of a ship, loaded from `data/ships/<id>.json`.
///
/// Lots of fields in the source JSON aren't used by the game yet (heat
/// dissipation, drag, weapon capacity, ramscoop, hyperdrive, etc.) — those
/// keys are simply ignored by `Decodable`. As gameplay catches up, add
/// fields to `Attributes` and they start parsing automatically.
struct ShipDef: Decodable {

    /// The JSON's `"ship"` field — the human-readable name. The ship's
    /// canonical ID (used as the lookup key) comes from the JSON FILE
    /// basename, not from this field.
    let ship: String

    let attributes: Attributes
    let outfits:    [InstalledOutfit]?

    /// Convenience accessor — display name is just `ship`, but `displayName`
    /// reads better at call sites.
    var displayName: String { ship }

    struct Attributes: Decodable {
        let category:        String?
        let cost:            Int?
        let shields:         Double
        let hull:            Double
        let fuelCapacity:    Double?
        let mass:            Double?
        let drag:            Double?
        let cargoSpace:      Double?
        let outfitSpace:     Double?
        let weaponCapacity:  Double?
        let engineCapacity:  Double?
        let heatDissipation: Double?

        enum CodingKeys: String, CodingKey {
            case category, cost, shields, hull, mass, drag
            case fuelCapacity     = "fuel capacity"
            case cargoSpace       = "cargo space"
            case outfitSpace      = "outfit space"
            case weaponCapacity   = "weapon capacity"
            case engineCapacity   = "engine capacity"
            case heatDissipation  = "heat dissipation"
        }
    }

    /// One entry in the ship's installed-outfits list. The name is the
    /// lookup key into `OutfitRegistry`.
    struct InstalledOutfit: Decodable {
        let name:  String
        let count: Int
    }
}

/// Loads every `*.json` resource in the bundle, keeps the ones that parse
/// as a `ShipDef`, and exposes them keyed by JSON-file basename.
///
/// Because Xcode's synchronized groups flatten loose resource folders to
/// the bundle root, we can't enumerate by path — we just walk every JSON
/// and let `JSONDecoder` reject non-ship files. Adding a new ship is a
/// one-step drop-in: put `<id>.json` somewhere under `data/ships/`.
@MainActor
final class ShipRegistry {

    static let shared = ShipRegistry()
    private init() { load() }

    private(set) var definitions: [String: ShipDef] = [:]

    /// All registered ship IDs, sorted for stable ordering in the shipyard.
    var allIDs: [String] { definitions.keys.sorted() }

    func def(for id: String) -> ShipDef? {
        definitions[id]
    }

    private func load() {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "json",
                                          subdirectory: nil)
        else {
            print("[ShipRegistry] no JSON resources in bundle")
            return
        }
        let decoder = JSONDecoder()
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            do {
                let def = try decoder.decode(ShipDef.self, from: data)
                let id  = url.deletingPathExtension().lastPathComponent
                definitions[id] = def
                print("[ShipRegistry] loaded ship \"\(id)\" — \(def.displayName)")
            } catch {
                // Not a ship JSON. Silent — system / outfit / nebula configs
                // all hit this path on every load. If you need to debug a
                // file that *should* parse but doesn't, log the error here.
            }
        }
    }
}
