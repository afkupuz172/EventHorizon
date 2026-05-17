import Foundation

/// One option inside a fleet's ship roster. Fleets pick from this list
/// by weight when spawning each member, so the same fleet can mix hull
/// types and personalities (e.g. mostly aggressive pirates with a token
/// coward who runs at first blood).
struct FleetShipEntry: Decodable {
    let ship: String         // ID into ShipRegistry / ShipMetadata.byID
    let personality: String  // ID into PersonalityRegistry
    let weight: Double
}

/// Fleet template — referenced from a system JSON's `fleets` array.
/// Spawning a fleet rolls a count in `[minCount, maxCount]` and picks
/// each member from `ships` by `weight`.
struct FleetDef: Decodable {
    let id: String
    let faction: String
    /// `"planet"` — rises from a dockable planet in the system.
    /// `"edge"`   — warps in from the system's outer boundary.
    let defaultSource: String?
    let ships: [FleetShipEntry]
    let minCount: Int
    let maxCount: Int

    /// Pick a ship entry weighted by `weight`. Returns nil for empty
    /// rosters so the spawner can skip rather than crash on bad data.
    func pickShip(randomUnit: Double) -> FleetShipEntry? {
        let total = ships.reduce(0.0) { $0 + $1.weight }
        guard total > 0 else { return ships.first }
        var roll = randomUnit * total
        for entry in ships {
            roll -= entry.weight
            if roll <= 0 { return entry }
        }
        return ships.last
    }
}

@MainActor
final class FleetRegistry {

    static let shared = FleetRegistry()
    private init() { load() }

    private(set) var definitions: [String: FleetDef] = [:]

    func fleet(id: String) -> FleetDef? { definitions[id] }

    private func load() {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "json",
                                          subdirectory: nil)
        else { return }
        struct Container: Decodable { let fleets: [FleetDef]? }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            // System JSONs ALSO have a `fleets` key but with a different
            // schema — the decode here will fail and silently skip them,
            // which is what we want. Only files that match FleetDef are
            // picked up.
            guard let container = try? decoder.decode(Container.self, from: data),
                  let list = container.fleets, !list.isEmpty
            else { continue }
            for f in list { definitions[f.id] = f }
            print("[FleetRegistry] loaded \(list.count) fleets from \(url.lastPathComponent)")
        }
    }
}
