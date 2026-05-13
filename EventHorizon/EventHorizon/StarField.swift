import SpriteKit
import UIKit

/// Bakes a dense pinprick starfield to a single SKTexture.
///
/// The far/background star layer would need tens of thousands of `SKSpriteNode`s
/// to read as a "Milky Way" density. That's a lot of node-tree work for content
/// that never changes per-frame. Instead we render thousands of stars into a
/// single image once at setup; the layer becomes a small grid of textured
/// sprites that tile the world. Effective star count multiplies by the tile
/// count, with cost no higher than a handful of sprites.
@MainActor
struct StarField {

    /// Generate one tile texture with `starCount` pinpricks distributed across
    /// a `canvasSize × canvasSize` image.
    static func makeFieldTexture(canvasSize: CGFloat = 1024,
                                 starCount:  Int       = 4500,
                                 palette:    [UIColor] = [.white]) -> SKTexture {
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale  = 1
        fmt.opaque = false
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: canvasSize, height: canvasSize),
            format: fmt
        )

        let space = CGColorSpaceCreateDeviceRGB()
        let image = renderer.image { ctx in
            let cg = ctx.cgContext

            for _ in 0..<starCount {
                let x       = CGFloat.random(in: 0...canvasSize)
                let y       = CGFloat.random(in: 0...canvasSize)
                let radius  = CGFloat.random(in: 0.5...1.6)
                let alpha   = CGFloat.random(in: 0.30...1.00)
                let color   = palette.randomElement() ?? .white

                // Tight 3-stop falloff. The outer ring is barely visible so the
                // dots blend smoothly into one another at high densities and
                // don't read as discrete circles.
                let stops: [CGColor] = [
                    color.withAlphaComponent(alpha).cgColor,
                    color.withAlphaComponent(alpha * 0.3).cgColor,
                    color.withAlphaComponent(0).cgColor,
                ]
                guard let g = CGGradient(colorsSpace: space,
                                         colors:      stops as CFArray,
                                         locations:   [0, 0.45, 1])
                else { continue }
                cg.drawRadialGradient(
                    g,
                    startCenter: CGPoint(x: x, y: y), startRadius: 0,
                    endCenter:   CGPoint(x: x, y: y), endRadius:   radius * 2.4,
                    options: []
                )
            }
        }
        return SKTexture(image: image)
    }
}
