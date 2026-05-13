import SpriteKit
import UIKit

/// Circular radar in the HUD. Shows the relative position of suns, planets,
/// and other ships around the local player, with a small wedge at the center
/// pointing in the ship's heading.
///
/// Objects beyond `worldRadius` are clamped to the radar's edge so the player
/// can still see their direction.
final class MiniMap: SKNode {

    let radius:      CGFloat
    let worldRadius: CGFloat        // how many world units the radar covers

    private let background:   SKShapeNode
    private let outerRing:    SKShapeNode
    private let crosshair:    SKNode
    private let headingWedge: SKShapeNode

    private var sunDots:    [SKShapeNode] = []
    private var planetDots: [SKShapeNode] = []
    private var shipDots:   [String: SKShapeNode] = [:]

    init(radius: CGFloat = 62, worldRadius: CGFloat = 5500) {
        self.radius      = radius
        self.worldRadius = worldRadius

        background              = SKShapeNode(circleOfRadius: radius)
        background.fillColor    = UIColor(white: 0.04, alpha: 0.78)
        background.strokeColor  = .clear

        outerRing               = SKShapeNode(circleOfRadius: radius)
        outerRing.fillColor     = .clear
        outerRing.strokeColor   = UIColor(white: 1, alpha: 0.35)
        outerRing.lineWidth     = 1

        // Faint crosshair lines for orientation reference.
        crosshair = SKNode()
        let h = SKShapeNode(rect: CGRect(x: -radius, y: -0.5, width: radius * 2, height: 1))
        let v = SKShapeNode(rect: CGRect(x: -0.5, y: -radius, width: 1, height: radius * 2))
        for line in [h, v] {
            line.fillColor   = UIColor(white: 1, alpha: 0.12)
            line.strokeColor = .clear
            crosshair.addChild(line)
        }

        // Heading wedge — small filled triangle, default pointing "up".
        let wedgePath = CGMutablePath()
        wedgePath.move(to:    CGPoint(x:  0, y:  10))
        wedgePath.addLine(to: CGPoint(x: -5, y:  -4))
        wedgePath.addLine(to: CGPoint(x:  5, y:  -4))
        wedgePath.closeSubpath()
        headingWedge             = SKShapeNode(path: wedgePath)
        headingWedge.fillColor   = UIColor(white: 1, alpha: 0.95)
        headingWedge.strokeColor = .clear

        super.init()
        addChild(background)
        addChild(crosshair)
        addChild(outerRing)
        addChild(headingWedge)
    }

    required init?(coder aDecoder: NSCoder) { fatalError() }

    // MARK: – Configuration (static objects)

    /// Set up the static dots for known suns and planets. Call once after
    /// the solar system is built — these positions don't change at runtime.
    func configure(suns: [CGPoint], planets: [CGPoint]) {
        sunDots.forEach    { $0.removeFromParent() }
        planetDots.forEach { $0.removeFromParent() }
        sunDots    = []
        planetDots = []

        for _ in suns {
            let dot          = SKShapeNode(circleOfRadius: 4.5)
            dot.fillColor    = .clear
            dot.strokeColor  = .white
            dot.lineWidth    = 1.5
            addChild(dot)
            sunDots.append(dot)
        }
        for _ in planets {
            let dot          = SKShapeNode(circleOfRadius: 4)
            dot.fillColor    = .clear
            dot.strokeColor  = UIColor(red: 0.20, green: 1.0, blue: 0.40, alpha: 1)
            dot.lineWidth    = 1.5
            addChild(dot)
            planetDots.append(dot)
        }
    }

    // MARK: – Per-frame update

    /// Recompute dot positions and wedge rotation based on the player's
    /// current world position and heading.
    func update(playerPosition: CGPoint,
                playerHeading:  CGFloat,
                suns:           [CGPoint],
                planets:        [CGPoint],
                ships:          [(id: String, position: CGPoint)]) {
        let scale = radius / worldRadius

        for (i, world) in suns.enumerated() where i < sunDots.count {
            sunDots[i].position = relativePosition(world: world,
                                                   player: playerPosition,
                                                   scale: scale)
        }
        for (i, world) in planets.enumerated() where i < planetDots.count {
            planetDots[i].position = relativePosition(world: world,
                                                      player: playerPosition,
                                                      scale: scale)
        }

        // Manage ship dots — add new ones, remove gone ones.
        let currentIDs = Set(ships.map { $0.id })
        for (id, dot) in shipDots where !currentIDs.contains(id) {
            dot.removeFromParent()
            shipDots.removeValue(forKey: id)
        }
        for ship in ships {
            let dot: SKShapeNode
            if let existing = shipDots[ship.id] {
                dot = existing
            } else {
                dot          = SKShapeNode(circleOfRadius: 3)
                dot.fillColor    = UIColor(red: 1.0, green: 0.35, blue: 0.30, alpha: 1)
                dot.strokeColor  = .clear
                addChild(dot)
                shipDots[ship.id] = dot
            }
            dot.position = relativePosition(world: ship.position,
                                            player: playerPosition,
                                            scale: scale)
        }

        // Default wedge points along +Y. Ship heading 0 = +X (world right),
        // so we offset by -π/2 to align.
        headingWedge.zRotation = playerHeading - .pi / 2
    }

    private func relativePosition(world: CGPoint,
                                  player: CGPoint,
                                  scale: CGFloat) -> CGPoint {
        let dx = (world.x - player.x) * scale
        let dy = (world.y - player.y) * scale
        let mag = sqrt(dx * dx + dy * dy)
        if mag > radius {
            // Clamp to the radar edge for off-radar objects.
            let s = radius / mag
            return CGPoint(x: dx * s, y: dy * s)
        }
        return CGPoint(x: dx, y: dy)
    }
}
