import SpriteKit
import UIKit

/// Compact info panel in the top-left HUD. Shows the display name + type
/// of the currently-selected celestial body, plus its distance from the
/// player. Hidden when nothing is selected.
final class InfoTooltip: SKNode {

    private let panelWidth:  CGFloat = 230
    private let panelHeight: CGFloat = 64

    private let background: SKShapeNode
    private let title:      SKLabelNode
    private let subtitle:   SKLabelNode
    private let detail:     SKLabelNode

    override init() {
        background           = SKShapeNode(
            rect: CGRect(x: 0, y: -InfoTooltip.height, width: 230, height: InfoTooltip.height),
            cornerRadius: 6
        )
        background.fillColor   = UIColor(white: 0.04, alpha: 0.78)
        background.strokeColor = UIColor(white: 1, alpha: 0.28)
        background.lineWidth   = 1

        title                       = SKLabelNode(text: "")
        title.fontName              = "AvenirNext-DemiBold"
        title.fontSize              = 14
        title.fontColor             = UIColor(red: 0.30, green: 1.0, blue: 0.45, alpha: 1)
        title.horizontalAlignmentMode = .left
        title.verticalAlignmentMode   = .baseline
        title.position              = CGPoint(x: 12, y: -22)

        subtitle                       = SKLabelNode(text: "")
        subtitle.fontName              = "AvenirNext-Regular"
        subtitle.fontSize              = 11
        subtitle.fontColor             = UIColor(white: 0.82, alpha: 1)
        subtitle.horizontalAlignmentMode = .left
        subtitle.verticalAlignmentMode   = .baseline
        subtitle.position              = CGPoint(x: 12, y: -39)

        detail                       = SKLabelNode(text: "")
        detail.fontName              = "AvenirNextCondensed-Regular"
        detail.fontSize              = 10
        detail.fontColor             = UIColor(white: 0.65, alpha: 1)
        detail.horizontalAlignmentMode = .left
        detail.verticalAlignmentMode   = .baseline
        detail.position              = CGPoint(x: 12, y: -55)

        super.init()
        addChild(background)
        addChild(title)
        addChild(subtitle)
        addChild(detail)
        isHidden = true
    }

    required init?(coder aDecoder: NSCoder) { fatalError() }

    static let height: CGFloat = 64

    func show(body: CelestialBodyNode, distance: CGFloat) {
        title.text    = body.displayName
        subtitle.text = body.typeDescription
        detail.text   = "Radius \(Int(body.bodyRadius)) · Distance \(Int(distance))"
        isHidden      = false
    }

    /// Update only the distance text — display name/type don't change between
    /// frames, so we don't bother retouching them.
    func updateDistance(_ distance: CGFloat, for body: CelestialBodyNode) {
        detail.text = "Radius \(Int(body.bodyRadius)) · Distance \(Int(distance))"
    }

    func hide() {
        isHidden = true
    }
}
