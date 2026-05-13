import SpriteKit
import SceneKit

final class ShipNode: SKNode {

    private let metadata:      ShipMetadata
    private let isLocalPlayer: Bool

    private var visual:       SKNode!
    private var thrustEmitter: SKEmitterNode?

    // SCN nodes whose Euler angles we tweak each frame.
    private weak var headingNode: SCNNode?   // yaw   — rotates around scene +Z
    private weak var leanNode:    SCNNode?   // roll  — rotates around scene +Y (nose axis)
    private weak var centerLight: SCNNode?   // re-aimed each frame to point from map origin

    /// Distance from ship center to where the thrust emitter mounts.
    private var thrustDistance: CGFloat = 40

    init(isLocalPlayer: Bool, metadata: ShipMetadata = .spaceship1) {
        self.isLocalPlayer = isLocalPlayer
        self.metadata      = metadata
        super.init()

        if let mount = metadata.thrustMounts.first {
            thrustDistance = abs(mount.bodyPoint.y)
        }

        setupVisual()
        addChild(visual)
        addChild(makeThrustEmitter())
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: – Setup

    private func setupVisual() {
        if let node3D = makeShipSceneNode() {
            visual = node3D
        } else {
            visual = makeFallback2D()
        }
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

    func update(from ship: ShipSnapshot) {
        position = CGPoint(x: CGFloat(ship.x), y: CGFloat(ship.y))

        // Heading: rotate the 3D model around scene +Z so the nose (which sits
        // at scene +Y after orientation) points along the world heading.
        let yaw = ship.angle - .pi / 2
        headingNode?.eulerAngles.z = yaw

        // Thrust emitter follows the ship's tail in world space. The emitter
        // is a 2D node, so we compute its rotated position and emission angle
        // manually rather than parenting it under a rotating container.
        let a       = CGFloat(ship.angle)
        let tailX   = -cos(a) * thrustDistance
        let tailY   = -sin(a) * thrustDistance
        thrustEmitter?.position         = CGPoint(x: tailX, y: tailY)
        thrustEmitter?.emissionAngle    = a + .pi
        thrustEmitter?.particleBirthRate = ship.thrusting ? 90 : 0

        aimCenterLight(shipX: ship.x, shipY: ship.y)

        alpha    = ship.dead ? 0 : 1
        isHidden = false
    }

    /// Aim the map-center directional light so it points FROM world origin
    /// TOWARD the ship. The face of the ship nearest the map center is lit.
    private func aimCenterLight(shipX: Float, shipY: Float) {
        guard let light = centerLight else { return }
        // Place the light "above" the map origin relative to the ship. Distance
        // doesn't matter for a directional light — only the orientation does.
        let dx = -shipX
        let dy = -shipY
        let mag = sqrt(dx * dx + dy * dy)
        let height: Float = 1.5
        if mag > 0.001 {
            let scale: Float = 3.0 / mag
            light.position = SCNVector3(dx * scale, dy * scale, height)
        } else {
            light.position = SCNVector3(0, 0, height)
        }
        light.look(at: SCNVector3(0, 0, 0),
                   up: SCNVector3(0, 0, 1),
                   localFront: SCNVector3(0, 0, -1))
    }

    /// Banks the 3D model around its nose axis (roll) when turning, giving the
    /// classic "lean into turns" feel. No-op on the 2D fallback.
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
