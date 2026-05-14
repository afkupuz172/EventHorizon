import SpriteKit
import SceneKit
import UIKit

/// Builds a playable solar system from a JSON config.
///
/// Every celestial body is a `CelestialBodyNode` (an addressable SKNode
/// subclass) holding the metadata needed for tap-to-select + the radar HUD.
/// Sun and planets are static 2D sprites with no animation. Asteroids spin
/// in 2D via `SKAction.rotate(byAngle:)`.
@MainActor
final class SolarSystem {

    let config: SolarSystemConfig

    /// World position of the first sun in the config. `GameScene` reads this
    /// to point each ship's directional light at the actual star.
    var primarySunPosition: CGPoint? {
        config.suns.first.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
    }

    /// All celestial bodies after `install(...)` — used by the HUD for
    /// tap-to-select hit testing and the mini-map.
    private(set) var bodies: [CelestialBodyNode] = []

    var sunPositions:    [CGPoint] { bodies.filter { $0.kind == .sun    }.map(\.position) }
    var planetPositions: [CGPoint] { bodies.filter { $0.kind == .planet }.map(\.position) }

    /// Cached PNG textures keyed by the sprite basename used in the JSON
    /// config. Loaded lazily on first reference.
    private var spriteTextures: [String: SKTexture] = [:]
    private var asteroidTextures: [SKTexture] = []
    private var asteroidCounter = 0

    init?(name: String) {
        guard let cfg = SolarSystemConfig.load(name: name) else { return nil }
        config = cfg
    }

    func install(into layer: SKNode) {
        installSuns(into:    layer)
        installPlanets(into: layer)
        installAsteroids(into: layer)
    }

    // MARK: – Suns

    private func installSuns(into layer: SKNode) {
        for (i, sunCfg) in config.suns.enumerated() {
            let body = makeSunBody(
                sprite:      sunCfg.sprite,
                radius:      CGFloat(sunCfg.radius),
                displayName: sunCfg.displayName ?? "Star \(i + 1)"
            )
            body.position  = CGPoint(x: CGFloat(sunCfg.x), y: CGFloat(sunCfg.y))
            body.zPosition = 0
            layer.addChild(body)
            bodies.append(body)
        }
    }

    private func makeSunBody(sprite: String,
                             radius: CGFloat,
                             displayName: String) -> CelestialBodyNode {
        let body = CelestialBodyNode(kind:            .sun,
                                     displayName:    displayName,
                                     typeDescription: "Stellar mass",
                                     radius:          radius)

        // Outer corona — large, dim, warm-orange.
        let outer       = SKSpriteNode(texture: Self.makeGlowTexture(
            color: UIColor(red: 1.0, green: 0.50, blue: 0.18, alpha: 1)
        ))
        outer.size      = CGSize(width: radius * 5.5, height: radius * 5.5)
        outer.blendMode = .add
        outer.alpha     = 0.45
        body.addChild(outer)

        // Inner corona — brighter, warm-yellow, just outside the disc.
        let inner       = SKSpriteNode(texture: Self.makeGlowTexture(
            color: UIColor(red: 1.0, green: 0.85, blue: 0.50, alpha: 1)
        ))
        inner.size      = CGSize(width: radius * 2.8, height: radius * 2.8)
        inner.blendMode = .add
        inner.alpha     = 0.65
        body.addChild(inner)

        if let texture = loadSpriteTexture(named: sprite) {
            let disc  = SKSpriteNode(texture: texture)
            disc.size = sizePreservingAspect(of: texture, width: radius * 2)
            body.addChild(disc)
        }
        return body
    }

    // MARK: – Planets

    private func installPlanets(into layer: SKNode) {
        for (i, p) in config.planets.enumerated() {
            let angle    = CGFloat.random(in: 0...(2 * .pi))
            let position = CGPoint(
                x: CGFloat(p.centerX) + cos(angle) * CGFloat(p.orbitDistance),
                y: CGFloat(p.centerY) + sin(angle) * CGFloat(p.orbitDistance)
            )
            guard let body = makePlanetBody(
                config: p,
                displayName: p.displayName ?? "Planet \(i + 1)"
            )
            else { continue }
            body.position  = position
            body.zPosition = 1
            layer.addChild(body)
            bodies.append(body)
        }
    }

