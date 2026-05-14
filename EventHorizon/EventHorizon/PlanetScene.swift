import SpriteKit
import UIKit

/// Information passed from `GameScene` to `PlanetScene` when the player docks.
struct DockedPlanetInfo {
    let displayName:     String
    let typeDescription: String
    /// PNG basename of the planet sprite (e.g. "rock_planet"). The scene
    /// looks for `<basename>_landscape.png` for the docked view and falls
    /// back to a procedural landscape if not found.
    let spriteName:      String?
    let radius:          CGFloat
    /// World position the ship docked at. On disembark the new `GameScene`
    /// spawns the ship just outside this body's radius and runs the rise
    /// animation FROM this point.
    let worldPosition:   CGPoint
    /// Services available at this planet — drives which menu buttons appear.
    let services:        Set<PlanetService>
}

/// The "docked" view shown when the player lands on a planet.
///
/// Layout (landscape):
///
/// ```
///   PLANET NAME                              [ DISEMBARK ]
///
///   ┌────────────────┐   [ BAR        ]
///   │   LANDSCAPE    │   [ TRADE      ]
///   │      IMAGE     │   [ SHIP VENDOR]
///   │                │   [ OUTFITTER  ]
///   └────────────────┘   [ BANK       ]
///
///   ┌──────────── TEXT BOX or SHIPYARD ─────────┐
///   │                                            │
///   └────────────────────────────────────────────┘
/// ```
///
/// The bottom panel is either a passive text box (BAR/TRADE/OUTFITTER/BANK
/// menu output) or the interactive shipyard (SHIP VENDOR).
final class PlanetScene: SKScene {

    private let info:     DockedPlanetInfo
    private let gameMode: GameMode

    private var textBoxBg:        SKShapeNode!
    private var textBoxLabel:     SKLabelNode!
    /// Container for the shipyard's ship-row UI. Sits over the text box,
    /// hidden by default; revealed when the player opens SHIP VENDOR.
    private var shipyardPanel:    SKNode!

    /// Top-level menu buttons (BAR / TRADE / ... / DISEMBARK).
    private var menuButtons: [(node: SKShapeNode, action: () -> Void)] = []
    /// Buttons inside the shipyard panel. Tracked separately so we can rebuild
    /// them on each open (state changes after a purchase).
    private var shipyardButtons: [(node: SKShapeNode, action: () -> Void)] = []

    // MARK: – Init

    init(size: CGSize, info: DockedPlanetInfo, gameMode: GameMode) {
        self.info     = info
        self.gameMode = gameMode
        super.init(size: size)
    }

    required init?(coder aDecoder: NSCoder) { fatalError() }

    // MARK: – Lifecycle

    override func didMove(to view: SKView) {
        backgroundColor = UIColor(white: 0.02, alpha: 1)
        anchorPoint     = CGPoint(x: 0.5, y: 0.5)

        buildTitleBar()
        buildLandscape()
        buildMenu()
        buildTextBox()

        setMode(text: "Welcome to \(info.displayName). Docking clamps engaged. Standard atmospheric pressure.")
    }

    override func didChangeSize(_ oldSize: CGSize) {
        anchorPoint = CGPoint(x: 0.5, y: 0.5)
    }

    // MARK: – Build

    private func buildTitleBar() {
        let hw = size.width / 2
        let hh = size.height / 2

        let title          = SKLabelNode(text: info.displayName.uppercased())
        title.fontName     = "AvenirNext-UltraLight"
        title.fontSize     = 34
        title.fontColor    = .white
        title.horizontalAlignmentMode = .left
        title.verticalAlignmentMode   = .top
        title.position     = CGPoint(x: -hw + 28, y: hh - 18)
        addChild(title)

        let subtitle          = SKLabelNode(text: info.typeDescription.uppercased())
        subtitle.fontName     = "AvenirNext-Medium"
        subtitle.fontSize     = 11
        subtitle.fontColor    = UIColor(white: 0.55, alpha: 1)
        subtitle.horizontalAlignmentMode = .left
        subtitle.verticalAlignmentMode   = .top
        subtitle.position     = CGPoint(x: -hw + 28, y: hh - 54)
        addChild(subtitle)

        // Disembark button — top-right corner.
        let btn = makeButton(text: "DISEMBARK",
                             size: CGSize(width: 110, height: 32),
                             position: CGPoint(x: hw - 75, y: hh - 30),
                             accent: UIColor(red: 0.85, green: 0.30, blue: 0.30, alpha: 0.85),
                             action: { [weak self] in self?.disembark() })
        addChild(btn)
    }

