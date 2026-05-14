import SpriteKit
import UIKit

/// Lists save profiles for the chosen mode. Tap a row to highlight it; use
/// per-row LOAD / DELETE buttons to act. Long lists scroll via a vertical
/// drag inside the list area.
@MainActor
final class LoadGameScene: SKScene {

    private let gameMode: GameMode

    private var profiles: [SaveProfile] = []

    /// Hosts the scrollable list rows. Translated on drag.
    private let listContainer = SKNode()

    /// Tappable nodes carrying actions. Buttons take priority over row taps.
    private var actionButtons: [(node: SKShapeNode, action: () -> Void)] = []
    private var rowHits:       [(bg: SKShapeNode, profile: SaveProfile)] = []

    /// Static (non-scrolling) buttons.
    private var staticButtons: [(node: SKShapeNode, action: () -> Void)] = []

    // Selection state removed — per-row LOAD/DELETE buttons act on
    // their row directly, no separate "select then act" step needed.

    /// "Are you sure?" overlay state — `nil` when no modal is up.
    private var confirmOverlay: SKNode?

    // Scroll bookkeeping
    private var listTop:    CGFloat = 0   // y of first row's top (in scene space)
    private var listBottom: CGFloat = 0   // y where rows stop being drawn
    private var contentHeight: CGFloat = 0
    private var scrollOffset:  CGFloat = 0
    private var dragLastY:     CGFloat = 0
    private var isDragging                     = false
    private var dragStartedInList              = false
    private var dragMovedEnoughToCancelTap     = false

    init(size: CGSize, gameMode: GameMode) {
        self.gameMode = gameMode
        super.init(size: size)
    }
    required init?(coder aDecoder: NSCoder) { fatalError() }

    override func didMove(to view: SKView) {
        backgroundColor = UIColor(white: 0.02, alpha: 1)
        anchorPoint     = CGPoint(x: 0.5, y: 0.5)
        rebuild()
    }

    private func rebuild() {
        removeAllChildren()
        actionButtons.removeAll()
        rowHits.removeAll()
        staticButtons.removeAll()
        listContainer.removeAllChildren()
        listContainer.position = .zero
        scrollOffset = 0
        confirmOverlay = nil
        pendingDelete = nil

        let hw = size.width  / 2
        let hh = size.height / 2

        let title             = SKLabelNode(text: "LOAD GAME")
        title.fontName        = "AvenirNext-UltraLight"
        title.fontSize        = 28
        title.fontColor       = .white
        title.horizontalAlignmentMode = .left
        title.verticalAlignmentMode   = .top
        title.position        = CGPoint(x: -hw + 24, y: hh - 12)
        addChild(title)

        let sub             = SKLabelNode(text: gameMode == .singlePlayer ? "SINGLE PLAYER" : "MULTIPLAYER")
        sub.fontName        = "AvenirNext-Medium"
        sub.fontSize        = 11
        sub.fontColor       = UIColor(white: 0.50, alpha: 1)
        sub.horizontalAlignmentMode = .left
        sub.position        = CGPoint(x: -hw + 24, y: hh - 44)
        addChild(sub)

        let backBtn = makeStaticButton(text: "← BACK",
                                       size: CGSize(width: 110, height: 32),
                                       position: CGPoint(x: hw - 72, y: hh - 28)) { [weak self] in
            self?.goBack()
        }
        addChild(backBtn)

        let divider     = SKShapeNode()
        let dp          = CGMutablePath()
        dp.move(to:    CGPoint(x: -hw + 16, y: hh - 60))
        dp.addLine(to: CGPoint(x:  hw - 16, y: hh - 60))
        divider.path        = dp
        divider.strokeColor = UIColor(white: 1, alpha: 0.12)
        divider.lineWidth   = 1
        addChild(divider)

        profiles = SaveProfileStore.shared.list(mode: gameMode.saveMode)

        guard !profiles.isEmpty else {
            let empty             = SKLabelNode(text: "NO SAVED CAPTAINS")
            empty.fontName        = "AvenirNext-Medium"
            empty.fontSize        = 14
            empty.fontColor       = UIColor(white: 0.40, alpha: 1)
            empty.position        = CGPoint(x: 0, y: 0)
            addChild(empty)
            return
        }

        addChild(listContainer)
        buildRows()
    }

    // MARK: – Row construction

