import SpriteKit

enum GameMode {
    case singlePlayer
    case multiplayer
}

final class LoadingScene: SKScene {

    private var mode: GameMode = .multiplayer

    private var singleBtn:    SKShapeNode!
    private var singleLabel:  SKLabelNode!
    private var multiBtn:     SKShapeNode!
    private var multiLabel:   SKLabelNode!
    private var joinBtn:      SKShapeNode!
    private var joinLabel:    SKLabelNode!

    override func didMove(to view: SKView) {
        backgroundColor = .black
        anchorPoint     = CGPoint(x: 0.5, y: 0.5)   // (0,0) sits at the view center
        buildStarfield()
        buildTitle()
        buildModeToggle()
        buildJoinButton()
    }

    override func didChangeSize(_ oldSize: CGSize) {
        // Re-anchor on rotation / size change so layout stays centered.
        anchorPoint = CGPoint(x: 0.5, y: 0.5)
    }

    // MARK: – Build

    private func buildStarfield() {
        // Spread wider than the view so rotation/resize never reveals empty edges.
        let spread = max(size.width, size.height) * 1.5
        for _ in 0..<240 {
            let r = CGFloat.random(in: 0.4...1.6)
            let s = SKShapeNode(circleOfRadius: r)
            s.fillColor   = .white
            s.strokeColor = .clear
            s.alpha       = CGFloat.random(in: 0.2...0.85)
            s.position    = CGPoint(x: CGFloat.random(in: -spread...spread),
                                    y: CGFloat.random(in: -spread...spread))
            addChild(s)

            if Int.random(in: 0...2) == 0 {
                let dim    = SKAction.fadeAlpha(to: s.alpha * 0.4, duration: Double.random(in: 1.2...2.6))
                let bright = SKAction.fadeAlpha(to: s.alpha,        duration: Double.random(in: 1.2...2.6))
                s.run(.repeatForever(.sequence([dim, bright])))
            }
        }
    }

    private func buildTitle() {
        let title           = SKLabelNode(text: "EVENT HORIZON")
        title.fontName      = "AvenirNext-UltraLight"
        title.fontSize      = 56
        title.fontColor     = .white
        title.position      = CGPoint(x: 0, y: size.height * 0.22)
        title.verticalAlignmentMode = .center
        addChild(title)

        let sub             = SKLabelNode(text: "PHASE  I")
        sub.fontName        = "AvenirNext-Medium"
        sub.fontSize        = 14
        sub.fontColor       = UIColor(white: 0.6, alpha: 1)
        sub.position        = CGPoint(x: 0, y: size.height * 0.22 - 38)
        sub.verticalAlignmentMode = .center
        addChild(sub)
    }

    private func buildModeToggle() {
        (singleBtn, singleLabel) = makePillButton(text: "SINGLE PLAYER",
                                                  position: CGPoint(x: -120, y: 0))
        (multiBtn,  multiLabel)  = makePillButton(text: "MULTIPLAYER",
                                                  position: CGPoint(x:  120, y: 0))
        addChild(singleBtn)
        addChild(multiBtn)
        renderToggle()
    }

    private func buildJoinButton() {
        let w: CGFloat = 220
        let h: CGFloat = 56
        joinBtn = SKShapeNode(rect: CGRect(x: -w/2, y: -h/2, width: w, height: h), cornerRadius: 8)
        joinBtn.fillColor   = UIColor(red: 0.18, green: 0.55, blue: 1.0, alpha: 0.85)
        joinBtn.strokeColor = UIColor(red: 0.45, green: 0.75, blue: 1.0, alpha: 1.0)
        joinBtn.lineWidth   = 1.5
        joinBtn.position    = CGPoint(x: 0, y: -size.height * 0.18)

        joinLabel                = SKLabelNode(text: "JOIN GAME")
        joinLabel.fontName       = "AvenirNext-Bold"
        joinLabel.fontSize       = 18
        joinLabel.fontColor      = .white
        joinLabel.verticalAlignmentMode = .center
        joinBtn.addChild(joinLabel)
        addChild(joinBtn)
    }

    private func makePillButton(text: String, position: CGPoint) -> (SKShapeNode, SKLabelNode) {
        let w: CGFloat = 200
        let h: CGFloat = 44
        let btn = SKShapeNode(rect: CGRect(x: -w/2, y: -h/2, width: w, height: h), cornerRadius: 22)
        btn.fillColor   = UIColor(white: 1, alpha: 0.06)
        btn.strokeColor = UIColor(white: 1, alpha: 0.25)
        btn.lineWidth   = 1.0
        btn.position    = position

        let lbl                       = SKLabelNode(text: text)
        lbl.fontName                  = "AvenirNext-Medium"
        lbl.fontSize                  = 14
        lbl.fontColor                 = UIColor(white: 0.85, alpha: 1)
        lbl.verticalAlignmentMode     = .center
        btn.addChild(lbl)

        return (btn, lbl)
    }

    private func renderToggle() {
        let activeFill   = UIColor(red: 0.18, green: 0.55, blue: 1.0, alpha: 0.85)
        let activeStroke = UIColor(red: 0.45, green: 0.75, blue: 1.0, alpha: 1.0)
        let dormantFill   = UIColor(white: 1, alpha: 0.06)
        let dormantStroke = UIColor(white: 1, alpha: 0.25)

        let singleActive = mode == .singlePlayer
        singleBtn.fillColor   = singleActive ? activeFill   : dormantFill
        singleBtn.strokeColor = singleActive ? activeStroke : dormantStroke
        singleLabel.fontColor = singleActive ? .white       : UIColor(white: 0.7, alpha: 1)

        let multiActive = mode == .multiplayer
        multiBtn.fillColor    = multiActive ? activeFill   : dormantFill
        multiBtn.strokeColor  = multiActive ? activeStroke : dormantStroke
        multiLabel.fontColor  = multiActive ? .white       : UIColor(white: 0.7, alpha: 1)
    }

    // MARK: – Touch

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        let p = t.location(in: self)

        if singleBtn.contains(p) { mode = .singlePlayer; renderToggle(); return }
        if multiBtn.contains(p)  { mode = .multiplayer;  renderToggle(); return }
        if joinBtn.contains(p)   { startGame(); return }
    }

    private func startGame() {
        let game        = GameScene(size: view?.bounds.size ?? size, mode: mode)
        game.scaleMode  = .resizeFill
        view?.presentScene(game, transition: .fade(withDuration: 0.4))
    }
}