    private func buildLandscape() {
        let landscapeSize = CGSize(width: 360, height: 250)
        let texture       = loadLandscapeTexture(for: info.spriteName)
                              ?? Self.makeProceduralLandscape(size: landscapeSize)
        let frame         = SKSpriteNode(texture: texture)
        frame.size        = landscapeSize
        frame.position    = CGPoint(x: -size.width / 2 + 28 + landscapeSize.width / 2,
                                    y: -20)
        addChild(frame)

        let border               = SKShapeNode(
            rect: CGRect(x: -landscapeSize.width / 2, y: -landscapeSize.height / 2,
                         width: landscapeSize.width, height: landscapeSize.height),
            cornerRadius: 4
        )
        border.fillColor   = .clear
        border.strokeColor = UIColor(white: 1, alpha: 0.25)
        border.lineWidth   = 1
        frame.addChild(border)
    }

    private func buildMenu() {
        let hw = size.width / 2
        let buttonSize = CGSize(width: 210, height: 36)
        let columnX    = hw - 28 - buttonSize.width / 2
        let topY: CGFloat = 110
        let gap: CGFloat  = 46

        // Order is fixed; we filter by services so buttons stack tightly.
        let candidates: [(PlanetService, () -> Void)] = [
            (.bar,       { [weak self] in self?.openBar() }),
            (.trade,     { [weak self] in self?.openTrade() }),
            (.shipyard,  { [weak self] in self?.openShipyard() }),
            (.outfitter, { [weak self] in self?.openOutfitter() }),
            (.bank,      { [weak self] in self?.openBank() }),
        ]
        let available = candidates.filter { info.services.contains($0.0) }

        for (i, entry) in available.enumerated() {
            let y   = topY - CGFloat(i) * gap
            let btn = makeButton(text: entry.0.buttonLabel,
                                 size: buttonSize,
                                 position: CGPoint(x: columnX, y: y),
                                 accent: UIColor(white: 0.20, alpha: 0.95),
                                 action: entry.1)
            addChild(btn)
        }
    }

    private func buildTextBox() {
        let boxWidth:  CGFloat = size.width - 56
        let boxHeight: CGFloat = 100
        textBoxBg                = SKShapeNode(
            rect: CGRect(x: -boxWidth / 2, y: -boxHeight / 2,
                         width: boxWidth, height: boxHeight),
            cornerRadius: 6
        )
        textBoxBg.fillColor   = UIColor(white: 0.05, alpha: 0.85)
        textBoxBg.strokeColor = UIColor(white: 1, alpha: 0.25)
        textBoxBg.lineWidth   = 1
        textBoxBg.position    = CGPoint(x: 0, y: -size.height / 2 + boxHeight / 2 + 24)
        addChild(textBoxBg)

        textBoxLabel                       = SKLabelNode(text: "")
        textBoxLabel.fontName              = "AvenirNext-Regular"
        textBoxLabel.fontSize              = 13
        textBoxLabel.fontColor             = .white
        textBoxLabel.numberOfLines         = 0
        textBoxLabel.preferredMaxLayoutWidth = boxWidth - 30
        textBoxLabel.lineBreakMode         = .byWordWrapping
        textBoxLabel.horizontalAlignmentMode = .left
        textBoxLabel.verticalAlignmentMode   = .top
        textBoxLabel.position              = CGPoint(x: -boxWidth / 2 + 15,
                                                     y: boxHeight / 2 - 14)
        textBoxBg.addChild(textBoxLabel)

        shipyardPanel          = SKNode()
        shipyardPanel.isHidden = true
        textBoxBg.addChild(shipyardPanel)
    }

    // MARK: – Mode switching (text panel vs. shipyard panel)

    private func setMode(text: String? = nil, shipyard: Bool = false) {
        if let text = text {
            textBoxLabel.text     = text
            textBoxLabel.isHidden = false
        } else {
            textBoxLabel.isHidden = true
        }
        shipyardPanel.isHidden = !shipyard
        if shipyard {
            rebuildShipyard()
        }
    }

