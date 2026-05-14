import SpriteKit
import UIKit

/// New-game intake form: captain + ship name. Hands off to `PlanetScene`
/// docked at the starting world (Hadrian) once submit succeeds.
@MainActor
final class NewGameScene: SKScene, UITextFieldDelegate {

    /// Where every new captain wakes up.
    static let startingSystem   = "home_system"
    static let startingPlanetID = "hadrian"
    static let startingShipID   = "ringship"
    static let startingCredits  = 100_000

    private let gameMode: GameMode

    private var captainField:  UITextField?
    private var shipField:     UITextField?
    private var startBtn:      SKShapeNode!
    private var backBtn:       SKShapeNode!
    private var errorLabel:    SKLabelNode!

    init(size: CGSize, gameMode: GameMode) {
        self.gameMode = gameMode
        super.init(size: size)
    }
    required init?(coder aDecoder: NSCoder) { fatalError() }

    override func didMove(to view: SKView) {
        backgroundColor = UIColor(white: 0.02, alpha: 1)
        anchorPoint     = CGPoint(x: 0.5, y: 0.5)
        buildLayout(in: view)
    }

    override func willMove(from view: SKView) {
        captainField?.removeFromSuperview()
        shipField?.removeFromSuperview()
        captainField = nil
        shipField    = nil
    }

    // MARK: – Build

    private func buildLayout(in view: SKView) {
        let title             = SKLabelNode(text: "NEW CAPTAIN")
        title.fontName        = "AvenirNext-UltraLight"
        title.fontSize        = 32
        title.fontColor       = .white
        title.position        = CGPoint(x: 0, y: size.height * 0.28)
        title.verticalAlignmentMode = .center
        addChild(title)

        let sub             = SKLabelNode(text: gameMode == .singlePlayer ? "SINGLE PLAYER" : "MULTIPLAYER")
        sub.fontName        = "AvenirNext-Medium"
        sub.fontSize        = 11
        sub.fontColor       = UIColor(white: 0.50, alpha: 1)
        sub.position        = CGPoint(x: 0, y: size.height * 0.28 - 28)
        addChild(sub)

        addFieldLabel("CAPTAIN NAME", y: 70)
        captainField = addTextField(in: view, y: 40, placeholder: "Ada Sterling")
        captainField?.delegate = self

        addFieldLabel("SHIP NAME", y: -20)
        shipField = addTextField(in: view, y: -50, placeholder: "Black Comet")
        shipField?.delegate = self

        // BEGIN button sits at -size.height * 0.28. Park the error label
        // halfway between the bottom field (y=-50) and BEGIN so it never
        // overlaps either, even on short landscape screens.
        let beginY: CGFloat = -size.height * 0.28
        let errorY: CGFloat = max(beginY + 36, -90)
        errorLabel             = SKLabelNode(text: "")
        errorLabel.fontName    = "AvenirNext-Medium"
        errorLabel.fontSize    = 12
        errorLabel.fontColor   = UIColor(red: 0.95, green: 0.40, blue: 0.35, alpha: 1)
        errorLabel.numberOfLines = 0
        errorLabel.preferredMaxLayoutWidth = min(size.width - 60, 360)
        errorLabel.position    = CGPoint(x: 0, y: errorY)
        addChild(errorLabel)

        startBtn = makeButton(text: "BEGIN",
                              size: CGSize(width: 200, height: 48),
                              position: CGPoint(x: 0, y: beginY),
                              primary: true)
        addChild(startBtn)

        backBtn = makeButton(text: "← BACK",
                             size: CGSize(width: 110, height: 36),
                             position: CGPoint(x: -size.width / 2 + 80,
                                               y:  size.height / 2 - 36),
                             primary: false)
        addChild(backBtn)
    }

    private func addFieldLabel(_ text: String, y: CGFloat) {
        let lbl             = SKLabelNode(text: text)
        lbl.fontName        = "AvenirNext-DemiBold"
        lbl.fontSize        = 10
        lbl.fontColor       = UIColor(white: 0.45, alpha: 1)
        lbl.horizontalAlignmentMode = .left
        lbl.position        = CGPoint(x: -140, y: y)
        addChild(lbl)
    }

