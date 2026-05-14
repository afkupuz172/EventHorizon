import SpriteKit
import SceneKit
import simd

final class ShipNode: SKNode {

    private let metadata:      ShipMetadata
    private let isLocalPlayer: Bool

    private var visual:       SKNode!
    private var thrustEmitter: SKEmitterNode?

    // SCN nodes whose Euler angles we tweak each frame.
    private weak var headingNode: SCNNode?   // yaw   — rotates around scene +Z
    private weak var leanNode:    SCNNode?   // roll  — rotates around scene +Y (nose axis)
    private weak var centerLight: SCNNode?   // re-aimed each frame to point from map origin

    /// PNG ship's lighting attribute. We keep a reference to the sprite so
    /// `updatePNGLighting` can push the new direction value each frame.
    private weak var pngLitSprite: SKSpriteNode?

    /// Distance from ship center to where the thrust emitter mounts.
    private var thrustDistance: CGFloat = 40

    /// World-space heading of the ship in radians. 0 = +X (right), π/2 = +Y
    /// (up). Updated from each snapshot; the HUD uses this for the radar
    /// wedge.
    private(set) var heading: CGFloat = 0

    /// Magnitude of the ship's velocity in world units per second. Used by
    /// the docking system to gate the "Dock" button on slow approaches.
    /// (Named to avoid colliding with `SKNode.speed`, which controls action
    /// playback rate.)
    private(set) var velocityMagnitude: CGFloat = 0

    /// Maximum values for the ship's three resource bars, pulled from the
    /// JSON gameplay definition (`data/ships/<id>.json`) at construction.
    /// Defaults are placeholders for hulls that don't have a JSON entry.
    let maxHull:    CGFloat
    let maxShields: CGFloat
    let maxFuel:    CGFloat

