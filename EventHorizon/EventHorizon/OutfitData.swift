import Foundation

/// Description of an outfit (weapon, reactor, engine, etc.) loaded from
/// `data/outfits/<category>.json`. JSON keys use snake_case throughout;
/// the decoder converts those into the camelCase property names you see
/// here via `JSONDecoder.keyDecodingStrategy = .convertFromSnakeCase`.
///
/// Two identifying fields:
///   • `id` — snake_case slug used everywhere as the lookup key (ship
///     installed-outfit lists, player profile, save files, code paths).
///   • `displayName` — plain-text human label shown in the UI.
struct OutfitDef: Decodable {

    /// Stable identifier — JSON's `"id"` field. Matches the slug used in
    /// ship `outfits[].name`, `guns[].weapon`, `turrets[].weapon`, and
    /// the player profile's `installedOutfits` dictionary.
    let id:           String
    /// Human-readable name shown in the shipyard, outfitter, etc.
    let displayName:  String
    let category:     String?
    let series:       String?
    let cost:            Int?
    let mass:            Double?
    let outfitSpace:     Double?   // negative in JSON (e.g. -40 means "uses 40")
    let weaponCapacity:  Double?
    let engineCapacity:  Double?
    let weapon:          WeaponStats?

    // ── Power / shield / engine contributions ─────────────────────────────
    // All optional. Default to zero when absent so summing across installed
    // outfits is a straight reduce.

    /// Adds to the ship's energy pool when installed.
    let energyCapacity:    Double?
    /// Adds to the ship's per-second energy recharge.
    let energyRecharge:    Double?
    /// Per-second passive energy drain (e.g. shield generators).
    let energyConsumption: Double?
    /// Adds to the ship's shield pool.
    let shieldCapacity:    Double?
    /// Adds to the ship's per-second shield recharge.
    let shieldRecharge:    Double?
    /// Heat generated continuously while the outfit is installed.
    let heatGeneration:    Double?

    /// Forward thrust contribution (engines).
    let thrust:            Double?
    /// Energy drained per second while thrusting.
    let thrustingEnergy:   Double?
    /// Heat produced per second while thrusting.
    let thrustingHeat:     Double?
    /// Yaw thrust contribution (steering engines).
    let turn:              Double?
    /// Energy drained per second while turning.
    let turningEnergy:     Double?
    /// Heat produced per second while turning.
    let turningHeat:       Double?

    /// `description` is sometimes a single string, sometimes an array of
    /// paragraphs. We accept either and normalize to one string at decode.
    let description: String?

    struct WeaponStats: Decodable {
        let velocity:      Double?
        let lifetime:      Double?
        let reload:        Double?
        let inaccuracy:    Double?
        let turretTurn:    Double?
        let firingEnergy:  Double?
        let firingHeat:    Double?
        let shieldDamage:  Double?
        let hullDamage:    Double?
        let hitForce:      Double?
        let blastRadius:   Double?
        /// Projectile classification used by the contact system.
        ///   - `"standard"` (default) — collides with ships + asteroids
        ///   - `"flare"`   — collides only with standard projectiles
        let kind:          String?
    }

    enum CodingKeys: String, CodingKey {
        case id, displayName, category, series, cost, mass, weapon, description
        case outfitSpace, weaponCapacity, engineCapacity
        case energyCapacity, energyRecharge, energyConsumption
        case shieldCapacity, shieldRecharge
        case heatGeneration
        case thrust, thrustingEnergy, thrustingHeat
        case turn,   turningEnergy,   turningHeat
    }

