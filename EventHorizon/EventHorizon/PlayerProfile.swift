import Foundation

/// Lightweight runtime store for the player's persistent state. The truth is
/// the **ship ID slug** (e.g. `"arclight"`), which simultaneously keys:
///   • the `data/ships/<id>.json` gameplay definition (`ShipRegistry`)
///   • the Swift `ShipMetadata` rendering descriptor (`ShipMetadata.byID`)
///   • the on-disk asset (`Art.scnassets/ships/<id>.{usdc|png}`)
///
/// All three live or die by the same slug, so swapping ships is a single
/// assignment to `currentShipID`.
@MainActor
final class PlayerProfile {

    static let shared = PlayerProfile()
    private init() { initInstalledOutfits() }

    /// Captain identity, persisted to the save profile. Empty until a
    /// session is started via New Game or Load Game.
    var captainName: String = ""
    var shipName:    String = ""

    /// Where the player is right now in the world. Used to drop them back
    /// into the correct planet on Load Game and to spawn `GameScene` into
    /// the right star system on departure.
    var currentSystem:   String = "home_system"
    var currentPlanetID: String = "hadrian"

    /// Faction standings. Reserved for gameplay; saved as-is.
    var reputation: [String: Int] = [:]

    /// Factions whose ships are fair game for the player's weapons without
    /// requiring tap-to-select first. Neutral/friendly hulls (and asteroids)
    /// must be explicitly selected before player projectiles will hit them.
    var hostileFactions: Set<String> = ["pirate", "hostile"]

    /// Per-hardpoint weapon overrides. Keys are mount slot identifiers
    /// (e.g. `"turret_0"`, `"gun_3"`); values are outfit IDs. When a key
    /// is present, that mount uses the named weapon regardless of the
    /// ship JSON's default; otherwise the JSON default applies. Cleared
    /// on ship change (`currentShipID.didSet`).
    private(set) var mountAssignments: [String: String] = [:]

    /// Number of copies of `outfitID` currently sitting unassigned in
    /// the captain's locker (installed but not at any mount). Floored
    /// at zero so over-assignment never reports negative inventory.
    func inventoryCount(forOutfitID outfitID: String) -> Int {
        let total = installedOutfits[outfitID] ?? 0
        let mounted = mountAssignments.values.filter { $0 == outfitID }.count
        return max(0, total - mounted)
    }

    /// Direct write — used for explicit clears. Most callers should go
    /// through `assignWeaponToMount(...)` which handles the
    /// move-from-another-mount case when inventory is empty.
    func assignMount(_ slot: String, outfitID: String?) {
        if let id = outfitID { mountAssignments[slot] = id }
        else                 { mountAssignments.removeValue(forKey: slot) }
    }

    /// Drop a weapon onto a hardpoint. Returns `true` when the
    /// assignment took effect. Behaviour:
    ///   • Rejects the drop when the outfit's category doesn't match the
    ///     slot's kind (turret/gun/engine) — so guns can't be jammed
    ///     into turret sockets and vice versa.
    ///   • If the slot already holds this outfit, no-op.
    ///   • If inventory has at least one free copy, just write the
    ///     assignment. The previous occupant of the slot returns to
    ///     inventory automatically (it's no longer counted as mounted).
    ///   • If inventory is empty (every owned copy is already mounted
    ///     elsewhere), donate one from another mount — clearing that
    ///     slot first so equipped count stays consistent.
    @discardableResult
    func assignWeaponToMount(_ outfitID: String, slot: String) -> Bool {
        guard let kind = HardpointKind(slotKey: slot),
              let outfit = OutfitRegistry.shared.outfit(id: outfitID),
              kind.accepts(category: outfit.category) else { return false }
        if mountAssignments[slot] == outfitID { return false }
        let hasInventory = inventoryCount(forOutfitID: outfitID) > 0
        if !hasInventory {
            guard let donorSlot = mountAssignments.first(
                where: { $0.value == outfitID && $0.key != slot }
            )?.key else { return false }
            mountAssignments.removeValue(forKey: donorSlot)
        }
        mountAssignments[slot] = outfitID
        return true
    }

