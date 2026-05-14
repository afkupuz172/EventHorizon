import Foundation

/// JSON-driven description of one playable solar system.
///
/// Stored as a `.json` file in the `systems/` subfolder of the bundle. Loaded
/// at scene init; nothing in here is mutated at runtime.
struct SolarSystemConfig: Decodable {

    let name: String

    /// HDR image file (without extension) inside
    /// `Art.scnassets/celestial_bodies/textures/`. Applied as the
    /// `lightingEnvironment` of every celestial body's internal SCN scene so
    /// PBR materials render with realistic ambient + reflections.
    let lightingEnvironment: String?

    let suns:     [SunConfig]
    let planets:  [PlanetConfig]
    let asteroids: AsteroidConfig

    static func load(name: String) -> SolarSystemConfig? {
        // Xcode's synchronized group flattens loose resource folders to the
        // bundle root, so we look there. The on-disk file may live in
        // `EventHorizon/systems/` for source organization; only the bundle
        // path matters at runtime.
        guard let url = Bundle.main.url(forResource: name, withExtension: "json")
        else {
            print("[SolarSystemConfig] missing \(name).json in bundle")
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(SolarSystemConfig.self, from: data)
        } catch {
            print("[SolarSystemConfig] failed to decode \(name).json: \(error)")
            return nil
        }
    }
}

struct SunConfig: Decodable {
    /// PNG basename in `Art.scnassets/celestial_bodies/` (no extension).
    let sprite: String
    /// World position.
    let x: Float
    let y: Float
    /// Visual radius in world units (the rendered sprite is `radius * 2` across).
    let radius: Float
    /// Optional human-readable name shown in the selection tooltip.
    let displayName: String?
}

struct PlanetConfig: Decodable {
    /// PNG basename in `Art.scnassets/celestial_bodies/` (no extension).
    let sprite: String

    /// Reference point — typically a sun's position. The planet is placed at
    /// `orbitDistance` away from this point, at a random angle picked when
    /// the system is built.
    let centerX: Float
    let centerY: Float
    let orbitDistance: Float

    /// Visual radius in world units.
    let radius: Float

    /// Optional human-readable name shown in the selection tooltip.
    let displayName: String?
}

struct AsteroidConfig: Decodable {
    /// Total number of asteroid sprites scattered across the map.
    let count: Int
    /// Distributed uniformly within `[-spreadRadius, +spreadRadius]` on both
    /// axes (square region, not radial).
    let spreadRadius: Float
    /// Visual radius range per instance.
    let minRadius: Float
    let maxRadius: Float
    /// Spin period range, seconds per full rotation. Direction is randomized
    /// per instance.
    let minSpinPeriod: Float
    let maxSpinPeriod: Float
}
