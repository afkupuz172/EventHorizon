import UIKit
import SpriteKit

class GameViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()

        guard let view = self.view as? SKView else { return }

        let scene = LoadingScene(size: view.bounds.size)
        scene.scaleMode = .resizeFill
        view.presentScene(scene)
        view.ignoresSiblingOrder = true

        #if DEBUG
        view.showsFPS = true
        view.showsNodeCount = true
        #endif
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .landscape
    }

    override var prefersStatusBarHidden: Bool {
        return true
    }
}
