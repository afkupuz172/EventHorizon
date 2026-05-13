import SpriteKit
import UIKit

/// Procedural nebula cloud textures.
///
/// Each texture is built by stacking ~70 soft radial gradients at random
/// positions within a circular region. The composition has three tiers —
/// large faint bases, medium clumps, small bright wisps — so the result
/// has organic density variation instead of looking like a single uniform disc.
enum NebulaTint: CaseIterable {
    case deepBlue, violet, rose, teal
}

@MainActor
struct NebulaAtlas {

    static let shared: NebulaAtlas = NebulaAtlas()

    /// Multiple variants per tint so we don't get visible repetition.
    let textures: [NebulaTint: [SKTexture]]

    private init() {
        var map: [NebulaTint: [SKTexture]] = [:]
        for tint in NebulaTint.allCases {
            map[tint] = (0..<3).map { _ in Self.makeTexture(tint: tint) }
        }
        textures = map
    }

    static func color(for tint: NebulaTint) -> UIColor {
        switch tint {
        case .deepBlue: return UIColor(red: 0.30, green: 0.42, blue: 0.95, alpha: 1)
        case .violet:   return UIColor(red: 0.65, green: 0.28, blue: 0.80, alpha: 1)
        case .rose:     return UIColor(red: 0.90, green: 0.35, blue: 0.50, alpha: 1)
        case .teal:     return UIColor(red: 0.20, green: 0.55, blue: 0.65, alpha: 1)
        }
    }

    // MARK: – Rendering

    private static func makeTexture(tint: NebulaTint) -> SKTexture {
        let canvasSize: CGFloat = 512
        let format = UIGraphicsImageRendererFormat.default()
        format.scale  = 2
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: canvasSize, height: canvasSize),
            format: format
        )

        let color = color(for: tint)
        let center = CGPoint(x: canvasSize / 2, y: canvasSize / 2)
        // Keep all blobs inside this radius so the texture has a clear edge.
        let maxR: CGFloat = canvasSize * 0.42
        let space = CGColorSpaceCreateDeviceRGB()

        let image = renderer.image { ctx in
            let cg = ctx.cgContext

            func blob(cx: CGFloat, cy: CGFloat, r: CGFloat, alpha: CGFloat) {
                let stops: [CGColor] = [
                    color.withAlphaComponent(alpha).cgColor,
                    color.withAlphaComponent(alpha * 0.45).cgColor,
                    color.withAlphaComponent(0).cgColor,
                ]
                guard let g = CGGradient(colorsSpace: space,
                                         colors:      stops as CFArray,
                                         locations:   [0, 0.5, 1])
                else { return }
                cg.drawRadialGradient(g,
                                      startCenter: CGPoint(x: cx, y: cy), startRadius: 0,
                                      endCenter:   CGPoint(x: cx, y: cy), endRadius:   r,
                                      options: [])
            }

            // Tier 1 — large faint bases. Cluster near the center to give the
            // cloud overall body.
            for _ in 0..<8 {
                let angle = CGFloat.random(in: 0...(2 * .pi))
                let dist  = CGFloat.random(in: 0...(maxR * 0.30))
                let r     = CGFloat.random(in: maxR * 0.35 ... maxR * 0.65)
                blob(cx: center.x + cos(angle) * dist,
                     cy: center.y + sin(angle) * dist,
                     r:  r,
                     alpha: CGFloat.random(in: 0.04...0.07))
            }

            // Tier 2 — medium clumps spread further out. Create the density
            // variation that makes the cloud look "puffy".
            for _ in 0..<28 {
                let angle = CGFloat.random(in: 0...(2 * .pi))
                let dist  = CGFloat.random(in: 0...(maxR * 0.65))
                let r     = CGFloat.random(in: maxR * 0.12 ... maxR * 0.28)
                blob(cx: center.x + cos(angle) * dist,
                     cy: center.y + sin(angle) * dist,
                     r:  r,
                     alpha: CGFloat.random(in: 0.08...0.13))
            }

            // Tier 3 — small bright wisps. These give the cloud crisp detail
            // up close. Distributed across the full disc including the edge.
            for _ in 0..<40 {
                let angle = CGFloat.random(in: 0...(2 * .pi))
                let dist  = CGFloat.random(in: 0...(maxR * 0.85))
                let r     = CGFloat.random(in: maxR * 0.04 ... maxR * 0.10)
                blob(cx: center.x + cos(angle) * dist,
                     cy: center.y + sin(angle) * dist,
                     r:  r,
                     alpha: CGFloat.random(in: 0.12...0.20))
            }
        }
        return SKTexture(image: image)
    }
}