    private func makePlanetBody(config: PlanetConfig,
                                displayName: String) -> CelestialBodyNode? {
        guard let texture = loadSpriteTexture(named: config.sprite) else {
            print("[SolarSystem] missing planet sprite \"\(config.sprite).png\"")
            return nil
        }
        let body = CelestialBodyNode(
            kind:            .planet,
            displayName:    displayName,
            typeDescription: prettyTypeDescription(from: config.sprite),
            radius:          CGFloat(config.radius)
        )

        let r = CGFloat(config.radius)
        let atmos       = SKSpriteNode(texture: Self.makeGlowTexture(
            color: UIColor(red: 0.55, green: 0.80, blue: 1.0, alpha: 1)
        ))
        atmos.size      = CGSize(width: r * 2.7, height: r * 2.7)
        atmos.blendMode = .add
        atmos.alpha     = 0.35
        body.addChild(atmos)

        let disc  = SKSpriteNode(texture: texture)
        disc.size = sizePreservingAspect(of: texture, width: r * 2)
        body.addChild(disc)

        return body
    }

    /// Compute a render size that preserves the texture's intrinsic aspect
    /// ratio. Prevents non-square PNGs from being stretched into ovals.
    private func sizePreservingAspect(of texture: SKTexture, width: CGFloat) -> CGSize {
        let texSize = texture.size()
        guard texSize.width > 0 else {
            return CGSize(width: width, height: width)
        }
        let aspect = texSize.height / texSize.width
        return CGSize(width: width, height: width * aspect)
    }

