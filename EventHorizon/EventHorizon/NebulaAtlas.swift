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
            // 8 unique textures per tint × 4 tints = 32 unique puff textures.
            // With many distinct sources, the eye doesn't catch repetition in
            // a cloud composed of 20+ overlapping puffs.
            map[tint] = (0..<8).map { _ in Self.makeTexture(tint: tint) }
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

    /// One puff is a small irregular wisp. A "cloud" is many puffs scattered
    /// at random world positions — that's how we avoid the cloud reading as
    /// a single uniform disc.
    private static func makeTexture(tint: NebulaTint) -> SKTexture {
        let canvasSize: CGFloat = 384
        let format = UIGraphicsImageRendererFormat.default()
        format.scale  = 2
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: canvasSize, height: canvasSize),
            format: format
        )

        let color = color(for: tint)
        let space = CGColorSpaceCreateDeviceRGB()

        let image = renderer.image { ctx in
            let cg = ctx.cgContext

            func blob(cx: CGFloat, cy: CGFloat, r: CGFloat, alpha: CGFloat) {
                let stops: [CGColor] = [
                    color.withAlphaComponent(alpha).cgColor,
                    color.withAlphaComponent(alpha * 0.4).cgColor,
                    color.withAlphaComponent(0).cgColor,
                ]
                guard let g = CGGradient(colorsSpace: space,
                                         colors:      stops as CFArray,
                                         locations:   [0, 0.45, 1])
                else { return }
                cg.drawRadialGradient(g,
                                      startCenter: CGPoint(x: cx, y: cy), startRadius: 0,
                                      endCenter:   CGPoint(x: cx, y: cy), endRadius:   r,
                                      options: [])
            }

            // Distribute blobs across the canvas. Keep them well INSIDE so
            // the gradient falloff has room to fade to zero before the texture
            // edge — partial blobs at the canvas boundary read as hard lines
            // when the sprite is rotated and composited with neighbours.
            // Slight count variation keeps each texture distinct without
            // dramatically changing the overall feel.
            let bigBlobs = Int.random(in: 5...8)
            for _ in 0..<bigBlobs {
                blob(cx:    CGFloat.random(in: canvasSize * 0.20 ... canvasSize * 0.80),
                     cy:    CGFloat.random(in: canvasSize * 0.20 ... canvasSize * 0.80),
                     r:     CGFloat.random(in: canvasSize * 0.20 ... canvasSize * 0.36),
                     alpha: CGFloat.random(in: 0.05...0.09))
            }
            let mediumBlobs = Int.random(in: 20...28)
            for _ in 0..<mediumBlobs {
                blob(cx:    CGFloat.random(in: canvasSize * 0.12 ... canvasSize * 0.88),
                     cy:    CGFloat.random(in: canvasSize * 0.12 ... canvasSize * 0.88),
                     r:     CGFloat.random(in: canvasSize * 0.08 ... canvasSize * 0.18),
                     alpha: CGFloat.random(in: 0.09...0.16))
            }
            let smallBlobs = Int.random(in: 30...45)
            for _ in 0..<smallBlobs {
                blob(cx:    CGFloat.random(in: canvasSize * 0.10 ... canvasSize * 0.90),
                     cy:    CGFloat.random(in: canvasSize * 0.10 ... canvasSize * 0.90),
                     r:     CGFloat.random(in: canvasSize * 0.03 ... canvasSize * 0.07),
                     alpha: CGFloat.random(in: 0.12...0.20))
            }
        }
        return SKTexture(image: image)
    }
}