    /// Exchanges the assignments at two mount slots. Used by the
    /// drag-from-marker-to-marker workflow so weapons trade places
    /// instead of demoting an unrelated mount via the donate-fallback in
    /// `assignWeaponToMount`. Returns `false` and leaves the model
    /// untouched if either slot's destination would violate the type
    /// filter — e.g. trying to swap a turret weapon onto a gun slot.
    @discardableResult
    func swapMountAssignments(slot1: String, slot2: String) -> Bool {
        guard let k1 = HardpointKind(slotKey: slot1),
              let k2 = HardpointKind(slotKey: slot2),
              slot1 != slot2
        else { return false }
        let v1 = mountAssignments[slot1]
        let v2 = mountAssignments[slot2]
        if let id = v2,
           let cat = OutfitRegistry.shared.outfit(id: id)?.category,
           !k1.accepts(category: cat) { return false }
        if let id = v1,
           let cat = OutfitRegistry.shared.outfit(id: id)?.category,
           !k2.accepts(category: cat) { return false }
        if let id = v2 { mountAssignments[slot1] = id }
        else            { mountAssignments.removeValue(forKey: slot1) }
        if let id = v1 { mountAssignments[slot2] = id }
        else            { mountAssignments.removeValue(forKey: slot2) }
        return true
    }

    /// Seeds `mountAssignments` from the ship JSON's default weapons,
    /// allocating each one only when there's available stock. Called
    /// once when a hull is fresh out of the shipyard or when a loaded
    /// save has no assignments (legacy profiles).
    func autoSeedMountAssignments() {
        guard let def = currentShipDef else { return }
        mountAssignments.removeAll()
        var remaining = installedOutfits
        func tryAssign(slot: String, outfitID: String?) {
            guard let w = outfitID, remaining[w, default: 0] > 0 else { return }
            mountAssignments[slot] = w
            remaining[w]! -= 1
        }
        for (i, m) in (def.turrets ?? []).enumerated() { tryAssign(slot: "turret_\(i)", outfitID: m.weapon) }
        for (i, m) in (def.guns    ?? []).enumerated() { tryAssign(slot: "gun_\(i)",    outfitID: m.weapon) }
        for (i, m) in (def.engines ?? []).enumerated() { tryAssign(slot: "engine_\(i)", outfitID: m.engine) }
    }

    /// Single- vs multiplayer session — also the save bucket.
    var mode: SaveProfile.Mode = .singlePlayer

    /// Canonical ID of the hull the player is flying.
    /// Changing the hull resets `installedOutfits` to the new ship's JSON defaults.
    var currentShipID: String = "ringship" {
        didSet {
            initInstalledOutfits()
            // Different hulls have different mount layouts — drop any
            // overrides that no longer make sense, then auto-equip the
            // new hull's default weapons up to available stock.
            mountAssignments = [:]
            autoSeedMountAssignments()
        }
    }

    /// Wallet.
    var credits: Int = 1_000_000

    /// Runtime installed-outfit counts, keyed by outfit name.
    /// Initialised from the current ship's JSON `outfits` array; mutated by
    /// `buyOutfit` / `sellOutfit`. Counts reflect how many of each outfit are
    /// currently installed (e.g. "Heavy Laser Turret" → 4).
    private(set) var installedOutfits: [String: Int] = [:]

    private func initInstalledOutfits() {
        installedOutfits = [:]
        for outfit in (currentShipDef?.outfits ?? []) {
            installedOutfits[outfit.name] = outfit.count
        }
    }

    // MARK: – Buy / sell outfits

    /// Deducts cost and adds one unit. Returns false if credits insufficient or
    /// outfit unknown.
    @discardableResult
    func buyOutfit(named name: String) -> Bool {
        guard let def  = OutfitRegistry.shared.outfit(id: name),
              let cost = def.cost,
              credits >= cost else { return false }
        credits -= cost
        installedOutfits[name, default: 0] += 1
        return true
    }

    /// Removes one unit and refunds half the cost. Returns false if none
    /// installed or outfit unknown. After the inventory ticks down, if
    /// there are more mount assignments for this outfit than remain
    /// installed, some assignments are cleared so the equipped count
    /// can never exceed stock.
    @discardableResult
    func sellOutfit(named name: String) -> Bool {
        guard (installedOutfits[name] ?? 0) > 0,
              let def  = OutfitRegistry.shared.outfit(id: name),
              let cost = def.cost else { return false }
        installedOutfits[name]! -= 1
        if installedOutfits[name]! == 0 { installedOutfits.removeValue(forKey: name) }
        let newCount = installedOutfits[name] ?? 0
        let mountedSlots = mountAssignments
            .filter { $0.value == name }
            .map { $0.key }
        let excess = mountedSlots.count - newCount
        if excess > 0 {
            for slot in mountedSlots.prefix(excess) {
                mountAssignments.removeValue(forKey: slot)
            }
        }
        credits += cost / 2
        return true
    }

    // MARK: – Capacity accounting (only counts registry-defined outfits)

    var outfitSpaceUsed: Double {
        installedOutfits.reduce(0.0) { sum, kv in
            sum + abs(OutfitRegistry.shared.outfit(id: kv.key)?.outfitSpace ?? 0) * Double(kv.value)
        }
    }

