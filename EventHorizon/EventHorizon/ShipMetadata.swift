import SceneKit
import UIKit

/// Describes how a 3D ship asset is oriented in model space and where its
/// thrusters/guns mount in body-local (post-orientation) 2D coordinates.
///
/// Adding a new ship is a matter of defining a `ShipMetadata` value — the
/// renderer is fully data-driven from it.
struct ShipMetadata {

    enum Axis {
        case xPlus, xMinus, yPlus, yMinus, zPlus, zMinus

        var vector: SCNVector3 {
            switch self {
            case .xPlus:  return SCNVector3( 1, 0, 0)
            case .xMinus: return SCNVector3(-1, 0, 0)
            case .yPlus:  return SCNVector3( 0, 1, 0)
            case .yMinus: return SCNVector3( 0,-1, 0)
            case .zPlus:  return SCNVector3( 0, 0, 1)
            case .zMinus: return SCNVector3( 0, 0,-1)
            }
        }
    }

    /// A hardpoint expressed in 2D body-local pixels.
    /// Body coordinates use `+y = nose`, `-y = tail`, `+x = right`.
    struct Mount {
        let bodyPoint: CGPoint
    }

    /// File format of the ship's visual asset.
    ///
    /// • `.usdc` — full 3D model. `forwardAxis`/`upAxis` are used to orient
    ///   the mesh and the SK3DNode-rendered scene supports lean (banking)
    ///   and dynamic sun lighting.
    /// • `.png`  — flat 2D sprite, drawn into an `SKSpriteNode`. The ship's
    ///   pose is the artwork's pose — `forwardAxis`/`upAxis` are ignored
    ///   and `applyLean(_:)` is a no-op. Cheaper to render.
    enum AssetKind { case usdc, png }

    /// Human-readable name shown in the shipyard and elsewhere in the UI.
    let displayName:      String

    // Asset
    let assetKind:        AssetKind
    let assetName:        String
    let assetSubdirectory: String

    // Orientation — direction the model's nose/top point in model-local space.
    // We rotate the model so `forwardAxis` aligns with the on-screen "up"
    // direction (nose toward top of screen at body.zRotation = 0).
    // (Ignored for `.png` assets — the artwork is assumed to already point up.)
    let forwardAxis: Axis
    let upAxis:      Axis

    // Hardpoints in body-local 2D pixels.
    let thrustMounts: [Mount]
    let gunMounts:    [Mount]

    // Visual sizing.
    let viewportSize:     CGSize    // SK3DNode render target / sprite display size
    let orthographicScale: Double   // half-height in world units; smaller = ship fills more of viewport
}

extension ShipMetadata {

    /// 3D USDC ship. Renderer reads this; gameplay stats (hull, shields,
    /// fuel, outfits) come from `data/ships/arclight.json` via `ShipRegistry`.
    static let arclight = ShipMetadata(
        displayName:      "Arclight",
        assetKind:        .usdc,
        assetName:        "arclight",
        assetSubdirectory: "Art.scnassets/ships",
        // First guess gave "nose down, on its side": model's true nose appears
        // to be -X (not +X), and its true top is +Z (not +Y, hence the roll).
        forwardAxis:      .xMinus,
        upAxis:           .zPlus,
        thrustMounts: [
            Mount(bodyPoint: CGPoint(x: 0, y: -42))
        ],
        gunMounts: [
            Mount(bodyPoint: CGPoint(x: -10, y: 32)),
            Mount(bodyPoint: CGPoint(x:  10, y: 32)),
        ],
        viewportSize:     CGSize(width: 110, height: 110),
        orthographicScale: 0.6
    )

    /// 2D ringship — the current default. The artwork is expected to point
    /// nose-up (top of the PNG). No 3D orientation, no lean.
    static let ringship = ShipMetadata(
        displayName:      "RingShip",
        assetKind:        .png,
        assetName:        "ringship",
        assetSubdirectory: "Art.scnassets/ships",
        forwardAxis:      .yPlus,         // unused for PNG, but the field is non-optional
        upAxis:           .zPlus,         // unused for PNG
        thrustMounts: [
            Mount(bodyPoint: CGPoint(x: 0, y: -42))
        ],
        // Legacy in-Swift mount list — turret positions now live in
        // `ringship.json`'s `"turret hardpoints"` array. These two front
        // mounts remain as a fallback for any code path that hasn't
        // migrated to the JSON-driven hardpoints yet.
        gunMounts: [
            Mount(bodyPoint: CGPoint(x: -10, y: 32)),
            Mount(bodyPoint: CGPoint(x:  10, y: 32)),
        ],
        viewportSize:     CGSize(width: 110, height: 110),
        orthographicScale: 0.6
    )

    /// Lookup by ID slug (must match the `data/ships/<id>.json` basename and
    /// the `Art.scnassets/ships/<id>.{usdc,png}` asset name). When a new
    /// ship JSON drops in, give it a Swift `ShipMetadata` here and add the
    /// pairing — registry-driven lookups stay automatic.
    static let byID: [String: ShipMetadata] = [
        "arclight": .arclight,
        "ringship": .ringship,
    ]
}