    // MARK: – Shipyard

    /// Tear down and rebuild the shipyard rows. Called every time the panel
    /// is shown (and after each purchase) so the "CURRENT" badge tracks
    /// `PlayerProfile.shared.currentShip`.
    private func rebuildShipyard() {
        shipyardPanel.removeAllChildren()
        shipyardButtons.removeAll()

        let boxWidth  = (textBoxBg.path?.boundingBox.width)  ?? size.width - 56
        let boxHeight = (textBoxBg.path?.boundingBox.height) ?? 100

        // Header line — credits balance + title.
        let header              = SKLabelNode(
            text: "SHIPYARD  ·  \(PlayerProfile.shared.credits) CR"
        )
        header.fontName         = "AvenirNext-DemiBold"
        header.fontSize         = 11
        header.fontColor        = UIColor(white: 0.65, alpha: 1)
        header.horizontalAlignmentMode = .left
        header.verticalAlignmentMode   = .top
        header.position         = CGPoint(x: -boxWidth / 2 + 15,
                                          y: boxHeight / 2 - 12)
        shipyardPanel.addChild(header)

        let ships    = PlayerProfile.shared.availableShips
        let current  = PlayerProfile.shared.currentShip
        let firstRowY: CGFloat = boxHeight / 2 - 36
        let rowGap: CGFloat    = 28

        for (i, ship) in ships.enumerated() {
            let isCurrent = (ship.assetName == current.assetName)
            let y         = firstRowY - CGFloat(i) * rowGap
            addShipyardRow(ship: ship, y: y, isCurrent: isCurrent,
                           boxWidth: boxWidth)
        }
    }

    private func addShipyardRow(ship: ShipMetadata,
                                y: CGFloat,
                                isCurrent: Bool,
                                boxWidth: CGFloat) {
        // Name on the left.
        let name                       = SKLabelNode(text: ship.displayName)
        name.fontName                  = "AvenirNext-DemiBold"
        name.fontSize                  = 13
        name.fontColor                 = .white
        name.horizontalAlignmentMode   = .left
        name.verticalAlignmentMode     = .center
        name.position                  = CGPoint(x: -boxWidth / 2 + 15, y: y)
        shipyardPanel.addChild(name)

        // Cost in the center.
        let cost                       = SKLabelNode(text: "0 cr")
        cost.fontName                  = "AvenirNextCondensed-Regular"
        cost.fontSize                  = 12
        cost.fontColor                 = UIColor(white: 0.65, alpha: 1)
        cost.horizontalAlignmentMode   = .center
        cost.verticalAlignmentMode     = .center
        cost.position                  = CGPoint(x: 0, y: y)
        shipyardPanel.addChild(cost)

        // Action button on the right. "CURRENT" if it's the active hull
        // (non-interactive), "BUY" otherwise.
        let btnW: CGFloat = 90
        let btnH: CGFloat = 22
        let btn = SKShapeNode(
            rect: CGRect(x: -btnW / 2, y: -btnH / 2, width: btnW, height: btnH),
            cornerRadius: 4
        )
        btn.position    = CGPoint(x: boxWidth / 2 - 60, y: y)
        btn.lineWidth   = 1

        let label                       = SKLabelNode(text: isCurrent ? "CURRENT" : "BUY")
        label.fontName                  = "AvenirNext-Bold"
        label.fontSize                  = 10
        label.verticalAlignmentMode     = .center
        label.horizontalAlignmentMode   = .center
        btn.addChild(label)

        if isCurrent {
            btn.fillColor   = UIColor(white: 0.18, alpha: 0.75)
            btn.strokeColor = UIColor(white: 0.45, alpha: 0.5)
            label.fontColor = UIColor(white: 0.65, alpha: 1)
        } else {
            btn.fillColor   = UIColor(red: 0.18, green: 0.55, blue: 1.0, alpha: 0.85)
            btn.strokeColor = UIColor(red: 0.45, green: 0.80, blue: 1.0, alpha: 1.0)
            label.fontColor = .white
            shipyardButtons.append((btn, { [weak self] in
                self?.purchaseShip(ship)
            }))
        }
        shipyardPanel.addChild(btn)
    }

