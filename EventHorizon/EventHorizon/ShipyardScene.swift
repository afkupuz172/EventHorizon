import SpriteKit
import SceneKit
import UIKit

@MainActor
final class ShipyardScene: SKScene {

    private let info:     DockedPlanetInfo
    private let gameMode: GameMode

    private var activeTab = 0
    private var tab1Container: SKNode!
    private var tab2Container: SKNode!
    private var tabBtns:       [SKShapeNode] = []

    private var selectedShipID: String = ""
    private var shipRowBgs:     [(bg: SKShapeNode, shipID: String)] = []
    private var tab2StatsNode:  SKNode!

    // All tappable buttons (back, tab switches, BUY). Row-bg selection is
    // handled separately in touchesBegan so BUY always wins over the row tap.
    private var buttons: [(node: SKShapeNode, action: () -> Void)] = []

    // MARK: – Init

    init(size: CGSize, info: DockedPlanetInfo, gameMode: GameMode) {
        self.info     = info
        self.gameMode = gameMode
        super.init(size: size)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: – Lifecycle

    override func didMove(to view: SKView) {
        backgroundColor = UIColor(white: 0.02, alpha: 1)
        anchorPoint     = CGPoint(x: 0.5, y: 0.5)

        selectedShipID = PlayerProfile.shared.currentShipID

        buildHeader()
        buildTabBar()
        buildTab1()
        buildTab2()
        showTab(0)
    }

    // MARK: – Header

    private func buildHeader() {
        let hw = size.width / 2
        let hh = size.height / 2

        let title             = SKLabelNode(text: "SHIPYARD")
        title.fontName        = "AvenirNext-UltraLight"
        title.fontSize        = 28
        title.fontColor       = .white
        title.horizontalAlignmentMode = .left
        title.verticalAlignmentMode   = .top
        title.position        = CGPoint(x: -hw + 24, y: hh - 12)
        addChild(title)

        let credits             = SKLabelNode(text: "\(PlayerProfile.shared.credits) CR")
        credits.fontName        = "AvenirNext-Medium"
        credits.fontSize        = 11
        credits.fontColor       = UIColor(white: 0.50, alpha: 1)
        credits.horizontalAlignmentMode = .right
        credits.verticalAlignmentMode   = .center
        credits.position        = CGPoint(x: hw - 130, y: hh - 26)
        addChild(credits)

        let back = makeButton(text: "← BACK",
                              size: CGSize(width: 90, height: 28),
                              position: CGPoint(x: hw - 60, y: hh - 26),
                              accent: UIColor(white: 0.18, alpha: 0.95)) { [weak self] in
            self?.goBack()
        }
        addChild(back)

        let divider = SKShapeNode()
        let path    = CGMutablePath()
        path.move(to:    CGPoint(x: -hw + 16, y: hh - 48))
        path.addLine(to: CGPoint(x:  hw - 16, y: hh - 48))
        divider.path        = path
        divider.strokeColor = UIColor(white: 1, alpha: 0.12)
        divider.lineWidth   = 1
        addChild(divider)
    }

    // MARK: – Tab bar

    private func buildTabBar() {
        let hw  = size.width  / 2
        let hh  = size.height / 2
        let tabW: CGFloat = 130
        let tabH: CGFloat = 28
        let tabY: CGFloat = hh - 66
        let startX        = -hw + 24 + tabW / 2

        for (i, label) in ["MY SHIP", "FOR SALE"].enumerated() {
            let x   = startX + CGFloat(i) * (tabW + 8)
            let btn = SKShapeNode(
                rect: CGRect(x: -tabW / 2, y: -tabH / 2, width: tabW, height: tabH),
                cornerRadius: 4
            )
            btn.position = CGPoint(x: x, y: tabY)
            btn.lineWidth = 1

            let lbl = SKLabelNode(text: label)
            lbl.fontName                  = "AvenirNext-DemiBold"
            lbl.fontSize                  = 12
            lbl.verticalAlignmentMode     = .center
            lbl.horizontalAlignmentMode   = .center
            btn.addChild(lbl)
            addChild(btn)
            tabBtns.append(btn)

            let idx = i
            buttons.append((btn, { [weak self] in self?.showTab(idx) }))
        }
        styleTabButtons()
    }

    private func styleTabButtons() {
        for (i, btn) in tabBtns.enumerated() {
            let active      = (i == activeTab)
            btn.fillColor   = active
                ? UIColor(red: 0.18, green: 0.55, blue: 1.0, alpha: 0.85)
                : UIColor(white: 0.12, alpha: 0.90)
            btn.strokeColor = active
                ? UIColor(red: 0.45, green: 0.80, blue: 1.0, alpha: 1.0)
                : UIColor(white: 0.30, alpha: 0.60)
            if let lbl = btn.children.first as? SKLabelNode {
                lbl.fontColor = active ? .white : UIColor(white: 0.65, alpha: 1)
            }
        }
    }

    private func showTab(_ index: Int) {
        activeTab = index
        styleTabButtons()
        tab1Container.isHidden = (index != 0)
        tab2Container.isHidden = (index != 1)
    }

    // MARK: – Tab 1: My Ship

    private func buildTab1() {
        let hw = size.width  / 2
        let hh = size.height / 2

        let container      = SKNode()
        container.isHidden = true
        addChild(container)
        tab1Container = container

        let contentTop:    CGFloat = hh  - 88
        let contentBottom: CGFloat = -hh + 16
        let midY           = (contentTop + contentBottom) / 2

        let profile  = PlayerProfile.shared
        let metadata = profile.currentShip
        let def      = profile.currentShipDef

        // ── Left: ship thumbnail ─────────────────────────────────────────────
        let thumbSize = CGSize(width: 170, height: 170)
        let thumbX    = -hw + 24 + thumbSize.width / 2

        let thumb = ShipNode.staticThumbnail(metadata: metadata, viewportSize: thumbSize)
        thumb.position = CGPoint(x: thumbX, y: midY + 10)
        container.addChild(thumb)

        let nameLbl             = SKLabelNode(text: metadata.displayName.uppercased())
        nameLbl.fontName        = "AvenirNext-DemiBold"
        nameLbl.fontSize        = 12
        nameLbl.fontColor       = .white
        nameLbl.horizontalAlignmentMode = .center
        nameLbl.verticalAlignmentMode   = .top
        nameLbl.position        = CGPoint(x: thumbX, y: midY + 10 - thumbSize.height / 2 - 4)
        container.addChild(nameLbl)

        let catLbl             = SKLabelNode(text: (def?.attributes.category ?? "Unknown").uppercased())
        catLbl.fontName        = "AvenirNext-Regular"
        catLbl.fontSize        = 10
        catLbl.fontColor       = UIColor(white: 0.45, alpha: 1)
        catLbl.horizontalAlignmentMode = .center
        catLbl.verticalAlignmentMode   = .top
        catLbl.position        = CGPoint(x: thumbX, y: midY + 10 - thumbSize.height / 2 - 18)
        container.addChild(catLbl)

        // ── Vertical divider ─────────────────────────────────────────────────
        let divX     = -hw + 24 + thumbSize.width + 18
        let divLine  = SKShapeNode()
        let divPath  = CGMutablePath()
        divPath.move(to:    CGPoint(x: divX, y: contentTop - 6))
        divPath.addLine(to: CGPoint(x: divX, y: contentBottom + 6))
        divLine.path        = divPath
        divLine.strokeColor = UIColor(white: 1, alpha: 0.10)
        divLine.lineWidth   = 1
        container.addChild(divLine)

        // ── Right side: stats column + outfits column ────────────────────────
        let rightStart = divX + 18
        let rightWidth = hw - 16 - rightStart
        let statsColW: CGFloat = min(200, rightWidth * 0.45)
        let outfitColX = rightStart + statsColW + 18

        addSectionHeader("ATTRIBUTES", x: rightStart, y: contentTop - 4, parent: container)

        let a = def?.attributes
        let statsRows: [(String, String)] = [
            ("SHIELDS",    fmt(a?.shields)),
            ("HULL",       fmt(a?.hull)),
            ("FUEL CAP",   fmtOpt(a?.fuelCapacity)),
            ("MASS",       fmtOpt(a?.mass, suffix: " t")),
            ("CARGO",      fmtOpt(a?.cargoSpace, suffix: " u³")),
            ("OUTFIT SPC", fmtOpt(a?.outfitSpace)),
            ("ENGINE CAP", fmtOpt(a?.engineCapacity)),
            ("WEAPON CAP", fmtOpt(a?.weaponCapacity)),
        ]

        var sy = contentTop - 22
        for (key, val) in statsRows {
            addStatRow(key: key, value: val, x: rightStart, y: sy, parent: container)
            sy -= 21
        }

        addSectionHeader("OUTFITS", x: outfitColX, y: contentTop - 4, parent: container)

        var oy = contentTop - 22
        for outfit in def?.outfits ?? [] {
            let txt = outfit.count > 1 ? "\(outfit.count)× \(outfit.name)" : outfit.name
            let lbl = SKLabelNode(text: txt)
            lbl.fontName                  = "AvenirNextCondensed-Regular"
            lbl.fontSize                  = 11
            lbl.fontColor                 = UIColor(white: 0.72, alpha: 1)
            lbl.horizontalAlignmentMode   = .left
            lbl.verticalAlignmentMode     = .center
            lbl.position                  = CGPoint(x: outfitColX, y: oy)
            container.addChild(lbl)
            oy -= 17
            if oy < contentBottom + 8 { break }
        }
    }

    // MARK: – Tab 2: For Sale

    private func buildTab2() {
        let hw = size.width  / 2
        let hh = size.height / 2

        let container      = SKNode()
        container.isHidden = true
        addChild(container)
        tab2Container = container

        let contentTop:    CGFloat = hh  - 88
        let contentBottom: CGFloat = -hh + 16

        let listW:   CGFloat = min(320, size.width * 0.38)
        let listLeft: CGFloat = -hw + 16
        let dividerX  = listLeft + listW + 10

        // Vertical divider
        let divLine = SKShapeNode()
        let divPath = CGMutablePath()
        divPath.move(to:    CGPoint(x: dividerX, y: contentTop - 6))
        divPath.addLine(to: CGPoint(x: dividerX, y: contentBottom + 6))
        divLine.path        = divPath
        divLine.strokeColor = UIColor(white: 1, alpha: 0.10)
        divLine.lineWidth   = 1
        container.addChild(divLine)

        addSectionHeader("AVAILABLE SHIPS", x: listLeft + 6, y: contentTop - 4, parent: container)

        // ── Ship rows ────────────────────────────────────────────────────────
        let rowH: CGFloat = 66
        let currentID     = PlayerProfile.shared.currentShipID
        var rowTop        = contentTop - 22

        for entry in PlayerProfile.shared.availableShips {
            guard rowTop - rowH > contentBottom else { break }

            let isCurrent  = entry.id == currentID
            let isSelected = entry.id == selectedShipID
            let rowMidY    = rowTop - rowH / 2

            // Row background (tap to select)
            let rowBg = SKShapeNode(
                rect: CGRect(x: listLeft + 4,
                             y: rowTop - rowH + 2,
                             width: listW - 8,
                             height: rowH - 4),
                cornerRadius: 4
            )
            rowBg.fillColor   = isSelected
                ? UIColor(red: 0.10, green: 0.28, blue: 0.52, alpha: 0.85)
                : UIColor(white: 0.06, alpha: 0.80)
            rowBg.strokeColor = isSelected
                ? UIColor(red: 0.28, green: 0.60, blue: 1.0, alpha: 0.60)
                : UIColor(white: 0.18, alpha: 0.45)
            rowBg.lineWidth = 1
            container.addChild(rowBg)
            shipRowBgs.append((rowBg, entry.id))

            // Mini thumbnail
            let miniSize   = CGSize(width: 48, height: 48)
            let miniThumb  = ShipNode.staticThumbnail(metadata: entry.metadata, viewportSize: miniSize)
            miniThumb.position = CGPoint(x: listLeft + 10 + miniSize.width / 2, y: rowMidY)
            container.addChild(miniThumb)

            // Ship name
            let nameLabel             = SKLabelNode(text: entry.metadata.displayName)
            nameLabel.fontName        = "AvenirNext-DemiBold"
            nameLabel.fontSize        = 13
            nameLabel.fontColor       = .white
            nameLabel.horizontalAlignmentMode = .left
            nameLabel.verticalAlignmentMode   = .center
            nameLabel.position        = CGPoint(x: listLeft + 66, y: rowMidY + 11)
            container.addChild(nameLabel)

            // Cost label
            let cost      = ShipRegistry.shared.def(for: entry.id)?.attributes.cost ?? 0
            let costLabel             = SKLabelNode(text: formatCR(cost))
            costLabel.fontName        = "AvenirNextCondensed-Regular"
            costLabel.fontSize        = 11
            costLabel.fontColor       = UIColor(white: 0.52, alpha: 1)
            costLabel.horizontalAlignmentMode = .left
            costLabel.verticalAlignmentMode   = .center
            costLabel.position        = CGPoint(x: listLeft + 66, y: rowMidY - 11)
            container.addChild(costLabel)

            // BUY / CURRENT button — placed to the right of the cost label
            let btnW: CGFloat = 76
            let btnH: CGFloat = 24
            let buyBtn = SKShapeNode(
                rect: CGRect(x: -btnW / 2, y: -btnH / 2, width: btnW, height: btnH),
                cornerRadius: 4
            )
            buyBtn.position = CGPoint(x: listLeft + listW - btnW / 2 - 10, y: rowMidY)
            buyBtn.lineWidth = 1

            let btnLbl             = SKLabelNode(text: isCurrent ? "CURRENT" : "BUY")
            btnLbl.fontName        = "AvenirNext-Bold"
            btnLbl.fontSize        = 10
            btnLbl.verticalAlignmentMode   = .center
            btnLbl.horizontalAlignmentMode = .center
            buyBtn.addChild(btnLbl)

            if isCurrent {
                buyBtn.fillColor   = UIColor(white: 0.16, alpha: 0.75)
                buyBtn.strokeColor = UIColor(white: 0.35, alpha: 0.45)
                btnLbl.fontColor   = UIColor(white: 0.50, alpha: 1)
            } else {
                buyBtn.fillColor   = UIColor(red: 0.18, green: 0.55, blue: 1.0, alpha: 0.85)
                buyBtn.strokeColor = UIColor(red: 0.45, green: 0.80, blue: 1.0, alpha: 1.0)
                btnLbl.fontColor   = .white
                let sid = entry.id
                // BUY buttons registered BEFORE row-bg selection so they win on overlap.
                buttons.append((buyBtn, { [weak self] in self?.purchaseShip(id: sid) }))
            }
            container.addChild(buyBtn)

            rowTop -= rowH
        }

        // ── Right: selected ship stats ───────────────────────────────────────
        let statsNode = SKNode()
        container.addChild(statsNode)
        tab2StatsNode = statsNode
        refreshTab2Stats(contentTop: contentTop, dividerX: dividerX)
    }

    private func refreshTab2Stats(contentTop: CGFloat, dividerX: CGFloat) {
        tab2StatsNode.removeAllChildren()

        guard let entry = PlayerProfile.shared.availableShips.first(where: { $0.id == selectedShipID }),
              let def   = ShipRegistry.shared.def(for: selectedShipID)
        else { return }

        let x = dividerX + 18
        let a = def.attributes

        let nameLbl             = SKLabelNode(text: entry.metadata.displayName.uppercased())
        nameLbl.fontName        = "AvenirNext-DemiBold"
        nameLbl.fontSize        = 14
        nameLbl.fontColor       = .white
        nameLbl.horizontalAlignmentMode = .left
        nameLbl.verticalAlignmentMode   = .top
        nameLbl.position        = CGPoint(x: x, y: contentTop - 4)
        tab2StatsNode.addChild(nameLbl)

        if let cat = a.category {
            let catLbl             = SKLabelNode(text: cat.uppercased())
            catLbl.fontName        = "AvenirNext-Regular"
            catLbl.fontSize        = 10
            catLbl.fontColor       = UIColor(white: 0.42, alpha: 1)
            catLbl.horizontalAlignmentMode = .left
            catLbl.verticalAlignmentMode   = .top
            catLbl.position        = CGPoint(x: x, y: contentTop - 22)
            tab2StatsNode.addChild(catLbl)
        }

        let rows: [(String, String)] = [
            ("SHIELDS",    fmt(a.shields)),
            ("HULL",       fmt(a.hull)),
            ("FUEL CAP",   fmtOpt(a.fuelCapacity)),
            ("MASS",       fmtOpt(a.mass, suffix: " t")),
            ("CARGO",      fmtOpt(a.cargoSpace, suffix: " u³")),
            ("OUTFIT SPC", fmtOpt(a.outfitSpace)),
            ("ENGINE CAP", fmtOpt(a.engineCapacity)),
            ("COST",       a.cost.map { formatCR($0) } ?? "—"),
        ]

        // Attributes column (left) + Outfits column (right) inside the right panel.
        let hw = size.width / 2
        let rightWidth = hw - 16 - x
        let statsColW: CGFloat = min(200, rightWidth * 0.55)
        let outfitColX = x + statsColW + 18

        var sy = contentTop - 40
        for (key, val) in rows {
            addStatRow(key: key, value: val, x: x, y: sy, parent: tab2StatsNode)
            sy -= 21
        }

        addSectionHeader("OUTFITS", x: outfitColX, y: contentTop - 22, parent: tab2StatsNode)

        let contentBottom: CGFloat = -size.height / 2 + 16
        var oy = contentTop - 40
        for outfit in def.outfits ?? [] {
            let txt = outfit.count > 1 ? "\(outfit.count)× \(outfit.name)" : outfit.name
            let lbl = SKLabelNode(text: txt)
            lbl.fontName                  = "AvenirNextCondensed-Regular"
            lbl.fontSize                  = 11
            lbl.fontColor                 = UIColor(white: 0.72, alpha: 1)
            lbl.horizontalAlignmentMode   = .left
            lbl.verticalAlignmentMode     = .center
            lbl.position                  = CGPoint(x: outfitColX, y: oy)
            tab2StatsNode.addChild(lbl)
            oy -= 17
            if oy < contentBottom + 8 { break }
        }
    }

    // MARK: – Selection / purchase

    private func selectShip(id: String) {
        selectedShipID = id
        for (bg, sid) in shipRowBgs {
            let sel       = (sid == id)
            bg.fillColor  = sel
                ? UIColor(red: 0.10, green: 0.28, blue: 0.52, alpha: 0.85)
                : UIColor(white: 0.06, alpha: 0.80)
            bg.strokeColor = sel
                ? UIColor(red: 0.28, green: 0.60, blue: 1.0, alpha: 0.60)
                : UIColor(white: 0.18, alpha: 0.45)
        }
        let hh          = size.height / 2
        let hw          = size.width  / 2
        let listW       = min(320.0, size.width * 0.38)
        let dividerX    = -hw + 16 + listW + 10
        refreshTab2Stats(contentTop: hh - 88, dividerX: dividerX)
    }

    private func purchaseShip(id: String) {
        PlayerProfile.shared.currentShipID = id
        // Re-present so MY SHIP tab reflects the purchase immediately.
        let next           = ShipyardScene(size: size, info: info, gameMode: gameMode)
        next.scaleMode     = .resizeFill
        view?.presentScene(next, transition: .fade(withDuration: 0.25))
    }

    // MARK: – Navigation

    private func goBack() {
        let planet         = PlanetScene(size: size, info: info, gameMode: gameMode)
        planet.scaleMode   = .resizeFill
        view?.presentScene(planet, transition: .fade(withDuration: 0.35))
    }

    // MARK: – Touch

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let pt = touch.location(in: self)

        // BUY buttons, tab buttons, and BACK take priority.
        for (node, action) in buttons where node.contains(pt) {
            flash(node)
            action()
            return
        }

        // Row background — selection only, lower priority than BUY.
        for (bg, sid) in shipRowBgs where bg.contains(pt) {
            selectShip(id: sid)
            return
        }
    }