    private func buildRows() {
        let hh = size.height / 2

        let rowH: CGFloat = 88
        let rowGap: CGFloat = 6
        let rowW: CGFloat = min(size.width - 48, 660)

        listTop    = hh - 80
        listBottom = -hh + 16
        contentHeight = CGFloat(profiles.count) * (rowH + rowGap)

        for (i, profile) in profiles.enumerated() {
            let midY = listTop - CGFloat(i) * (rowH + rowGap) - rowH / 2

            let bg = SKShapeNode(
                rect: CGRect(x: -rowW / 2, y: -rowH / 2 + 2,
                             width: rowW, height: rowH - 4),
                cornerRadius: 6
            )
            bg.position    = CGPoint(x: 0, y: midY)
            bg.fillColor   = UIColor(white: 0.07, alpha: 0.90)
            bg.strokeColor = UIColor(white: 0.22, alpha: 0.55)
            bg.lineWidth   = 1
            listContainer.addChild(bg)
            rowHits.append((bg, profile))

            // Ship thumbnail — uses the same static renderer as the shipyard.
            let thumbSize = CGSize(width: 70, height: 70)
            let metadata  = ShipMetadata.byID[profile.shipID] ?? .ringship
            let thumb     = ShipNode.staticThumbnail(metadata: metadata, viewportSize: thumbSize)
            thumb.position = CGPoint(x: -rowW / 2 + 14 + thumbSize.width / 2, y: 0)
            bg.addChild(thumb)

            let textLeft: CGFloat = -rowW / 2 + 14 + thumbSize.width + 14

            let captain             = SKLabelNode(text: profile.captainName.uppercased())
            captain.fontName        = "AvenirNext-DemiBold"
            captain.fontSize        = 15
            captain.fontColor       = .white
            captain.horizontalAlignmentMode = .left
            captain.verticalAlignmentMode   = .center
            captain.position        = CGPoint(x: textLeft, y: 24)
            bg.addChild(captain)

            let location = describePlanet(systemName: profile.currentSystem,
                                          planetID: profile.currentPlanetID)
            let where_             = SKLabelNode(text: "DOCKED AT \(location.uppercased())")
            where_.fontName        = "AvenirNextCondensed-Regular"
            where_.fontSize        = 11
            where_.fontColor       = UIColor(white: 0.55, alpha: 1)
            where_.horizontalAlignmentMode = .left
            where_.verticalAlignmentMode   = .center
            where_.position        = CGPoint(x: textLeft, y: 4)
            bg.addChild(where_)

            let ship             = SKLabelNode(text: "\(profile.shipName)  ·  \(profile.credits) CR")
            ship.fontName        = "AvenirNextCondensed-Regular"
            ship.fontSize        = 11
            ship.fontColor       = UIColor(white: 0.45, alpha: 1)
            ship.horizontalAlignmentMode = .left
            ship.verticalAlignmentMode   = .center
            ship.position        = CGPoint(x: textLeft, y: -14)
            bg.addChild(ship)

            let saved             = SKLabelNode(text: formatTimestamp(profile.lastSavedAtUnix))
            saved.fontName        = "AvenirNextCondensed-Regular"
            saved.fontSize        = 10
            saved.fontColor       = UIColor(white: 0.40, alpha: 1)
            saved.horizontalAlignmentMode = .right
            saved.verticalAlignmentMode   = .center
            saved.position        = CGPoint(x: rowW / 2 - 12, y: 28)
            bg.addChild(saved)

            // Per-row LOAD / DELETE buttons. Both registered BEFORE row tap.
            let btnW: CGFloat = 78
            let btnH: CGFloat = 28
            let loadBtn = SKShapeNode(
                rect: CGRect(x: -btnW / 2, y: -btnH / 2, width: btnW, height: btnH),
                cornerRadius: 4
            )
            loadBtn.position    = CGPoint(x: rowW / 2 - 12 - btnW / 2 - btnW - 8, y: -18)
            loadBtn.fillColor   = UIColor(red: 0.18, green: 0.55, blue: 1.0, alpha: 0.85)
            loadBtn.strokeColor = UIColor(red: 0.45, green: 0.80, blue: 1.0, alpha: 1.0)
            loadBtn.lineWidth   = 1
            let loadLbl             = SKLabelNode(text: "LOAD")
            loadLbl.fontName        = "AvenirNext-Bold"
            loadLbl.fontSize        = 11
            loadLbl.fontColor       = .white
            loadLbl.verticalAlignmentMode   = .center
            loadLbl.horizontalAlignmentMode = .center
            loadBtn.addChild(loadLbl)
            bg.addChild(loadBtn)
            actionButtons.append((loadBtn, { [weak self] in self?.resume(profile: profile) }))

            let delBtn = SKShapeNode(
                rect: CGRect(x: -btnW / 2, y: -btnH / 2, width: btnW, height: btnH),
                cornerRadius: 4
            )
            delBtn.position    = CGPoint(x: rowW / 2 - 12 - btnW / 2, y: -18)
            delBtn.fillColor   = UIColor(red: 0.30, green: 0.12, blue: 0.10, alpha: 0.95)
            delBtn.strokeColor = UIColor(red: 0.85, green: 0.30, blue: 0.25, alpha: 0.85)
            delBtn.lineWidth   = 1
            let delLbl             = SKLabelNode(text: "DELETE")
            delLbl.fontName        = "AvenirNext-Bold"
            delLbl.fontSize        = 10
            delLbl.fontColor       = UIColor(red: 0.95, green: 0.55, blue: 0.50, alpha: 1)
            delLbl.verticalAlignmentMode   = .center
            delLbl.horizontalAlignmentMode = .center
            delBtn.addChild(delLbl)
            bg.addChild(delBtn)
            actionButtons.append((delBtn, { [weak self] in self?.confirmDelete(profile: profile) }))
        }
    }