    // Custom decode so `description` can be either string or array.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id             = try c.decode(String.self, forKey: .id)
        displayName    = try c.decode(String.self, forKey: .displayName)
        category       = try c.decodeIfPresent(String.self, forKey: .category)
        series         = try c.decodeIfPresent(String.self, forKey: .series)
        cost           = try c.decodeIfPresent(Int.self,    forKey: .cost)
        mass           = try c.decodeIfPresent(Double.self, forKey: .mass)
        outfitSpace    = try c.decodeIfPresent(Double.self, forKey: .outfitSpace)
        weaponCapacity = try c.decodeIfPresent(Double.self, forKey: .weaponCapacity)
        engineCapacity = try c.decodeIfPresent(Double.self, forKey: .engineCapacity)
        weapon         = try c.decodeIfPresent(WeaponStats.self, forKey: .weapon)

        energyCapacity    = try c.decodeIfPresent(Double.self, forKey: .energyCapacity)
        energyRecharge    = try c.decodeIfPresent(Double.self, forKey: .energyRecharge)
        energyConsumption = try c.decodeIfPresent(Double.self, forKey: .energyConsumption)
        shieldCapacity    = try c.decodeIfPresent(Double.self, forKey: .shieldCapacity)
        shieldRecharge    = try c.decodeIfPresent(Double.self, forKey: .shieldRecharge)
        heatGeneration    = try c.decodeIfPresent(Double.self, forKey: .heatGeneration)
        thrust            = try c.decodeIfPresent(Double.self, forKey: .thrust)
        thrustingEnergy   = try c.decodeIfPresent(Double.self, forKey: .thrustingEnergy)
        thrustingHeat     = try c.decodeIfPresent(Double.self, forKey: .thrustingHeat)
        turn              = try c.decodeIfPresent(Double.self, forKey: .turn)
        turningEnergy     = try c.decodeIfPresent(Double.self, forKey: .turningEnergy)
        turningHeat       = try c.decodeIfPresent(Double.self, forKey: .turningHeat)

        if let str = try? c.decode(String.self, forKey: .description) {
            description = str
        } else if let arr = try? c.decode([String].self, forKey: .description) {
            description = arr.joined(separator: "\n\n")
        } else {
            description = nil
        }
    }
}

/// Outfit lookup. Walks every `*.json` in the bundle, parses the ones that
/// expose a `weapons` array, and indexes the contained `OutfitDef`s by
/// their `id`. Future categories slot in as new keys on `Container`.
@MainActor
final class OutfitRegistry {

    static let shared = OutfitRegistry()
    private init() { load() }

    private(set) var definitions: [String: OutfitDef] = [:]

    /// Look up an outfit by its snake_case slug (e.g. `"heavy_laser_turret"`).
    /// Falls back to a display-name match for legacy save files that
    /// stored outfits by their human label (`"Heavy Laser Turret"`) before
    /// the snake_case refactor — keeps old captains playable.
    func outfit(id: String) -> OutfitDef? {
        if let def = definitions[id] { return def }
        return definitions.values.first { $0.displayName == id }
    }

    /// Set of IDs the caller asked for that weren't in the registry —
    /// useful for spotting ship JSONs that reference unimplemented gear.
    func missingOutfits(in ids: [String]) -> [String] {
        ids.filter { definitions[$0] == nil }
    }

    private func load() {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "json",
                                          subdirectory: nil)
        else { return }

        // Top-level outfit groups. The loader walks every JSON resource
        // and picks up whichever of these arrays are present — files
        // missing all of them are silently skipped (ship configs, system
        // JSONs, etc. all hit this path).
        struct Container: Decodable {
            let weapons: [OutfitDef]?
            let systems: [OutfitDef]?
            let engines: [OutfitDef]?
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let container = try? decoder.decode(Container.self, from: data)
            else { continue }
            let groups: [(String, [OutfitDef]?)] = [
                ("weapons", container.weapons),
                ("systems", container.systems),
                ("engines", container.engines),
            ]
            var total = 0
            for (label, entries) in groups {
                guard let list = entries, !list.isEmpty else { continue }
                for outfit in list { definitions[outfit.id] = outfit }
                total += list.count
                print("[OutfitRegistry] loaded \(list.count) \(label) from \(url.lastPathComponent)")
            }
            if total == 0 { continue }
        }
    }
}
