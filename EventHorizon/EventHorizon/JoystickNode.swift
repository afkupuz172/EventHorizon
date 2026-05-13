import SpriteKit

final class JoystickNode: SKNode {

    let baseRadius:  CGFloat = 52
    let thumbRadius: CGFloat = 22

    private let base  = SKShapeNode()
    private let thumb = SKShapeNode()

    override init() {
        super.init()

        base.path        = CGPath(ellipseIn: CGRect(x: -baseRadius, y: -baseRadius,
                                                    width: baseRadius * 2, height: baseRadius * 2),
                                  transform: nil)
        base.fillColor   = UIColor(white: 1, alpha: 0.07)
        base.strokeColor = UIColor(white: 1, alpha: 0.25)
        base.lineWidth   = 1.5

        thumb.path        = CGPath(ellipseIn: CGRect(x: -thumbRadius, y: -thumbRadius,
                                                     width: thumbRadius * 2, height: thumbRadius * 2),
                                   transform: nil)
        thumb.fillColor   = UIColor(white: 1, alpha: 0.25)
        thumb.strokeColor = UIColor(white: 1, alpha: 0.55)
        thumb.lineWidth   = 1.5

        addChild(base)
        addChild(thumb)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setThumb(offset: CGPoint) {
        let maxDist = baseRadius - thumbRadius
        let dist    = hypot(offset.x, offset.y)
        if dist > maxDist {
            let s = maxDist / dist
            thumb.position = CGPoint(x: offset.x * s, y: offset.y * s)
        } else {
            thumb.position = offset
        }
    }

    func reset() {
        thumb.position = .zero
    }
}
