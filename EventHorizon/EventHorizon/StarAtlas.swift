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
    case dimWhite       // small, low-contrast — fills the far field
    case mediumWhite    // workhorse, most stars
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
        // All sizes scaled up so dim stars don't reduce to a 3-pixel blob when
        // scaled down for parallax. With @2x rendering, the source pixel count
        // is double these numbers.
        switch v {
        case .dimWhite:
            return Style(size: 36, core: .white,
                         halo: UIColor(white: 0.9, alpha: 1),
                         coreFraction: 0.04, hasFlare: false, flareIntensity: 0)
        case .mediumWhite:
            return Style(size: 56, core: .white,
                         halo: UIColor(white: 0.92, alpha: 1),
                         coreFraction: 0.05, hasFlare: false, flareIntensity: 0)
        case .brightWhite:
            return Style(size: 96, core: .white,
                         halo: UIColor(white: 0.95, alpha: 1),
                         coreFraction: 0.06, hasFlare: true, flareIntensity: 0.55)
        case .blueGiant:
            return Style(size: 96,
                         core: UIColor(red: 0.85, green: 0.95, blue: 1.0,  alpha: 1),
                         halo: UIColor(red: 0.45, green: 0.70, blue: 1.0,  alpha: 1),
                         coreFraction: 0.05, hasFlare: true, flareIntensity: 0.6)
        case .yellowSun:
            return Style(size: 80,
                         core: UIColor(red: 1.0,  green: 0.96, blue: 0.78, alpha: 1),
                         halo: UIColor(red: 1.0,  green: 0.80, blue: 0.40, alpha: 1),
                         coreFraction: 0.06, hasFlare: false, flareIntensity: 0)
        case .redGiant:
            return Style(size: 80,
                         core: UIColor(red: 1.0,  green: 0.78, blue: 0.55, alpha: 1),
                         halo: UIColor(red: 1.0,  green: 0.40, blue: 0.25, alpha: 1),
                         coreFraction: 0.05, hasFlare: false, flareIntensity: 0)
        }
    }

    private static func makeTexture(for v: StarVariant) -> SKTexture {
        let s = style(for: v)
        let canvas = CGSize(width: s.size, height: s.size)

        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 2     // render @2x for crisp scaling
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
    private static func drawCrossFlare(in cg: CGContext, size: CGFloat,
                                       color: UIColor, intensity: CGFloat) {
        cg.saveGState()
        cg.setBlendMode(.plusLighter)

        let length    = size * 0.95
        let thickness = max(1.0, size * 0.035)
        let center    = size / 2

        let stops: [CGColor] = [
            color.withAlphaComponent(0).cgColor,
            color.withAlphaComponent(intensity * 0.55).cgColor,
            color.withAlphaComponent(intensity).cgColor,
            color.withAlphaComponent(intensity * 0.55).cgColor,
            color.withAlphaComponent(0).cgColor,
        ]
        let locations: [CGFloat] = [0.0, 0.35, 0.5, 0.65, 1.0]
        let space = CGColorSpaceCreateDeviceRGB()
        guard let g = CGGradient(colorsSpace: space, colors: stops as CFArray, locations: locations)
        else { cg.restoreGState(); return }

        // Horizontal flare strip
        let hRect = CGRect(x: center - length / 2, y: center - thickness / 2,
                           width: length, height: thickness)
        cg.saveGState()
        cg.clip(to: hRect)
        cg.drawLinearGradient(g,
                              start: CGPoint(x: hRect.minX, y: center),
                              end:   CGPoint(x: hRect.maxX, y: center),
                              options: [])
        cg.restoreGState()

        // Vertical flare strip
        let vRect = CGRect(x: center - thickness / 2, y: center - length / 2,
                           width: thickness, height: length)
        cg.saveGState()
        cg.clip(to: vRect)
        cg.drawLinearGradient(g,
                              start: CGPoint(x: center, y: vRect.minY),
                              end:   CGPoint(x: center, y: vRect.maxY),
                              options: [])
        cg.restoreGState()

        cg.restoreGState()
    }
}
