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

    // Tab 1 hardpoint customisation state — mirrors the outfitter so the
    // player can also customise mount assignments straight from the
    // shipyard's MY SHIP view.
    private struct HardpointMarker {
        let slot: String                // e.g. "turret_0"
        let kind: HardpointKind
        let node: SKShapeNode
        let label: SKLabelNode
    }
    private var hardpointMarkers: [HardpointMarker] = []
    /// `(node, outfitID, sourceSlot)` — `sourceSlot` is `nil` for icons
    /// in the inventory column (a fresh assignment); it's the slot key
    /// when the drag started on a hardpoint marker so the source can be
    /// vacated on drop.
    private var inventoryIconHits: [(node: SKNode, outfitID: String, sourceSlot: String?)] = []
    private var dragOutfitID:   String?
    private var dragSourceSlot: String?
    private var dragGhost:      SKNode?
    private var dragHoverSlot:  String?
    private var lastDragPoint:  CGPoint = .zero

    // Scrollable inventory columns — separate for WEAPONS (col 3) and
    // ALL OUTFITS (col 4) so they pan independently.
    private var weaponsListContainer = SKNode()
    private var weaponsListScroll:    CGFloat = 0
    private var weaponsListHeight:    CGFloat = 0
    private var weaponsListViewport:  CGFloat = 0
    private var allListContainer     = SKNode()
    private var allListScroll:        CGFloat = 0
    private var allListHeight:        CGFloat = 0
    private var allListViewport:      CGFloat = 0
    /// X-range tags so `touchesMoved` knows which column owns the drag.
    private var weaponsListXRange:   ClosedRange<CGFloat> = 0...0
    private var allListXRange:       ClosedRange<CGFloat> = 0...0
    private enum ActiveScroll { case none, weapons, all }
    private var activeScroll: ActiveScroll = .none
    private var scrollLastY: CGFloat = 0
    private var scrollMovedEnough = false

    private enum RowHighlightStyle { case fillBox, none }

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

    // MARK: – Tab 1: My Ship (thumbnail + hardpoints + draggable inventory)

    private func buildTab1() {
        let hw = size.width  / 2
        let hh = size.height / 2

        let container      = SKNode()
        container.isHidden = true
        addChild(container)
        tab1Container = container

        // Reset per-tab1 customisation state.
        hardpointMarkers.removeAll()
        inventoryIconHits.removeAll()

        let contentTop:    CGFloat = hh  - 88
        let contentBottom: CGFloat = -hh + 16
        let midY           = (contentTop + contentBottom) / 2

        let profile  = PlayerProfile.shared
        let metadata = profile.currentShip
        let def      = profile.currentShipDef

        // ── Left column: ship thumbnail + hardpoint markers ─────────────────
        let thumbSize = CGSize(width: 200, height: 200)
        let thumbX    = -hw + 24 + thumbSize.width / 2
        let thumbY    = midY + 8

        let thumb = ShipNode.staticThumbnail(metadata: metadata, viewportSize: thumbSize)
        thumb.position = CGPoint(x: thumbX, y: thumbY)
        container.addChild(thumb)

        let nameLbl             = SKLabelNode(text: metadata.displayName.uppercased())
        nameLbl.fontName        = "AvenirNext-DemiBold"
        nameLbl.fontSize        = 12
        nameLbl.fontColor       = .white
        nameLbl.horizontalAlignmentMode = .center
        nameLbl.verticalAlignmentMode   = .top
        nameLbl.position        = CGPoint(x: thumbX, y: thumbY - thumbSize.height / 2 - 4)
        container.addChild(nameLbl)

        let catLbl             = SKLabelNode(text: (def?.attributes.category ?? "Unknown").uppercased())
        catLbl.fontName        = "AvenirNext-Regular"
        catLbl.fontSize        = 10
        catLbl.fontColor       = UIColor(white: 0.45, alpha: 1)
        catLbl.horizontalAlignmentMode = .center
        catLbl.verticalAlignmentMode   = .top
        catLbl.position        = CGPoint(x: thumbX, y: thumbY - thumbSize.height / 2 - 18)
        container.addChild(catLbl)

        // Hardpoint markers — turret/gun/engine, each in its theme colour
        // (see `HardpointKind.color`). Body-local coords are scaled to
        // the thumbnail's pixel size.
        let viewW    = metadata.viewportSize.width
        let scale    = thumbSize.width / max(1, viewW)
        for (i, mount) in (def?.turrets ?? []).enumerated() {
            installHardpointMarker(slot: "turret_\(i)", kind: .turret, mount: mount,
                                   weaponID: profile.mountAssignments["turret_\(i)"],
                                   centerX: thumbX, centerY: thumbY, scale: scale,
                                   parent: container)
        }
        for (i, mount) in (def?.guns ?? []).enumerated() {
            installHardpointMarker(slot: "gun_\(i)", kind: .gun, mount: mount,
                                   weaponID: profile.mountAssignments["gun_\(i)"],
                                   centerX: thumbX, centerY: thumbY, scale: scale,
                                   parent: container)
        }
        for (i, mount) in (def?.engines ?? []).enumerated() {
            installHardpointMarker(slot: "engine_\(i)", kind: .engine, mount: mount,
                                   weaponID: profile.mountAssignments["engine_\(i)"],
                                   centerX: thumbX, centerY: thumbY, scale: scale,
                                   parent: container)
        }

        // ── Vertical divider 1 ──────────────────────────────────────────────
        let divX     = -hw + 24 + thumbSize.width + 24
        addVDivider(x: divX, top: contentTop - 6, bottom: contentBottom + 6,
                    parent: container)

        // ── Middle: ATTRIBUTES stats column ─────────────────────────────────
        let middleStart    = divX + 16
        let middleColWidth: CGFloat = 180

        addSectionHeader("ATTRIBUTES", x: middleStart, y: contentTop - 4, parent: container)

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
            addStatRow(key: key, value: val, x: middleStart, y: sy, parent: container)
            sy -= 21
        }

        // ── Vertical divider 2 ──────────────────────────────────────────────
        let weaponsX = middleStart + middleColWidth + 12
        addVDivider(x: weaponsX, top: contentTop - 6, bottom: contentBottom + 6,
                    parent: container)

        // ── Column 3: WEAPONS + ENGINES (drag → hardpoint) ──────────────────
        let weaponsLeft   = weaponsX + 12
        let weaponsWidth: CGFloat = 200
        addSectionHeader("LOADOUT  (drag to hardpoint)",
                         x: weaponsLeft, y: contentTop - 4, parent: container)
        let weaponsTop    = contentTop - 22
        let weaponsBottom = contentBottom + 8
        weaponsListViewport = weaponsTop - weaponsBottom
        weaponsListXRange   = weaponsLeft ... (weaponsLeft + weaponsWidth)
        let weaponsCrop = SKCropNode()
        let wmask = SKSpriteNode(color: .white,
                                 size: CGSize(width: weaponsWidth, height: weaponsListViewport))
        wmask.position = CGPoint(x: weaponsLeft + weaponsWidth / 2,
                                 y: (weaponsTop + weaponsBottom) / 2)
        weaponsCrop.maskNode = wmask
        weaponsListContainer = SKNode()
        weaponsCrop.addChild(weaponsListContainer)
        container.addChild(weaponsCrop)
        weaponsListHeight   = renderInventoryRows(
            in: weaponsListContainer,
            originX: weaponsLeft, topY: weaponsTop, width: weaponsWidth,
            filter: { outfit in
                guard let o = outfit else { return false }
                let b = HardpointKind.bucket(forCategory: o.category)
                return b == "turret" || b == "gun" || b == "engine"
            },
            highlightStyle: .fillBox,
            registerDragIcons: true
        )
        let maxWeaponsScroll = max(0, weaponsListHeight - weaponsListViewport)
        weaponsListScroll = max(0, min(maxWeaponsScroll, weaponsListScroll))
        weaponsListContainer.position = CGPoint(x: 0, y: weaponsListScroll)

        // ── Vertical divider 3 ──────────────────────────────────────────────
        let allX = weaponsLeft + weaponsWidth + 12
        addVDivider(x: allX, top: contentTop - 6, bottom: contentBottom + 6,
                    parent: container)

        // ── Column 4: ALL OUTFITS by category (read-only) ───────────────────
        let allLeft  = allX + 12
        let allWidth = hw - 16 - allLeft
        addSectionHeader("INVENTORY  (by category)",
                         x: allLeft, y: contentTop - 4, parent: container)
        let allTop    = contentTop - 22
        let allBottom = contentBottom + 8
        allListViewport = allTop - allBottom
        allListXRange   = allLeft ... (allLeft + allWidth)
        let allCrop = SKCropNode()
        let amask = SKSpriteNode(color: .white,
                                 size: CGSize(width: allWidth, height: allListViewport))
        amask.position = CGPoint(x: allLeft + allWidth / 2,
                                 y: (allTop + allBottom) / 2)
        allCrop.maskNode = amask
        allListContainer = SKNode()
        allCrop.addChild(allListContainer)
        container.addChild(allCrop)
        allListHeight   = renderInventoryRows(
            in: allListContainer,
            originX: allLeft, topY: allTop, width: allWidth,
            filter: { _ in true },
            highlightStyle: .none,
            registerDragIcons: false
        )
        let maxAllScroll = max(0, allListHeight - allListViewport)
        allListScroll = max(0, min(maxAllScroll, allListScroll))
        allListContainer.position = CGPoint(x: 0, y: allListScroll)
    }

    /// Lays out a categorised installed-outfits list inside `parent`.
    /// All rows render with no background box, in a single column, with
    /// `×N` notation for counts. Headers separate categories; outfits
    /// with no `category` fall into "OTHER". Returns the total laid-out
    /// height so the caller can configure scroll bounds.
    ///
    /// Rows whose weapon is currently assigned to a hardpoint slot get a
    /// thin coloured underline matching the slot's kind (amber turret,
    /// red gun, green engine) per the request to "match the color of
    /// the node they belong to".
    @discardableResult
    private func renderInventoryRows(in parent: SKNode,
                                     originX: CGFloat,
                                     topY: CGFloat,
                                     width: CGFloat,
                                     filter: (OutfitDef?) -> Bool,
                                     highlightStyle: RowHighlightStyle,
                                     registerDragIcons: Bool) -> CGFloat {
        let profile = PlayerProfile.shared
        // Group by HardpointKind bucket so the same outfit doesn't end up
        // in two places when its raw category alias differs.
        var groups: [String: [String]] = [:]
        for id in profile.installedOutfits.keys {
            let outfit = OutfitRegistry.shared.outfit(id: id)
            if !filter(outfit) { continue }
            let bucket = HardpointKind.bucket(forCategory: outfit?.category)
            groups[bucket, default: []].append(id)
        }
        for cat in groups.keys {
            groups[cat]!.sort {
                let a = OutfitRegistry.shared.outfit(id: $0)?.displayName ?? $0
                let b = OutfitRegistry.shared.outfit(id: $1)?.displayName ?? $1
                return a < b
            }
        }
        let categoryOrder = ["turret", "gun", "engine",
                             "power", "shield", "weapon", "other"]
        let known   = categoryOrder.filter { groups[$0] != nil && $0 != "other" }
        let extra   = groups.keys.filter { !categoryOrder.contains($0) && $0 != "other" }.sorted()
        let trailing = groups["other"] != nil ? ["other"] : []
        let order    = known + extra + trailing

        let iconSize: CGFloat = 18
        let rowH:     CGFloat = 18
        // Start a few pixels below topY so the first centered category
        // header fits entirely below the SKCropNode mask boundary.
        var y = topY - 8
        for cat in order {
            let header             = SKLabelNode(text: cat.uppercased())
            header.fontName        = "AvenirNext-DemiBold"
            header.fontSize        = 9
            header.fontColor       = UIColor(white: 0.55, alpha: 1)
            header.horizontalAlignmentMode = .left
            header.verticalAlignmentMode   = .center
            header.position        = CGPoint(x: originX, y: y)
            parent.addChild(header)
            y -= rowH

            for id in groups[cat] ?? [] {
                let outfit = OutfitRegistry.shared.outfit(id: id)
                // LOADOUT col keeps icons because they're the drag handle;
                // read-only INVENTORY col drops them entirely.
                let labelX: CGFloat
                if registerDragIcons {
                    let icon = outfitCategoryIcon(category: outfit?.category, size: iconSize)
                    icon.position = CGPoint(x: originX + iconSize / 2, y: y)
                    parent.addChild(icon)
                    inventoryIconHits.append((icon, id, nil))
                    labelX = originX + iconSize + 6
                } else {
                    labelX = originX + 4
                }
                let label = outfit?.displayName ?? id
                let total = profile.installedOutfits[id] ?? 0
                let txt   = total > 1 ? "\(label) ×\(total)" : label
                let lbl   = SKLabelNode(text: txt)
                lbl.fontName            = "AvenirNextCondensed-Regular"
                lbl.fontSize            = 10
                lbl.fontColor           = UIColor(white: 0.85, alpha: 1)
                lbl.horizontalAlignmentMode = .left
                lbl.verticalAlignmentMode   = .center
                lbl.position            = CGPoint(x: labelX, y: y)
                lbl.preferredMaxLayoutWidth = max(40, width - (labelX - originX) - 4)
                parent.addChild(lbl)

                // Filled box behind equipped rows (LOADOUT col only).
                if case .fillBox = highlightStyle,
                   let kind = equippedKind(forOutfitID: id) {
                    let bg = SKShapeNode(
                        rect: CGRect(x: originX, y: y - rowH / 2,
                                     width: width, height: rowH),
                        cornerRadius: 3
                    )
                    bg.fillColor   = kind.color.withAlphaComponent(0.28)
                    bg.strokeColor = .clear
                    bg.zPosition   = -1
                    parent.addChild(bg)
                }

                y -= rowH
            }
            y -= 4
        }
        return topY - y
    }

    /// Determines which kind of mount this outfit is currently equipped
    /// at (if any). Used for the row's coloured outline. If equipped on
    /// multiple kinds at once (shouldn't happen with the type filter)
    /// the first match wins.
    private func equippedKind(forOutfitID outfitID: String) -> HardpointKind? {
        for (slot, oid) in PlayerProfile.shared.mountAssignments
            where oid == outfitID {
            if let kind = HardpointKind(slotKey: slot) { return kind }
        }
        return nil
    }

    /// Adds a hardpoint marker dot at the mount's body-local position,
    /// scaled into the on-screen thumbnail. Marker colour comes from
    /// `HardpointKind` so turret/gun/engine markers are visually
    /// distinct. The accompanying label shows the assigned outfit's
    /// full display name (or "empty").
    private func installHardpointMarker(slot: String,
                                         kind: HardpointKind,
                                         mount: ShipDef.Hardpoint,
                                         weaponID: String?,
                                         centerX: CGFloat, centerY: CGFloat,
                                         scale: CGFloat,
                                         parent: SKNode) {
        let mx = centerX + CGFloat(mount.x) * scale
        let my = centerY + CGFloat(mount.y) * scale
        let color = kind.color
        let dot = SKShapeNode(circleOfRadius: 7)
        dot.fillColor   = color.withAlphaComponent(weaponID == nil ? 0.18 : 0.85)
        dot.strokeColor = color
        dot.lineWidth   = 1.5
        dot.position    = CGPoint(x: mx, y: my)
        dot.zPosition   = 10
        parent.addChild(dot)

        let txt: String
        if let wid = weaponID,
           let display = OutfitRegistry.shared.outfit(id: wid)?.displayName {
            txt = display
        } else { txt = "empty" }
        let lbl             = SKLabelNode(text: txt)
        lbl.fontName        = "AvenirNextCondensed-DemiBold"
        lbl.fontSize        = 8
        lbl.fontColor       = (weaponID == nil)
            ? UIColor(white: 0.55, alpha: 1)
            : .white
        let onLeft          = mount.x < 0
        lbl.horizontalAlignmentMode = onLeft ? .right : .left
        lbl.verticalAlignmentMode   = .center
        lbl.position        = CGPoint(x: mx + (onLeft ? -10 : 10), y: my)
        lbl.zPosition       = 11
        parent.addChild(lbl)

        hardpointMarkers.append(.init(slot: slot, kind: kind, node: dot, label: lbl))
    }

    private func addVDivider(x: CGFloat, top: CGFloat, bottom: CGFloat, parent: SKNode) {
        let line = SKShapeNode()
        let p    = CGMutablePath()
        p.move(to:    CGPoint(x: x, y: top))
        p.addLine(to: CGPoint(x: x, y: bottom))
        line.path        = p
        line.strokeColor = UIColor(white: 1, alpha: 0.10)
        line.lineWidth   = 1
        parent.addChild(line)
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
        let outfitsList = def.outfits ?? []
        let oTop        = contentTop - 40
        let rowH:    CGFloat = 17
        let available   = oTop - (contentBottom + 8)
        let perColumn   = max(1, Int(available / rowH))
        let useTwoCols  = outfitsList.count > perColumn
        let colWidth    = (hw - 16 - outfitColX) / 2
        let secondColX  = outfitColX + colWidth

        for (i, outfit) in outfitsList.enumerated() {
            let col: Int = useTwoCols ? (i / perColumn) : 0
            let row: Int = useTwoCols ? (i % perColumn) : i
            if col > 1 { break }
            let colX = (col == 0) ? outfitColX : secondColX
            let rowY = oTop - CGFloat(row) * rowH
            if rowY < contentBottom + 8 { break }

            let label = OutfitRegistry.shared.outfit(id: outfit.name)?.displayName ?? outfit.name
            let txt   = outfit.count > 1 ? "\(outfit.count)× \(label)" : label
            let lbl = SKLabelNode(text: txt)
            lbl.fontName                  = "AvenirNextCondensed-Regular"
            lbl.fontSize                  = 11
            lbl.fontColor                 = UIColor(white: 0.72, alpha: 1)
            lbl.horizontalAlignmentMode   = .left
            lbl.verticalAlignmentMode     = .center
            lbl.position                  = CGPoint(x: colX, y: rowY)
            tab2StatsNode.addChild(lbl)
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

        // BUY buttons, tab buttons, and BACK take priority. Skip taps
        // that land on a node whose ancestor tab is hidden — otherwise
        // BUY buttons in the FOR SALE tab stay clickable through the MY
        // SHIP tab (the buttons are visually hidden but `node.contains`
        // doesn't care about ancestor visibility).
        for (node, action) in buttons
            where node.contains(pt) && isVisibleInTree(node) {
            flash(node)
            action()
            return
        }

        if activeTab == 0 {
            // 1. Did the touch land on a hardpoint marker that already
            //    has a weapon? If so, start a drag with that weapon
            //    (source slot captured so `endDrag` can move it).
            for marker in hardpointMarkers {
                let dx = pt.x - marker.node.position.x
                let dy = pt.y - marker.node.position.y
                if hypot(dx, dy) < 16 {
                    if let oid = PlayerProfile.shared.mountAssignments[marker.slot] {
                        beginDrag(outfitID: oid, sourceSlot: marker.slot, at: pt)
                    }
                    return   // a tap on a marker never falls through to scroll/select
                }
            }
            // 2. Inventory icon? Begin a drag from the captain's locker.
            for hit in inventoryIconHits {
                guard let parent = hit.node.parent else { continue }
                let local = parent.convert(pt, from: self)
                if hit.node.contains(local) {
                    beginDrag(outfitID: hit.outfitID,
                              sourceSlot: hit.sourceSlot, at: pt)
                    return
                }
            }
            // 3. Otherwise — if the touch is inside one of the two
            //    inventory columns, start a scroll there.
            if weaponsListXRange.contains(pt.x) {
                activeScroll      = .weapons
                scrollLastY       = pt.y
                scrollMovedEnough = false
                return
            }
            if allListXRange.contains(pt.x) {
                activeScroll      = .all
                scrollLastY       = pt.y
                scrollMovedEnough = false
                return
            }
        }

        // Row background — ship selection on tab 2.
        for (bg, sid) in shipRowBgs
            where bg.contains(pt) && isVisibleInTree(bg) {
            selectShip(id: sid)
            return
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let pt = touch.location(in: self)

        if dragOutfitID != nil {
            dragGhost?.position = pt
            updateDragHover(at: pt)
            lastDragPoint = pt
            return
        }
        switch activeScroll {
        case .weapons:
            let dy = pt.y - scrollLastY
            scrollLastY = pt.y
            if abs(dy) > 2 { scrollMovedEnough = true }
            if scrollMovedEnough {
                let maxScroll = max(0, weaponsListHeight - weaponsListViewport)
                weaponsListScroll = max(0, min(maxScroll, weaponsListScroll + dy))
                weaponsListContainer.position = CGPoint(x: 0, y: weaponsListScroll)
            }
        case .all:
            let dy = pt.y - scrollLastY
            scrollLastY = pt.y
            if abs(dy) > 2 { scrollMovedEnough = true }
            if scrollMovedEnough {
                let maxScroll = max(0, allListHeight - allListViewport)
                allListScroll = max(0, min(maxScroll, allListScroll + dy))
                allListContainer.position = CGPoint(x: 0, y: allListScroll)
            }
        case .none:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        defer {
            activeScroll      = .none
            scrollMovedEnough = false
        }
        guard let touch = touches.first else { return }
        let pt = touch.location(in: self)
        if let outfitID = dragOutfitID {
            endDrag(at: pt, outfitID: outfitID)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        cancelDrag()
        activeScroll      = .none
        scrollMovedEnough = false
    }

    // MARK: – Drag-to-assign

    private func beginDrag(outfitID: String, sourceSlot: String?, at pt: CGPoint) {
        dragOutfitID   = outfitID
        dragSourceSlot = sourceSlot
        let category   = OutfitRegistry.shared.outfit(id: outfitID)?.category
        let ghost      = outfitCategoryIcon(category: category, size: 30)
        ghost.alpha     = 0.75
        ghost.zPosition = 1000
        ghost.position  = pt
        addChild(ghost)
        dragGhost = ghost
    }

    /// Highlights a compatible marker as the finger passes over it. Only
    /// markers whose `kind` accepts the dragged outfit are eligible —
    /// turret weapons can't preview-drop into gun mounts, etc.
    private func updateDragHover(at pt: CGPoint) {
        guard let oid = dragOutfitID,
              let outfit = OutfitRegistry.shared.outfit(id: oid) else { return }
        var nearestSlot: String?
        var nearestDist: CGFloat = 24      // hit + a touch of hover slack
        for marker in hardpointMarkers {
            guard marker.kind.accepts(category: outfit.category) else { continue }
            let dx = pt.x - marker.node.position.x
            let dy = pt.y - marker.node.position.y
            let d  = hypot(dx, dy)
            if d < nearestDist {
                nearestDist = d
                nearestSlot = marker.slot
            }
        }
        if nearestSlot == dragHoverSlot { return }
        // Reset previous hover's appearance.
        if let prev = dragHoverSlot,
           let m    = hardpointMarkers.first(where: { $0.slot == prev }) {
            applyHover(marker: m, on: false)
        }
        if let next = nearestSlot,
           let m    = hardpointMarkers.first(where: { $0.slot == next }) {
            applyHover(marker: m, on: true)
        }
        dragHoverSlot = nearestSlot
    }

    private func applyHover(marker: HardpointMarker, on: Bool) {
        marker.node.setScale(on ? 1.4 : 1.0)
        marker.node.fillColor = on
            ? marker.kind.color
            : marker.kind.color.withAlphaComponent(
                PlayerProfile.shared.mountAssignments[marker.slot] == nil ? 0.18 : 0.85
            )
    }

    private func endDrag(at pt: CGPoint, outfitID: String) {
        // Prefer the hover-highlighted slot when present (it's already
        // type-validated); otherwise scan all markers in case the user
        // released without ever moving over a valid one.
        let targetSlot: String? = dragHoverSlot ?? {
            let outfit = OutfitRegistry.shared.outfit(id: outfitID)
            for marker in hardpointMarkers {
                guard marker.kind.accepts(category: outfit?.category) else { continue }
                let dx = pt.x - marker.node.position.x
                let dy = pt.y - marker.node.position.y
                if hypot(dx, dy) < 16 { return marker.slot }
            }
            return nil
        }()
        defer { cancelDrag() }
        guard let target = targetSlot else { return }
        let profile = PlayerProfile.shared
        let changed: Bool
        if let source = dragSourceSlot, source != target {
            // Drag started on a marker — always go through swap so the
            // source slot is the deterministic donor (target gets the
            // dragged item, source either gets target's old item or
            // becomes empty). Avoids assignWeaponToMount's arbitrary
            // donor-fallback when inventory is exhausted.
            changed = profile.swapMountAssignments(slot1: source, slot2: target)
        } else {
            changed = profile.assignWeaponToMount(outfitID, slot: target)
        }
        guard changed else { return }
        profile.persistCurrentSave()
        tab1Container.removeFromParent()
        buildTab1()
        showTab(activeTab)
    }

    private func cancelDrag() {
        // Clear hover state on any marker we may have highlighted.
        if let prev = dragHoverSlot,
           let m    = hardpointMarkers.first(where: { $0.slot == prev }) {
            applyHover(marker: m, on: false)
        }
        dragHoverSlot = nil
        dragGhost?.removeFromParent()
        dragGhost      = nil
        dragOutfitID   = nil
        dragSourceSlot = nil
    }

    /// `node.isHidden` only reports the node's own flag — a tap on a
    /// visually hidden BUY button still hits it because its parent tab
    /// container is the one with `isHidden = true`. Walks the parent
    /// chain so the inactive tab's controls are truly inert.
    private func isVisibleInTree(_ node: SKNode) -> Bool {
        var current: SKNode? = node
        while let n = current {
            if n.isHidden { return false }
            current = n.parent
        }
        return true
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
