import SpriteKit
import UIKit

// MARK: – Shared outfit icon (used by OutfitterScene and ShipyardScene)

/// Returns a small coloured rounded-rect icon keyed on outfit category.
func outfitCategoryIcon(category: String?, size: CGFloat) -> SKNode {
    let color: UIColor
    switch category?.lowercased() {
    case "turrets":             color = UIColor(red: 0.90, green: 0.55, blue: 0.10, alpha: 1)
    case "guns", "weapons":     color = UIColor(red: 0.85, green: 0.25, blue: 0.25, alpha: 1)
    case "engines":             color = UIColor(red: 0.15, green: 0.50, blue: 0.90, alpha: 1)
    case "power", "reactors":   color = UIColor(red: 0.85, green: 0.80, blue: 0.10, alpha: 1)
    case "shields":             color = UIColor(red: 0.10, green: 0.75, blue: 0.85, alpha: 1)
    default:                    color = UIColor(white: 0.35, alpha: 1)
    }
    let node = SKShapeNode(
        rect: CGRect(x: -size / 2, y: -size / 2, width: size, height: size),
        cornerRadius: 5
    )
    node.fillColor   = color.withAlphaComponent(0.30)
    node.strokeColor = color.withAlphaComponent(0.85)
    node.lineWidth   = 1.5
    return node
}

// MARK: – OutfitterScene

@MainActor
final class OutfitterScene: SKScene {

    private let info:     DockedPlanetInfo
    private let gameMode: GameMode

    // Layout (set in computeLayout, used everywhere else)
    private var listLeft:      CGFloat = 0
    private var listW:         CGFloat = 0
    private var div1X:         CGFloat = 0
    private var centerLeft:    CGFloat = 0
    private var centerW:       CGFloat = 0
    private var div2X:         CGFloat = 0
    private var rightLeft:     CGFloat = 0
    private var contentTop:    CGFloat = 0
    private var contentBottom: CGFloat = 0

    // Rebuildable containers
    private var creditsLabel:        SKLabelNode!
    private var outfitListContainer: SKNode!
    private var centerContainer:     SKNode!
    private var rightContainer:      SKNode!

    // Selection
    private var selectedOutfitName: String = ""

    // Touch targets
    // staticButtons: back button — never rebuilt
    private var staticButtons:  [(node: SKShapeNode, action: () -> Void)] = []
    // outfitButtons: buy/sell — rebuilt on every buy/sell
    private var outfitButtons:  [(node: SKShapeNode, action: () -> Void)] = []
    // rowBgNodes: row selection — rebuilt on every buy/sell
    private var rowBgNodes:     [(bg: SKShapeNode, name: String)] = []

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

        computeLayout()
        selectedOutfitName = OutfitRegistry.shared.definitions.keys.sorted().first ?? ""

        buildHeader()
        buildDividers()
        buildSectionHeaders()

        outfitListContainer = SKNode(); addChild(outfitListContainer)
        centerContainer     = SKNode(); addChild(centerContainer)
        rightContainer      = SKNode(); addChild(rightContainer)

