import SpriteKit
import UIKit

/// A celestial body in the playfield. Carries the metadata needed for
/// tap-to-select (kind, display name, radius) and renders the green
/// four-cornered selection bracket when selected.
///
/// The node itself has no visible content — its children (a textured sprite,
/// halo, asteroid mesh, etc.) do all the drawing. This keeps the selection
/// bracket axis-aligned even when a child (e.g. a spinning asteroid sprite)
/// is rotating.
final class CelestialBodyNode: SKNode {

    enum Kind { case sun, planet, asteroid }

    let kind:             Kind
    let displayName:      String
    let typeDescription:  String
    let bodyRadius:       CGFloat

    /// `false` for the sun — only planets and asteroids respond to taps.
    var isSelectable: Bool { kind != .sun }

    private weak var selectionBracket: SKShapeNode?

    init(kind: Kind,
         displayName: String,
         typeDescription: String,
         radius: CGFloat) {
        self.kind            = kind
        self.displayName     = displayName
        self.typeDescription = typeDescription
        self.bodyRadius      = radius
        super.init()
    }

    required init?(coder aDecoder: NSCoder) { fatalError() }

    // MARK: – Selection state

    func setSelected(_ selected: Bool) {
        if selected {
            guard selectionBracket == nil else { return }
            let bracket = makeSelectionBracket()
            addChild(bracket)
            selectionBracket = bracket
        } else {
            selectionBracket?.removeFromParent()
            selectionBracket = nil
        }
    }

    private func makeSelectionBracket() -> SKShapeNode {
        let frameSize = bodyRadius * 2.45      // slightly larger than the body
        let cornerLen = max(8, frameSize * 0.18)
        let half      = frameSize / 2

        let path = CGMutablePath()
        // top-left
        path.move(to:    CGPoint(x: -half + cornerLen, y:  half))
        path.addLine(to: CGPoint(x: -half,             y:  half))
        path.addLine(to: CGPoint(x: -half,             y:  half - cornerLen))
        // top-right
        path.move(to:    CGPoint(x:  half - cornerLen, y:  half))
        path.addLine(to: CGPoint(x:  half,             y:  half))
        path.addLine(to: CGPoint(x:  half,             y:  half - cornerLen))
        // bottom-right
        path.move(to:    CGPoint(x:  half - cornerLen, y: -half))
        path.addLine(to: CGPoint(x:  half,             y: -half))
        path.addLine(to: CGPoint(x:  half,             y: -half + cornerLen))
        // bottom-left
        path.move(to:    CGPoint(x: -half + cornerLen, y: -half))
        path.addLine(to: CGPoint(x: -half,             y: -half))
        path.addLine(to: CGPoint(x: -half,             y: -half + cornerLen))

        let shape          = SKShapeNode(path: path)
        shape.strokeColor  = UIColor(red: 0.20, green: 1.0, blue: 0.35, alpha: 1.0)
        shape.fillColor    = .clear
        shape.lineWidth    = 2.0
        shape.lineCap      = .round
        shape.zPosition    = 50    // sit above the body's children
        return shape
    }
}
