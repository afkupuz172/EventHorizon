import SpriteKit
import UIKit

/// Information passed from `GameScene` to `PlanetScene` when the player docks.
struct DockedPlanetInfo {
    /// JSON body ID. Used by `disembark()` to look up the planet's CURRENT
    /// orbital position via `OrbitalSolver` so the ship lifts off from
    /// wherever the planet actually is right now — important because
    /// planets keep orbiting while you're parked.
    let bodyID:          String
    let displayName:     String
    let typeDescription: String
    /// PNG basename of the planet sprite (e.g. "rock_planet").
    let spriteName:      String?
    let radius:          CGFloat
    /// World position at the moment of docking. Used only as a fallback if
    /// the orbital re-resolution fails on disembark.
    let worldPosition:   CGPoint
    /// Services available at this planet — drives which menu buttons appear.
    let services:        Set<PlanetService>
}

extension DockedPlanetInfo {
    /// Reconstruct a `DockedPlanetInfo` directly from JSON for "load game" /
    /// "new game" flows that bypass the live `GameScene` docking animation.
    /// World position is resolved via the orbital solver against now so the
    /// disembark take-off matches the planet's current orbital position.
    static func load(systemName: String, planetID: String) -> DockedPlanetInfo? {
        guard let cfg = SolarSystemConfig.load(name: systemName),
              let p   = cfg.planets.first(where: { $0.id == planetID })
        else { return nil }

        let pos = OrbitalSolver.position(of: planetID, in: cfg,
                                         at: Date().timeIntervalSince1970) ?? .zero
        let services: Set<PlanetService>
        if let strs = p.services {
            services = Set(strs.compactMap { PlanetService(rawValue: $0) })
        } else {
            services = Set(PlanetService.allCases)
        }
        let words    = p.sprite.replacingOccurrences(of: "_", with: " ")
        let typeDesc = words.prefix(1).uppercased() + words.dropFirst()

        return DockedPlanetInfo(
            bodyID:          p.id,
            displayName:     p.displayName ?? p.id.capitalized,
            typeDescription: typeDesc,
            spriteName:      p.sprite,
            radius:          CGFloat(p.radius),
            worldPosition:   pos,
            services:        services
        )
    }
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

    private var textBoxBg:    SKShapeNode!
    private var textBoxLabel: SKLabelNode!

    private var menuButtons: [(node: SKShapeNode, action: () -> Void)] = []

    /// Nodes hidden during disembark prep — restored on cancel, replaced
    /// with the loading panel until the transition fires.
    private var dismissableUI: [SKNode] = []
    private var loadingPanel: SKNode?
    /// `GameScene` that's being pre-warmed in parallel with the bar fill so
    /// the actual transition is instant once the bar completes.
    private var pendingGameScene: GameScene?

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

        buildBackground()
        buildTitleBar()
        buildMenu()
        buildTextBox()

        setMode("Welcome to \(info.displayName). Docking clamps engaged. Standard atmospheric pressure.")

        // Update the player's location and snapshot to disk. Landing is the
        // canonical save trigger — anything bought/sold while docked is
        // already in the live `PlayerProfile`.
        PlayerProfile.shared.currentPlanetID = info.bodyID
        PlayerProfile.shared.persistCurrentSave()
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

        // Disembark + Quit buttons — top-right corner. Quit returns to the
        // home screen; save already happened on dock so no confirmation.
        let disembarkBtn = makeButton(text: "DISEMBARK",
                             size: CGSize(width: 110, height: 32),
                             position: CGPoint(x: hw - 75, y: hh - 30),
                             accent: UIColor(red: 0.85, green: 0.30, blue: 0.30, alpha: 0.85),
                             action: { [weak self] in self?.beginDisembarkSequence() })
        addChild(disembarkBtn)
        dismissableUI.append(disembarkBtn)