    private func flash(_ node: SKShapeNode) {
        let orig = node.fillColor
        node.run(.sequence([
            .run { node.fillColor = UIColor(red: 0.55, green: 0.85, blue: 1.0, alpha: 0.95) },
            .wait(forDuration: 0.10),
            .run { node.fillColor = orig },
        ]))
    }

    // MARK: – UI helpers

    private func addSectionHeader(_ text: String, x: CGFloat, y: CGFloat, parent: SKNode) {
        let lbl             = SKLabelNode(text: text)
        lbl.fontName        = "AvenirNext-DemiBold"
        lbl.fontSize        = 10
        lbl.fontColor       = UIColor(white: 0.40, alpha: 1)
        lbl.horizontalAlignmentMode = .left
        lbl.verticalAlignmentMode   = .top
        lbl.position        = CGPoint(x: x, y: y)
        parent.addChild(lbl)
    }

    private func addStatRow(key: String, value: String, x: CGFloat, y: CGFloat, parent: SKNode) {
        let k             = SKLabelNode(text: key)
        k.fontName        = "AvenirNextCondensed-Regular"
        k.fontSize        = 11
        k.fontColor       = UIColor(white: 0.42, alpha: 1)
        k.horizontalAlignmentMode = .left
        k.verticalAlignmentMode   = .center
        k.position        = CGPoint(x: x, y: y)
        parent.addChild(k)

        let v             = SKLabelNode(text: value)
        v.fontName        = "AvenirNextCondensed-DemiBold"
        v.fontSize        = 11
        v.fontColor       = UIColor(white: 0.90, alpha: 1)
        v.horizontalAlignmentMode = .left
        v.verticalAlignmentMode   = .center
        v.position        = CGPoint(x: x + 88, y: y)
        parent.addChild(v)
    }