    init(isLocalPlayer: Bool, metadata: ShipMetadata? = nil) {
        // Local player flies whichever hull they last purchased at the
        // shipyard; remote ships fall back to the default until we have a
        // protocol message that announces per-player ship type.
        self.isLocalPlayer = isLocalPlayer
        self.metadata      = metadata
            ?? (isLocalPlayer ? PlayerProfile.shared.currentShip : .ringship)

        // Pull gameplay attributes from the JSON-loaded definition. The
        // lookup ID matches the metadata's asset basename so the rendering
        // and gameplay layers stay in sync without a separate mapping.
        let shipID = self.metadata.assetName
        let def    = ShipRegistry.shared.def(for: shipID)
        self.maxHull    = CGFloat(def?.attributes.hull         ?? 100)
        self.maxShields = CGFloat(def?.attributes.shields      ?? 100)
        self.maxFuel    = CGFloat(def?.attributes.fuelCapacity ?? 100)

        super.init()

        if let mount = self.metadata.thrustMounts.first {
            thrustDistance = abs(mount.bodyPoint.y)
        }

        setupVisual()
        addChild(visual)
        addChild(makeThrustEmitter())
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: – Setup

    private func setupVisual() {
        switch metadata.assetKind {
        case .usdc:
            if let node3D = makeShipSceneNode() {
                visual = node3D
                return
            }
        case .png:
            if let sprite = makeShipSpriteNode() {
                visual = sprite
                return
            }
        }
        visual = makeFallback2D()
    }

    /// Load the ship's PNG and wrap it in a sized `SKSpriteNode`. The PNG is
    /// assumed to point nose-up; heading is applied via `visual.zRotation` in
    /// `update(from:)`. An `SKShader` is attached to give the sprite a
    /// directional shadow side based on the sun's world position.
    private func makeShipSpriteNode() -> SKSpriteNode? {
        guard let url = Bundle.main.url(forResource: metadata.assetName,
                                        withExtension: "png",
                                        subdirectory: metadata.assetSubdirectory),
              let image = UIImage(contentsOfFile: url.path)
        else {
            print("[ShipNode] missing PNG: \(metadata.assetSubdirectory)/\(metadata.assetName).png")
            return nil
        }
        let sprite  = SKSpriteNode(texture: SKTexture(image: image))
        sprite.size = metadata.viewportSize

        attachLightingShader(to: sprite)
        return sprite
    }

    /// Per-pixel directional darkening. Pixels on the side facing AWAY from
    /// the sun get dimmed; pixels facing toward stay full-bright. The light
    /// direction is per-node (each ship has its own sun-relative vector),
    /// so we use an `SKAttribute` rather than an `SKUniform` — attribute
    /// values pushed via `setValue(_:forAttribute:)` propagate reliably,
    /// where `SKUniform.vectorFloat2Value` updates sometimes don't.
    private func attachLightingShader(to sprite: SKSpriteNode) {
        let shader = SKShader(source: """
            void main() {
                vec4 base = texture2D(u_texture, v_tex_coord);
                if (base.a < 0.01) {
                    gl_FragColor = base;
                    return;
                }
                vec2 fromCenter = v_tex_coord - vec2(0.5);
                float d = length(fromCenter);
                if (d < 0.001) {
                    gl_FragColor = base;
                    return;
                }
                vec2 norm    = fromCenter / d;
                float facing = dot(norm, a_lightDir);          // -1 = shadow, +1 = lit
                float t      = 0.5 + 0.5 * facing;             // 0..1
                float intensity = mix(0.25, 1.0, t);           // 25% on shadow side, full on lit
                gl_FragColor = vec4(base.rgb * intensity, base.a);
            }
            """)
        shader.attributes = [SKAttribute(name: "a_lightDir", type: .vectorFloat2)]
        sprite.shader     = shader
        // Initial direction: light from +X in texture space. Sets the right
        // half lit, left half dark — useful for sanity-checking the shader
        // is running before the first per-frame update.
        sprite.setValue(SKAttributeValue(vectorFloat2: vector_float2(1, 0)),
                        forAttribute: "a_lightDir")
        pngLitSprite = sprite
    }

    /// Loads the USDC asset, orients it, attaches an orthographic top-down
    /// camera and lighting, and returns an SK3DNode sized per metadata.
    private func makeShipSceneNode() -> SK3DNode? {
        guard let url = Bundle.main.url(forResource: metadata.assetName,
                                        withExtension: "usdc",
                                        subdirectory: metadata.assetSubdirectory)
        else { return nil }

        let loadOptions: [SCNSceneSource.LoadingOption: Any] = [
            .checkConsistency:   false,
            // Tell SCN to resolve external texture refs (Image_0.jpg etc.) from
            // the same directory the USDC lives in.
            .assetDirectoryURLs: [url.deletingLastPathComponent()],
        ]
        guard let scene = try? SCNScene(url: url, options: loadOptions)
        else { return nil }

        // ── Materials: force blinn shading (PBR without an HDR env map tends to
        //    flat-white in SK3DNode) and apply Image_0.jpg as a diffuse fallback
        //    so the ship has color when the USDC's PBR shader graph doesn't
        //    surface its baseColor texture through SCN's simple material API.
        let diffuseURL = url.deletingLastPathComponent()
            .appendingPathComponent("Image_0.jpg")
        let diffuseImage = UIImage(contentsOfFile: diffuseURL.path)
        scene.rootNode.enumerateChildNodes { node, _ in
            node.geometry?.materials.forEach { mat in
                mat.lightingModel = .blinn
                let alreadyTextured = mat.diffuse.contents is UIImage
                                   || mat.diffuse.contents is URL
                if !alreadyTextured, let img = diffuseImage {
                    mat.diffuse.contents = img
                }
                mat.isDoubleSided = true
            }
        }

        // ── Hierarchy: heading → lean → orient → center → geometry ──────────
        // Each layer applies one piece of the transform stack. Keeping them
        // separate lets us animate any one without clobbering the others.
        let center = SCNNode()
        for child in scene.rootNode.childNodes { center.addChildNode(child) }

        let (minBB, maxBB) = center.boundingBox
        let cx = (minBB.x + maxBB.x) * 0.5
        let cy = (minBB.y + maxBB.y) * 0.5
        let cz = (minBB.z + maxBB.z) * 0.5
        center.position = SCNVector3(-cx, -cy, -cz)

        let orient = SCNNode()
        orient.addChildNode(center)
        orient.rotation = Self.rotationMapping(forward: metadata.forwardAxis.vector,
                                               up:      metadata.upAxis.vector,
                                               targetForward: SCNVector3(0, 1, 0),
                                               targetUp:      SCNVector3(0, 0, 1))

        let lean = SCNNode()
        lean.addChildNode(orient)

        // Heading is the outermost rotation node. It also carries the uniform
        // scale that fits the model into our orthographic camera frustum.
        let heading = SCNNode()
        heading.addChildNode(lean)

        let extent = max(maxBB.x - minBB.x,
                         max(maxBB.y - minBB.y, maxBB.z - minBB.z))
        if extent > 0 {
            let s = 1.0 / Float(extent)
            heading.scale = SCNVector3(s, s, s)
        }
        scene.rootNode.addChildNode(heading)
        leanNode    = lean
        headingNode = heading

        // ── Camera ──────────────────────────────────────────────────────────
        // Orthographic top-down: looks down −Z onto the X-Y plane with +Y up.
        let cam            = SCNCamera()
        cam.usesOrthographicProjection = true
        cam.orthographicScale         = metadata.orthographicScale
        cam.zNear                     = 0.01
        cam.zFar                      = 50

        let camNode    = SCNNode()
        camNode.camera = cam
        camNode.position = SCNVector3(0, 0, 4)
        camNode.look(at: SCNVector3(0, 0, 0),
                     up: SCNVector3(0, 1, 0),
                     localFront: SCNVector3(0, 0, -1))
        scene.rootNode.addChildNode(camNode)
        scene.background.contents = nil

        // ── Lighting ────────────────────────────────────────────────────────
        // Modest intensities — the SCN default is 1000, and stacking three
        // bright sources washed materials to flat-white.
        func directional(intensity: Float, color: UIColor, from p: SCNVector3) -> SCNNode {
            let n     = SCNNode()
            n.light   = SCNLight()
            n.light!.type      = .directional
            n.light!.intensity = CGFloat(intensity)
            n.light!.color     = color
            n.position         = p
            n.look(at: SCNVector3(0, 0, 0),
                   up: SCNVector3(0, 1, 0),
                   localFront: SCNVector3(0, 0, -1))
            return n
        }
        scene.rootNode.addChildNode(directional(intensity: 450,
                                                color: UIColor(white: 1, alpha: 1),
                                                from:  SCNVector3(3, 4, 8)))
        let rimColor: UIColor = isLocalPlayer
            ? UIColor(red: 0.55, green: 0.85, blue: 1.0, alpha: 1)
            : UIColor(red: 1.0,  green: 0.75, blue: 0.55, alpha: 1)
        scene.rootNode.addChildNode(directional(intensity: 220,
                                                color: rimColor,
                                                from:  SCNVector3(-3, -4, 6)))

        let ambient       = SCNNode()
        ambient.light     = SCNLight()
        ambient.light!.type      = .ambient
        ambient.light!.intensity = 130
        scene.rootNode.addChildNode(ambient)

        // ── Map-center light ─────────────────────────────────────────────────
        // A directional light re-aimed each frame so it shines from the map
        // origin toward the ship. Casts shadows so the ship self-shadows.
        let centerL       = SCNNode()
        centerL.light     = SCNLight()
        centerL.light!.type        = .directional
        centerL.light!.intensity   = 850
        centerL.light!.color       = UIColor(red: 1.0, green: 0.92, blue: 0.75, alpha: 1) // warm sun
        centerL.light!.castsShadow = true
        centerL.light!.shadowMode  = .forward
        centerL.light!.shadowSampleCount = 8
        centerL.light!.shadowRadius      = 2
        centerL.light!.shadowColor = UIColor(white: 0, alpha: 0.55)
        scene.rootNode.addChildNode(centerL)
        centerLight = centerL

        let node3D       = SK3DNode(viewportSize: metadata.viewportSize)
        node3D.scnScene  = scene
        node3D.pointOfView = camNode
        return node3D
    }

    /// 2D fallback used if the usdc can't be loaded.
    private func makeFallback2D() -> SKNode {
        let modelColor: UIColor = isLocalPlayer ? .cyan : UIColor(white: 0.85, alpha: 1)
        let container = SKNode()

        let hull = CGMutablePath()
        hull.move(to:    CGPoint(x:  0,  y:  26))
        hull.addLine(to: CGPoint(x: -10, y: -18))
        hull.addLine(to: CGPoint(x:  10, y: -18))
        hull.closeSubpath()
        let hullShape         = SKShapeNode(path: hull)
        hullShape.fillColor   = modelColor
        hullShape.strokeColor = modelColor.withAlphaComponent(0.5)
        hullShape.lineWidth   = 1
        hullShape.glowWidth   = isLocalPlayer ? 5 : 0

        let wings = CGMutablePath()
        wings.move(to:    CGPoint(x: -10, y: -10))
        wings.addLine(to: CGPoint(x: -22, y: -20))
        wings.addLine(to: CGPoint(x:  -8, y: -18))
        wings.move(to:    CGPoint(x:  10, y: -10))
        wings.addLine(to: CGPoint(x:  22, y: -20))
        wings.addLine(to: CGPoint(x:   8, y: -18))
        let wingsShape         = SKShapeNode(path: wings)
        wingsShape.strokeColor = modelColor.withAlphaComponent(0.7)
        wingsShape.fillColor   = .clear
        wingsShape.lineWidth   = 2

        container.addChild(hullShape)
        container.addChild(wingsShape)
        return container
    }

    private func makeThrustEmitter() -> SKEmitterNode {
        let e = SKEmitterNode()
        e.particleBirthRate        = 0
        e.particleLifetime         = 0.22
        e.particleLifetimeRange    = 0.08
        e.particleSpeed            = 65
        e.particleSpeedRange       = 25
        e.particleSize             = CGSize(width: 5, height: 5)
        e.particleScaleSpeed       = -3
        e.particleColor            = isLocalPlayer ? .orange : UIColor(red: 0.5, green: 0.5, blue: 1, alpha: 1)
        e.particleColorBlendFactor = 1
        e.particleAlpha            = 0.85
        e.particleAlphaSpeed       = -3.5
        e.emissionAngleRange       = 0.35
        thrustEmitter = e
        return e
    }

    // MARK: – Update

    func update(from ship: ShipSnapshot, sunPosition: CGPoint = .zero) {
        position = CGPoint(x: CGFloat(ship.x), y: CGFloat(ship.y))
        heading           = CGFloat(ship.angle)
        velocityMagnitude = hypot(CGFloat(ship.velX), CGFloat(ship.velY))

        // Heading: for the 3D path, rotate the model around scene +Z inside
        // the SCN scene. For the 2D PNG path, there's no SCN headingNode —
        // we rotate the sprite directly.
        let yaw = ship.angle - .pi / 2
        if let headingNode = headingNode {
            headingNode.eulerAngles.z = yaw
        } else {
            visual.zRotation = CGFloat(yaw)
        }

        // Thrust emitter follows the ship's tail in world space. The emitter
        // is a 2D node, so we compute its rotated position and emission angle
        // manually rather than parenting it under a rotating container.
        let a       = CGFloat(ship.angle)
        let tailX   = -cos(a) * thrustDistance
        let tailY   = -sin(a) * thrustDistance
        thrustEmitter?.position         = CGPoint(x: tailX, y: tailY)
        thrustEmitter?.emissionAngle    = a + .pi
        thrustEmitter?.particleBirthRate = ship.thrusting ? 90 : 0

        aimCenterLight(shipX: ship.x, shipY: ship.y,
                       sunX:  Float(sunPosition.x),
                       sunY:  Float(sunPosition.y))

        updatePNGLighting(sunPosition: sunPosition)

        alpha    = ship.dead ? 0 : 1
        isHidden = false
    }

    /// Recompute the sun direction in the sprite's texture frame and push it
    /// to the lighting shader. The sprite rotates with heading; the shadow
    /// side must stay anchored to the world-space sun direction, so the
    /// value changes whenever heading or relative sun position changes.
    private func updatePNGLighting(sunPosition: CGPoint) {
        guard let sprite = pngLitSprite else { return }
        let dx = sunPosition.x - position.x
        let dy = sunPosition.y - position.y
        let sunWorldAngle = atan2(dy, dx)
        // Sprite is rotated by visual.zRotation; convert sun direction into
        // the texture's local frame.
        let texAngle = sunWorldAngle - sprite.zRotation
        sprite.setValue(
            SKAttributeValue(vectorFloat2: vector_float2(
                Float(cos(texAngle)),
                Float(sin(texAngle))
            )),
            forAttribute: "a_lightDir"
        )
    }

    /// Aim the directional light inside the ship's SCN scene so it points
    /// FROM the sun's world position TOWARD the ship. The face of the ship
    /// nearest the sun is lit; self-shadows fall on the opposite side.
    private func aimCenterLight(shipX: Float, shipY: Float,
                                sunX: Float,  sunY: Float) {
        guard let light = centerLight else { return }
        let dx  = sunX - shipX
        let dy  = sunY - shipY
        let mag = sqrt(dx * dx + dy * dy)
        let height: Float = 1.5
        if mag > 0.001 {
            // Directional light — only orientation matters. Position is just
            // any point in the desired direction.
            let scale: Float = 3.0 / mag
            light.position = SCNVector3(dx * scale, dy * scale, height)
        } else {
            // Ship is sitting on top of the sun. Light it from straight above.
            light.position = SCNVector3(0, 0, height)
        }
        light.look(at: SCNVector3(0, 0, 0),
                   up: SCNVector3(0, 0, 1),
                   localFront: SCNVector3(0, 0, -1))
    }

    /// Banks the 3D ship around its nose axis (roll) when turning. No-op on
    /// the PNG ship — a flat sprite can't roll in any way that reads as a
    /// bank, so we just leave it alone.
    func applyLean(_ amount: Float) {
        // Negative sign so the inside wing dips into the turn (lean into the
        // turn, not out of it).
        leanNode?.eulerAngles.y = -amount * 0.35
    }

    // MARK: – Math

    /// Returns an SCNVector4 axis-angle rotation that maps the local frame
    /// (forward, up) onto the target frame (targetForward, targetUp).
    private static func rotationMapping(forward f1: SCNVector3, up u1: SCNVector3,
                                        targetForward f2: SCNVector3, targetUp u2: SCNVector3) -> SCNVector4 {
        let r1  = normalize(cross(f1, u1))
        let u1c = normalize(cross(r1, f1))
        let f1n = normalize(f1)

        let r2  = normalize(cross(f2, u2))
        let u2c = normalize(cross(r2, f2))
        let f2n = normalize(f2)

        let m = matrixMultiply(
            cols: (r2, u2c, f2n),
            byTransposeCols: (r1, u1c, f1n)
        )
        return rotationVectorFromMatrix(m)
    }

    private static func normalize(_ v: SCNVector3) -> SCNVector3 {
        let len = sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
        return len > 1e-6 ? SCNVector3(v.x / len, v.y / len, v.z / len) : v
    }

    private static func cross(_ a: SCNVector3, _ b: SCNVector3) -> SCNVector3 {
        SCNVector3(a.y * b.z - a.z * b.y,
                   a.z * b.x - a.x * b.z,
                   a.x * b.y - a.y * b.x)
    }

    private static func matrixMultiply(cols a: (SCNVector3, SCNVector3, SCNVector3),
                                       byTransposeCols b: (SCNVector3, SCNVector3, SCNVector3)) -> [[Float]] {
        let A0 = a.0, A1 = a.1, A2 = a.2
        let B0 = b.0, B1 = b.1, B2 = b.2

        func col(_ c: SCNVector3, _ row: Int) -> Float {
            switch row { case 0: return c.x; case 1: return c.y; default: return c.z }
        }

        var m = Array(repeating: Array(repeating: Float(0), count: 3), count: 3)
        for i in 0..<3 {
            let Ai = (col(A0, i), col(A1, i), col(A2, i))
            for j in 0..<3 {
                let Bj = (col(B0, j), col(B1, j), col(B2, j))
                m[i][j] = Ai.0 * Bj.0 + Ai.1 * Bj.1 + Ai.2 * Bj.2
            }
        }
        return m
    }

    // Internal so ShipyardScene can call it without duplicating the USDC path.
    static func rotationMappingInternal(forward: SCNVector3, up: SCNVector3,
                                        targetForward: SCNVector3, targetUp: SCNVector3) -> SCNVector4 {
        rotationMapping(forward: forward, up: up,
                        targetForward: targetForward, targetUp: targetUp)
    }

    // MARK: – Static thumbnail (used by ShipyardScene)

    /// Returns a static, non-animated visual node sized to `viewportSize`.
    /// PNG ships → plain SKSpriteNode. USDC ships → SK3DNode with basic lighting.
    static func staticThumbnail(metadata: ShipMetadata, viewportSize: CGSize) -> SKNode {
        switch metadata.assetKind {
        case .png:
            if let url = Bundle.main.url(forResource: metadata.assetName,
                                         withExtension: "png",
                                         subdirectory: metadata.assetSubdirectory),
               let image = UIImage(contentsOfFile: url.path) {
                let sprite = SKSpriteNode(texture: SKTexture(image: image))
                sprite.size = viewportSize
                return sprite
            }
        case .usdc:
            if let node3D = makeStaticUSDC(metadata: metadata, viewportSize: viewportSize) {
                return node3D
            }
        }
        let fallback = SKShapeNode(rectOf: viewportSize, cornerRadius: 4)
        fallback.fillColor   = UIColor(white: 0.08, alpha: 1)
        fallback.strokeColor = UIColor(white: 0.30, alpha: 0.5)
        return fallback
    }

    private static func makeStaticUSDC(metadata: ShipMetadata, viewportSize: CGSize) -> SK3DNode? {
        guard let url = Bundle.main.url(forResource: metadata.assetName,
                                        withExtension: "usdc",
                                        subdirectory: metadata.assetSubdirectory)
        else { return nil }

        let options: [SCNSceneSource.LoadingOption: Any] = [
            .checkConsistency:   false,
            .assetDirectoryURLs: [url.deletingLastPathComponent()],
        ]
        guard let scene = try? SCNScene(url: url, options: options) else { return nil }

        let diffuseURL   = url.deletingLastPathComponent().appendingPathComponent("Image_0.jpg")
        let diffuseImage = UIImage(contentsOfFile: diffuseURL.path)
        scene.rootNode.enumerateChildNodes { node, _ in
            node.geometry?.materials.forEach { mat in
                mat.lightingModel = .blinn
                if !(mat.diffuse.contents is UIImage), let img = diffuseImage {
                    mat.diffuse.contents = img
                }
                mat.isDoubleSided = true
            }
        }

        let center = SCNNode()
        for child in scene.rootNode.childNodes { center.addChildNode(child) }
        let (minBB, maxBB) = center.boundingBox
        center.position = SCNVector3(-(minBB.x + maxBB.x) * 0.5,
                                     -(minBB.y + maxBB.y) * 0.5,
                                     -(minBB.z + maxBB.z) * 0.5)

        let orient = SCNNode()
        orient.addChildNode(center)
        orient.rotation = rotationMapping(forward: metadata.forwardAxis.vector,
                                          up:      metadata.upAxis.vector,
                                          targetForward: SCNVector3(0, 1, 0),
                                          targetUp:      SCNVector3(0, 0, 1))

        let root = SCNNode()
        root.addChildNode(orient)
        let extent = max(maxBB.x - minBB.x, max(maxBB.y - minBB.y, maxBB.z - minBB.z))
        if extent > 0 { let s = 1.0 / Float(extent); root.scale = SCNVector3(s, s, s) }
        scene.rootNode.addChildNode(root)

        let cam = SCNCamera()
        cam.usesOrthographicProjection = true
        cam.orthographicScale = metadata.orthographicScale
        cam.zNear = 0.01; cam.zFar = 50
        let camNode = SCNNode()
        camNode.camera = cam
        camNode.position = SCNVector3(0, 0, 4)
        camNode.look(at: SCNVector3(0, 0, 0), up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
        scene.rootNode.addChildNode(camNode)
        scene.background.contents = nil

        func light(_ intensity: Float, _ color: UIColor, from pos: SCNVector3) -> SCNNode {
            let n = SCNNode(); n.light = SCNLight()
            n.light!.type = .directional; n.light!.intensity = CGFloat(intensity); n.light!.color = color
            n.position = pos
            n.look(at: SCNVector3(0, 0, 0), up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
            return n
        }
        scene.rootNode.addChildNode(light(450, .white,
                                          from: SCNVector3(3, 4, 8)))
        scene.rootNode.addChildNode(light(220, UIColor(red: 0.55, green: 0.85, blue: 1, alpha: 1),
                                          from: SCNVector3(-3, -4, 6)))
        let ambient = SCNNode(); ambient.light = SCNLight()
        ambient.light!.type = .ambient; ambient.light!.intensity = 130
        scene.rootNode.addChildNode(ambient)

        let node3D = SK3DNode(viewportSize: viewportSize)
        node3D.scnScene = scene
        node3D.pointOfView = camNode
        return node3D
    }

    private static func rotationVectorFromMatrix(_ m: [[Float]]) -> SCNVector4 {
        let trace = m[0][0] + m[1][1] + m[2][2]
        let cosA  = max(-1, min(1, (trace - 1) * 0.5))
        let angle = acos(cosA)

        if angle < 1e-5 {
            return SCNVector4(0, 1, 0, 0)
        }

        if angle > Float.pi - 1e-3 {
            // 180° rotation: off-diagonal formula degenerates to zero.
            // Use M + I = 2·n·nᵀ → n_i² = (M[i][i] + 1) / 2.
            let nx2 = max(0, (m[0][0] + 1) * 0.5)
            let ny2 = max(0, (m[1][1] + 1) * 0.5)
            let nz2 = max(0, (m[2][2] + 1) * 0.5)
            if nx2 >= ny2 && nx2 >= nz2 {
                let nx = sqrt(nx2)
                let ny = nx > 0 ? m[0][1] / (2 * nx) : sqrt(ny2)
                let nz = nx > 0 ? m[0][2] / (2 * nx) : sqrt(nz2)
                return SCNVector4(nx, ny, nz, .pi)
            } else if ny2 >= nz2 {
                let ny = sqrt(ny2)
                let nx = m[0][1] / (2 * ny)
                let nz = m[1][2] / (2 * ny)
                return SCNVector4(nx, ny, nz, .pi)
            } else {
                let nz = sqrt(nz2)
                let nx = m[0][2] / (2 * nz)
                let ny = m[1][2] / (2 * nz)
                return SCNVector4(nx, ny, nz, .pi)
            }
        }

        let sinA  = sin(angle)
        let denom = 2 * sinA
        let x = (m[2][1] - m[1][2]) / denom
        let y = (m[0][2] - m[2][0]) / denom
        let z = (m[1][0] - m[0][1]) / denom
        return SCNVector4(x, y, z, angle)
    }
}