    /// Adds a UITextField overlay since SpriteKit has no native text input.
    /// `y` is in SK scene coordinates (origin at center, +y up). We convert
    /// to view coordinates (origin top-left, +y down) for UIKit.
    private func addTextField(in view: SKView, y skY: CGFloat, placeholder: String) -> UITextField {
        let w: CGFloat = 280
        let h: CGFloat = 36
        let viewMidX = view.bounds.midX
        let viewMidY = view.bounds.midY
        let frame = CGRect(x: viewMidX - w / 2,
                           y: viewMidY - skY - h / 2,
                           width: w, height: h)
        let f = UITextField(frame: frame)
        f.borderStyle      = .roundedRect
        f.backgroundColor  = UIColor(white: 0.10, alpha: 1.0)
        f.textColor        = .white
        f.tintColor        = UIColor(red: 0.45, green: 0.75, blue: 1.0, alpha: 1.0)
        f.font             = UIFont(name: "AvenirNext-Medium", size: 16)
        f.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: UIColor(white: 0.35, alpha: 1)]
        )
        f.autocapitalizationType = .words
        f.autocorrectionType     = .no
        f.returnKeyType          = .done
        view.addSubview(f)
        return f
    }

    private func makeButton(text: String, size s: CGSize,
                            position: CGPoint, primary: Bool) -> SKShapeNode {
        let btn = SKShapeNode(rect: CGRect(x: -s.width / 2, y: -s.height / 2,
                                           width: s.width, height: s.height),
                              cornerRadius: 6)
        btn.fillColor = primary
            ? UIColor(red: 0.18, green: 0.55, blue: 1.0, alpha: 0.85)
            : UIColor(white: 0.16, alpha: 0.90)
        btn.strokeColor = primary
            ? UIColor(red: 0.45, green: 0.75, blue: 1.0, alpha: 1.0)
            : UIColor(white: 0.40, alpha: 0.55)
        btn.lineWidth = 1.5
        btn.position  = position

        let lbl                       = SKLabelNode(text: text)
        lbl.fontName                  = "AvenirNext-Bold"
        lbl.fontSize                  = primary ? 16 : 12
        lbl.fontColor                 = .white
        lbl.verticalAlignmentMode     = .center
        btn.addChild(lbl)
        return btn
    }

    // MARK: – Submit

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === captainField {
            shipField?.becomeFirstResponder()
        } else {
            textField.resignFirstResponder()
        }
        return true
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        let p = t.location(in: self)
        if backBtn.contains(p) {
            goBack(); return
        }
        if startBtn.contains(p) {
            commit(); return
        }
        captainField?.resignFirstResponder()
        shipField?.resignFirstResponder()
    }

    private func commit() {
        let captain = (captainField?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let ship    = (shipField?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        guard !captain.isEmpty else { showError("Captain name required."); return }
        guard !ship.isEmpty    else { showError("Ship name required.");    return }

        let existing = SaveProfileStore.shared.list(mode: gameMode.saveMode)
        if existing.contains(where: { $0.fileSlug == SaveProfile.slug(for: captain) }) {
            showError("A captain by that name already exists.")
            return
        }

        // Reset the live profile to a clean slate, then seed it.
        let p = PlayerProfile.shared
        p.captainName     = captain
        p.shipName        = ship
        p.mode            = gameMode.saveMode
        p.currentSystem   = NewGameScene.startingSystem
        p.currentPlanetID = NewGameScene.startingPlanetID
        p.reputation      = [:]
        p.credits         = NewGameScene.startingCredits
        p.currentShipID   = NewGameScene.startingShipID   // didSet seeds installedOutfits

        SaveProfileStore.shared.save(p.toSaveProfile())
        landAtStartingPlanet()
    }

    private func landAtStartingPlanet() {
        guard let info = DockedPlanetInfo.load(systemName: NewGameScene.startingSystem,
                                               planetID:   NewGameScene.startingPlanetID)
        else { showError("Could not load starting planet."); return }

        let planet = PlanetScene(size: size, info: info, gameMode: gameMode)
        planet.scaleMode = .resizeFill
        view?.presentScene(planet, transition: .fade(withDuration: 0.4))
    }

    private func showError(_ text: String) {
        errorLabel.text = text
    }

    private func goBack() {
        let loading = LoadingScene(size: size)
        loading.scaleMode = .resizeFill
        view?.presentScene(loading, transition: .fade(withDuration: 0.25))
    }
}