    private func purchaseShip(_ ship: ShipMetadata) {
        // Free for now. When credits are real, deduct here.
        PlayerProfile.shared.currentShip = ship
        rebuildShipyard()
    }

    // MARK: – Button factory

    private func makeButton(text: String,
                            size: CGSize,
                            position: CGPoint,
                            accent: UIColor,
                            action: @escaping () -> Void) -> SKShapeNode {
        let btn = SKShapeNode(
            rect: CGRect(x: -size.width / 2, y: -size.height / 2,
                         width: size.width, height: size.height),
            cornerRadius: 5
        )
        btn.fillColor   = accent
        btn.strokeColor = UIColor(white: 1, alpha: 0.30)
        btn.lineWidth   = 1
        btn.position    = position

        let label                       = SKLabelNode(text: text)
        label.fontName                  = "AvenirNext-DemiBold"
        label.fontSize                  = 13
        label.fontColor                 = .white
        label.verticalAlignmentMode     = .center
        label.horizontalAlignmentMode   = .center
        btn.addChild(label)

        menuButtons.append((btn, action))
        return btn
    }

    // MARK: – Touch

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let scenePoint = touch.location(in: self)

        // Shipyard buttons take priority while the panel is open. Their
        // positions are in textBoxBg's local frame, so convert there.
        if !shipyardPanel.isHidden {
            let panelLocal = touch.location(in: textBoxBg)
            for (btn, action) in shipyardButtons where btn.contains(panelLocal) {
                flash(button: btn)
                action()
                return
            }
        }

