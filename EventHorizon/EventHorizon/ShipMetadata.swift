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

    // Asset
    let assetName:        String
    let assetSubdirectory: String

    // Orientation — direction the model's nose/top point in model-local space.
    // We rotate the model so `forwardAxis` aligns with the on-screen "up"
    // direction (nose toward top of screen at body.zRotation = 0).
    let forwardAxis: Axis
    let upAxis:      Axis

    // Hardpoints in body-local 2D pixels.
    let thrustMounts: [Mount]
    let gunMounts:    [Mount]

    // Visual sizing.
    let viewportSize:     CGSize    // SK3DNode render target size
    let orthographicScale: Double   // half-height in world units; smaller = ship fills more of viewport
}

extension ShipMetadata {

    static let spaceship1 = ShipMetadata(
        assetName:        "spaceship1",
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
}