    // MARK: – Description helpers

    private func describePlanet(systemName: String, planetID: String) -> String {
        guard let cfg = SolarSystemConfig.load(name: systemName),
              let p   = cfg.planets.first(where: { $0.id == planetID })
        else { return planetID }
        return p.displayName ?? planetID
    }

    private func formatTimestamp(_ t: TimeInterval) -> String {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short
        return df.string(from: Date(timeIntervalSince1970: t))
    }

    private func makeStaticButton(text: String, size s: CGSize, position: CGPoint,
                                  action: @escaping () -> Void) -> SKShapeNode {
        let btn = SKShapeNode(rect: CGRect(x: -s.width / 2, y: -s.height / 2,
                                           width: s.width, height: s.height),
                              cornerRadius: 5)
        btn.fillColor   = UIColor(white: 0.16, alpha: 0.95)
        btn.strokeColor = UIColor(white: 0.40, alpha: 0.55)
        btn.lineWidth   = 1
        btn.position    = position
        let lbl                       = SKLabelNode(text: text)
        lbl.fontName                  = "AvenirNext-DemiBold"
        lbl.fontSize                  = 11
        lbl.fontColor                 = .white
        lbl.verticalAlignmentMode     = .center
        btn.addChild(lbl)
        staticButtons.append((btn, action))
        return btn
    }

    // MARK: – Touch

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        let p = t.location(in: self)

        // Confirmation overlay swallows everything beneath it.
        if confirmOverlay != nil {
            _ = handleConfirmTouch(at: p)
            return
        }

        // Static (non-scrolling) buttons first.
        for (node, action) in staticButtons where node.contains(p) {
            action(); return
        }

        // Buttons live inside per-row backgrounds. `SKNode.contains` uses
        // the node's frame in its PARENT's coord space, so convert the
        // scene-space point into each button's parent's space before test.
        for (node, action) in actionButtons {
            guard let parent = node.parent else { continue }
            let local = parent.convert(p, from: self)
            if node.contains(local) {
                action(); return
            }
        }

