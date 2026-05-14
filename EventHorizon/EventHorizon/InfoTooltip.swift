import SpriteKit
import UIKit

/// Compact info panel in the top-left HUD. Shows the display name + type of
/// the currently-selected celestial body, plus its distance from the player.
/// For planets, an extra "Dock" button appears at the bottom — enabled when
/// the player is close to the planet and moving slowly, disabled otherwise.
/// Hidden entirely when nothing is selected.
final class InfoTooltip: SKNode {

    static let height: CGFloat = 92      // includes dock-button slot

    private let panelWidth:  CGFloat = 230
    private let panelHeight: CGFloat = 92

    private let background: SKShapeNode
    private let title:      SKLabelNode
    private let subtitle:   SKLabelNode
    private let detail:     SKLabelNode

    private let dockButton:      SKShapeNode
    private let dockLabel:       SKLabelNode
    private var isDockable       = false
    private var dockButtonShown  = false

    /// Callback fired when the user taps the active Dock button.
    var onDockTapped: (() -> Void)?

    override init() {
        background           = SKShapeNode(
            rect: CGRect(x: 0, y: -panelHeight, width: 230, height: panelHeight),
            cornerRadius: 6
        )
        background.fillColor   = UIColor(white: 0.04, alpha: 0.80)
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

        // Dock button — full width minus margins, sits at the bottom of the
        // panel with a small gap above it.
        let btnHeight: CGFloat   = 22
        let btnX: CGFloat        = 12
        let btnWidth: CGFloat    = 230 - 24
        let btnY: CGFloat        = -panelHeight + 8
        dockButton               = SKShapeNode(
            rect: CGRect(x: btnX, y: btnY, width: btnWidth, height: btnHeight),
            cornerRadius: 4
        )
        dockButton.lineWidth     = 1
        dockButton.isHidden      = true

        dockLabel                       = SKLabelNode(text: "DOCK")
        dockLabel.fontName              = "AvenirNext-Bold"
        dockLabel.fontSize              = 11
        dockLabel.horizontalAlignmentMode = .center
        dockLabel.verticalAlignmentMode   = .center
        dockLabel.position              = CGPoint(x: btnX + btnWidth / 2,
                                                  y: btnY + btnHeight / 2)
        dockLabel.isHidden              = true

        super.init()
        addChild(background)
        addChild(title)
        addChild(subtitle)
        addChild(detail)
        addChild(dockButton)
        addChild(dockLabel)
        isHidden = true
    }

    required init?(coder aDecoder: NSCoder) { fatalError() }

    // MARK: – Body display

    func show(body: CelestialBodyNode, distance: CGFloat) {
        title.text    = body.displayName
        subtitle.text = body.typeDescription
        detail.text   = "Radius \(Int(body.bodyRadius)) · Distance \(Int(distance))"

        // Dock button visibility — only for planets. Active state is then
        // controlled by `setDockable(_:)` based on distance + speed checks.
        let isPlanet      = body.kind == .planet
        dockButtonShown   = isPlanet
        dockButton.isHidden = !isPlanet
        dockLabel.isHidden  = !isPlanet
        setDockable(false)            // default to disabled until conditions met

        isHidden = false
    }

    func updateDistance(_ distance: CGFloat, for body: CelestialBodyNode) {
        detail.text = "Radius \(Int(body.bodyRadius)) · Distance \(Int(distance))"
    }

    func hide() {
        isHidden            = true
        dockButtonShown     = false
        dockButton.isHidden = true
        dockLabel.isHidden  = true
    }

    // MARK: – Dock button state

    /// Style the dock button based on whether the dock conditions are
    /// currently satisfied. Greyed-out when disabled.
    func setDockable(_ dockable: Bool) {
        isDockable = dockable
        if dockable {
            dockButton.fillColor   = UIColor(red: 0.18, green: 0.55, blue: 1.0, alpha: 0.85)
            dockButton.strokeColor = UIColor(red: 0.45, green: 0.80, blue: 1.0, alpha: 1.0)
            dockLabel.fontColor    = .white
            dockLabel.text         = "DOCK"
        } else {
            dockButton.fillColor   = UIColor(white: 0.15, alpha: 0.55)
            dockButton.strokeColor = UIColor(white: 0.45, alpha: 0.5)
            dockLabel.fontColor    = UIColor(white: 0.50, alpha: 1)
            // Helpful hint when shown but disabled.
            dockLabel.text         = "DOCK — APPROACH SLOWLY"
        }
    }

    // MARK: – Touch handling

    /// Returns true if the touch was on the active Dock button (so the caller
    /// can consume it and not propagate to the joystick or selection logic).
    func handleTouch(_ touch: UITouch) -> Bool {
        guard dockButtonShown, isDockable else { return false }
        let p = touch.location(in: self)
        guard dockButton.frame.contains(p) else { return false }
        // Brief flash so the tap is felt, then fire the callback.
        let originalFill = dockButton.fillColor
        dockButton.run(.sequence([
            .run { [weak self] in
                self?.dockButton.fillColor = UIColor(red: 0.55, green: 0.85, blue: 1.0, alpha: 1.0)
            },
            .wait(forDuration: 0.10),
            .run { [weak self] in
                self?.dockButton.fillColor = originalFill
            },
        ]))
        onDockTapped?()
        return true
    }
}
