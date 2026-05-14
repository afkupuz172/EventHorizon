import SpriteKit

enum GameMode {
    case singlePlayer
    case multiplayer
}

extension GameMode {
    var saveMode: SaveProfile.Mode {
        switch self {
        case .singlePlayer: return .singlePlayer
        case .multiplayer:  return .multiplayer
        }
    }
}

final class LoadingScene: SKScene {

    /// Mode persists across LoadingScene instances so navigating
    /// New Game / Load Game and tapping BACK preserves the user's choice.
    private static var lastMode: GameMode = .singlePlayer
    private var mode: GameMode {
        get { Self.lastMode }
        set { Self.lastMode = newValue }
    }

    private var singleBtn:    SKShapeNode!
    private var singleLabel:  SKLabelNode!
    private var multiBtn:     SKShapeNode!
    private var multiLabel:   SKLabelNode!
    private var newGameBtn:   SKShapeNode!
    private var loadGameBtn:  SKShapeNode!
    private var errorLabel:   SKLabelNode!

    override func didMove(to view: SKView) {
        backgroundColor = .black
        anchorPoint     = CGPoint(x: 0.5, y: 0.5)
        buildStarfield()
        buildTitle()
        buildModeToggle()
        buildPrimaryButtons()
    }

    override func didChangeSize(_ oldSize: CGSize) {
        anchorPoint = CGPoint(x: 0.5, y: 0.5)
    }

    // MARK: – Build

    private func buildStarfield() {
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

    private func buildPrimaryButtons() {
        let w: CGFloat = 220
        let h: CGFloat = 52
        let y: CGFloat = -size.height * 0.18

        newGameBtn = makeBigButton(text: "NEW GAME",
                                   size: CGSize(width: w, height: h),
                                   position: CGPoint(x: -w / 2 - 8, y: y),
                                   primary: true)
        loadGameBtn = makeBigButton(text: "LOAD GAME",
                                    size: CGSize(width: w, height: h),
                                    position: CGPoint(x: w / 2 + 8, y: y),
                                    primary: false)
        addChild(newGameBtn)
        addChild(loadGameBtn)

        errorLabel             = SKLabelNode(text: "")
        errorLabel.fontName    = "AvenirNext-Medium"
        errorLabel.fontSize    = 13
        errorLabel.fontColor   = UIColor(red: 0.95, green: 0.40, blue: 0.35, alpha: 1)
        errorLabel.position    = CGPoint(x: 0, y: y - 50)
        addChild(errorLabel)
    }

    private func makeBigButton(text: String, size s: CGSize,
                               position: CGPoint, primary: Bool) -> SKShapeNode {
        let btn = SKShapeNode(rect: CGRect(x: -s.width / 2, y: -s.height / 2,
                                           width: s.width, height: s.height),
                              cornerRadius: 8)
        btn.fillColor   = primary
            ? UIColor(red: 0.18, green: 0.55, blue: 1.0, alpha: 0.85)
            : UIColor(white: 0.10, alpha: 0.85)
        btn.strokeColor = primary
            ? UIColor(red: 0.45, green: 0.75, blue: 1.0, alpha: 1.0)
            : UIColor(white: 0.40, alpha: 0.65)
        btn.lineWidth   = 1.5
        btn.position    = position

        let lbl                       = SKLabelNode(text: text)
        lbl.fontName                  = "AvenirNext-Bold"
        lbl.fontSize                  = 18
        lbl.fontColor                 = .white
        lbl.verticalAlignmentMode     = .center
        btn.addChild(lbl)
        return btn
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
        let activeFill    = UIColor(red: 0.18, green: 0.55, blue: 1.0, alpha: 0.85)
        let activeStroke  = UIColor(red: 0.45, green: 0.75, blue: 1.0, alpha: 1.0)
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

        if singleBtn.contains(p)  { mode = .singlePlayer; renderToggle(); return }
        if multiBtn.contains(p)   { mode = .multiplayer;  renderToggle(); return }
        if newGameBtn.contains(p) { openNewGame();  return }
        if loadGameBtn.contains(p) { openLoadGame(); return }
    }

    private func openNewGame() {
        proceedIfServerReachable {
            let s = NewGameScene(size: self.view?.bounds.size ?? self.size, gameMode: self.mode)
            s.scaleMode = .resizeFill
            self.view?.presentScene(s, transition: .fade(withDuration: 0.30))
        }
    }

    private func openLoadGame() {
        proceedIfServerReachable {
            let s = LoadGameScene(size: self.view?.bounds.size ?? self.size, gameMode: self.mode)
            s.scaleMode = .resizeFill
            self.view?.presentScene(s, transition: .fade(withDuration: 0.30))
        }
    }

    /// In multiplayer mode, only call `next` if the server's TCP port answers.
    /// Singleplayer never blocks — there's nothing to reach.
    private func proceedIfServerReachable(_ next: @escaping () -> Void) {
        errorLabel.text = ""
        guard mode == .multiplayer else { next(); return }

        errorLabel.text = "Contacting server…"
        errorLabel.fontColor = UIColor(white: 0.65, alpha: 1)
        NetworkManager.probeServer { [weak self] reachable in
            guard let self else { return }
            if reachable {
                self.errorLabel.text = ""
                next()
            } else {
                self.errorLabel.fontColor = UIColor(red: 0.95, green: 0.40, blue: 0.35, alpha: 1)
                self.errorLabel.text = "Multiplayer server unreachable."
            }
        }
    }
}
