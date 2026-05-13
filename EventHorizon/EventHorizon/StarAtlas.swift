import SpriteKit
import UIKit

/// Catalog of procedurally-rendered star sprites.
///
/// Each variant is a small radial-gradient bloom drawn into a Core Graphics
/// context once at startup. Bright stars also get a soft cross-shaped lens
/// flare. The textures are stamped onto `SKSpriteNode`s and additively blended
/// in `GameScene` to give the starfield a high-dynamic-range feel without
/// requiring any external assets.
enum StarVariant: CaseIterable {
    case pinprick       // tiny tight Gaussian dot — no halo, no flare. The bulk.
    case dimWhite       // small, low-contrast bloom
    case mediumWhite    // workhorse, most "real" stars
    case brightWhite    // featured, with cross flare
    case blueGiant      // hot blue-white, cross flare
    case yellowSun      // sun-like
    case redGiant       // warm red, soft halo
}

@MainActor
struct StarAtlas {

    static let shared: StarAtlas = StarAtlas()
    let textures: [StarVariant: SKTexture]

    private init() {
        var map: [StarVariant: SKTexture] = [:]
        for v in StarVariant.allCases {
            map[v] = Self.makeTexture(for: v)
        }
        textures = map
    }

    // MARK: – Rendering

    private struct Style {
        let size:     CGFloat   // pixel diameter of the texture
        let core:     UIColor   // center color (saturates to white at the very middle)
        let halo:     UIColor   // outer falloff color
        let coreFraction: CGFloat   // 0…1, how much of the radius is the saturated core
        let hasFlare: Bool
        let flareIntensity: CGFloat
    }

    private static func style(for v: StarVariant) -> Style {
        // Hero-tier (`brightWhite`, `blueGiant`, `yellowSun`, `redGiant`) need
        // a LOT of source pixels to stay crisp at max zoom-in (camera xScale
        // 0.35 ⇒ retina display ≈ 8.6× the texture point size). The bloom
        // renderer uses `format.scale = 6` (see below), so e.g. a hero with
        // `size = 220` ends up with 1320 source pixels per axis.
        switch v {
        case .pinprick:
            // Effectively unused — pinpricks go through `makePinprickTexture`
            // below. Returned style is a placeholder so the switch is total.
            return Style(size: 32, core: .white, halo: .white,
                         coreFraction: 0.20, hasFlare: false, flareIntensity: 0)
        case .dimWhite:
            return Style(size: 56, core: .white,
                         halo: UIColor(white: 0.9, alpha: 1),
                         coreFraction: 0.05, hasFlare: false, flareIntensity: 0)
        case .mediumWhite:
            return Style(size: 96, core: .white,
                         halo: UIColor(white: 0.92, alpha: 1),
                         coreFraction: 0.05, hasFlare: false, flareIntensity: 0)
        case .brightWhite:
            return Style(size: 220, core: .white,
                         halo: UIColor(white: 0.95, alpha: 1),
                         coreFraction: 0.04, hasFlare: true, flareIntensity: 0.55)
        case .blueGiant:
            return Style(size: 220,
                         core: UIColor(red: 0.85, green: 0.95, blue: 1.0,  alpha: 1),
                         halo: UIColor(red: 0.45, green: 0.70, blue: 1.0,  alpha: 1),
                         coreFraction: 0.04, hasFlare: true, flareIntensity: 0.6)
        case .yellowSun:
            return Style(size: 180,
                         core: UIColor(red: 1.0,  green: 0.96, blue: 0.78, alpha: 1),
                         halo: UIColor(red: 1.0,  green: 0.80, blue: 0.40, alpha: 1),
                         coreFraction: 0.05, hasFlare: false, flareIntensity: 0)
        case .redGiant:
            return Style(size: 180,
                         core: UIColor(red: 1.0,  green: 0.78, blue: 0.55, alpha: 1),
                         halo: UIColor(red: 1.0,  green: 0.40, blue: 0.25, alpha: 1),
                         coreFraction: 0.04, hasFlare: false, flareIntensity: 0)
        }
    }

