import SpriteKit

final class GameScene: SKScene, SKPhysicsContactDelegate {

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
    private var projectileNodes:[String: ProjectileNode] = [:]

    /// Position + velocity of the local ship at the moment of the last
    /// snapshot. Used to extrapolate per-frame in `update(_:)` so the
    /// camera (and therefore everything camera-relative, like planets) moves
    /// at 60 Hz instead of jumping every 50 ms with the sim tick rate —
    /// otherwise planets visibly jitter when the player follows them.
    private var localBaselinePos:  CGPoint = .zero
    private var localBaselineVel:  CGVector = .zero
    private var localBaselineTime: TimeInterval = 0

    /// One slot per installed beam-weapon instance. Each tracks its own
    /// world-space aim angle so multiple turrets can converge on the same
    /// target at the configured `turretTurn` rate. Slots are recycled
    /// frame-to-frame; the array shrinks/grows when outfits change.
    private struct TurretSlot {
        var aimAngle: CGFloat       // current world-space angle in radians
        let beam:     BeamNode
        let impact:   SKNode
    }
    private var turretSlots: [TurretSlot] = []
    private var lastBeamUpdateTime: TimeInterval = 0

    /// Soft cloud texture used for every beam impact puff. Generated once,
    /// cached. Far smoother than a hard-edged `SKShapeNode` circle.
    private lazy var impactCloudTexture: SKTexture = Self.makeCloudTexture(
        coreColor: .white,
        glowColor: UIColor(red: 0.55, green: 0.95, blue: 1.0, alpha: 1)
    )

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
    private var energyBar:       SKShapeNode!
    private var energyFill:      SKShapeNode!
    private var heatBar:         SKShapeNode!
    private var heatFill:        SKShapeNode!
    // Per-row labels rewritten by `setStatus` so the numbers track the
    // ship's current state (not the max value baked in at scene start).
    private var shieldLabel:     SKLabelNode!
    private var hullLabel:       SKLabelNode!
    private var fuelLabel:       SKLabelNode!
    private var energyLabel:     SKLabelNode!
    private var heatLabel:       SKLabelNode!
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
        setupPhysics()
        setupCamera()
        setupStarField()
        setupBoundary()
        setupSolarSystem()
        setupHUD()
    }

    private func setupPhysics() {
        // Zero gravity — we use the physics engine for contact callbacks
        // only. The sim owns ship/projectile motion.
        physicsWorld.gravity         = .zero
        physicsWorld.contactDelegate = self
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
            let sim         = OfflineSim(spawnAt: spawnAt)
            // Seed the sim with the active hull's energy/heat profile.
            // Outfit contributions to capacity/recharge will live here when
            // the registry grows those fields — currently only the ship
            // JSON drives the values.
            let def         = PlayerProfile.shared.currentShipDef
            // Aggregate every per-outfit contribution that the ship cares
            // about. Each outfit's `count` multiplies its stat (two Plasma
            // Cores → +2000 energy capacity, +20 recharge, etc.).
            var maxEnergy     = Float(def?.attributes.energyCapacity ?? 100)
            var energyReg     = Float(def?.attributes.energyRecharge ?? 1)
            var maxShields    = Float(def?.attributes.shields        ?? 100)
            var shieldReg:    Float = 0       // ship base shield regen not yet in JSON
            var totalThrust:  Float = 0
            var totalTurn:    Float = 0
            var outfitMass:   Float = 0
            var thrustDrain:  Float = 0
            var thrustHeat:   Float = 0
            var turnDrain:    Float = 0
            var turnHeat:     Float = 0
            var passiveDrain: Float = 0
            var passiveHeat:  Float = 0
            // Capacity-style contributions (energy pool, shield pool,
            // heat output, mass) scale with every installed copy, even
            // those sitting in inventory.
            for (id, count) in PlayerProfile.shared.installedOutfits {
                guard let o = OutfitRegistry.shared.outfit(id: id) else { continue }
                let n = Float(count)
                maxEnergy    += Float(o.energyCapacity    ?? 0) * n
                energyReg    += Float(o.energyRecharge    ?? 0) * n
                maxShields   += Float(o.shieldCapacity    ?? 0) * n
                shieldReg    += Float(o.shieldRecharge    ?? 0) * n
                outfitMass   += Float(o.mass              ?? 0) * n
                passiveDrain += Float(o.energyConsumption ?? 0) * n
                passiveHeat  += Float(o.heatGeneration    ?? 0) * n
            }
            // Thrust/turn (and the active drains they trigger) only
            // count from engines actually MOUNTED in an engine slot.
            // Unmounted thrusters sitting in inventory don't push.
            for (slot, oid) in PlayerProfile.shared.mountAssignments
                where slot.hasPrefix("engine_") {
                guard let o = OutfitRegistry.shared.outfit(id: oid) else { continue }
                totalThrust += Float(o.thrust          ?? 0)
                totalTurn   += Float(o.turn            ?? 0)
                thrustDrain += Float(o.thrustingEnergy ?? 0)
                thrustHeat  += Float(o.thrustingHeat   ?? 0)
                turnDrain   += Float(o.turningEnergy   ?? 0)
                turnHeat    += Float(o.turningHeat     ?? 0)
            }
            let shipMass    = Float(def?.attributes.mass            ?? 100)
            let totalMass   = shipMass + outfitMass
            let maxHull     = Float(def?.attributes.hull            ?? 100)
            let dissipation = Float(def?.attributes.heatDissipation ?? 0.1)
            // ES-style maxHeat / dissipation scaling: 60 heat units per ton
            // is the threshold; dissipation is mass × heat_dissipation per
            // second so heavier ships shed proportionally more heat.
            let maxHeat     = max(1, totalMass * 60)
            let dissipateHz = max(0.01, totalMass * dissipation)
            sim.configureShipParams(maxEnergy:           maxEnergy,
                                    energyRecharge:      energyReg,
                                    maxHeat:             maxHeat,
                                    heatDissipationRate: dissipateHz,
                                    maxShields:          maxShields,
                                    shieldRecharge:      shieldReg,
                                    maxHull:             maxHull,
                                    totalThrust:         totalThrust,
                                    totalTurn:           totalTurn,
                                    totalMass:           totalMass,
                                    thrustingEnergyDrain: thrustDrain,
                                    thrustingHeatGen:     thrustHeat,
                                    turningEnergyDrain:   turnDrain,
                                    turningHeatGen:       turnHeat,
                                    passiveEnergyDrain:   passiveDrain,
                                    passiveHeatGen:       passiveHeat)
            offlineSim   = sim
            mySessionId  = sim.sessionId
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
        scatter(farStarLayer, count: 4000, spread: 2000,
                scaleRange: 0.05...0.27,
                alphaRange: 0.42...0.55,
                variants:   [.pinprick, .mediumWhite, .pinprick, .pinprick,
                             .pinprick, .pinprick, .pinprick, .pinprick,
                             .pinprick, .pinprick, .pinprick, .pinprick,
                             .pinprick, .pinprick, .yellowSun, .pinprick,
                             .dimWhite, .pinprick, .pinprick, .redGiant])

        // Mid field — sprite-node pinpricks plus a sprinkle of bloom stars
        // and the occasional warm tinted giant for color variety.
        scatter(midStarLayer, count: 3000, spread: 3000,
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
        scatter(nearStarLayer, count: 3000, spread: 6000,
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
        // Five bars now (shields / hull / fuel / energy / heat) — drop the
        // mini-map below them so they don't overlap.
        miniMap.position = CGPoint(x: hw - 18 - miniMap.radius,
                                   y: hh - 24 - 90 - miniMap.radius)
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
        // it from the right (track edge) instead of the centre. The label
        // reference is returned so `setStatus` can rewrite the displayed
        // number as the value changes each frame.
        func makeRow(y: CGFloat, color: UIColor, label: String)
            -> (track: SKShapeNode, fill: SKShapeNode, label: SKLabelNode) {
            let lbl = key(label, y: y)
            panel.addChild(lbl)
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
            return (track, fill, lbl)
        }

        // Initial labels show the ship's max value — `setStatus` overrides
        // them every snapshot with the actual current numbers.
        let def         = PlayerProfile.shared.currentShipDef
        let maxShield   = Int(def?.attributes.shields        ?? 100)
        let maxHull     = Int(def?.attributes.hull           ?? 100)
        let maxFuel     = Int(def?.attributes.fuelCapacity   ?? 100)
        let maxEnergy   = Int(def?.attributes.energyCapacity ?? 100)

        let shieldRow = makeRow(y:   0, color: UIColor(red: 0.30, green: 0.65, blue: 1.00, alpha: 0.95),
                                label: "SHIELDS \(maxShield)")
        shieldBar   = shieldRow.track
        shieldFill  = shieldRow.fill
        shieldLabel = shieldRow.label

        let hullRow = makeRow(y: -18, color: UIColor(red: 1.00, green: 0.30, blue: 0.30, alpha: 0.95),
                              label: "HULL \(maxHull)")
        hullBar   = hullRow.track
        hullFill  = hullRow.fill
        hullLabel = hullRow.label

        // Fuel row — amber. Fuel doesn't deplete yet; bar stays at 100%
        // and the label shows current/max.
        let fuelRow = makeRow(y: -36, color: UIColor(red: 1.00, green: 0.65, blue: 0.20, alpha: 0.95),
                              label: "FUEL \(maxFuel)")
        fuelBar   = fuelRow.track
        fuelFill  = fuelRow.fill
        fuelLabel = fuelRow.label

        // Energy row — cyan, sits under fuel. Drained by firing; recharges
        // passively via `energy_recharge` per second.
        let energyRow = makeRow(y: -54, color: UIColor(red: 0.30, green: 0.85, blue: 1.00, alpha: 0.95),
                                label: "ENERGY \(maxEnergy)")
        energyBar   = energyRow.track
        energyFill  = energyRow.fill
        energyLabel = energyRow.label

        // Heat row — red-orange, displayed as a percentage so the label
        // and fill share the same source of truth.
        let heatRow = makeRow(y: -72, color: UIColor(red: 1.00, green: 0.45, blue: 0.10, alpha: 0.95),
                              label: "HEAT 0%")
        heatBar   = heatRow.track
        heatFill  = heatRow.fill
        heatLabel = heatRow.label
    }

    /// Updates every readout from the live snapshot — bars by fraction,
    /// labels with the current raw value (rounded). Heat stays as a
    /// percentage since the underlying scale changes per hull.
    private func setStatus(shields: Float, maxShields: Float,
                           hull: Float, maxHull: Float,
                           fuel: Float, maxFuel: Float,
                           energy: Float, maxEnergy: Float,
                           heat: Float, maxHeat: Float) {
        func pct(_ n: Float, _ d: Float) -> CGFloat {
            guard d > 0 else { return 0 }
            return max(0, min(1, CGFloat(n / d)))
        }
        shieldFill?.xScale = max(0.001, pct(shields, maxShields))
        hullFill?.xScale   = max(0.001, pct(hull,    maxHull))
        fuelFill?.xScale   = max(0.001, pct(fuel,    maxFuel))
        energyFill?.xScale = max(0.001, pct(energy,  maxEnergy))
        let h              = pct(heat, maxHeat)
        heatFill?.xScale   = max(0.001, h)
        shieldLabel?.text  = "SHIELDS \(Int(shields.rounded()))"
        hullLabel?.text    = "HULL \(Int(hull.rounded()))"
        fuelLabel?.text    = "FUEL \(Int(fuel.rounded()))"
        energyLabel?.text  = "ENERGY \(Int(energy.rounded()))"
        heatLabel?.text    = "HEAT \(Int((h * 100).rounded()))%"
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
                let (wname, weapon) = currentPlayerWeapon()
                let snap = sim.step(input: localInput,
                                    weaponName: wname,
                                    weapon: weapon)
                applySnapshot(snap, mySessionId: sim.sessionId)
            }
        }

        // Beam weapons fire EVERY frame (continuous), separately from the
        // sim tick — `reload <= 0` weapons render a line + apply per-second
        // damage scaled by elapsed render time.
        tickBeamWeapon(at: currentTime)

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
            // Between sim ticks, slide the local ship along its last known
            // velocity vector. Without this the ship's world position jumps
            // every 50 ms while planets advance every frame — which looks
            // like the planet is jittering whenever the player is alongside.
            if !isDocking, !isDisembarking, let predicted = extrapolatedLocalPosition() {
                node.position = predicted
            }
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
                       ships:          otherShips,
                       selection:      selectedBody?.position)

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
                $0.thrust        = false
                $0.turnLeft      = false
                $0.turnRight     = false
                $0.targetHeading = nil
            }
            return
        }

        // Joystick controls FACING: deflect in any direction → ship slews
        // its nose to that absolute world bearing and thrusts forward.
        // Sending the target as a single number to the sim lets it clamp
        // the per-tick rotation step so the heading never overshoots —
        // that's what kept the controls from wobbling at high turn rates.
        let targetAngle = atan2(offset.y, offset.x)
        // Derive the turn direction (purely for the lean animation —
        // the sim ignores the flags when `targetHeading` is set).
        let current = currentPlayerHeading()
        let rawDiff = targetAngle - current
        let diff    = atan2(sin(rawDiff), cos(rawDiff))
        let leanDead: CGFloat = 0.05
        setInput {
            $0.thrust        = true
            $0.targetHeading = Float(targetAngle)
            $0.turnLeft      = diff < -leanDead
            $0.turnRight     = diff >  leanDead
        }
    }

    /// Snapshot of the local ship's current sim state. Recorded so the
    /// `update(_:)` loop can extrapolate its position smoothly between
    /// sim ticks — otherwise the camera lurches in 50 ms steps while the
    /// solar system moves at the render rate, producing visible jitter on
    /// nearby planets.
    private func captureLocalBaseline(from snapshot: ShipSnapshot) {
        localBaselinePos  = CGPoint(x: CGFloat(snapshot.x),    y: CGFloat(snapshot.y))
        localBaselineVel  = CGVector(dx: CGFloat(snapshot.velX), dy: CGFloat(snapshot.velY))
        localBaselineTime = CACurrentMediaTime()
    }

    /// Returns the local ship's predicted world position right now, using
    /// `pos + vel * elapsed` from the most recent snapshot. Falls back to
    /// the node's current position if no baseline has been captured yet.
    private func extrapolatedLocalPosition() -> CGPoint? {
        guard let sid = mySessionId, let node = shipNodes[sid] else { return nil }
        guard localBaselineTime > 0 else { return node.position }
        let dt = CACurrentMediaTime() - localBaselineTime
        // Clamp dt so an extreme stall (app backgrounded, lag spike) doesn't
        // catapult the prediction far past the next tick.
        let clamped = min(max(dt, 0), simInterval * 2)
        return CGPoint(
            x: localBaselinePos.x + localBaselineVel.dx * CGFloat(clamped),
            y: localBaselinePos.y + localBaselineVel.dy * CGFloat(clamped)
        )
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
                if id == mySessionId { captureLocalBaseline(from: data) }
            } else {
                let node = ShipNode(isLocalPlayer: id == mySessionId)
                addChild(node)
                shipNodes[id] = node
                node.update(from: data, sunPosition: primarySunPosition)
                if id == mySessionId { captureLocalBaseline(from: data) }

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
            // Fuel still defaults to ship JSON (no consumption mechanics
            // yet); every other max ships in the snapshot so outfit
            // contributions show up live.
            let def     = PlayerProfile.shared.currentShipDef
            let maxFuel = Float(def?.attributes.fuelCapacity ?? 100)
            setStatus(shields:    s.shields,   maxShields: s.maxShields,
                      hull:       s.hull,      maxHull:    s.maxHull,
                      fuel:       maxFuel,     maxFuel:    maxFuel,
                      energy:     s.energy,    maxEnergy:  s.maxEnergy,
                      heat:       s.heat,      maxHeat:    s.maxHeat)
        }

        // Projectiles
        let activeProjs = Set(snapshot.projectiles.keys)
        for (id, data) in snapshot.projectiles {
            if let node = projectileNodes[id] {
                node.position = CGPoint(x: CGFloat(data.x), y: CGFloat(data.y))
            } else {
                let node = ProjectileNode(id:         id,
                                          ownerId:    data.ownerId,
                                          weaponName: data.weaponName,
                                          kind:       data.kind,
                                          isOwn:      data.ownerId == mySessionId)
                node.position = CGPoint(x: CGFloat(data.x), y: CGFloat(data.y))
                addChild(node)
                projectileNodes[id] = node
            }
        }
        for id in projectileNodes.keys where !activeProjs.contains(id) {
            projectileNodes.removeValue(forKey: id)?.removeFromParent()
        }
    }

    // MARK: – Weapons + contact handling

    /// Looks up the player's currently-equipped firing weapon. First
    /// installed outfit with a non-nil `weapon` block wins; sorted by name
    /// so behavior is stable across runs.
    private func currentPlayerWeapon() -> (name: String?, stats: OutfitDef.WeaponStats?) {
        let profile = PlayerProfile.shared
        for name in profile.installedOutfits.keys.sorted() {
            if let def = OutfitRegistry.shared.outfit(id: name),
               let w   = def.weapon {
                return (name, w)
            }
        }
        return (nil, nil)
    }

    func didBegin(_ contact: SKPhysicsContact) {
        // Pair the two bodies by their categories so the rest of the
        // method can address them by role rather than A/B order.
        let bodies = [contact.bodyA, contact.bodyB]
        guard let projBody = bodies.first(where: {
                ($0.categoryBitMask & (CollisionCategory.projectileStandard
                                     | CollisionCategory.projectileFlare)) != 0 }),
              let proj     = projBody.node as? ProjectileNode
        else { return }
        let otherBody = bodies.first { $0 !== projBody }

        switch projBody.categoryBitMask {
        case CollisionCategory.projectileFlare:
            // Flare intercepts an incoming standard projectile.
            if let other = otherBody?.node as? ProjectileNode {
                consumeProjectile(other, withExplosion: false)
                consumeProjectile(proj,  withExplosion: false)
            }

        case CollisionCategory.projectileStandard:
            if let ship = otherBody?.node as? ShipNode {
                handleHit(projectile: proj, ship: ship)
            } else if let body = otherBody?.node as? CelestialBodyNode {
                handleHit(projectile: proj, asteroid: body)
            } else if let flare = otherBody?.node as? ProjectileNode,
                      flare.categoryBit == CollisionCategory.projectileFlare {
                // Flare-vs-standard handled in the flare branch above; this
                // catches the symmetric case.
                consumeProjectile(proj,  withExplosion: false)
                consumeProjectile(flare, withExplosion: false)
            }

        default: break
        }
    }

    /// Applies (or skips) damage to a ship target. Player-fired projectiles
    /// hit hostile-faction ships without selection; neutral/friendly hulls
    /// must be selected first or the bolt passes harmlessly.
    private func handleHit(projectile: ProjectileNode, ship: ShipNode) {
        // Don't damage the firing ship.
        if let sid = mySessionId, projectile.ownerId == sid, ship === shipNodes[sid] { return }

        let weapon = projectile.weaponName.flatMap { OutfitRegistry.shared.outfit(id: $0)?.weapon }
        // Only player-owned bolts respect the selection-required rule.
        // (Future: NPC AI projectiles will always hit the player.)
        let fromPlayer = projectile.ownerId == (mySessionId ?? "")
        if fromPlayer {
            let target = shipNodes.first(where: { $0.value === ship })?.key
            let isHostile = isHostileShip(sessionId: target)
            let isSelected = false  // ships aren't selectable yet in this codebase
            if !isHostile && !isSelected { return }
        }

        // Local player damage flows back into OfflineSim so shields/hull are
        // authoritative. Other ships will get the same treatment once
        // NPC/server damage state lands. Damage stats in JSON are *per
        // second*; for a discrete projectile we multiply by the weapon's
        // reload (= seconds between shots) so total DPS is constant.
        if let sid = mySessionId, ship === shipNodes[sid], let sim = offlineSim {
            let dx = Float(ship.position.x - projectile.position.x)
            let dy = Float(ship.position.y - projectile.position.y)
            let len = max(0.001, sqrt(dx * dx + dy * dy))
            let reload = Float(max(weapon?.reload ?? 1, 0.001))
            sim.applyDamage(
                shieldDamage: Float(weapon?.shieldDamage ?? 1) * reload,
                hullDamage:   Float(weapon?.hullDamage   ?? 1) * reload,
                force:        Float(weapon?.hitForce     ?? 1),
                direction:    (dx / len, dy / len)
            )
        }

        spawnHitFlash(at: projectile.position)
        consumeProjectile(projectile, withExplosion: false)
    }

    /// Selection-gated asteroid damage. Off-selection bolts pass through;
    /// on-selection bolts deduct from `hitPoints` and push the rock along
    /// the projectile travel vector. At zero HP the asteroid is removed.
    private func handleHit(projectile: ProjectileNode, asteroid: CelestialBodyNode) {
        let fromPlayer = projectile.ownerId == (mySessionId ?? "")
        if fromPlayer && selectedBody !== asteroid { return }

        let weapon = projectile.weaponName.flatMap { OutfitRegistry.shared.outfit(id: $0)?.weapon }
        let reload = max(weapon?.reload ?? 1, 0.001)
        // hullDamage is per-second; one shot accounts for `reload` seconds.
        let hullDmg = CGFloat((weapon?.hullDamage ?? 1) * reload)
        asteroid.hitPoints -= hullDmg

        // Knockback — impulse from projectile point of impact toward the
        // asteroid's center, scaled by the weapon's `hitForce`.
        if let pb = asteroid.physicsBody {
            let dx  = asteroid.position.x - projectile.position.x
            let dy  = asteroid.position.y - projectile.position.y
            let len = max(0.001, sqrt(dx * dx + dy * dy))
            let force = CGFloat(weapon?.hitForce ?? 1) * 0.6
            pb.applyImpulse(CGVector(dx: (dx / len) * force,
                                     dy: (dy / len) * force))
        }

        spawnHitFlash(at: projectile.position)
        consumeProjectile(projectile, withExplosion: false)

        if asteroid.hitPoints <= 0 {
            destroyAsteroid(asteroid)
        }
    }

    private func destroyAsteroid(_ asteroid: CelestialBodyNode) {
        if selectedBody === asteroid {
            selectedBody = nil
            infoTooltip.hide()
        }
        spawnBurst(at: asteroid.position, color: .orange, radius: asteroid.bodyRadius)
        asteroid.removeFromParent()
        solarSystem?.removeAsteroid(asteroid)
    }

    private func consumeProjectile(_ proj: ProjectileNode, withExplosion: Bool) {
        offlineSim?.markProjectileConsumed(proj.projectileID)
        proj.removeFromParent()
        projectileNodes.removeValue(forKey: proj.projectileID)
    }

    private func spawnHitFlash(at point: CGPoint) {
        let flash         = SKShapeNode(circleOfRadius: 5)
        flash.fillColor   = UIColor(red: 1.0, green: 0.85, blue: 0.4, alpha: 1)
        flash.strokeColor = .clear
        flash.glowWidth   = 10
        flash.blendMode   = .add
        flash.position    = point
        flash.zPosition   = 5
        addChild(flash)
        flash.run(.sequence([
            .group([.scale(to: 2.5, duration: 0.18),
                    .fadeOut(withDuration: 0.18)]),
            .removeFromParent(),
        ]))
    }

    private func spawnBurst(at point: CGPoint, color: UIColor, radius: CGFloat) {
        for _ in 0..<10 {
            let shard         = SKShapeNode(circleOfRadius: CGFloat.random(in: 1.5...3.5))
            shard.fillColor   = color
            shard.strokeColor = .clear
            shard.glowWidth   = 4
            shard.position    = point
            shard.blendMode   = .add
            addChild(shard)
            let angle  = CGFloat.random(in: 0..<(2 * .pi))
            let speed  = CGFloat.random(in: radius * 1.2 ... radius * 2.5)
            let dest   = CGPoint(x: point.x + cos(angle) * speed,
                                 y: point.y + sin(angle) * speed)
            shard.run(.sequence([
                .group([.move(to: dest, duration: 0.5),
                        .fadeOut(withDuration: 0.5)]),
                .removeFromParent(),
            ]))
        }
    }

    /// Returns true if `sessionId` corresponds to a ship whose `faction`
    /// is in `PlayerProfile.hostileFactions`. Asteroids never count as
    /// ships here.
    private func isHostileShip(sessionId: String?) -> Bool {
        // No NPC/peer faction wiring yet — placeholder for when ship
        // snapshots start carrying a faction string. The local player ship
        // never returns true here.
        return false
    }

    // MARK: – Beam weapons (turret-tracking)

    /// Per render frame: figure out which beam weapons the player has
    /// installed, allocate one tracking slot per instance, and update
    /// each slot's aim / ray-cast / damage / visual. Turrets (category
    /// "Turrets") rotate independently of the ship at their `turretTurn`
    /// rate; non-turret beams fire straight along the ship heading.
    private func tickBeamWeapon(at now: TimeInterval) {
        let firing = mode == .multiplayer
            ? NetworkManager.shared.input.firing
            : localInput.firing

        // We DON'T short-circuit on `!firing` any more: turret hardpoint
        // sprites need to keep tracking the selected target between
        // bursts so they always point where the next shot would go.
        // Beam visuals and damage still get gated on `firing` below.
        guard let sid  = mySessionId,
              let ship = shipNodes[sid]
        else {
            for slot in turretSlots {
                slot.beam.isHidden   = true
                slot.impact.isHidden = true
            }
            lastBeamUpdateTime = now
            return
        }

        // Pull the ship's mount layout from its JSON. Each entry already
        // declares its weapon — we just need to find ones whose weapon is
        // actually installed AND classifies as a beam (reload >= 1).
        let def       = ShipRegistry.shared.def(for: ship.metadata.assetName)
        let turretHPs = def?.turrets ?? []
        let gunHPs    = def?.guns    ?? []

        // Each mount fires from one installed copy of its declared
        // weapon. Track remaining installed counts so two mounts with the
        // same weapon don't both fire if only one is installed.
        var remaining = PlayerProfile.shared.installedOutfits
        let overrides = PlayerProfile.shared.mountAssignments

        // Build an ordered slot list: every mount whose weapon is
        // installed AND is a beam type. Turrets first (so they get low
        // slot indices and tracking memory persists across rebuilds).
        struct MountAssignment {
            let slot:     String   // "turret_0", "gun_2", etc.
            let mount:    ShipDef.Hardpoint
            let weapon:   OutfitDef.WeaponStats
            let isTurret: Bool
        }
        var assignments: [MountAssignment] = []
        // Pair each mount with its slot key so the user-customised
        // override (mountAssignments["turret_3"] = "..." etc.) can replace
        // the JSON's default `weapon` value at fire time.
        let turretEntries = turretHPs.enumerated().map {
            (slot: "turret_\($0.offset)", mount: $0.element, isTurret: true)
        }
        let gunEntries = gunHPs.enumerated().map {
            (slot: "gun_\($0.offset)", mount: $0.element, isTurret: false)
        }
        // `mountAssignments` is now authoritative — JSON-default weapons
        // are seeded into it at ship-equip time, and any subsequent
        // drag-to-assign overwrites the slot. No fall-back to the JSON
        // mount's `weapon` field here.
        for entry in turretEntries + gunEntries {
            guard let weaponID = overrides[entry.slot],
                  remaining[weaponID, default: 0] > 0,
                  let def = OutfitRegistry.shared.outfit(id: weaponID),
                  let weapon = def.weapon,
                  (weapon.reload ?? 0) >= 1.0
            else { continue }
            assignments.append(.init(slot:     entry.slot,
                                     mount:    entry.mount,
                                     weapon:   weapon,
                                     isTurret: entry.isTurret))
            remaining[weaponID]! -= 1
        }

        resizeTurretSlots(to: assignments.count)
        for i in turretSlots.indices where turretSlots[i].aimAngle == 0 {
            turretSlots[i].aimAngle = ship.heading
        }

        let dt = min(max(now - lastBeamUpdateTime, 0), 0.1)
        for (slotIdx, a) in assignments.enumerated() {
            let mount = ShipMetadata.Mount(bodyPoint: CGPoint(x: a.mount.x,
                                                              y: a.mount.y))
            tickTurret(slotIndex: slotIdx,
                       weapon:    a.weapon,
                       isTurret:  a.isTurret,
                       slot:      a.slot,
                       mount:     mount,
                       ship:      ship,
                       dt:        dt,
                       firing:    firing)
        }

        lastBeamUpdateTime = now
    }

    /// `(name, weapon, count, isTurret)` for every installed outfit whose
    /// weapon block flags it as a beam (`reload >= 1`).
    private func installedBeamWeapons() -> [(name: String,
                                              weapon: OutfitDef.WeaponStats,
                                              count: Int,
                                              isTurret: Bool)] {
        var out: [(String, OutfitDef.WeaponStats, Int, Bool)] = []
        let profile = PlayerProfile.shared
        for name in profile.installedOutfits.keys.sorted() {
            guard let def    = OutfitRegistry.shared.outfit(id: name),
                  let weapon = def.weapon,
                  (weapon.reload ?? 0) >= 1.0,
                  let count  = profile.installedOutfits[name], count > 0
            else { continue }
            // JSON category is "turret" (singular, lowercased) for the
            // Heavy Laser Turret. Accept the plural form too so future
            // outfit JSON typos don't silently disable tracking.
            let cat = def.category?.lowercased() ?? ""
            let isTurret = (cat == "turret" || cat == "turrets")
            out.append((name, weapon, count, isTurret))
        }
        return out
    }

    private func resizeTurretSlots(to count: Int) {
        while turretSlots.count < count {
            let beam   = BeamNode()
            beam.zPosition = 4
            addChild(beam)
            let impact = makeImpactPuff()
            addChild(impact)
            turretSlots.append(TurretSlot(aimAngle: 0,
                                          beam: beam,
                                          impact: impact))
        }
        while turretSlots.count > count {
            let s = turretSlots.removeLast()
            s.beam.removeFromParent()
            s.impact.removeFromParent()
        }
    }

    /// Translates a body-local mount point through the ship's current
    /// visual yaw to obtain its world-space position. The PNG asset's
    /// "nose" is +y in body coords; the visual is rotated by
    /// `heading − π/2` so heading=0 (facing world +x) corresponds to yaw
    /// = −π/2, which maps body +y to world +x as expected.
    private func mountWorldPosition(mount: ShipMetadata.Mount,
                                    ship: ShipNode) -> CGPoint {
        let yaw = ship.heading - .pi / 2
        let bx  = mount.bodyPoint.x
        let by  = mount.bodyPoint.y
        let wx  = bx * cos(yaw) - by * sin(yaw)
        let wy  = bx * sin(yaw) + by * cos(yaw)
        return CGPoint(x: ship.position.x + wx, y: ship.position.y + wy)
    }

    /// One frame's worth of work for a single turret slot.
    private func tickTurret(slotIndex i: Int,
                            weapon: OutfitDef.WeaponStats,
                            isTurret: Bool,
                            slot: String,
                            mount: ShipMetadata.Mount,
                            ship: ShipNode,
                            dt: TimeInterval,
                            firing: Bool) {
        let origin = mountWorldPosition(mount: mount, ship: ship)

        // ── Determine where the turret WANTS to aim ────────────────────
        let targetAngle: CGFloat
        if isTurret, let target = selectedBody, target.kind == .asteroid {
            // Bearing from the mount to the target's centre.
            let dx = target.position.x - origin.x
            let dy = target.position.y - origin.y
            targetAngle = atan2(dy, dx)
        } else {
            // No target (or non-turret weapon) → align with ship heading.
            targetAngle = ship.heading
        }

        // ── Rotate current aim toward target at `turretTurn` rad/sec ──
        var aim = turretSlots[i].aimAngle
        if isTurret {
            let raw   = targetAngle - aim
            let diff  = atan2(sin(raw), cos(raw))
            let speed = CGFloat(weapon.turretTurn ?? 2.0)
            let step  = speed * CGFloat(dt)
            aim += abs(diff) <= step ? diff : (diff > 0 ? step : -step)
        } else {
            aim = targetAngle    // fixed-mount weapons aim straight ahead
        }
        turretSlots[i].aimAngle = aim

        // Push the live aim to the painted hardpoint so its barrel
        // matches the firing solution even when the player isn't
        // actively firing. Non-turret mounts don't get a sprite today.
        if isTurret {
            ship.setTurretAim(slot: slot, worldAngle: aim)
        }

        // ── Beam visuals + damage only while actively firing ───────────
        guard firing else {
            turretSlots[i].beam.isHidden   = true
            turretSlots[i].impact.isHidden = true
            return
        }

        // Spend energy + accrue heat for this frame of firing. If energy
        // runs out, hide this beam slot and bail before any visuals or
        // ray-casting work.
        let canFire = offlineSim?.applyBeamFiringCost(
            firingEnergy: Float(weapon.firingEnergy ?? 0),
            firingHeat:   Float(weapon.firingHeat   ?? 0),
            dt:           Float(dt)
        ) ?? true
        if !canFire {
            turretSlots[i].beam.isHidden   = true
            turretSlots[i].impact.isHidden = true
            return
        }

        let range = CGFloat((weapon.velocity ?? 400) * (weapon.lifetime ?? 1))
        let fullEnd = CGPoint(x: origin.x + cos(aim) * range,
                              y: origin.y + sin(aim) * range)

        // ── Ray-cast for a valid target ────────────────────────────────
        var bestNode: SKNode?
        var bestDist: CGFloat = .greatestFiniteMagnitude
        physicsWorld.enumerateBodies(alongRayStart: origin, end: fullEnd) {
            [weak self] body, point, _, _ in
            guard let self, let node = body.node else { return }
            if node === ship { return }

            let isValid: Bool
            if let s = node as? ShipNode {
                let id = self.shipNodes.first(where: { $0.value === s })?.key
                isValid = self.isHostileShip(sessionId: id)
            } else if let cb = node as? CelestialBodyNode, cb.kind == .asteroid {
                isValid = self.selectedBody === cb
            } else {
                isValid = false
            }
            guard isValid else { return }

            let d = hypot(point.x - origin.x, point.y - origin.y)
            if d < bestDist { bestDist = d; bestNode = node }
        }

        let endpoint: CGPoint
        let didHit:   Bool
        if bestDist.isFinite, let hit = bestNode {
            endpoint = CGPoint(x: origin.x + cos(aim) * bestDist,
                               y: origin.y + sin(aim) * bestDist)
            // Damage is additive across slots — each beam ticks
            // independently with its own `dt`, so N turrets on one target
            // multiply DPS by N as requested.
            applyBeamDamage(to: hit, weapon: weapon, elapsed: dt)
            didHit = true
        } else {
            endpoint = fullEnd
            didHit   = false
        }

        let slot = turretSlots[i]
        slot.beam.isHidden = false
        slot.beam.setEndpoints(from: origin, to: endpoint)
        slot.impact.isHidden = !didHit
        if didHit { slot.impact.position = endpoint }
    }

    // MARK: – Impact puff (soft cloud)

    /// Instantiates one ready-to-use impact node. Reuses the cached cloud
    /// texture so allocation is cheap; the gentle scale pulse is local to
    /// the SKAction tree, no per-frame work from us.
    private func makeImpactPuff() -> SKNode {
        let impact         = SKNode()
        impact.zPosition   = 5
        impact.isHidden    = true

        let cloud          = SKSpriteNode(texture: impactCloudTexture)
        cloud.size         = CGSize(width: 42, height: 42)
        cloud.blendMode    = .add
        cloud.name         = "cloud"
        impact.addChild(cloud)

        // Gentle pulse — purely cosmetic, runs forever once set up.
        let pulseUp        = SKAction.scale(to: 1.18, duration: 0.14)
        let pulseDn        = SKAction.scale(to: 0.86, duration: 0.14)
        pulseUp.timingMode = .easeInEaseOut
        pulseDn.timingMode = .easeInEaseOut
        cloud.run(.repeatForever(.sequence([pulseUp, pulseDn])))

        return impact
    }

    /// Builds a soft, cloud-like radial gradient texture: bright white
    /// core, fading to cyan, fading to fully transparent. Multiple stops
    /// produce a non-circular, billowy falloff that reads as gas/plasma
    /// rather than a hard disc.
    private static func makeCloudTexture(coreColor: UIColor,
                                         glowColor: UIColor) -> SKTexture {
        let pixelSize: CGFloat = 256
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale  = 1
        fmt.opaque = false
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: pixelSize, height: pixelSize), format: fmt
        )
        let img = renderer.image { ctx in
            let cg     = ctx.cgContext
            let center = CGPoint(x: pixelSize / 2, y: pixelSize / 2)
            let maxR   = pixelSize / 2
            let stops: [CGColor] = [
                coreColor.withAlphaComponent(0.95).cgColor,
                glowColor.withAlphaComponent(0.65).cgColor,
                glowColor.withAlphaComponent(0.32).cgColor,
                glowColor.withAlphaComponent(0.14).cgColor,
                glowColor.withAlphaComponent(0.05).cgColor,
                glowColor.withAlphaComponent(0.0).cgColor,
            ]
            let locations: [CGFloat] = [0.0, 0.16, 0.36, 0.56, 0.78, 1.0]
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: stops as CFArray,
                                  locations: locations) {
                cg.drawRadialGradient(g,
                                      startCenter: center, startRadius: 0,
                                      endCenter:   center, endRadius:   maxR,
                                      options: [])
            }
        }
        return SKTexture(image: img)
    }

    private func applyBeamDamage(to node: SKNode,
                                 weapon: OutfitDef.WeaponStats,
                                 elapsed: TimeInterval) {
        // Clamp elapsed so a long pause (background → resume, app launch)
        // doesn't produce a single oversized damage tick on the first frame
        // after firing resumes.
        let dt = min(max(elapsed, 0), 0.1)
        let shieldHit = CGFloat((weapon.shieldDamage ?? 0)) * CGFloat(dt)
        let hullHit   = CGFloat((weapon.hullDamage   ?? 0)) * CGFloat(dt)

        if let asteroid = node as? CelestialBodyNode, asteroid.kind == .asteroid {
            asteroid.hitPoints -= hullHit
            // Per-frame knockback impulse, small and in the beam's direction.
            if let pb = asteroid.physicsBody,
               let sid = mySessionId, let ship = shipNodes[sid] {
                let dx = asteroid.position.x - ship.position.x
                let dy = asteroid.position.y - ship.position.y
                let len = max(0.001, sqrt(dx * dx + dy * dy))
                let f   = CGFloat(weapon.hitForce ?? 0) * CGFloat(dt) * 0.5
                pb.applyImpulse(CGVector(dx: dx / len * f, dy: dy / len * f))
            }
            if asteroid.hitPoints <= 0 {
                destroyAsteroid(asteroid)
            }
        }
        // Ship damage path will route through OfflineSim when remote/NPC
        // ships carry damage state — placeholder for now.
        _ = shieldHit
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
