import SpriteKit
import UIKit

/// A bright cyan beam rendered between a ship's gun mount and either the
/// first target it intersects or the weapon's max range. Instant-hit by
/// design (no `physicsBody`) — `GameScene` ray-casts each frame to find
/// the target and applies damage; the node is just visual.
///
/// The beam is two stacked nodes:
///   • a **bright white core**: thin SKShapeNode, additive blending.
///   • a **cyan outer glow**:   thicker SKShapeNode, half alpha, also additive.
///
/// `setEndpoints(from:to:)` resizes and rotates both in place so the same
/// instance is reused frame-to-frame while the player is firing.
@MainActor
final class BeamNode: SKNode {

    /// Multiplied into the core/glow alpha each frame so the beam shimmers
    /// slightly while held — purely cosmetic.
    private static let pulseAlphaRange: ClosedRange<CGFloat> = 0.85...1.0

    private let core: SKShapeNode
    private let glow: SKShapeNode

    /// Tint accents. Cyan/white sells "beam"; subclass-friendly so future
    /// weapons (red plasma lance, green laser) can drop in different hues
    /// via convenience initialisers later.
    init(coreColor: UIColor = .white,
         glowColor: UIColor = UIColor(red: 0.55, green: 0.95, blue: 1.0, alpha: 1)) {

        self.core = SKShapeNode()
        self.glow = SKShapeNode()

        super.init()

        core.fillColor   = coreColor
        core.strokeColor = .clear
        core.glowWidth   = 6
        core.blendMode   = .add
        core.zPosition   = 1

        glow.fillColor   = glowColor.withAlphaComponent(0.55)
        glow.strokeColor = .clear
        glow.glowWidth   = 16
        glow.blendMode   = .add
        glow.zPosition   = 0

        addChild(glow)
        addChild(core)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Updates both stripes to span `from → to`. Coordinates are scene-space.
    func setEndpoints(from a: CGPoint, to b: CGPoint) {
        let dx     = b.x - a.x
        let dy     = b.y - a.y
        let length = max(2, hypot(dx, dy))
        let angle  = atan2(dy, dx)

        position   = a
        zRotation  = angle

        // Beam is drawn along its local +X axis, length on X, thickness on Y.
        core.path = beamPath(length: length, thickness: 2)
        glow.path = beamPath(length: length, thickness: 6)

        // Subtle alpha shimmer.
        let shimmer = CGFloat.random(in: Self.pulseAlphaRange)
        core.alpha = shimmer
        glow.alpha = shimmer
    }

    private func beamPath(length: CGFloat, thickness t: CGFloat) -> CGPath {
        CGPath(roundedRect: CGRect(x: 0, y: -t / 2, width: length, height: t),
               cornerWidth: t / 2, cornerHeight: t / 2, transform: nil)
    }
}