        // Main menu / disembark.
        for (btn, action) in menuButtons where btn.contains(scenePoint) {
            flash(button: btn)
            action()
            return
        }
    }

    private func flash(button btn: SKShapeNode) {
        let originalFill = btn.fillColor
        btn.run(.sequence([
            .run { btn.fillColor = UIColor(red: 0.55, green: 0.85, blue: 1.0, alpha: 0.95) },
            .wait(forDuration: 0.10),
            .run { btn.fillColor = originalFill },
        ]))
    }

    // MARK: – Menu actions

    private func openBar() {
        setMode(text: Self.barFlavor.randomElement() ?? "It's quiet here.")
    }

    private func openTrade() {
        setMode(text: "TRADE — Cargo manifest empty. Trade routes are not yet established in this system. Check back when warp lanes are charted.")
    }

    private func openShipyard() {
        setMode(shipyard: true)
    }

    private func openOutfitter() {
        setMode(text: "OUTFITTER — On a smoke break. The bell over the door is unattended. A handwritten sign reads: 'BACK IN 10 STANDARD MINUTES'.")
    }

    private func openBank() {
        setMode(text: "BANK — Balance: \(PlayerProfile.shared.credits) credits. Outstanding debts: 0. The teller looks bored. 'Come back when you have business,' he says.")
    }

    private func disembark() {
        // Spawn just outside the planet's body radius at a random angle so
        // the ship drifts back into open space rather than re-overlapping
        // the planet (which would re-trigger the dock proximity check).
        let spawnAngle    = CGFloat.random(in: 0...(2 * .pi))
        let spawnDistance = info.radius + 220
        let spawnPos      = CGPoint(
            x: info.worldPosition.x + cos(spawnAngle) * spawnDistance,
            y: info.worldPosition.y + sin(spawnAngle) * spawnDistance
        )

        let game        = GameScene(size: size,
                                    mode: gameMode,
                                    spawnAt: spawnPos,
                                    disembarkFrom: info.worldPosition)
        game.scaleMode  = .resizeFill
        view?.presentScene(game, transition: .fade(withDuration: 0.5))
    }

    // MARK: – Landscape texture loading

    private func loadLandscapeTexture(for spriteName: String?) -> SKTexture? {
        guard let base = spriteName else { return nil }
        guard let url  = Bundle.main.url(
            forResource:  "\(base)_landscape",
            withExtension: "png",
            subdirectory: "Art.scnassets/celestial_bodies"
        ),
        let image = UIImage(contentsOfFile: url.path)
        else { return nil }
        return SKTexture(image: image)
    }

    private static func makeProceduralLandscape(size: CGSize) -> SKTexture {
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale  = 2
        fmt.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: fmt)
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            let space = CGColorSpaceCreateDeviceRGB()

            let skyColors: [CGColor] = [
                UIColor(red: 0.06, green: 0.07, blue: 0.18, alpha: 1).cgColor,
                UIColor(red: 0.20, green: 0.12, blue: 0.22, alpha: 1).cgColor,
                UIColor(red: 0.42, green: 0.22, blue: 0.18, alpha: 1).cgColor,
            ]
            if let sky = CGGradient(colorsSpace: space, colors: skyColors as CFArray,
                                    locations: [0, 0.7, 1.0]) {
                cg.drawLinearGradient(
                    sky,
                    start: CGPoint(x: 0, y: 0),
                    end:   CGPoint(x: 0, y: size.height * 0.65),
                    options: []
                )
            }
            cg.setFillColor(UIColor(red: 0.10, green: 0.07, blue: 0.05, alpha: 1).cgColor)
            cg.fill(CGRect(x: 0, y: size.height * 0.65, width: size.width, height: size.height * 0.35))

            for _ in 0..<50 {
                let x = CGFloat.random(in: 0...size.width)
                let y = CGFloat.random(in: 0...(size.height * 0.55))
                let r = CGFloat.random(in: 0.5...1.4)
                cg.setFillColor(UIColor(white: 1, alpha: CGFloat.random(in: 0.30...0.95)).cgColor)
                cg.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            }
            for _ in 0..<10 {
                let w = CGFloat.random(in: 12...32)
                let h = CGFloat.random(in: 25...80)
                let x = CGFloat.random(in: 0...(size.width - w))
                let y = size.height * 0.65 - h
                cg.setFillColor(UIColor(white: 0.03, alpha: 1).cgColor)
                cg.fill(CGRect(x: x, y: y, width: w, height: h))

                cg.setFillColor(UIColor(red: 1, green: 0.78, blue: 0.35, alpha: 0.85).cgColor)
                let rows = Int(h / 6)
                for r in 0..<rows where Int.random(in: 0...3) == 0 {
                    let lx = x + w * 0.5 - 1.5
                    let ly = y + CGFloat(r) * 6 + 3
                    cg.fill(CGRect(x: lx, y: ly, width: 3, height: 3))
                }
            }
            cg.setFillColor(UIColor(red: 1.0, green: 0.45, blue: 0.20, alpha: 0.7).cgColor)
            let beaconX = size.width * 0.65
            let beaconY = size.height * 0.65 - 4
            cg.fillEllipse(in: CGRect(x: beaconX - 3, y: beaconY - 3, width: 6, height: 6))
        }
        return SKTexture(image: image)
    }

    // MARK: – Flavor text

    private static let barFlavor: [String] = [
        "A grizzled spacer mutters something about 'the void wolves' that you can't quite make out.",
        "A merchant complains about pirates raiding her latest shipment near the Hadrian belt.",
        "Someone laughs too loudly at their own joke. Their drink spills. No one acknowledges them.",
        "The barkeep slides you a drink you didn't order. 'On the house,' she says. 'You look like you've seen worse than this place.'",
        "Two pilots argue about the best loadout for an old-model freighter. They're both wrong.",
        "An old-timer claims he once flew through a nebula 'so thick you could chew it'.",
        "A holovid in the corner is showing a war you've never heard of. The footage looks ancient.",
        "Music plays from somewhere. You can't quite locate the source.",
        "Someone is selling maps to a derelict ship. You doubt the maps are real.",
        "A traveler asks if you've heard about the strange signals coming from the outer rim.",
        "You catch a fragment of conversation: '…and that's when the planet just… stopped rotating.'",
        "The lights flicker. No one seems to notice.",
        "A child runs past, chased by a small mechanical dog. The dog is missing an eye.",
        "Someone at the bar buys a round for everyone. You drink quickly before they change their mind.",
        "An offworlder asks where she can find a ship vendor. You point. She nods and leaves.",
        "A jukebox in the corner plays the same song for the third time. Nobody's complaining.",
        "Two patrons compare scars. One of them, you suspect, is fictional.",
        "You overhear someone whisper about a station that 'isn't on any chart, but everyone knows where it is.'",
    ]
}
