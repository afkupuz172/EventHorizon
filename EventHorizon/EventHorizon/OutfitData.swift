import Foundation

/// Description of an outfit (weapon, reactor, engine, etc.) loaded from
/// `data/outfits/<category>.json`. Currently only weapons are wired up; as
/// more category files arrive (`engines.json`, `power.json`, …) the
/// `Container` type can grow new optional arrays and `OutfitRegistry.load`
/// merges them all into one keyed lookup.
struct OutfitDef: Decodable {

    /// The JSON's `"outfit"` field — also the lookup key (e.g.
    /// `"Heavy Laser Turret"`). Case-sensitive, matches the strings ships
    /// reference in their `outfits` array.
    let outfit:   String
    let category: String?
    let series:   String?
    let cost:           Int?
    let mass:           Double?
    let outfitSpace:    Double?   // negative in JSON (e.g. -40 means "uses 40")
    let weaponCapacity: Double?
    let engineCapacity: Double?
    let weapon:         WeaponStats?
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
        /// Future kinds (homing, mines, etc.) slot in here.
        let kind:          String?

        enum CodingKeys: String, CodingKey {
            case velocity, lifetime, reload, inaccuracy, kind
            case turretTurn   = "turret turn"
            case firingEnergy = "firing energy"
            case firingHeat   = "firing heat"
            case shieldDamage = "shield damage"
            case hullDamage   = "hull damage"
            case hitForce     = "hit force"
            case blastRadius  = "blast radius"
        }
    }

    enum CodingKeys: String, CodingKey {
        case outfit, category, series, cost, mass, weapon, description
        case outfitSpace    = "outfit space"
        case weaponCapacity = "weapon capacity"
        case engineCapacity = "engine capacity"
    }

    // Custom decode so `description` can be either string or array.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        outfit   = try c.decode(String.self, forKey: .outfit)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        series   = try c.decodeIfPresent(String.self, forKey: .series)
        cost           = try c.decodeIfPresent(Int.self,    forKey: .cost)
        mass           = try c.decodeIfPresent(Double.self, forKey: .mass)
        outfitSpace    = try c.decodeIfPresent(Double.self, forKey: .outfitSpace)
        weaponCapacity = try c.decodeIfPresent(Double.self, forKey: .weaponCapacity)
        engineCapacity = try c.decodeIfPresent(Double.self, forKey: .engineCapacity)
        weapon         = try c.decodeIfPresent(WeaponStats.self, forKey: .weapon)
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
/// expose a `weapons` array, and indexes the contained `OutfitDef`s by their
/// `outfit` name. Future categories slot in as new keys on `Container`.
@MainActor
final class OutfitRegistry {

    static let shared = OutfitRegistry()
    private init() { load() }

    private(set) var definitions: [String: OutfitDef] = [:]

    func outfit(named name: String) -> OutfitDef? {
        definitions[name]
    }

    /// Set of outfit names the caller asked for that weren't in the registry
    /// — useful for spotting ship JSONs that reference unimplemented gear.
    func missingOutfits(in names: [String]) -> [String] {
        names.filter { definitions[$0] == nil }
    }

    private func load() {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "json",
                                          subdirectory: nil)
        else { return }

        struct Container: Decodable {
            let weapons: [OutfitDef]?
            // Future: engines, power, shields, utility...
        }
        let decoder = JSONDecoder()
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let container = try? decoder.decode(Container.self, from: data),
                  let entries   = container.weapons
            else { continue }
            for outfit in entries {
                definitions[outfit.outfit] = outfit
            }
            print("[OutfitRegistry] loaded \(entries.count) outfits from \(url.lastPathComponent)")
        }
    }
}
