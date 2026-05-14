import SpriteKit

final class GameScene: SKScene {

    // ── Mode ───────────────────────────────────────────────────────────────────
    private let mode: GameMode
    private var offlineSim: OfflineSim?
    private var lastSimTime: TimeInterval = 0
    private let simInterval: TimeInterval = 1.0 / 20.0   // match server tick rate

    // ── Camera & world layers ──────────────────────────────────────────────────
    private let cameraNode         = SKCameraNode()
    private let nebulaLayer        = SKNode()    // deepest, slowest
    private let farStarLayer       = SKNode()    // distant pinpoints
    private let midStarLayer       = SKNode()    // main starfield, varied
    private let nearStarLayer      = SKNode()    // foreground bright stars
    private let localObjectsLayer  = SKNode()    // planets/asteroids/suns/ships — moves with world

    // ── Game entities ──────────────────────────────────────────────────────────
    private var mySessionId:    String?
    private var shipNodes:      [String: ShipNode]    = [:]
    private var projectileNodes:[String: SKShapeNode] = [:]

    // ── Lean animation ─────────────────────────────────────────────────────────
    private var leanAmount: Float = 0

    // ── HUD ────────────────────────────────────────────────────────────────────
    private var joystick:        JoystickNode!
    private var fireButton:      SKShapeNode!
    private var joystickTouch:   UITouch?
    private var joystickAnchor:  CGPoint = .zero
    /// Current joystick deflection in camera-space coords. Stored so that
    /// `update(_:)` can re-evaluate turn flags every frame instead of only
    /// when the finger moves — UIKit doesn't fire `touchesMoved` when the
    /// finger is held still, so without this the input flags lock to
    /// whatever was set at the last move event and the ship sails right
    /// past its target heading.
    private var joystickOffset: CGPoint?
    private var fireTouch:       UITouch?
    private var shieldBar:       SKShapeNode!
    private var shieldFill:      SKShapeNode!
    private var hullBar:         SKShapeNode!
    private var hullFill:        SKShapeNode!
    private var fuelBar:         SKShapeNode!
    private var fuelFill:        SKShapeNode!
    private let hudBarWidth:     CGFloat = 140

    // ── Zoom ───────────────────────────────────────────────────────────────────
    private var isPinching = false
    private let zoomMin: CGFloat = 0.35
    private let zoomMax: CGFloat = 3.0

    // ── Solar system context ───────────────────────────────────────────────────
    private var solarSystem: SolarSystem?

    /// Live position of the system's primary sun — recomputed each access so
    /// it tracks the sun if it happens to orbit. Used to point the ship's
    /// lighting/shadow shader at the actual star.
    private var primarySunPosition: CGPoint {
        solarSystem?.primarySunPosition ?? .zero
    }

    // ── Selection / tooltip / mini-map ─────────────────────────────────────────
    private var miniMap:        MiniMap!
    private var infoTooltip:    InfoTooltip!
    private weak var selectedBody: CelestialBodyNode?

    // ── Docking state ──────────────────────────────────────────────────────────
    /// True while the dock animation is playing. While set, snapshots aren't
    /// applied to the local player, the offline sim is paused, and all touch
    /// input is ignored so the animation can't be interrupted.
    private var isDocking = false

    /// True while the disembark "rise" animation is playing — set in
    /// `didMove` if `disembarkFrom` is provided and cleared by the animation
    /// completion handler. Mirrors `isDocking`'s gating: skip local-player
    /// snapshot updates so the animation owns the ship's position.
    private var isDisembarking = false

    /// Tuned thresholds for the "close + slow" dock gate.
    private let dockProximityMultiplier: CGFloat = 1.6   // ≤ 1.6 × planet radius
    private let dockMaxSpeed:            CGFloat = 55    // world units per second

    // MARK: – Init

    /// `spawnAt` is consulted in single-player mode as the offline sim's
    /// starting position — `PlanetScene` passes a point just outside the
    /// docked planet so the ship drifts back into open space on disembark.
    /// Nil (the default) preserves the random spawn used on first launch.
    private let spawnAt: CGPoint?

    /// World position the docking animation should "rise" out of (typically
    /// the planet's center). Non-nil → on first spawn the local ship is
    /// placed here at scale 0, then animated to its sim position.
    private let disembarkFrom: CGPoint?

    /// Star-system JSON to load. Defaults to the player's last known
    /// system — set on Load Game and updated whenever the player jumps.
    private let systemName: String

    init(size: CGSize,
         mode: GameMode,
         systemName: String? = nil,
         spawnAt: CGPoint? = nil,
         disembarkFrom: CGPoint? = nil) {
        self.mode          = mode
        self.systemName    = systemName ?? PlayerProfile.shared.currentSystem
        self.spawnAt       = spawnAt
        self.disembarkFrom = disembarkFrom
        super.init(size: size)
    }
    required init?(coder aDecoder: NSCoder) { fatalError() }