        buildOutfitList()
        buildCenterPanel()
        buildRightPanel()
    }

    // MARK: – Layout constants

    private func computeLayout() {
        let hw = size.width  / 2
        let hh = size.height / 2
        listLeft      = -hw + 16
        listW         = min(290, size.width * 0.34)
        div1X         = listLeft + listW + 8
        centerLeft    = div1X + 10
        centerW       = min(210, (size.width - listW - 90) * 0.50)
        div2X         = centerLeft + centerW + 8
        rightLeft     = div2X + 10
        contentTop    = hh  - 58
        contentBottom = -hh + 16
    }

    // MARK: – Static header

    private func buildHeader() {
        let hw = size.width  / 2
        let hh = size.height / 2

        let title             = SKLabelNode(text: "OUTFITTER")
        title.fontName        = "AvenirNext-UltraLight"
        title.fontSize        = 28
        title.fontColor       = .white
        title.horizontalAlignmentMode = .left
        title.verticalAlignmentMode   = .top
        title.position        = CGPoint(x: -hw + 24, y: hh - 12)
        addChild(title)

        creditsLabel             = SKLabelNode(text: "\(PlayerProfile.shared.credits) CR")
        creditsLabel.fontName    = "AvenirNext-Medium"
        creditsLabel.fontSize    = 11
        creditsLabel.fontColor   = UIColor(white: 0.50, alpha: 1)
        creditsLabel.horizontalAlignmentMode = .right
        creditsLabel.verticalAlignmentMode   = .center
        creditsLabel.position    = CGPoint(x: hw - 130, y: hh - 26)
        addChild(creditsLabel)

        let back = makeStaticButton(text: "← BACK",
                                    size: CGSize(width: 90, height: 28),
                                    position: CGPoint(x: hw - 60, y: hh - 26)) { [weak self] in
            self?.goBack()
        }
        addChild(back)

        let divider      = SKShapeNode()
        let dPath        = CGMutablePath()
        dPath.move(to:    CGPoint(x: -hw + 16, y: hh - 48))
        dPath.addLine(to: CGPoint(x:  hw - 16, y: hh - 48))
        divider.path        = dPath
        divider.strokeColor = UIColor(white: 1, alpha: 0.12)
        divider.lineWidth   = 1
        addChild(divider)
    }

    private func buildDividers() {
        for x in [div1X, div2X] {
            let line    = SKShapeNode()
            let path    = CGMutablePath()
            path.move(to:    CGPoint(x: x, y: contentTop - 4))
            path.addLine(to: CGPoint(x: x, y: contentBottom + 4))
            line.path        = path
            line.strokeColor = UIColor(white: 1, alpha: 0.10)
            line.lineWidth   = 1
            addChild(line)
        }
    }

    private func buildSectionHeaders() {
        addColHeader("AVAILABLE OUTFITS",  x: listLeft   + 4, y: contentTop)
        addColHeader("OUTFIT STATS",       x: centerLeft + 4, y: contentTop)
        addColHeader("YOUR SHIP",          x: rightLeft  + 4, y: contentTop)
    }

    private func addColHeader(_ text: String, x: CGFloat, y: CGFloat) {
        let lbl             = SKLabelNode(text: text)
        lbl.fontName        = "AvenirNext-DemiBold"
        lbl.fontSize        = 10
        lbl.fontColor       = UIColor(white: 0.40, alpha: 1)
        lbl.horizontalAlignmentMode = .left
        lbl.verticalAlignmentMode   = .top
        lbl.position        = CGPoint(x: x, y: y)
        addChild(lbl)
    }

    // MARK: – Outfit list (left column) — rebuilt on each buy/sell

    private func buildOutfitList() {
        outfitListContainer.removeAllChildren()
        outfitButtons.removeAll()
        rowBgNodes.removeAll()

        let rowH: CGFloat    = 70
        let profile          = PlayerProfile.shared
        var rowTop: CGFloat  = contentTop - 16

        for def in OutfitRegistry.shared.definitions.values.sorted(by: { $0.outfit < $1.outfit }) {
            guard rowTop - rowH > contentBottom else { break }

            let midY         = rowTop - rowH / 2
            let isSelected   = (def.outfit == selectedOutfitName)
            let installed    = profile.installedOutfits[def.outfit] ?? 0
            let canAffordBuy = (def.cost ?? Int.max) <= profile.credits

            // Row background
            let rowBg = SKShapeNode(
                rect: CGRect(x: listLeft + 4, y: rowTop - rowH + 2,
                             width: listW - 8, height: rowH - 4),
                cornerRadius: 4
            )
            rowBg.fillColor   = isSelected
                ? UIColor(red: 0.10, green: 0.28, blue: 0.52, alpha: 0.85)
                : UIColor(white: 0.06, alpha: 0.80)
            rowBg.strokeColor = isSelected
                ? UIColor(red: 0.28, green: 0.60, blue: 1.0, alpha: 0.60)
                : UIColor(white: 0.18, alpha: 0.45)
            rowBg.lineWidth = 1
            outfitListContainer.addChild(rowBg)
            rowBgNodes.append((rowBg, def.outfit))

            // Category icon
            let icon = outfitCategoryIcon(category: def.category, size: 38)
            icon.position = CGPoint(x: listLeft + 10 + 19, y: midY)
            outfitListContainer.addChild(icon)

            // Name
            let nameLbl             = SKLabelNode(text: def.outfit)
            nameLbl.fontName        = "AvenirNext-DemiBold"
            nameLbl.fontSize        = 11
            nameLbl.fontColor       = .white
            nameLbl.horizontalAlignmentMode = .left
            nameLbl.verticalAlignmentMode   = .center
            nameLbl.position        = CGPoint(x: listLeft + 58, y: midY + 14)
            outfitListContainer.addChild(nameLbl)

            // Category
            let catLbl             = SKLabelNode(text: def.category?.uppercased() ?? "")
            catLbl.fontName        = "AvenirNext-Regular"
            catLbl.fontSize        = 9
            catLbl.fontColor       = UIColor(white: 0.42, alpha: 1)
            catLbl.horizontalAlignmentMode = .left
            catLbl.verticalAlignmentMode   = .center
            catLbl.position        = CGPoint(x: listLeft + 58, y: midY)
            outfitListContainer.addChild(catLbl)

            // Installed count
            if installed > 0 {
                let cntLbl             = SKLabelNode(text: "×\(installed) installed")
                cntLbl.fontName        = "AvenirNextCondensed-Regular"
                cntLbl.fontSize        = 9
                cntLbl.fontColor       = UIColor(red: 0.45, green: 0.80, blue: 1.0, alpha: 0.90)
                cntLbl.horizontalAlignmentMode = .left
                cntLbl.verticalAlignmentMode   = .center
                cntLbl.position        = CGPoint(x: listLeft + 58, y: midY - 14)
                outfitListContainer.addChild(cntLbl)
            }

            // BUY / SELL buttons — kept inside the list panel to avoid clipping the divider/stats.
            let btnH: CGFloat  = 22
            let btnW: CGFloat  = 52
            let sellBtnCenterX = listLeft + listW - 8 - btnW / 2
            let buyBtnCenterX  = sellBtnCenterX - btnW - 6

            // BUY button
            let buyBtn = makeActionButton(text: "BUY", width: btnW, height: btnH,
                                          center: CGPoint(x: buyBtnCenterX, y: midY + 12),
                                          color: canAffordBuy
                                            ? UIColor(red: 0.18, green: 0.55, blue: 1.0, alpha: 0.85)
                                            : UIColor(white: 0.20, alpha: 0.60))
            outfitListContainer.addChild(buyBtn)

            let buyPriceLbl             = SKLabelNode(text: def.cost.map { crShort($0) } ?? "—")
            buyPriceLbl.fontName        = "AvenirNextCondensed-Regular"
            buyPriceLbl.fontSize        = 9
            buyPriceLbl.fontColor       = UIColor(white: 0.45, alpha: 1)
            buyPriceLbl.horizontalAlignmentMode = .center
            buyPriceLbl.verticalAlignmentMode   = .center
            buyPriceLbl.position        = CGPoint(x: buyBtnCenterX, y: midY - 6)
            outfitListContainer.addChild(buyPriceLbl)

            // SELL button
            let hasSell = installed > 0
            let sellBtn = makeActionButton(text: "SELL", width: btnW, height: btnH,
                                           center: CGPoint(x: sellBtnCenterX, y: midY + 12),
                                           color: hasSell
                                            ? UIColor(red: 0.80, green: 0.50, blue: 0.10, alpha: 0.85)
                                            : UIColor(white: 0.18, alpha: 0.55))
            outfitListContainer.addChild(sellBtn)

            let sellPriceLbl             = SKLabelNode(text: def.cost.map { crShort($0 / 2) } ?? "—")
            sellPriceLbl.fontName        = "AvenirNextCondensed-Regular"
            sellPriceLbl.fontSize        = 9
            sellPriceLbl.fontColor       = UIColor(white: 0.45, alpha: 1)
            sellPriceLbl.horizontalAlignmentMode = .center
            sellPriceLbl.verticalAlignmentMode   = .center
            sellPriceLbl.position        = CGPoint(x: sellBtnCenterX, y: midY - 6)
            outfitListContainer.addChild(sellPriceLbl)

            // Register buy / sell — buy before row bg so it wins on overlap
            if canAffordBuy {
                let name = def.outfit
                outfitButtons.append((buyBtn, { [weak self] in self?.performBuy(name: name) }))
            }
            if hasSell {
                let name = def.outfit
                outfitButtons.append((sellBtn, { [weak self] in self?.performSell(name: name) }))
            }

            rowTop -= rowH
        }
    }

    private func makeActionButton(text: String, width: CGFloat, height: CGFloat,
                                  center: CGPoint, color: UIColor) -> SKShapeNode {
        let btn = SKShapeNode(
            rect: CGRect(x: -width / 2, y: -height / 2, width: width, height: height),
            cornerRadius: 4
        )
        btn.fillColor   = color
        btn.strokeColor = color.withAlphaComponent(0.5).lighter(by: 0.3)
        btn.lineWidth   = 1
        btn.position    = center
        let lbl             = SKLabelNode(text: text)
        lbl.fontName        = "AvenirNext-Bold"
        lbl.fontSize        = 10
        lbl.fontColor       = .white
        lbl.verticalAlignmentMode   = .center
        lbl.horizontalAlignmentMode = .center
        btn.addChild(lbl)
        return btn
    }

    // MARK: – Center panel (selected outfit stats) — rebuilt on selection change

    private func buildCenterPanel() {
        centerContainer.removeAllChildren()

        guard !selectedOutfitName.isEmpty,
              let def = OutfitRegistry.shared.outfit(named: selectedOutfitName)
        else { return }

        let x   = centerLeft + 4
        var y   = contentTop - 16

        // Name
        let nameLbl             = SKLabelNode(text: def.outfit)
        nameLbl.fontName        = "AvenirNext-DemiBold"
        nameLbl.fontSize        = 13
        nameLbl.fontColor       = .white
        nameLbl.horizontalAlignmentMode = .left
        nameLbl.verticalAlignmentMode   = .top
        nameLbl.position        = CGPoint(x: x, y: y)
        centerContainer.addChild(nameLbl)
        y -= 18

        // Category
        if let cat = def.category {
            let catLbl             = SKLabelNode(text: cat.uppercased())
            catLbl.fontName        = "AvenirNext-Regular"
            catLbl.fontSize        = 10
            catLbl.fontColor       = UIColor(white: 0.40, alpha: 1)
            catLbl.horizontalAlignmentMode = .left
            catLbl.verticalAlignmentMode   = .top
            catLbl.position        = CGPoint(x: x, y: y)
            centerContainer.addChild(catLbl)
            y -= 16
        }
        y -= 4

        // Physical stats
        var statRows: [(String, String)] = []
        if let v = def.mass         { statRows.append(("MASS",        "\(Int(v)) t")) }
        if let v = def.outfitSpace  { statRows.append(("OUTFIT SPC",  "\(Int(abs(v)))")) }
        if let v = def.weaponCapacity { statRows.append(("WEAPON CAP", "\(Int(abs(v)))")) }
        if let v = def.engineCapacity { statRows.append(("ENGINE CAP", "\(Int(abs(v)))")) }

        // Weapon stats
        if let w = def.weapon {
            if let v = w.shieldDamage  { statRows.append(("SHIELD DMG",  String(format: "%.1f", v))) }
            if let v = w.hullDamage    { statRows.append(("HULL DMG",    String(format: "%.1f", v))) }
            if let v = w.velocity      { statRows.append(("VELOCITY",    "\(Int(v))")) }
            if let v = w.reload        { statRows.append(("RELOAD",      String(format: "%.1f", v))) }
            if let v = w.firingEnergy  { statRows.append(("FIRING NRG",  String(format: "%.2f", v))) }
            if let v = w.hitForce      { statRows.append(("HIT FORCE",   String(format: "%.0f", v))) }
            if let v = w.inaccuracy    { statRows.append(("INACCURACY",  String(format: "%.1f°", v))) }
        }

        for (k, v) in statRows {
            addStatRow(k, value: v, x: x, y: y)
            y -= 20
            if y < contentBottom + 8 { break }
        }
        y -= 4

        // Description (word-wrapped, truncated)
        if let desc = def.description, y > contentBottom + 24 {
            let maxW    = centerW - 8
            let descLbl = SKLabelNode(text: desc)
            descLbl.fontName              = "AvenirNextCondensed-Regular"
            descLbl.fontSize              = 10
            descLbl.fontColor             = UIColor(white: 0.58, alpha: 1)
            descLbl.numberOfLines         = 0
            descLbl.preferredMaxLayoutWidth = maxW
            descLbl.lineBreakMode         = .byWordWrapping
            descLbl.horizontalAlignmentMode = .left
            descLbl.verticalAlignmentMode   = .top
            descLbl.position              = CGPoint(x: x, y: y)
            centerContainer.addChild(descLbl)
        }
    }

    private func addStatRow(_ key: String, value: String, x: CGFloat, y: CGFloat) {
        let k             = SKLabelNode(text: key)
        k.fontName        = "AvenirNextCondensed-Regular"
        k.fontSize        = 11
        k.fontColor       = UIColor(white: 0.42, alpha: 1)
        k.horizontalAlignmentMode = .left
        k.verticalAlignmentMode   = .center
        k.position        = CGPoint(x: x, y: y)
        centerContainer.addChild(k)

        let v             = SKLabelNode(text: value)
        v.fontName        = "AvenirNextCondensed-DemiBold"
        v.fontSize        = 11
        v.fontColor       = UIColor(white: 0.90, alpha: 1)
        v.horizontalAlignmentMode = .left
        v.verticalAlignmentMode   = .center
        v.position        = CGPoint(x: x + 80, y: y)
        centerContainer.addChild(v)
    }

    // MARK: – Right panel (ship capacity + installed outfits) — rebuilt on buy/sell

    private func buildRightPanel() {
        rightContainer.removeAllChildren()

        let profile  = PlayerProfile.shared
        let def      = profile.currentShipDef
        let x        = rightLeft + 4
        var y        = contentTop - 16

        // Ship name
        let shipLbl             = SKLabelNode(text: profile.currentShip.displayName.uppercased())
        shipLbl.fontName        = "AvenirNext-DemiBold"
        shipLbl.fontSize        = 12
        shipLbl.fontColor       = .white
        shipLbl.horizontalAlignmentMode = .left
        shipLbl.verticalAlignmentMode   = .top
        shipLbl.position        = CGPoint(x: x, y: y)
        rightContainer.addChild(shipLbl)
        y -= 20

        // Capacity bars
        let barW    = (size.width / 2 - 16) - rightLeft - 4 - 58  // leaves room for X/Y label
        let bars: [(String, Double, Double, UIColor)] = [
            ("OUTFIT SPC",  profile.outfitSpaceUsed,    def?.attributes.outfitSpace    ?? 0,
             UIColor(red: 0.18, green: 0.55, blue: 1.0, alpha: 1)),
            ("WEAPON CAP",  profile.weaponCapacityUsed, def?.attributes.weaponCapacity ?? 0,
             UIColor(red: 0.90, green: 0.50, blue: 0.10, alpha: 1)),
            ("ENGINE CAP",  profile.engineCapacityUsed, def?.attributes.engineCapacity ?? 0,
             UIColor(red: 0.10, green: 0.75, blue: 0.40, alpha: 1)),
        ]

        for (label, used, total, color) in bars {
            addCapacityBar(label: label, used: used, total: total, color: color,
                           x: x, y: y, barWidth: max(barW, 60))
            y -= 30
        }
        y -= 8

        // Divider
        let sep = SKShapeNode()
        let sp  = CGMutablePath()
        sp.move(to:    CGPoint(x: x,           y: y))
        sp.addLine(to: CGPoint(x: size.width / 2 - 16, y: y))
        sep.path        = sp
        sep.strokeColor = UIColor(white: 1, alpha: 0.08)
        sep.lineWidth   = 1
        rightContainer.addChild(sep)
        y -= 12

        // Section label
        let instLbl             = SKLabelNode(text: "INSTALLED OUTFITS")
        instLbl.fontName        = "AvenirNext-DemiBold"
        instLbl.fontSize        = 10
        instLbl.fontColor       = UIColor(white: 0.40, alpha: 1)
        instLbl.horizontalAlignmentMode = .left
        instLbl.verticalAlignmentMode   = .top
        instLbl.position        = CGPoint(x: x, y: y)
        rightContainer.addChild(instLbl)
        y -= 16

        // Installed outfit rows — show all, registry-defined first
        let defined   = profile.installedOutfits.keys.filter {
            OutfitRegistry.shared.outfit(named: $0) != nil }.sorted()
        let undefined = profile.installedOutfits.keys.filter {
            OutfitRegistry.shared.outfit(named: $0) == nil }.sorted()

        let panelRight = size.width / 2 - 16
        for name in defined + undefined {
            guard let count = profile.installedOutfits[name], y > contentBottom + 8 else { break }
            let isSelected = (name == selectedOutfitName)

            if isSelected {
                let hi = SKShapeNode(
                    rect: CGRect(x: x - 4, y: y - 8, width: panelRight - x + 4, height: 16),
                    cornerRadius: 3
                )
                hi.fillColor   = UIColor(red: 0.10, green: 0.28, blue: 0.52, alpha: 0.70)
                hi.strokeColor = UIColor(red: 0.28, green: 0.60, blue: 1.0, alpha: 0.55)
                hi.lineWidth   = 1
                rightContainer.addChild(hi)
            }

            let txt             = count > 1 ? "\(name)  ×\(count)" : name
            let lbl             = SKLabelNode(text: txt)
            lbl.fontName        = "AvenirNextCondensed-Regular"
            lbl.fontSize        = 10
            lbl.fontColor       = isSelected ? .white : UIColor(white: 0.72, alpha: 1)
            lbl.horizontalAlignmentMode = .left
            lbl.verticalAlignmentMode   = .center
            lbl.position        = CGPoint(x: x, y: y)
            rightContainer.addChild(lbl)
            y -= 18
        }
    }

    private func addCapacityBar(label: String, used: Double, total: Double,
                                color: UIColor, x: CGFloat, y: CGFloat, barWidth: CGFloat) {
        let keyLbl             = SKLabelNode(text: label)
        keyLbl.fontName        = "AvenirNextCondensed-Regular"
        keyLbl.fontSize        = 10
        keyLbl.fontColor       = UIColor(white: 0.45, alpha: 1)
        keyLbl.horizontalAlignmentMode = .left
        keyLbl.verticalAlignmentMode   = .top
        keyLbl.position        = CGPoint(x: x, y: y)
        rightContainer.addChild(keyLbl)

        let barY       = y - 16
        let barBg      = SKShapeNode(rect: CGRect(x: 0, y: -3, width: barWidth, height: 6),
                                     cornerRadius: 3)
        barBg.fillColor   = UIColor(white: 0.14, alpha: 1)
        barBg.strokeColor = .clear
        barBg.position    = CGPoint(x: x, y: barY)
        rightContainer.addChild(barBg)

        if total > 0 {
            let fraction   = min(used / total, 1.0)
            let fillColor  = fraction > 0.90 ? UIColor(red: 0.85, green: 0.25, blue: 0.15, alpha: 1)
                           : fraction > 0.70 ? UIColor(red: 0.85, green: 0.70, blue: 0.10, alpha: 1)
                           : color
            let fillW = barWidth * CGFloat(fraction)
            if fillW > 2 {
                let fill = SKShapeNode(rect: CGRect(x: 0, y: -3, width: fillW, height: 6),
                                       cornerRadius: 3)
                fill.fillColor   = fillColor
                fill.strokeColor = .clear
                fill.position    = CGPoint(x: x, y: barY)
                rightContainer.addChild(fill)
            }
        }

        let valStr        = total > 0 ? "\(Int(used))/\(Int(total))" : "\(Int(used))"
        let valLbl        = SKLabelNode(text: valStr)
        valLbl.fontName   = "AvenirNextCondensed-DemiBold"
        valLbl.fontSize   = 10
        valLbl.fontColor  = UIColor(white: 0.80, alpha: 1)
        valLbl.horizontalAlignmentMode = .left
        valLbl.verticalAlignmentMode   = .center
        valLbl.position   = CGPoint(x: x + barWidth + 6, y: barY)
        rightContainer.addChild(valLbl)
    }

    // MARK: – Buy / sell actions

    private func performBuy(name: String) {
        guard PlayerProfile.shared.buyOutfit(named: name) else { return }
        didModifyOutfits()
    }

    private func performSell(name: String) {
        guard PlayerProfile.shared.sellOutfit(named: name) else { return }
        didModifyOutfits()
    }

    private func didModifyOutfits() {
        creditsLabel.text = "\(PlayerProfile.shared.credits) CR"
        buildOutfitList()
        buildRightPanel()
    }

    // MARK: – Outfit selection

    private func selectOutfit(name: String) {
        guard name != selectedOutfitName else { return }
        selectedOutfitName = name
        // Update row highlight colours
        for (bg, n) in rowBgNodes {
            let sel       = (n == name)
            bg.fillColor  = sel
                ? UIColor(red: 0.10, green: 0.28, blue: 0.52, alpha: 0.85)
                : UIColor(white: 0.06, alpha: 0.80)
            bg.strokeColor = sel
                ? UIColor(red: 0.28, green: 0.60, blue: 1.0, alpha: 0.60)
                : UIColor(white: 0.18, alpha: 0.45)
        }
        buildCenterPanel()
        buildRightPanel()
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

        for (node, action) in staticButtons where node.contains(pt) {
            flash(node); action(); return
        }
        // Buy/sell take priority over row selection
        for (node, action) in outfitButtons where node.contains(pt) {
            flash(node); action(); return
        }
        for (bg, name) in rowBgNodes where bg.contains(pt) {
            selectOutfit(name: name); return
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

    // MARK: – Static button factory (back only)

    private func makeStaticButton(text: String, size s: CGSize, position: CGPoint,
                                  action: @escaping () -> Void) -> SKShapeNode {
        let btn = SKShapeNode(
            rect: CGRect(x: -s.width / 2, y: -s.height / 2, width: s.width, height: s.height),
            cornerRadius: 5
        )
        btn.fillColor   = UIColor(white: 0.18, alpha: 0.95)
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
        staticButtons.append((btn, action))
        return btn
    }

    // MARK: – Formatting helpers

    private func crShort(_ amount: Int) -> String {
        if amount >= 1_000_000 { return String(format: "%.1fM", Double(amount) / 1_000_000) }
        if amount >= 1_000     { return String(format: "%.0fk", Double(amount) / 1_000) }
        return "\(amount)"
    }
}

// MARK: – UIColor convenience

private extension UIColor {
    func lighter(by amount: CGFloat) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return UIColor(hue: h, saturation: s, brightness: min(b + amount, 1), alpha: a)
    }
}