    /// `"rock_planet"` → `"Rock planet"`.
    private func prettyTypeDescription(from sprite: String) -> String {
        let words = sprite.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// Load a PNG by basename from `Art.scnassets/celestial_bodies/`. Cached
    /// so two suns of the same sprite share one GPU texture.
    private func loadSpriteTexture(named name: String) -> SKTexture? {
        if let cached = spriteTextures[name] { return cached }
        guard let url = Bundle.main.url(
            forResource:  name,
            withExtension: "png",
            subdirectory: "Art.scnassets/celestial_bodies"
        ),
        let image = UIImage(contentsOfFile: url.path)
        else {
            print("[SolarSystem] missing PNG: Art.scnassets/celestial_bodies/\(name).png")
            return nil
        }
        let texture = SKTexture(image: image)
        spriteTextures[name] = texture
        return texture
    }

    // MARK: – Asteroids

    private func installAsteroids(into layer: SKNode) {
        bakeAsteroidTexturesIfNeeded()
        guard !asteroidTextures.isEmpty else { return }

        let cfg = config.asteroids
        for _ in 0..<cfg.count {
            guard let texture = asteroidTextures.randomElement() else { continue }
            asteroidCounter += 1
            let diameter = CGFloat.random(in: CGFloat(cfg.minRadius)...CGFloat(cfg.maxRadius)) * 2
            let body = CelestialBodyNode(
                kind:            .asteroid,
                displayName:    "Asteroid \(asteroidCounter)",
                typeDescription: "Rocky debris",
                radius:          diameter / 2
            )
            body.position  = CGPoint(
                x: CGFloat.random(in: -CGFloat(cfg.spreadRadius)...CGFloat(cfg.spreadRadius)),
                y: CGFloat.random(in: -CGFloat(cfg.spreadRadius)...CGFloat(cfg.spreadRadius))
            )
            body.zPosition = 2

            // The sprite (visible mesh) spins; its parent body stays
            // axis-aligned so the selection bracket reads correctly.
            let sprite       = SKSpriteNode(texture: texture)
            sprite.size      = CGSize(width: diameter, height: diameter)
            sprite.zRotation = CGFloat.random(in: 0...(2 * .pi))
            let period       = TimeInterval(CGFloat.random(in: CGFloat(cfg.minSpinPeriod)...CGFloat(cfg.maxSpinPeriod)))
            let direction: CGFloat = Bool.random() ? 1 : -1
            sprite.run(.repeatForever(
                .rotate(byAngle: direction * 2 * .pi, duration: period)
            ))
            body.addChild(sprite)

            layer.addChild(body)
            bodies.append(body)
        }
    }

    // MARK: – Asteroid texture baking
    // (Sun and planet are PNG-based; only asteroids still come from USDZ.)

    private func bakeAsteroidTexturesIfNeeded() {
        guard asteroidTextures.isEmpty else { return }
        let meshes = CelestialBodyAssets.shared.asteroidMeshes()
        asteroidTextures = Array(meshes.shuffled().prefix(6)).compactMap { mesh in
            renderStillTexture(
                model:             mesh,
                tilt:              SCNVector3(
                    Float.random(in: 0...(2 * .pi)),
                    Float.random(in: 0...(2 * .pi)),
                    Float.random(in: 0...(2 * .pi))
                ),
                textureSize:       256,
                keyLightDirection: (3, 4, 5),
                keyLightIntensity: 700,
                ambientIntensity:  180
            )
        }
    }

    /// Render an SCNNode to a single still SKTexture via offscreen SCNRenderer.
    /// Centers + unit-scales the model, sets up a top-down orthographic camera,
    /// applies the HDR lighting environment, and snapshots once.
    private func renderStillTexture(
        model:             SCNNode,
        tilt:              SCNVector3,
        textureSize:       CGFloat,
        keyLightDirection: (Float, Float, Float)? = (3, 4, 5),
        keyLightIntensity: CGFloat = 700,
        ambientIntensity:  CGFloat = 180
    ) -> SKTexture? {
        let scene = SCNScene()

        let clone = model.clone()
        let (minBB, maxBB) = clone.boundingBox
        let cx = (minBB.x + maxBB.x) * 0.5
        let cy = (minBB.y + maxBB.y) * 0.5
        let cz = (minBB.z + maxBB.z) * 0.5
        let extent = max(maxBB.x - minBB.x,
                         max(maxBB.y - minBB.y, maxBB.z - minBB.z))

        let centerer = SCNNode()
        clone.position = SCNVector3(-cx, -cy, -cz)
        centerer.addChildNode(clone)
        if extent > 0 {
            let s = 1.0 / Float(extent)
            centerer.scale = SCNVector3(s, s, s)
        }
        let tiltNode = SCNNode()
        tiltNode.eulerAngles = tilt
        tiltNode.addChildNode(centerer)
        scene.rootNode.addChildNode(tiltNode)

        let cam = SCNCamera()
        cam.usesOrthographicProjection = true
        cam.orthographicScale          = 0.55
        cam.zNear                      = 0.01
        cam.zFar                       = 50
        let camNode    = SCNNode()
        camNode.camera = cam
        camNode.position = SCNVector3(0, 0, 4)
        camNode.look(at:        SCNVector3(0, 0, 0),
                     up:        SCNVector3(0, 1, 0),
                     localFront: SCNVector3(0, 0, -1))
        scene.rootNode.addChildNode(camNode)
        scene.background.contents = UIColor.clear

        if let hdr = CelestialBodyAssets.shared.hdrEnvironmentURL {
            scene.lightingEnvironment.contents  = hdr
            scene.lightingEnvironment.intensity = 1.0
        }
        if keyLightIntensity > 0, let (lx, ly, lz) = keyLightDirection {
            let key       = SCNNode()
            key.light     = SCNLight()
            key.light!.type      = .directional
            key.light!.intensity = keyLightIntensity
            key.position         = SCNVector3(lx, ly, lz)
            key.look(at:        SCNVector3(0, 0, 0),
                     up:        SCNVector3(0, 1, 0),
                     localFront: SCNVector3(0, 0, -1))
            scene.rootNode.addChildNode(key)
        }
        let ambient       = SCNNode()
        ambient.light     = SCNLight()
        ambient.light!.type      = .ambient
        ambient.light!.intensity = ambientIntensity
        scene.rootNode.addChildNode(ambient)

        let renderer    = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene  = scene
        renderer.pointOfView = camNode
        let image = renderer.snapshot(
            atTime: 0,
            with:   CGSize(width: textureSize, height: textureSize),
            antialiasingMode: .multisampling4X
        )
        return SKTexture(image: image)
    }

    // MARK: – Glow texture

    /// Soft radial-gradient glow with smooth multi-stop falloff. Used as the
    /// sun's corona layers and the planets' atmospheric halos.
    private static func makeGlowTexture(color: UIColor) -> SKTexture {
        let pixelSize: CGFloat = 512
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
                color.withAlphaComponent(1.0).cgColor,
                color.withAlphaComponent(0.70).cgColor,
                color.withAlphaComponent(0.35).cgColor,
                color.withAlphaComponent(0.12).cgColor,
                color.withAlphaComponent(0.03).cgColor,
                color.withAlphaComponent(0.0).cgColor,
            ]
            let locations: [CGFloat] = [0.0, 0.18, 0.42, 0.68, 0.88, 1.0]
            let space = CGColorSpaceCreateDeviceRGB()
            if let g = CGGradient(colorsSpace: space,
                                  colors:      stops as CFArray,
                                  locations:   locations) {
                cg.drawRadialGradient(g,
                                      startCenter: center, startRadius: 0,
                                      endCenter:   center, endRadius:   maxR,
                                      options: [])
            }
        }
        return SKTexture(image: img)
    }
}