        let quitBtn = makeButton(text: "QUIT",
                             size: CGSize(width: 70, height: 28),
                             position: CGPoint(x: hw - 75 - 110 / 2 - 10 - 70 / 2, y: hh - 30),
                             accent: UIColor(white: 0.18, alpha: 0.95),
                             action: { [weak self] in self?.quitToHome() })
        addChild(quitBtn)
        dismissableUI.append(quitBtn)
    }

    private func quitToHome() {
        let loading = LoadingScene(size: size)
        loading.scaleMode = .resizeFill
        view?.presentScene(loading, transition: .fade(withDuration: 0.30))
    }

    private func buildBackground() {
        // Full-screen port artwork. Scaled to fill the entire scene rect
        // and pushed to the back; menu buttons + text box overlay on top.
        let texture = Self.loadPortTexture(named: "badlands")
                       ?? Self.makeProceduralLandscape(size: size)
        let bg          = SKSpriteNode(texture: texture)
        bg.size         = sizeFilling(viewportSize: size, textureSize: texture.size())
        bg.position     = .zero
        bg.zPosition    = -10
        addChild(bg)

        // Subtle vignette so light text near the edges stays legible against
        // bright sky / lit terrain in the artwork.
        let vignette = SKShapeNode(rectOf: size)
        vignette.fillColor   = UIColor(white: 0, alpha: 0.25)
        vignette.strokeColor = .clear
        vignette.zPosition   = -9
        addChild(vignette)
    }

    /// Aspect-fill scale: ensures the artwork covers the whole scene with no
    /// transparent gaps; excess is cropped by the scene bounds.
    private func sizeFilling(viewportSize: CGSize, textureSize: CGSize) -> CGSize {
        guard textureSize.width > 0, textureSize.height > 0 else { return viewportSize }
        let sx = viewportSize.width  / textureSize.width
        let sy = viewportSize.height / textureSize.height
        let s  = max(sx, sy)
        return CGSize(width: textureSize.width * s, height: textureSize.height * s)
    }

    private static func loadPortTexture(named base: String) -> SKTexture? {
        for ext in ["jpg", "png"] {
            if let url = Bundle.main.url(forResource: base, withExtension: ext,
                                         subdirectory: "Art.scnassets/ports"),
               let img = UIImage(contentsOfFile: url.path) {
                return SKTexture(image: img)
            }
        }
        return nil
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
                                 accent: UIColor(white: 0.10, alpha: 0.92),
                                 action: entry.1)
            addChild(btn)
            dismissableUI.append(btn)
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
        // Near-opaque so light text reads even when the badlands artwork
        // behind it is bright.
        textBoxBg.fillColor   = UIColor(white: 0.04, alpha: 0.92)
        textBoxBg.strokeColor = UIColor(white: 1, alpha: 0.35)
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
    }

    // MARK: – Mode switching

    private func setMode(_ text: String) {
        textBoxLabel.text = text
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
        setMode(Self.barFlavor.randomElement() ?? "It's quiet here.")
    }

    private func openTrade() {
        setMode("TRADE — Cargo manifest empty. Trade routes are not yet established in this system. Check back when warp lanes are charted.")
    }

    private func openShipyard() {
        let scene        = ShipyardScene(size: size, info: info, gameMode: gameMode)
        scene.scaleMode  = .resizeFill
        view?.presentScene(scene, transition: .fade(withDuration: 0.30))
    }

    private func openOutfitter() {
        let scene        = OutfitterScene(size: size, info: info, gameMode: gameMode)
        scene.scaleMode  = .resizeFill
        view?.presentScene(scene, transition: .fade(withDuration: 0.30))
    }

    private func openBank() {
        setMode("BANK — Balance: \(PlayerProfile.shared.credits) credits. Outstanding debts: 0. The teller looks bored. 'Come back when you have business,' he says.")
    }

    private static let disembarkSteps: [String] = [
        "Releasing docking clamps…",
        "Spooling fusion reactor…",
        "Calibrating inertial dampers…",
        "Loading flight plan into nav…",
        "Pressurizing the cockpit…",
        "Clearing atmospheric exit lane…",
    ]

    /// Replaces the menu/disembark buttons with a progress bar that fills
    /// over a short sequence of flavour notes, then triggers the real
    /// `disembark()` transition. Saves are already on dock, so this is
    /// purely visual cover for scene setup.
    private func beginDisembarkSequence() {
        guard loadingPanel == nil else { return }   // ignore re-tap

        for node in dismissableUI { node.isHidden = true }
        menuButtons.removeAll()                     // disable any inflight taps

        // Kick off GameScene construction NOW so its expensive setup
        // (starfield, solar-system install) runs in parallel with the bar
        // animation. By the time the bar fills, the scene is fully built
        // and `presentScene` is a near-instant swap.
        let now = Date().timeIntervalSince1970
        let spawnPos: CGPoint
        if let cfg = SolarSystemConfig.load(name: PlayerProfile.shared.currentSystem),
           let resolved = OrbitalSolver.position(of: info.bodyID, in: cfg, at: now) {
            spawnPos = resolved
        } else {
            spawnPos = info.worldPosition
        }
        let game = GameScene(size: size,
                             mode: gameMode,
                             spawnAt: spawnPos,
                             disembarkFrom: spawnPos)
        pendingGameScene = game
        game.prepareSceneAsync { /* prep finished; transition is gated by bar timer */ }

        let panel = SKNode()
        addChild(panel)
        loadingPanel = panel

        let hw = size.width / 2
        let panelW: CGFloat = min(size.width - 80, 520)
        let panelH: CGFloat = 90
        let backdrop = SKShapeNode(
            rect: CGRect(x: -panelW / 2, y: -panelH / 2, width: panelW, height: panelH),
            cornerRadius: 8
        )
        backdrop.fillColor   = UIColor(white: 0.04, alpha: 0.92)
        backdrop.strokeColor = UIColor(white: 1, alpha: 0.32)
        backdrop.lineWidth   = 1
        backdrop.position    = CGPoint(x: 0, y: 20)
        panel.addChild(backdrop)

        let title             = SKLabelNode(text: "DISEMBARK PREP")
        title.fontName        = "AvenirNext-DemiBold"
        title.fontSize        = 12
        title.fontColor       = UIColor(white: 0.60, alpha: 1)
        title.position        = CGPoint(x: 0, y: panelH / 2 - 18)
        backdrop.addChild(title)

        let stepLbl             = SKLabelNode(text: Self.disembarkSteps[0])
        stepLbl.fontName        = "AvenirNext-Regular"
        stepLbl.fontSize        = 14
        stepLbl.fontColor       = .white
        stepLbl.numberOfLines   = 1
        stepLbl.preferredMaxLayoutWidth = panelW - 32
        stepLbl.position        = CGPoint(x: 0, y: 6)
        backdrop.addChild(stepLbl)

        let barW: CGFloat = panelW - 40
        let barH: CGFloat = 6
        let barTrack = SKShapeNode(
            rect: CGRect(x: -barW / 2, y: -barH / 2, width: barW, height: barH),
            cornerRadius: barH / 2
        )
        barTrack.fillColor   = UIColor(white: 0.14, alpha: 1)
        barTrack.strokeColor = .clear
        barTrack.position    = CGPoint(x: 0, y: -panelH / 2 + 18)
        backdrop.addChild(barTrack)

        // Fill grows from left → right via xScale. Anchor at left edge so
        // scaling doesn't push it off-center.
        let barFill = SKShapeNode(
            rect: CGRect(x: 0, y: -barH / 2, width: barW, height: barH),
            cornerRadius: barH / 2
        )
        barFill.fillColor   = UIColor(red: 0.18, green: 0.55, blue: 1.0, alpha: 1)
        barFill.strokeColor = .clear
        barFill.position    = CGPoint(x: -barW / 2, y: -panelH / 2 + 18)
        barFill.xScale      = 0.001
        backdrop.addChild(barFill)

        let totalDuration: TimeInterval = 2.4
        let steps = Self.disembarkSteps
        let stepDur = totalDuration / TimeInterval(steps.count)

        // Schedule each prep note so the text and bar stay in sync.
        for (i, msg) in steps.enumerated() {
            let when = stepDur * TimeInterval(i)
            backdrop.run(.sequence([
                .wait(forDuration: when),
                .run { stepLbl.text = msg },
            ]))
        }

        let grow = SKAction.scaleX(to: 1.0, duration: totalDuration)
        grow.timingMode = .easeInEaseOut
        barFill.run(grow)

        // Hand off to the actual disembark once the bar fills.
        _ = hw  // (silence unused warning if compiler whinges)
        run(.sequence([
            .wait(forDuration: totalDuration),
            .run { [weak self] in self?.performDisembarkTransition() },
        ]))
    }

    private func performDisembarkTransition() {
        // Scene was pre-built and pre-warmed in `beginDisembarkSequence`.
        // `prepareScene()` inside didMove is a no-op when `isPrepared` is
        // already true, so this transition is essentially instant.
        guard let game = pendingGameScene else { return }
        game.scaleMode  = .resizeFill
        view?.presentScene(game, transition: .fade(withDuration: 0.25))
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
