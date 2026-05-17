import Foundation

/// Behaviour profile for an NPC. The numbers feed the AI tick — there's
/// no enum lookup, the same code path reads these knobs for every
/// personality so designers can tune values in JSON without touching
/// Swift.
struct PersonalityDef: Decodable {
    let id: String
    /// Range at which a hostile target attracts engagement (scene units).
    /// Zero = pacifist, never engages.
    let engagementRange: Float
    /// Distance the AI tries to maintain to its target while engaged.
    let preferredDistance: Float
    /// Hull fraction (0..1) below which the AI breaks off and heads for
    /// the nearest planet. Zero = never flee (fight to the death).
    let fleeHullPct: Float
    /// Random radians added to aim each shot — sloppier shooters miss
    /// more often.
    let aimJitter: Float
    /// 0..1 multiplier on engine thrust. Cowards meander, defenders
    /// charge.
    let thrustIntensity: Float
    /// Radius of random patrol waypoints around the spawn anchor.
    let patrolRadius: Float
}

@MainActor
final class PersonalityRegistry {

    static let shared = PersonalityRegistry()
    private init() { load() }

    private(set) var definitions: [String: PersonalityDef] = [:]

    func personality(id: String) -> PersonalityDef? { definitions[id] }

    private func load() {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "json",
                                          subdirectory: nil)
        else { return }
        struct Container: Decodable { let personalities: [PersonalityDef]? }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let container = try? decoder.decode(Container.self, from: data),
                  let list = container.personalities, !list.isEmpty
            else { continue }
            for p in list { definitions[p.id] = p }
            print("[PersonalityRegistry] loaded \(list.count) personalities from \(url.lastPathComponent)")
        }
    }
}