        // Below the back/title area is the scrollable list region.
        if p.y < listTop && p.y > listBottom {
            dragStartedInList         = true
            dragLastY                 = p.y
            dragMovedEnoughToCancelTap = false
            isDragging                = false
        } else {
            dragStartedInList = false
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first, dragStartedInList else { return }
        let p = t.location(in: self)
        let dy = p.y - dragLastY
        dragLastY = p.y
        if abs(dy) > 2 { dragMovedEnoughToCancelTap = true; isDragging = true }
        if isDragging {
            applyScrollDelta(dy)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        dragStartedInList = false
        isDragging = false
        // Row taps no longer have an action — LOAD/DELETE are the only
        // affordances. End-touch is purely scroll bookkeeping.
    }

    private func applyScrollDelta(_ dy: CGFloat) {
        let viewportH    = listTop - listBottom
        let maxOffset    = max(contentHeight - viewportH, 0)
        // Natural-direction scrolling: drag UP to bring lower rows into view.
        let proposed     = scrollOffset + dy
        let clamped      = max(0, min(maxOffset, proposed))
        scrollOffset     = clamped
        listContainer.position = CGPoint(x: 0, y: clamped)
    }

    // MARK: – Actions

    private func confirmDelete(profile: SaveProfile) {
        let overlay = SKNode()
        overlay.zPosition = 1000

        // Dim layer covering the whole scene — also intercepts touches via
        // `confirmOverlay != nil` guard in touchesBegan.
        let dim = SKShapeNode(rectOf: size)
        dim.fillColor   = UIColor(white: 0, alpha: 0.65)
        dim.strokeColor = .clear
        overlay.addChild(dim)

        let panelW: CGFloat = 360
        let panelH: CGFloat = 180
        let panel = SKShapeNode(
            rect: CGRect(x: -panelW / 2, y: -panelH / 2, width: panelW, height: panelH),
            cornerRadius: 10
        )
        panel.fillColor   = UIColor(white: 0.08, alpha: 1)
        panel.strokeColor = UIColor(white: 0.35, alpha: 0.65)
        panel.lineWidth   = 1
        overlay.addChild(panel)

        let title             = SKLabelNode(text: "DELETE CAPTAIN?")
        title.fontName        = "AvenirNext-DemiBold"
        title.fontSize        = 14
        title.fontColor       = .white
        title.position        = CGPoint(x: 0, y: panelH / 2 - 28)
        overlay.addChild(title)

        let detail             = SKLabelNode(text: "\(profile.captainName) — this save will be permanently removed.")
        detail.fontName        = "AvenirNextCondensed-Regular"
        detail.fontSize        = 12
        detail.fontColor       = UIColor(white: 0.70, alpha: 1)
        detail.numberOfLines   = 0
        detail.preferredMaxLayoutWidth = panelW - 40
        detail.lineBreakMode   = .byWordWrapping
        detail.verticalAlignmentMode = .center
        detail.position        = CGPoint(x: 0, y: 6)
        overlay.addChild(detail)

        // Buttons — special handling: they're hit-tested manually here
        // because the normal arrays are guarded out while overlay is up.
        let yesBtn = SKShapeNode(rect: CGRect(x: -68, y: -16, width: 136, height: 32),
                                 cornerRadius: 6)
        yesBtn.fillColor   = UIColor(red: 0.85, green: 0.30, blue: 0.25, alpha: 0.92)
        yesBtn.strokeColor = UIColor(red: 1.0,  green: 0.55, blue: 0.50, alpha: 1)
        yesBtn.lineWidth   = 1
        yesBtn.position    = CGPoint(x: -78, y: -panelH / 2 + 36)
        let yesLbl             = SKLabelNode(text: "YES, DELETE")
        yesLbl.fontName        = "AvenirNext-Bold"
        yesLbl.fontSize        = 11
        yesLbl.fontColor       = .white
        yesLbl.verticalAlignmentMode = .center
        yesBtn.addChild(yesLbl)
        yesBtn.name = "confirm_yes"
        overlay.addChild(yesBtn)

        let noBtn = SKShapeNode(rect: CGRect(x: -68, y: -16, width: 136, height: 32),
                                 cornerRadius: 6)
        noBtn.fillColor   = UIColor(white: 0.18, alpha: 0.95)
        noBtn.strokeColor = UIColor(white: 0.50, alpha: 0.55)
        noBtn.lineWidth   = 1
        noBtn.position    = CGPoint(x: 78, y: -panelH / 2 + 36)
        let noLbl             = SKLabelNode(text: "CANCEL")
        noLbl.fontName        = "AvenirNext-Bold"
        noLbl.fontSize        = 11
        noLbl.fontColor       = .white
        noLbl.verticalAlignmentMode = .center
        noBtn.addChild(noLbl)
        noBtn.name = "confirm_no"
        overlay.addChild(noBtn)

        addChild(overlay)
        confirmOverlay = overlay
        pendingDelete  = profile
    }

    private var pendingDelete: SaveProfile?

    // Confirm-overlay hit testing — runs on touchesBegan when overlay exists.
    private func handleConfirmTouch(at p: CGPoint) -> Bool {
        guard let overlay = confirmOverlay else { return false }
        for child in overlay.children {
            guard let shape = child as? SKShapeNode, let name = shape.name else { continue }
            if shape.calculateAccumulatedFrame().contains(p) {
                if name == "confirm_yes", let target = pendingDelete {
                    SaveProfileStore.shared.delete(target)
                    pendingDelete = nil
                    overlay.removeFromParent()
                    confirmOverlay = nil
                    rebuild()
                } else if name == "confirm_no" {
                    pendingDelete = nil
                    overlay.removeFromParent()
                    confirmOverlay = nil
                }
                return true
            }
        }
        return true   // swallow taps outside buttons too
    }

    private func resume(profile: SaveProfile) {
        PlayerProfile.shared.loadFromSave(profile)
        guard let info = DockedPlanetInfo.load(systemName: profile.currentSystem,
                                               planetID:   profile.currentPlanetID)
        else {
            print("[LoadGameScene] missing planet \(profile.currentPlanetID) in \(profile.currentSystem)")
            return
        }
        let scene = PlanetScene(size: size, info: info, gameMode: gameMode)
        scene.scaleMode = .resizeFill
        view?.presentScene(scene, transition: .fade(withDuration: 0.40))
    }

    private func goBack() {
        let loading = LoadingScene(size: size)
        loading.scaleMode = .resizeFill
        view?.presentScene(loading, transition: .fade(withDuration: 0.25))
    }
}