    private static func makeTexture(for v: StarVariant) -> SKTexture {
        if v == .pinprick { return makePinprickTexture() }
        let s = style(for: v)
        let canvas = CGSize(width: s.size, height: s.size)

        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale  = 6       // @6x bloom — heroes stay crisp at max zoom-in
        fmt.opaque = false

        let renderer = UIGraphicsImageRenderer(size: canvas, format: fmt)
        let img = renderer.image { ctx in
            let cg     = ctx.cgContext
            let center = CGPoint(x: s.size / 2, y: s.size / 2)
            let maxR   = s.size / 2

            // Radial bloom approximating a Gaussian falloff:
            //   • tight white-hot core (saturates to white at the very middle)
            //   • rapid drop through the tinted body
            //   • long soft tail to halo color, fading to fully transparent
            // The extra interior stops smooth the falloff so we don't get
            // visible banding in the gradient.
            let stops: [CGColor] = [
                UIColor.white.withAlphaComponent(1.0).cgColor,
                UIColor.white.withAlphaComponent(0.92).cgColor,
                s.core.withAlphaComponent(0.65).cgColor,
                s.core.withAlphaComponent(0.30).cgColor,
                s.halo.withAlphaComponent(0.12).cgColor,
                s.halo.withAlphaComponent(0.04).cgColor,
                s.halo.withAlphaComponent(0.0).cgColor,
            ]
            let locations: [CGFloat] = [
                0.0,
                s.coreFraction * 0.5,
                s.coreFraction,
                s.coreFraction + 0.12,
                0.40,
                0.75,
                1.0,
            ]
            let space = CGColorSpaceCreateDeviceRGB()
            if let g = CGGradient(colorsSpace: space, colors: stops as CFArray, locations: locations) {
                cg.drawRadialGradient(g,
                                      startCenter: center, startRadius: 0,
                                      endCenter:   center, endRadius:   maxR,
                                      options: [])
            }

            if s.hasFlare {
                drawCrossFlare(in: cg, size: s.size, color: s.core, intensity: s.flareIntensity)
            }
        }
        return SKTexture(image: img)
    }

    /// Soft 4-point diffraction spike, additive over the existing bloom.
    ///
    /// Each spike is rendered as a radial gradient stretched along one axis,
    /// so the falloff is smooth in BOTH directions — no hard clipped edges
    /// that visibly pixelate when the camera zooms in on the hero star.
    private static func drawCrossFlare(in cg: CGContext, size: CGFloat,
                                       color: UIColor, intensity: CGFloat) {
        cg.saveGState()
        cg.setBlendMode(.plusLighter)

        let length    = size * 0.95
        let thickness = max(2.0, size * 0.05)
        let center    = size / 2

        let stops: [CGColor] = [
            color.withAlphaComponent(intensity).cgColor,
            color.withAlphaComponent(intensity * 0.50).cgColor,
            color.withAlphaComponent(intensity * 0.18).cgColor,
            color.withAlphaComponent(0).cgColor,
        ]
        let locations: [CGFloat] = [0.0, 0.35, 0.65, 1.0]
        let space = CGColorSpaceCreateDeviceRGB()
        guard let g = CGGradient(colorsSpace: space, colors: stops as CFArray, locations: locations)
        else { cg.restoreGState(); return }

        // Each spike: translate to star center, anisotropically scale so a
        // circular radial gradient becomes a thin elongated ellipse with
        // smooth alpha falloff everywhere — no clipped rectangle edges.
        func drawSpike(scaleX: CGFloat, scaleY: CGFloat) {
            cg.saveGState()
            cg.translateBy(x: center, y: center)
            cg.scaleBy(x: scaleX, y: scaleY)
            cg.drawRadialGradient(g,
                                  startCenter: .zero, startRadius: 0,
                                  endCenter:   .zero, endRadius:   length / 2,
                                  options: [])
            cg.restoreGState()
        }
        let stretch = thickness / length
        drawSpike(scaleX: 1.0,     scaleY: stretch)   // horizontal
        drawSpike(scaleX: stretch, scaleY: 1.0)       // vertical

        cg.restoreGState()
    }

    /// Pinprick — a tight Gaussian-like dot with no halo or flare. The hot
    /// center is sub-pixel small so even at extreme zoom it reads as a single
    /// bright point, not a circle.
    private static func makePinprickTexture() -> SKTexture {
        // Compact texture — 128 source pixels at @4x. Small enough that even
        // at max scale on the far layer it's downsampled (= crisp), not
        // upsampled (= blurry).
        let size: CGFloat = 32
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale  = 4
        fmt.opaque = false
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: size, height: size), format: fmt)
        let img = renderer.image { ctx in
            let cg     = ctx.cgContext
            let center = CGPoint(x: size / 2, y: size / 2)
            let maxR   = size / 2

            // Tight core dominant gradient — the inner 20% is fully opaque
            // white, so the pinprick reads as a definite dot at any display
            // size instead of a soft fuzz. Tail to zero is short.
            let stops: [CGColor] = [
                UIColor.white.withAlphaComponent(1.0).cgColor,
                UIColor.white.withAlphaComponent(1.0).cgColor,
                UIColor.white.withAlphaComponent(0.55).cgColor,
                UIColor.white.withAlphaComponent(0.10).cgColor,
                UIColor.white.withAlphaComponent(0.0).cgColor,
            ]
            let locations: [CGFloat] = [0.0, 0.18, 0.35, 0.65, 1.0]
            let space = CGColorSpaceCreateDeviceRGB()
            if let g = CGGradient(colorsSpace: space, colors: stops as CFArray, locations: locations) {
                cg.drawRadialGradient(g,
                                      startCenter: center, startRadius: 0,
                                      endCenter:   center, endRadius:   maxR,
                                      options: [])
            }
        }
        return SKTexture(image: img)
    }
}