    var weaponCapacityUsed: Double {
        installedOutfits.reduce(0.0) { sum, kv in
            sum + abs(OutfitRegistry.shared.outfit(id: kv.key)?.weaponCapacity ?? 0) * Double(kv.value)
        }
    }

    var engineCapacityUsed: Double {
        installedOutfits.reduce(0.0) { sum, kv in
            sum + abs(OutfitRegistry.shared.outfit(id: kv.key)?.engineCapacity ?? 0) * Double(kv.value)
        }
    }

    /// Sum of `thrust` across MOUNTED engines (those actually equipped
    /// at engine slots). Unmounted thrusters sitting in inventory don't
    /// contribute. Zero means the ship can't accelerate.
    var totalEngineThrust: Double {
        mountAssignments
            .filter { $0.key.hasPrefix("engine_") }
            .reduce(0.0) { sum, kv in
                sum + (OutfitRegistry.shared.outfit(id: kv.value)?.thrust ?? 0)
            }
    }

    /// Sum of `turn` across MOUNTED engines. Zero means no steering and
    /// the ship can't rotate.
    var totalSteeringTurn: Double {
        mountAssignments
            .filter { $0.key.hasPrefix("engine_") }
            .reduce(0.0) { sum, kv in
                sum + (OutfitRegistry.shared.outfit(id: kv.value)?.turn ?? 0)
            }
    }

    /// Rendering metadata for the current ship. Falls back to ringship if a
    /// JSON references an ID we haven't got a Swift `ShipMetadata` for.
    var currentShip: ShipMetadata {
        ShipMetadata.byID[currentShipID] ?? .ringship
    }

    /// Gameplay definition for the current ship (hull, shields, fuel,
    /// installed outfits). Nil only if the JSON didn't load.
    var currentShipDef: ShipDef? {
        ShipRegistry.shared.def(for: currentShipID)
    }

    /// Ships available at the shipyard — registry-driven. Adding a new
    /// `data/ships/foo.json` + a `ShipMetadata.foo` entry in `byID` makes
    /// the new hull appear automatically.
    var availableShips: [(id: String, metadata: ShipMetadata)] {
        ShipRegistry.shared.allIDs.compactMap { id in
            ShipMetadata.byID[id].map { (id: id, metadata: $0) }
        }
    }

    // MARK: – Save profile bridge

    /// Hydrate the singleton from a save file. Order matters: setting
    /// `currentShipID` clears `installedOutfits` via `didSet`, so we
    /// overwrite it afterwards.
    func loadFromSave(_ profile: SaveProfile) {
        captainName     = profile.captainName
        shipName        = profile.shipName
        currentSystem   = profile.currentSystem
        currentPlanetID = profile.currentPlanetID
        reputation      = profile.reputation
        mode            = profile.mode
        currentShipID   = profile.shipID
        // Migrate legacy installedOutfits keys (pre-snake_case saves used
        // human display names like "Heavy Laser Turret") to canonical
        // snake_case IDs so weapon lookups + counts converge on one key.
        var migrated: [String: Int] = [:]
        for (key, count) in profile.installedOutfits {
            let canonical = OutfitRegistry.shared.outfit(id: key)?.id ?? key
            migrated[canonical, default: 0] += count
        }
        installedOutfits  = migrated
        credits           = profile.credits
        mountAssignments  = profile.mountAssignments
        // Legacy saves predate `mountAssignments` — seed them from the
        // ship JSON's defaults so weapons aren't all loose in inventory.
        if mountAssignments.isEmpty {
            autoSeedMountAssignments()
        }
    }

    /// Snapshot the current runtime state into a save record. `createdAtUnix`
    /// is preserved if a prior save exists for the same captain+mode.
    func toSaveProfile() -> SaveProfile {
        let now = Date().timeIntervalSince1970
        let created = SaveProfileStore.shared
            .list(mode: mode)
            .first(where: { $0.captainName == captainName })?
            .createdAtUnix ?? now
        return SaveProfile(
            version:          SaveProfile.currentVersion,
            mode:             mode,
            captainName:      captainName,
            shipName:         shipName,
            currentSystem:    currentSystem,
            currentPlanetID:  currentPlanetID,
            shipID:           currentShipID,
            credits:          credits,
            installedOutfits: installedOutfits,
            reputation:       reputation,
            mountAssignments: mountAssignments,
            createdAtUnix:    created,
            lastSavedAtUnix:  now
        )
    }

    /// Convenience used by `PlanetScene.didMove`.
    func persistCurrentSave() {
        guard !captainName.isEmpty else { return }
        SaveProfileStore.shared.save(toSaveProfile())
    }
}
