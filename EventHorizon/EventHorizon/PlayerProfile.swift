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

    /// Single- vs multiplayer session — also the save bucket.
    var mode: SaveProfile.Mode = .singlePlayer

    /// Canonical ID of the hull the player is flying.
    /// Changing the hull resets `installedOutfits` to the new ship's JSON defaults.
    var currentShipID: String = "ringship" {
        didSet { initInstalledOutfits() }
    }

    /// Wallet.
    var credits: Int = 100_000

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
        guard let def  = OutfitRegistry.shared.outfit(named: name),
              let cost = def.cost,
              credits >= cost else { return false }
        credits -= cost
        installedOutfits[name, default: 0] += 1
        return true
    }

    /// Removes one unit and refunds half the cost. Returns false if none
    /// installed or outfit unknown.
    @discardableResult
    func sellOutfit(named name: String) -> Bool {
        guard (installedOutfits[name] ?? 0) > 0,
              let def  = OutfitRegistry.shared.outfit(named: name),
              let cost = def.cost else { return false }
        installedOutfits[name]! -= 1
        if installedOutfits[name]! == 0 { installedOutfits.removeValue(forKey: name) }
        credits += cost / 2
        return true
    }

    // MARK: – Capacity accounting (only counts registry-defined outfits)

    var outfitSpaceUsed: Double {
        installedOutfits.reduce(0.0) { sum, kv in
            sum + abs(OutfitRegistry.shared.outfit(named: kv.key)?.outfitSpace ?? 0) * Double(kv.value)
        }
    }

    var weaponCapacityUsed: Double {
        installedOutfits.reduce(0.0) { sum, kv in
            sum + abs(OutfitRegistry.shared.outfit(named: kv.key)?.weaponCapacity ?? 0) * Double(kv.value)
        }
    }

    var engineCapacityUsed: Double {
        installedOutfits.reduce(0.0) { sum, kv in
            sum + abs(OutfitRegistry.shared.outfit(named: kv.key)?.engineCapacity ?? 0) * Double(kv.value)
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
        installedOutfits = profile.installedOutfits
        credits         = profile.credits
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
