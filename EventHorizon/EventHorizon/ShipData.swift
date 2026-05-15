import Foundation

/// Gameplay-side description of a ship, loaded from `data/ships/<id>.json`.
///
/// JSON keys are snake_case; the loader applies
/// `JSONDecoder.keyDecodingStrategy = .convertFromSnakeCase` so the Swift
/// properties stay camelCase. Many fields in the source JSON aren't used
/// by the game yet (heat dissipation, drag, weapon capacity, ramscoop,
/// hyperdrive, etc.) — those keys are simply ignored by `Decodable`.
struct ShipDef: Decodable {

    /// Plain-text display name — JSON's `"ship"` field.
    let ship: String

    /// Snake_case slug — matches the JSON file basename and is the lookup
    /// key in `ShipRegistry`. Optional in JSON for backward compatibility
    /// (older files omit it).
    let id: String?

    let attributes: Attributes
    let outfits:    [InstalledOutfit]?

    /// Faction this hull is flown by. Drives whether the player's projectiles
    /// can damage it without first being selected: hostile factions are
    /// fair game, neutral/friendly must be selected.
    let faction: String?

    /// Turret hardpoints — body-local position + which weapon is mounted
    /// at that slot. The contact/beam system consumes one installed copy
    /// of the named weapon per occupied mount.
    let turrets: [Hardpoint]?

    /// Fixed-mount (gun) hardpoints — body-local position + weapon.
    /// Guns fire straight along the ship's heading; they don't track.
    let guns: [Hardpoint]?

    /// Engine mounts — body-local position + which thruster outfit is
    /// installed in that slot. Drives thrust-emitter placement on the
    /// rendered ship sprite.
    let engines: [Hardpoint]?

    /// A single mount: body-local coordinate plus an optional weapon
    /// (turrets/guns) or engine (engines) reference. Mounts without a
    /// matching field are ignored by their respective subsystems.
    struct Hardpoint: Decodable {
        let x: Double
        let y: Double
        let weapon: String?
        let engine: String?
    }

    /// Convenience accessor — display name reads cleaner at call sites.
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
        /// Pool of energy this hull holds at full charge, in points.
        /// Outfits may also contribute to this total at runtime. JSON key:
        /// `"energy_capacity"`. Defaults to 100 when unset.
        let energyCapacity: Double?
        /// Passive energy regeneration rate in points per second. Outfits
        /// (reactors, batteries) typically amplify this. JSON key:
        /// `"energy_recharge"`. Defaults to 1 when unset.
        let energyRecharge: Double?
        /// Radius (in world units) of the circular physics body used for
        /// projectile collisions.
        let collisionRadius: Double?
    }

    /// One entry in the ship's installed-outfits list. `name` is the
    /// snake_case outfit slug (lookup key into `OutfitRegistry`).
    struct InstalledOutfit: Decodable {
        let name:  String
        let count: Int
    }
}

/// Loads every `*.json` resource in the bundle, keeps the ones that parse
/// as a `ShipDef`, and exposes them keyed by JSON-file basename.
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
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            do {
                let def = try decoder.decode(ShipDef.self, from: data)
                let id  = def.id ?? url.deletingPathExtension().lastPathComponent
                definitions[id] = def
                print("[ShipRegistry] loaded ship \"\(id)\" — \(def.displayName)")
            } catch {
                // Not a ship JSON. Silent — system / outfit configs all hit
                // this path on every load. If a file that *should* parse
                // doesn't, log the error here for debugging.
            }
        }
    }
}