    // MARK: – Lifecycle

    /// Set true once the heavy `setup*` calls have run. Lets `prepareScene*`
    /// and `didMove` be invoked in either order without double-building.
    private var isPrepared = false

    /// Synchronously builds every scene element except view-bound gestures.
    /// Safe to call before the scene is presented — `addChild` doesn't
    /// require a parent view.
    func prepareScene() {
        guard !isPrepared else { return }
        isPrepared = true
        backgroundColor = .black
        setupCamera()
        setupStarField()
        setupBoundary()
        setupSolarSystem()
        setupHUD()
    }

    /// Same heavy build as `prepareScene` but split across main-queue async
    /// dispatches so the calling scene's UI (e.g. the disembark loading
    /// bar) keeps animating between chunks instead of stalling for the
    /// whole prep duration.
    func prepareSceneAsync(completion: @escaping () -> Void) {
        guard !isPrepared else { completion(); return }
        isPrepared = true
        // Steps are ordered: each depends on the camera/scene layers set up
        // by earlier ones. Starfield is the heaviest by far so it gets its
        // own slot.
        let steps: [() -> Void] = [
            { [weak self] in self?.backgroundColor = .black; self?.setupCamera() },
            { [weak self] in self?.setupStarField() },
            { [weak self] in self?.setupBoundary(); self?.setupSolarSystem() },
            { [weak self] in self?.setupHUD() },
        ]
        var i = 0
        func next() {
            guard i < steps.count else { completion(); return }
            steps[i]()
            i += 1
            DispatchQueue.main.async { next() }
        }
        DispatchQueue.main.async { next() }
    }

    override func didMove(to view: SKView) {
        prepareScene()                  // no-op if pre-warmed by the caller
        setupGestures(in: view)

        // Pre-position the camera so the brief gap before the first snapshot
        // doesn't show a flash of (0,0) world space.
        if let from = disembarkFrom {
            cameraNode.position = from
            isDisembarking      = true
        }

        switch mode {
        case .singlePlayer:
            offlineSim   = OfflineSim(spawnAt: spawnAt)
            mySessionId  = offlineSim?.sessionId
        case .multiplayer:
            NetworkManager.shared.delegate = self
            NetworkManager.shared.connect()
        }
    }

    override func willMove(from view: SKView) {
        view.gestureRecognizers?.removeAll()
        if mode == .multiplayer {
            NetworkManager.shared.disconnect()
        }
    }

    // MARK: – Gestures