    private func makeButton(text: String,
                            size s: CGSize,
                            position: CGPoint,
                            accent: UIColor,
                            action: @escaping () -> Void) -> SKShapeNode {
        let btn = SKShapeNode(
            rect: CGRect(x: -s.width / 2, y: -s.height / 2,
                         width: s.width, height: s.height),
            cornerRadius: 5
        )
        btn.fillColor   = accent
        btn.strokeColor = UIColor(white: 1, alpha: 0.28)
        btn.lineWidth   = 1
        btn.position    = position

        let lbl             = SKLabelNode(text: text)
        lbl.fontName        = "AvenirNext-DemiBold"
        lbl.fontSize        = 12
        lbl.fontColor       = .white
        lbl.verticalAlignmentMode   = .center
        lbl.horizontalAlignmentMode = .center
        btn.addChild(lbl)

        buttons.append((btn, action))
        return btn
    }

    // MARK: – Formatting helpers

    private func fmt(_ v: Double?) -> String {
        guard let v else { return "—" }
        return "\(Int(v))"
    }

    private func fmtOpt(_ v: Double?, suffix: String = "") -> String {
        guard let v else { return "—" }
        return "\(Int(v))\(suffix)"
    }

    private func formatCR(_ amount: Int) -> String {
        if amount >= 1_000_000 {
            return String(format: "%.1fM cr", Double(amount) / 1_000_000)
        }
        if amount >= 1_000 {
            return String(format: "%.1fk cr", Double(amount) / 1_000)
        }
        return "\(amount) cr"
    }
}
