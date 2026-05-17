import SpriteKit
import UIKit

/// Shown when the player's hull reaches zero. Tap (or wait) returns to
/// the main menu — the active save is preserved as-is, so reloading
/// brings the captain back at their last dock.
@MainActor
final class GameOverScene: SKScene {

    override func didMove(to view: SKView) {
        backgroundColor = UIColor(red: 0.04, green: 0.02, blue: 0.04, alpha: 1)
        anchorPoint = CGPoint(x: 0.5, y: 0.5)

        let title             = SKLabelNode(text: "GAME OVER")
        title.fontName        = "AvenirNext-UltraLight"
        title.fontSize        = 56
        title.fontColor       = UIColor(red: 1, green: 0.55, blue: 0.50, alpha: 1)
        title.verticalAlignmentMode = .center
        title.position        = CGPoint(x: 0, y: 60)
        title.alpha           = 0
        title.run(.fadeIn(withDuration: 0.6))
        addChild(title)

        let sub             = SKLabelNode(text: "Your ship was destroyed.")
        sub.fontName        = "AvenirNext-Regular"
        sub.fontSize        = 16
        sub.fontColor       = UIColor(white: 0.75, alpha: 1)
        sub.verticalAlignmentMode = .center
        sub.position        = CGPoint(x: 0, y: 14)
        sub.alpha           = 0
        sub.run(.sequence([.wait(forDuration: 0.3), .fadeIn(withDuration: 0.6)]))
        addChild(sub)

        let tap             = SKLabelNode(text: "TAP TO RETURN TO MAIN MENU")
        tap.fontName        = "AvenirNext-DemiBold"
        tap.fontSize        = 13
        tap.fontColor       = UIColor(white: 0.55, alpha: 1)
        tap.verticalAlignmentMode = .center
        tap.position        = CGPoint(x: 0, y: -60)
        tap.alpha           = 0
        tap.run(.sequence([
            .wait(forDuration: 0.8),
            .fadeIn(withDuration: 0.5),
            // Subtle blink to invite the tap.
            .repeatForever(.sequence([
                .fadeAlpha(to: 0.35, duration: 0.9),
                .fadeAlpha(to: 1.0,  duration: 0.9),
            ])),
        ]))
        addChild(tap)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        returnToMainMenu()
    }

    private func returnToMainMenu() {
        guard let view = view else { return }
        let loading        = LoadingScene(size: size)
        loading.scaleMode  = .resizeFill
        view.presentScene(loading, transition: .fade(withDuration: 0.5))
    }
}