    private func setupGestures(in view: SKView) {
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.cancelsTouchesInView = false
        view.addGestureRecognizer(pinch)
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            isPinching = true
        case .changed:
            // Each .changed event reports the cumulative scale; reset to 1 so
            // every event is a delta we can apply incrementally.
            let factor = g.scale
            let proposed = cameraNode.xScale / factor
            let clamped  = min(zoomMax, max(zoomMin, proposed))
            cameraNode.setScale(clamped)
            g.scale = 1.0
        case .ended, .cancelled, .failed:
            isPinching = false
        default:
            break
        }
    }

    // MARK: – Setup

    private func setupCamera() {
        addChild(cameraNode)
        camera = cameraNode
    }

    private func setupStarField() {
        // Z-stack from back (deepest) to front (closest). Stars are behind
        // everything, then nebula clouds (treated as foreground gas you fly
        // through), then localObjects (planets/asteroids/ships).
        farStarLayer.zPosition      = -100   // deepest
        midStarLayer.zPosition      =  -90
        nearStarLayer.zPosition     =  -80
        nebulaLayer.zPosition       =  -30   // clouds in front of stars
        localObjectsLayer.zPosition =  -20

        addChild(nebulaLayer)
        addChild(farStarLayer)
        addChild(midStarLayer)
        addChild(nearStarLayer)
        addChild(localObjectsLayer)

        // Far field — scattered pinpricks. With parallax factor 0.92 this
        // layer follows the camera at 92%, so the visible local-coords window
        // is small (≈ ±1800) regardless of where the player is. A tight spread
        // gives high visible density with few total nodes.
        scatter(farStarLayer, count: 2000, spread: 1000,
                scaleRange: 0.05...0.27,
                alphaRange: 0.42...0.55,
                variants:   [.pinprick, .mediumWhite, .pinprick, .pinprick,
                             .pinprick, .pinprick, .pinprick, .pinprick,
                             .pinprick, .pinprick, .pinprick, .pinprick,
                             .pinprick, .pinprick, .yellowSun, .pinprick,
                             .dimWhite, .pinprick, .pinprick, .redGiant])

        // Mid field — sprite-node pinpricks plus a sprinkle of bloom stars
        // and the occasional warm tinted giant for color variety.
        scatter(midStarLayer, count: 2000, spread: 3000,
                scaleRange: 0.24...0.42,
                alphaRange: 0.42...0.95,
                variants:   [.pinprick, .pinprick, .pinprick, .pinprick,
                             .pinprick, .pinprick, .pinprick, .pinprick,
                             .pinprick, .pinprick, .pinprick, .pinprick,
                             .pinprick, .pinprick, .pinprick, .pinprick,
                             .dimWhite, .mediumWhite, .yellowSun, .redGiant,
                             .dimWhite, .mediumWhite, .yellowSun, .redGiant, .brightWhite])

        // Near field — hero stars with bloom and diffraction spikes. Sparse
        // by design; these are accent lights, not background.
        scatter(nearStarLayer, count: 2000, spread: 6000,
                scaleRange: 0.40...0.50,
                alphaRange: 0.75...0.80,
                variants:   [.pinprick, .pinprick, .pinprick, .pinprick,
                             .pinprick, .pinprick, .pinprick, .pinprick,
                             .pinprick, .pinprick, .pinprick, .pinprick,
                             .pinprick, .pinprick, .pinprick, .pinprick,
                             .dimWhite, .mediumWhite, .yellowSun, .redGiant,
                             .mediumWhite, .brightWhite, .blueGiant, .yellowSun, .redGiant])

        scatterNebulae()
    }

    /// Bake the far starfield into a small set of tile textures and stamp them
    /// in a grid covering the play area + parallax buffer. Each tile contains
    /// thousands of pinpricks, so the effective star count is
    /// `tilesPerSide² × starsPerTile` while the live node count is just
    /// `tilesPerSide²`.
    private func tileFarStarfield(tilesPerSide: Int,
                                  tileWorldSize: CGFloat,
                                  starsPerTile: Int) {
        let palette: [UIColor] = [
            .white,
            UIColor(white: 0.92, alpha: 1),
            UIColor(red: 0.92, green: 0.95, blue: 1.0, alpha: 1),
            UIColor(red: 1.0,  green: 0.95, blue: 0.85, alpha: 1),
        ]
        // Pre-render a few unique tiles so the same pattern doesn't repeat
        // every neighbour. Random rotation on each placement breaks repetition
        // further.
        let tileVariants = (0..<6).map { _ in
            StarField.makeFieldTexture(canvasSize: 1024,
                                       starCount:  starsPerTile,
                                       palette:    palette)
        }
        let half = (CGFloat(tilesPerSide) - 1) * 0.5
        for i in 0..<tilesPerSide {
            for j in 0..<tilesPerSide {
                guard let texture = tileVariants.randomElement() else { continue }
                let sprite       = SKSpriteNode(texture: texture)
                sprite.size      = CGSize(width: tileWorldSize, height: tileWorldSize)
                sprite.position  = CGPoint(
                    x: (CGFloat(i) - half) * tileWorldSize,
                    y: (CGFloat(j) - half) * tileWorldSize
                )
                sprite.blendMode = .add
                sprite.zRotation = CGFloat.random(in: 0...(2 * .pi))
                farStarLayer.addChild(sprite)
            }
        }
    }

    private func scatter(_ layer: SKNode, count: Int, spread: CGFloat,
                         scaleRange: ClosedRange<CGFloat>,
                         alphaRange: ClosedRange<CGFloat>,
                         variants:   [StarVariant]) {
        let atlas = StarAtlas.shared
        for _ in 0..<count {
            guard let variant = variants.randomElement(),
                  let texture = atlas.textures[variant] else { continue }
            let star            = SKSpriteNode(texture: texture)
            star.setScale(CGFloat.random(in: scaleRange))
            star.alpha          = CGFloat.random(in: alphaRange)
            star.position       = CGPoint(x: CGFloat.random(in: -spread...spread),
                                          y: CGFloat.random(in: -spread...spread))
            // Additive blending makes overlapping stars sum to brighter, which
            // is how a real-camera starfield reads.
            star.blendMode      = .add
            layer.addChild(star)

            // Twinkle a fraction of stars so the field doesn't read as static.
            if Int.random(in: 0...8) == 0 {
                let baseAlpha = star.alpha
                let dim    = SKAction.fadeAlpha(to: baseAlpha * 0.5,
                                                duration: Double.random(in: 1.4...3.2))
                let bright = SKAction.fadeAlpha(to: baseAlpha,
                                                duration: Double.random(in: 1.4...3.2))
                dim.timingMode    = .easeInEaseOut
                bright.timingMode = .easeInEaseOut
                star.run(.repeatForever(.sequence([dim, bright])))
            }
        }
    }

    private func scatterNebulae() {
        let atlas = NebulaAtlas.shared
        // Each "cloud" is composed of many small overlapping puff sprites.
        // The puffs are individually irregular; scattered together with a
        // Gaussian-ish offset, the composite has no detectable outline.
        let cloudCount = 10
        for _ in 0..<cloudCount {
            let tint = NebulaTint.allCases.randomElement()!
            let cx   = CGFloat.random(in: -10000...10000)
            let cy   = CGFloat.random(in: -10000...10000)
            let cloudRadius: CGFloat = CGFloat.random(in: 2000...4500)
            let puffCount = Int.random(in: 18...32)

            for _ in 0..<puffCount {
                guard let texture = atlas.textures[tint]?.randomElement() else { continue }

                // Approximate 2D Gaussian via sum of two uniform random offsets —
                // produces a triangular distribution that's peaked at the center
                // and tapers off. Puffs near the cloud center overlap densely;
                // puffs near the edge are sparse and form the wispy outline.
                let dxNorm = (CGFloat.random(in: -1...1) + CGFloat.random(in: -1...1)) * 0.5
                let dyNorm = (CGFloat.random(in: -1...1) + CGFloat.random(in: -1...1)) * 0.5
                let px = cx + dxNorm * cloudRadius * 1.4
                let py = cy + dyNorm * cloudRadius * 1.4

                let puff = SKSpriteNode(texture: texture)
                let puffSize = CGFloat.random(in: 900...2200)
                puff.size      = CGSize(width: puffSize, height: puffSize)
                puff.alpha     = CGFloat.random(in: 0.12...0.32)
                puff.blendMode = .add
                puff.zRotation = CGFloat.random(in: 0...(2 * .pi))
                puff.position  = CGPoint(x: px, y: py)
                nebulaLayer.addChild(puff)
            }
        }
    }

    private func setupBoundary() {
        let ring         = SKShapeNode(circleOfRadius: 5000)
        ring.strokeColor = UIColor(white: 1, alpha: 0.07)
        ring.fillColor   = .clear
        ring.lineWidth   = 3
        addChild(ring)
    }

    private func setupSolarSystem() {
        // The system config (which planets, suns, asteroids) lives in JSON.
        // Which file we load is driven by the player's current system,
        // which the save profile / Load Game pipeline keeps current.
        guard let system = SolarSystem(name: systemName) else { return }
        system.install(into: localObjectsLayer)
        solarSystem = system

        // Seed the mini-map with the static body positions. Dynamic ship
        // positions are pushed in every frame.
        miniMap?.configure(suns:    system.sunPositions,
                           planets: system.planetPositions)
    }

    private func setupHUD() {
        let hw = size.width  / 2
        let hh = size.height / 2

        joystick          = JoystickNode()
        joystick.position = CGPoint(x: -hw + 110, y: -hh + 110)
        joystick.alpha    = 0.75
        cameraNode.addChild(joystick)

        fireButton             = SKShapeNode(circleOfRadius: 38)
        fireButton.fillColor   = UIColor(red: 1, green: 0.2, blue: 0.15, alpha: 0.38)
        fireButton.strokeColor = UIColor(red: 1, green: 0.45, blue: 0.4,  alpha: 0.70)
        fireButton.lineWidth   = 1.5
        fireButton.position    = CGPoint(x: hw - 90, y: -hh + 90)

        let fireLabel              = SKLabelNode(text: "FIRE")
        fireLabel.fontName         = "AvenirNext-Bold"
        fireLabel.fontSize         = 11
        fireLabel.fontColor        = .white
        fireLabel.verticalAlignmentMode = .center
        fireButton.addChild(fireLabel)
        cameraNode.addChild(fireButton)

        buildStatusReadout(topRight: CGPoint(x: hw - 18, y: hh - 24))

        // Mini-map under the health bars, top-right corner.
        miniMap = MiniMap(radius: 62)
        // Drop the mini-map further below the readout panel — it has three
        // bars now (shield / hull / fuel) instead of two, so we need ~18 pt
        // more vertical clearance.
        miniMap.position = CGPoint(x: hw - 18 - miniMap.radius,
                                   y: hh - 24 - 50 - miniMap.radius)
        cameraNode.addChild(miniMap)
        if let system = solarSystem {
            miniMap.configure(suns:    system.sunPositions,
                              planets: system.planetPositions)
        }

        // Info tooltip in the top-left corner. Hidden until something is
        // selected.
        infoTooltip              = InfoTooltip()
        infoTooltip.position     = CGPoint(x: -hw + 16, y: hh - 16)
        infoTooltip.onDockTapped = { [weak self] in self?.beginDocking() }
        cameraNode.addChild(infoTooltip)
    }

    private func buildStatusReadout(topRight: CGPoint) {
        // Container so positions are local — top-right alignment
        let panel       = SKNode()
        panel.position  = topRight
        cameraNode.addChild(panel)

        func key(_ text: String, y: CGFloat) -> SKLabelNode {
            let l                       = SKLabelNode(text: text)
            l.fontName                  = "AvenirNext-Medium"
            l.fontSize                  = 10
            l.fontColor                 = UIColor(white: 0.7, alpha: 1)
            l.horizontalAlignmentMode   = .right
            l.verticalAlignmentMode     = .center
            l.position                  = CGPoint(x: -hudBarWidth - 8, y: y)
            return l
        }

        func barTrack(y: CGFloat) -> SKShapeNode {
            let track         = SKShapeNode(rect: CGRect(x: -hudBarWidth, y: y - 4,
                                                         width: hudBarWidth, height: 8),
                                            cornerRadius: 2)
            track.fillColor   = UIColor(white: 1, alpha: 0.08)
            track.strokeColor = UIColor(white: 1, alpha: 0.25)
            track.lineWidth   = 1
            return track
        }

        // Helper to spin up one of the three resource rows (track + fill +
        // key label). The fill is wrapped in a container so `xScale` shrinks
        // it from the right (track edge) instead of the centre.
        func makeRow(y: CGFloat, color: UIColor, label: String) -> (track: SKShapeNode, fill: SKShapeNode) {
            panel.addChild(key(label, y: y))
            let track = barTrack(y: y)
            panel.addChild(track)

            let container       = SKNode()
            container.position  = CGPoint(x: -hudBarWidth, y: y)
            let fill            = SKShapeNode(
                rect: CGRect(x: 0, y: -3, width: hudBarWidth, height: 6),
                cornerRadius: 1.5
            )
            fill.fillColor      = color
            fill.strokeColor    = .clear
            container.addChild(fill)
            panel.addChild(container)
            return (track, fill)
        }

        // Resolve the player's max values from the loaded ship definition so
        // the key labels read "SHIELDS 2200" / "HULL 500" / "FUEL 400" for
        // the current ship. Defaults match the 0-100 placeholders if the
        // JSON didn't load.
        let def       = PlayerProfile.shared.currentShipDef
        let maxShield = Int(def?.attributes.shields      ?? 100)
        let maxHull   = Int(def?.attributes.hull         ?? 100)
        let maxFuel   = Int(def?.attributes.fuelCapacity ?? 100)

        let shieldRow = makeRow(y:   0, color: UIColor(red: 0.30, green: 0.65, blue: 1.00, alpha: 0.95),
                                label: "SHIELDS \(maxShield)")
        shieldBar = shieldRow.track
        shieldFill = shieldRow.fill

        let hullRow = makeRow(y: -18, color: UIColor(red: 1.00, green: 0.30, blue: 0.30, alpha: 0.95),
                              label: "HULL \(maxHull)")
        hullBar = hullRow.track
        hullFill = hullRow.fill

        // Fuel row — amber, sits directly under hull. Fuel doesn't deplete
        // yet (no consumption mechanics); the bar is initialised at 100%
        // and `setStatus` accepts a fuel percent for future use.
        let fuelRow = makeRow(y: -36, color: UIColor(red: 1.00, green: 0.65, blue: 0.20, alpha: 0.95),
                              label: "FUEL \(maxFuel)")
        fuelBar = fuelRow.track
        fuelFill = fuelRow.fill
    }

    private func setStatus(shieldsPct: CGFloat, hullPct: CGFloat, fuelPct: CGFloat = 1.0) {
        shieldFill?.xScale = max(0.001, min(1, shieldsPct))
        hullFill?.xScale   = max(0.001, min(1, hullPct))
        fuelFill?.xScale   = max(0.001, min(1, fuelPct))
    }

    // MARK: – Game loop

    override func update(_ currentTime: TimeInterval) {
        // Lean smoothing
        let i = mode == .multiplayer ? NetworkManager.shared.input : localInput
        let target: Float = i.turnLeft ? -1 : (i.turnRight ? 1 : 0)
        leanAmount += (target - leanAmount) * 0.12
        if let sid = mySessionId { shipNodes[sid]?.applyLean(leanAmount) }

        // Re-apply joystick → input mapping every frame so the turn flags
        // stay live as the ship rotates toward target, even when the finger
        // is held still (no further `touchesMoved` events).
        applyJoystickInput()

        // Offline sim drives the same delegate path as the network. Pause
        // while docking so the player's ship doesn't drift mid-animation.
        if mode == .singlePlayer, !isDocking, let sim = offlineSim {
            if currentTime - lastSimTime >= simInterval {
                lastSimTime = currentTime
                let snap = sim.step(input: localInput)
                applySnapshot(snap, mySessionId: sim.sessionId)
            }
        }

        // Parallax — `layer.position = cam.position * factor`. A layer with
        // factor = 1 moves perfectly with the camera and therefore appears
        // STATIONARY on screen (= infinitely far). A layer with factor = 0
        // is anchored to world coordinates and drifts past at full speed
        // (= closest). So far stars get a factor near 1, the closer-feeling
        // nebula gets a small factor, and `localObjectsLayer` (factor 0,
        // unmoved) is the actual playfield.
        // Orbital motion of suns/planets — driven by absolute wall-clock so
        // every client computes the same positions regardless of when they
        // joined. Pure function, so cheap to call every frame even with
        // many bodies.
        solarSystem?.tick(at: Date().timeIntervalSince1970)

        // Camera follows the local ship NODE rather than the latest snapshot
        // position. The node's position is what's actually animated during
        // dock (shrink-into-planet) and disembark (rise-from-planet), so
        // tracking it keeps the camera locked to the visible ship through
        // both transitions.
        if let sid = mySessionId, let node = shipNodes[sid] {
            cameraNode.position = node.position
        }

        let cx = cameraNode.position.x
        let cy = cameraNode.position.y
        nebulaLayer.position   = CGPoint(x: cx * 0.15, y: cy * 0.15)
        nearStarLayer.position = CGPoint(x: cx * 0.70, y: cy * 0.70)
        midStarLayer.position  = CGPoint(x: cx * 0.80, y: cy * 0.80)
        farStarLayer.position  = CGPoint(x: cx * 0.92, y: cy * 0.92)

        refreshHUD()
    }

    // MARK: – HUD updates

    private func refreshHUD() {
        // Mini-map relative to the local player ship.
        guard let sid       = mySessionId,
              let playerNode = shipNodes[sid],
              let system    = solarSystem
        else { return }

        let playerPos     = playerNode.position
        let playerHeading = playerNode.heading

        // Build the list of OTHER ships (exclude the local player — they sit
        // at the radar's centre by definition).
        let otherShips: [(id: String, position: CGPoint)] =
            shipNodes
                .filter { $0.key != sid }
                .map { ($0.key, $0.value.position) }

        miniMap.update(playerPosition: playerPos,
                       playerHeading:  playerHeading,
                       suns:           system.sunPositions,
                       planets:        system.planetPositions,
                       ships:          otherShips)

        // Keep the tooltip's distance value in sync as the player flies, and
        // gate the Dock button on the close-and-slow conditions.
        if let body = selectedBody {
            let dx       = body.position.x - playerPos.x
            let dy       = body.position.y - playerPos.y
            let distance = hypot(dx, dy)
            infoTooltip.updateDistance(distance, for: body)

            if body.kind == .planet {
                let isClose = distance <= body.bodyRadius * dockProximityMultiplier
                let isSlow  = playerNode.velocityMagnitude <= dockMaxSpeed
                infoTooltip.setDockable(isClose && isSlow)
            }
        }
    }

    // MARK: – Input routing

    /// Offline mode reads from the same InputState struct as online for code reuse.
    private var localInput = InputState()

    // MARK: – Touch

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !isPinching, !isDocking else { return }
        for touch in touches {
            // Dock button (in the tooltip) wins over selection and joystick.
            if infoTooltip.handleTouch(touch) {
                continue
            }

            // Tap-to-select takes priority. If the touch lands on a selectable
            // body, consume the touch — don't route it to the joystick or fire
            // button.
            let scenePoint = touch.location(in: self)
            if let body = selectableBody(at: scenePoint) {
                selectBody(body)
                continue
            }

            let p = touch.location(in: cameraNode)
            if p.x < 0, joystickTouch == nil {
                joystickTouch  = touch
                joystickAnchor = p
                joystick.position = p
                joystick.reset()
                joystickOffset = .zero
            } else if p.x >= 0, fireTouch == nil {
                fireTouch = touch
                setInput { $0.firing = true }
                fireButton.fillColor = UIColor(red: 1, green: 0.45, blue: 0.2, alpha: 0.65)
            }
        }
    }

    // MARK: – Selection

    /// Distance-based hit test against every selectable celestial body. Touch
    /// is in scene coordinates, which match world coordinates because the
    /// camera is the scene's `camera`. The local-objects layer is unparented
    /// from any parallax offset, so a body's `position` IS its world position.
    private func selectableBody(at scenePoint: CGPoint) -> CelestialBodyNode? {
        guard let bodies = solarSystem?.bodies else { return nil }
        var best: (body: CelestialBodyNode, dist: CGFloat)?
        for body in bodies where body.isSelectable {
            let dx = scenePoint.x - body.position.x
            let dy = scenePoint.y - body.position.y
            let dist = hypot(dx, dy)
            // Generous hit radius so tiny asteroids are still tappable.
            let hitRadius = max(body.bodyRadius, 28)
            guard dist <= hitRadius else { continue }
            if best == nil || dist < best!.dist {
                best = (body, dist)
            }
        }
        return best?.body
    }

    // MARK: – Docking

    /// Fired by `InfoTooltip` when its active Dock button is tapped. Runs the
    /// shrink-into-planet animation on the local player ship and then hands
    /// off to `PlanetScene` once the ship has visually disappeared.
    private func beginDocking() {
        guard !isDocking,
              let body = selectedBody, body.kind == .planet,
              let sid = mySessionId, let ship = shipNodes[sid]
        else { return }

        isDocking = true

        // Capture the planet info up front — by the time the animation
        // finishes, the selection might have been cleared or the node
        // removed by other game logic.
        let info = DockedPlanetInfo(
            bodyID:          body.id,
            displayName:    body.displayName,
            typeDescription: body.typeDescription,
            spriteName:      body.spriteName,
            radius:          body.bodyRadius,
            worldPosition:   body.position,
            services:        body.services
        )

        let shrink   = SKAction.group([
            .move(to: body.position, duration: 0.8),
            .scale(to: 0.05,          duration: 0.8),
            .fadeOut(withDuration:    0.8),
        ])
        shrink.timingMode = .easeIn

        let proceed = SKAction.run { [weak self] in
            self?.presentPlanetScene(info: info)
        }
        ship.run(.sequence([shrink, proceed]))
    }

    private func presentPlanetScene(info: DockedPlanetInfo) {
        let scene       = PlanetScene(size: size, info: info, gameMode: mode)
        scene.scaleMode = .resizeFill
        view?.presentScene(scene, transition: .fade(withDuration: 0.5))
    }

    /// "Take-off" animation when the player disembarks from a planet. The
    /// node has just been positioned by the first snapshot at its
    /// sim-spawn coordinates; we override to the planet center at scale 0,
    /// then animate back to where the snapshot put it. The completion
    /// closure clears `isDisembarking` so subsequent snapshots resume
    /// driving the ship's position normally.
    private func playDisembarkRise(node: ShipNode, from: CGPoint) {
        let targetPos = node.position
        node.position = from
        node.setScale(0.05)
        node.alpha    = 0

        let rise = SKAction.group([
            .move(to: targetPos, duration: 0.9),
            .scale(to: 1.0,       duration: 0.9),
            .fadeIn(withDuration: 0.9),
        ])
        rise.timingMode = .easeOut

        let clear = SKAction.run { [weak self] in
            self?.isDisembarking = false
        }
        node.run(.sequence([rise, clear]))
    }

    private func selectBody(_ body: CelestialBodyNode) {
        // Tapping the same body again deselects, otherwise switch selection.
        if selectedBody === body {
            selectedBody?.setSelected(false)
            selectedBody = nil
            infoTooltip.hide()
            return
        }
        selectedBody?.setSelected(false)
        body.setSelected(true)
        selectedBody = body

        let distance: CGFloat
        if let sid = mySessionId, let player = shipNodes[sid] {
            distance = hypot(body.position.x - player.position.x,
                             body.position.y - player.position.y)
        } else {
            distance = 0
        }
        infoTooltip.show(body: body, distance: distance)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches where touch === joystickTouch {
            let p      = touch.location(in: cameraNode)
            let offset = CGPoint(x: p.x - joystickAnchor.x, y: p.y - joystickAnchor.y)
            joystick.setThumb(offset: offset)
            joystickOffset = offset
            applyJoystickInput()
        }
    }

    /// Translates the stored joystick deflection into turn/thrust flags.
    /// Called from `touchesMoved` AND from `update(_:)` every frame so the
    /// ship keeps re-aiming even when the finger is held still — otherwise
    /// the last move event's flags persist past the target heading and the
    /// ship oscillates instead of settling.
    private func applyJoystickInput() {
        guard let offset = joystickOffset else { return }
        let dead: CGFloat = 12
        let mag           = hypot(offset.x, offset.y)
        guard mag > dead else {
            setInput {
                $0.thrust    = false
                $0.turnLeft  = false
                $0.turnRight = false
            }
            return
        }

        // Joystick controls FACING: deflect in any direction → rotate to point
        // that way and thrust forward. `atan2(sin, cos)` gives the signed
        // shortest difference in (−π, π] without while-loop normalization,
        // and is stable at exactly ±π where naive subtraction flip-flops.
        let targetAngle = atan2(offset.y, offset.x)
        let current     = currentPlayerHeading()
        let rawDiff     = targetAngle - current
        let diff        = atan2(sin(rawDiff), cos(rawDiff))

        // Dead zone slightly larger than one tick's turn step so the ship
        // settles cleanly instead of micro-correcting around the target.
        let angleDead: CGFloat = 0.10
        setInput {
            $0.thrust    = true                    // any deflection = forward
            $0.turnRight = diff >  angleDead       // server: turnRight increments angle (CCW)
            $0.turnLeft  = diff < -angleDead       // server: turnLeft decrements angle (CW)
        }
    }

    private func currentPlayerHeading() -> CGFloat {
        guard let sid = mySessionId, let ship = shipNodes[sid] else { return 0 }
        return ship.heading
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        endTouches(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        endTouches(touches)
    }

    private func endTouches(_ touches: Set<UITouch>) {
        for touch in touches {
            if touch === joystickTouch {
                joystickTouch  = nil
                joystickOffset = nil
                joystick.reset()
                setInput {
                    $0.thrust    = false
                    $0.turnLeft  = false
                    $0.turnRight = false
                }
            }
            if touch === fireTouch {
                fireTouch = nil
                setInput { $0.firing = false }
                fireButton.fillColor = UIColor(red: 1, green: 0.2, blue: 0.15, alpha: 0.38)
            }
        }
    }

    private func setInput(_ mutate: (inout InputState) -> Void) {
        switch mode {
        case .multiplayer:  mutate(&NetworkManager.shared.input)
        case .singlePlayer: mutate(&localInput)
        }
    }

    // MARK: – Snapshot application (shared between online and offline)

    private func applySnapshot(_ snapshot: GameSnapshot, mySessionId: String) {
        // Ships
        let activeShips = Set(snapshot.ships.keys)

        for (id, data) in snapshot.ships {
            // While the local player's ship is mid-dock-animation, its
            // position/scale/alpha are owned by the SKAction. Skipping
            // the snapshot prevents the simulator from yanking it back
            // to its sim-tracked world position.
            if isDocking, id == mySessionId { continue }

            if let node = shipNodes[id] {
                // Same gate during the disembark rise — the animation owns
                // the local ship's transform until it completes.
                if isDisembarking, id == mySessionId { continue }
                node.update(from: data, sunPosition: primarySunPosition)
            } else {
                let node = ShipNode(isLocalPlayer: id == mySessionId)
                addChild(node)
                shipNodes[id] = node
                node.update(from: data, sunPosition: primarySunPosition)

                // First appearance for the local player while disembarking:
                // override the sim's position with the planet center, then
                // animate back to it. The animation completion clears the
                // `isDisembarking` flag.
                if isDisembarking, id == mySessionId, let from = disembarkFrom {
                    playDisembarkRise(node: node, from: from)
                }
            }
        }
        for id in shipNodes.keys where !activeShips.contains(id) {
            shipNodes.removeValue(forKey: id)?.removeFromParent()
        }

        // Status bars come from the snapshot. Camera-follow is driven by the
        // ship node directly in `update(_:)` so it tracks dock/disembark
        // animations smoothly.
        if let s = snapshot.ships[mySessionId] {
            setStatus(shieldsPct: CGFloat(s.shields) / 100,
                      hullPct:    CGFloat(s.hull)    / 100)
        }

        // Projectiles
        let activeProjs = Set(snapshot.projectiles.keys)
        for (id, data) in snapshot.projectiles {
            if let node = projectileNodes[id] {
                node.position = CGPoint(x: CGFloat(data.x), y: CGFloat(data.y))
            } else {
                let node      = makeProjectile(isOwn: data.ownerId == mySessionId)
                node.position = CGPoint(x: CGFloat(data.x), y: CGFloat(data.y))
                addChild(node)
                projectileNodes[id] = node
            }
        }
        for id in projectileNodes.keys where !activeProjs.contains(id) {
            projectileNodes.removeValue(forKey: id)?.removeFromParent()
        }
    }

    // MARK: – Helpers

    private func makeProjectile(isOwn: Bool) -> SKShapeNode {
        let node         = SKShapeNode(rectOf: CGSize(width: 5, height: 12), cornerRadius: 2)
        node.fillColor   = isOwn ? .yellow : UIColor(red: 1, green: 0.4, blue: 0.4, alpha: 1)
        node.strokeColor = .clear
        node.glowWidth   = 8
        return node
    }
}

// MARK: – NetworkManagerDelegate

extension GameScene: NetworkManagerDelegate {

    func didConnect(mySessionId: String) {
        self.mySessionId = mySessionId
    }

    func didReceiveSnapshot(_ snapshot: GameSnapshot, mySessionId: String) {
        applySnapshot(snapshot, mySessionId: mySessionId)
    }

    func didShipDestroyed(sessionId: String, killedBy: String) {
        guard let node = shipNodes[sessionId] else { return }
        let flash = SKAction.sequence([
            .fadeAlpha(to: 1.0, duration: 0),
            .fadeAlpha(to: 0.0, duration: 0.15),
        ])
        node.run(flash)
    }

    func didShipRespawned(sessionId: String) {
        shipNodes[sessionId]?.alpha = 1
    }

    func didPlayerLeft(sessionId: String) {
        shipNodes.removeValue(forKey: sessionId)?.removeFromParent()
    }

    func didDisconnect() {
        print("Server disconnected")
    }
}
