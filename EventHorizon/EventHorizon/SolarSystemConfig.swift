import Foundation
import CoreGraphics

/// JSON-driven description of one playable solar system.
///
/// Bodies define their orbital relationships, not their absolute positions.
/// `location` is either a fixed point (`{"x": …, "y": …}`) or the ID of
/// another body (a string). `orbit` is the radial distance from that center.
/// The combination forms a tree of bodies whose absolute positions are
/// resolved at runtime by `OrbitalSolver` from the current Unix time — so
/// every client on the same wall-clock sees the same positions.
struct SolarSystemConfig: Decodable {

    let name: String

    /// HDR image basename (without extension) inside
    /// `Art.scnassets/celestial_bodies/textures/`.
    let lightingEnvironment: String?

    let suns:      [SunConfig]
    let planets:   [PlanetConfig]
    let asteroids: AsteroidConfig

    /// Optional NPC spawn table — each entry references a fleet template
    /// (loaded by `FleetRegistry`) and how many fleets per minute roll a
    /// spawn check in this system.
    let fleets:    [SystemFleetRef]?

    static func load(name: String) -> SolarSystemConfig? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json")
        else {
            print("[SolarSystemConfig] missing \(name).json in bundle")
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            // JSON uses snake_case keys; Swift properties stay camelCase.
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(SolarSystemConfig.self, from: data)
        } catch {
            print("[SolarSystemConfig] failed to decode \(name).json: \(error)")
            return nil
        }
    }
}

// MARK: – Orbital target

/// Where a body's orbit is centered. Either a literal `(x, y)` point in
/// world coordinates or the ID of another body it follows.
///
/// JSON shapes:
///   • `"location": {"x": 0, "y": 0}` → `.fixed`
///   • `"location": "sol"`            → `.body("sol")`
enum OrbitTarget {
    case fixed(x: Float, y: Float)
    case body(id: String)
}

extension OrbitTarget: Decodable {
    init(from decoder: Decoder) throws {
        // String form first (it's the most permissive single-value).
        if let single = try? decoder.singleValueContainer(),
           let str   = try? single.decode(String.self) {
            self = .body(id: str)
            return
        }
        // Object form `{x, y}`.
        if let keyed = try? decoder.container(keyedBy: PointKeys.self),
           let x     = try? keyed.decode(Float.self, forKey: .x),
           let y     = try? keyed.decode(Float.self, forKey: .y) {
            self = .fixed(x: x, y: y)
            return
        }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "location must be a string body-ID or an {x,y} object"
            )
        )
    }

    private enum PointKeys: String, CodingKey { case x, y }
}

// MARK: – Body configs

struct SunConfig: Decodable {
    /// Unique slug used by other bodies to reference this one as their
    /// orbital center. Also surfaces as the `CelestialBodyNode.id`.
    let id: String
    let sprite: String
    let displayName: String?
    let radius: Float

    /// What this body orbits around.
    let location: OrbitTarget
    /// Radial distance from `location`. Zero = static at center.
    let orbit: Float
    /// Orbital period in seconds. Optional; nil → derived by `OrbitalSolver`.
    let period: Float?
}

struct PlanetConfig: Decodable {
    let id: String
    let sprite: String
    let displayName: String?
    let radius: Float

    let location: OrbitTarget
    let orbit: Float
    let period: Float?

    /// Services this planet offers in the docked view. Each string must be
    /// the raw value of a `PlanetService` case. Omit to grant all services.
    let services: [String]?
}

struct SystemFleetRef: Decodable {
    let fleet: String
    let spawnsPerMinute: Double
}

struct AsteroidConfig: Decodable {
    let count: Int
    let spreadRadius: Float
    let minRadius: Float
    let maxRadius: Float
    let minSpinPeriod: Float
    let maxSpinPeriod: Float
}
