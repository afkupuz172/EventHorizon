import Foundation
import CoreGraphics

/// Pure function for "where is body `X` at time `t`?".
///
/// Bodies form a tree: a body's orbital center is either a fixed point or
/// another body. `position(of:in:at:)` walks the chain — recursively resolving
/// each ancestor's position first — and adds the body's own orbital offset
/// at the given time.
///
/// Because the math is a pure function of (config, time), every client on
/// the same wall-clock arrives at the same answer. Multiplayer-safe by
/// construction.
struct OrbitalSolver {

    /// Default orbital period (seconds) used when a body's JSON doesn't
    /// specify one. Scales with the square root of the radius, so bigger
    /// orbits take longer — a hand-wavy nod to Kepler that keeps everything
    /// moving on a human-watchable timescale.
    static func defaultPeriod(radius: Float) -> Float {
        let baseSeconds:   Float = 600    // 10 minutes at the reference distance
        let referenceUnit: Float = 1000   // world units
        return baseSeconds * sqrt(max(radius, 1) / referenceUnit)
    }

    /// Resolve a body's absolute world position at `time` (seconds since
    /// epoch). Returns nil for unknown IDs or if the orbital chain cycles
    /// back on itself.
    static func position(of bodyID: String,
                         in config: SolarSystemConfig,
                         at time: TimeInterval) -> CGPoint? {
        return resolve(bodyID: bodyID, in: config, at: time, visited: [])
    }

    // MARK: – Internals

    private static func resolve(bodyID: String,
                                in config: SolarSystemConfig,
                                at time: TimeInterval,
                                visited: Set<String>) -> CGPoint? {
        // Detect cycles — `planetA orbits planetB orbits planetA` would loop
        // forever otherwise.
        guard !visited.contains(bodyID) else {
            print("[OrbitalSolver] orbital cycle detected at \(bodyID)")
            return nil
        }
        var seen = visited
        seen.insert(bodyID)

        let location: OrbitTarget
        let radius:   Float
        let period:   Float?

        if let sun = config.suns.first(where: { $0.id == bodyID }) {
            location = sun.location
            radius   = sun.orbit
            period   = sun.period
        } else if let planet = config.planets.first(where: { $0.id == bodyID }) {
            location = planet.location
            radius   = planet.orbit
            period   = planet.period
        } else {
            return nil
        }

        // Find the center of this body's orbit.
        let center: CGPoint
        switch location {
        case .fixed(let x, let y):
            center = CGPoint(x: CGFloat(x), y: CGFloat(y))
        case .body(let parentID):
            guard let parent = resolve(bodyID: parentID, in: config,
                                       at: time, visited: seen)
            else { return nil }
            center = parent
        }

        // Body is AT the center if it has no orbital radius.
        guard radius > 0 else { return center }

        // Use the JSON-supplied period if positive, otherwise fall back to
        // the auto-derived default. Period <= 0 is treated as "use default"
        // rather than "divide by zero".
        let effectivePeriod: Float = {
            if let p = period, p > 0 { return p }
            return defaultPeriod(radius: radius)
        }()

        let angle = 2 * .pi * CGFloat(time) / CGFloat(effectivePeriod)
        return CGPoint(
            x: center.x + cos(angle) * CGFloat(radius),
            y: center.y + sin(angle) * CGFloat(radius)
        )
    }
}
