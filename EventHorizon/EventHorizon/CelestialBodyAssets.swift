import SceneKit
import UIKit

/// One-time loader for the SCN scenes that ship in `Art.scnassets/celestial_bodies/`.
///
/// USDZ archives are loaded into `SCNScene` instances once and kept in memory.
/// At system-build time, `SolarSystem` asks this for a clone of a specific
/// child node — clones share geometry/materials, so placing 10 asteroids
/// uses the same GPU data as placing 1.
@MainActor
final class CelestialBodyAssets {

    static let shared = CelestialBodyAssets()

    private let sunScene:       SCNScene?
    private let planetsScene:   SCNScene?
    private let asteroidsScene: SCNScene?
    let hdrEnvironmentURL:      URL?

    private init() {
        let dir = "Art.scnassets/celestial_bodies"
        sunScene       = Self.loadUSDZ(name: "Sun",             subdir: dir)
        planetsScene   = Self.loadUSDZ(name: "Various_Planets", subdir: dir)
        asteroidsScene = Self.loadUSDZ(name: "asteroids",       subdir: dir)
        hdrEnvironmentURL = Bundle.main.url(
            forResource:  "HDR_multi_nebulae",
            withExtension: "hdr",
            subdirectory: "\(dir)/textures"
        )
    }

    private static func loadUSDZ(name: String, subdir: String) -> SCNScene? {
        guard let url = Bundle.main.url(forResource: name,
                                        withExtension: "usdz",
                                        subdirectory: subdir)
        else {
            print("[CelestialBodyAssets] missing \(subdir)/\(name).usdz")
            return nil
        }
        return try? SCNScene(url: url, options: nil)
    }

    /// Returns a fresh clone of the sun model (root node of `Sun.usdz`).
    func sunNodeClone() -> SCNNode? {
        return sunScene?.rootNode.clone()
    }

    /// Returns a clone of the first node inside `Various_Planets.usdz` whose
    /// name contains `keyword` (case-insensitive). Returns nil if no match.
    func planetNodeClone(matching keyword: String) -> SCNNode? {
        return planetsScene?.rootNode.firstDescendant(nameContaining: keyword)?.clone()
    }

    /// All top-level geometry-bearing nodes from `asteroids.usdz`. Each one is
    /// a unique asteroid mesh that can be cloned and rendered to a sprite.
    func asteroidMeshes() -> [SCNNode] {
        guard let scene = asteroidsScene else { return [] }
        var out: [SCNNode] = []
        scene.rootNode.enumerateChildNodes { node, _ in
            if node.geometry != nil { out.append(node) }
        }
        return out
    }
}

// MARK: – SCNNode descent helper

extension SCNNode {
    /// Depth-first search for the first descendant whose `name` contains the
    /// given keyword (case-insensitive). Used to robustly match planet types
    /// even when the USDZ prim names have arbitrary prefixes.
    func firstDescendant(nameContaining keyword: String) -> SCNNode? {
        let target = keyword.lowercased()
        var match: SCNNode?
        enumerateChildNodes { node, stop in
            if let name = node.name?.lowercased(), name.contains(target) {
                match = node
                stop.pointee = true
            }
        }
        return match
    }
}
