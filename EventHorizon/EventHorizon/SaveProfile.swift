import Foundation

/// On-disk save game. Mirrors everything mutable about a captain's run so
/// the player can come back to exactly where they left off. Single- and
/// multiplayer saves live in sibling directories so the same captain name
/// can exist in both without collision.
///
/// Future: this struct is also the shape we'll ship to the database.
struct SaveProfile: Codable {

    enum Mode: String, Codable { case singlePlayer, multiplayer }

    static let currentVersion = 1

    var version: Int = SaveProfile.currentVersion
    var mode: Mode

    // Identity
    var captainName: String
    var shipName: String

    // World position
    var currentSystem:   String   // SolarSystemConfig name (file basename)
    var currentPlanetID: String   // PlanetConfig.id

    // Ship + economy
    var shipID:           String
    var credits:          Int
    var installedOutfits: [String: Int]

    /// Faction → standing in [-100, 100]. Stub for now; gameplay hook later.
    var reputation: [String: Int] = [:]

    /// Per-hardpoint weapon overrides. Keys are mount slot identifiers
    /// (`"turret_<i>"`, `"gun_<i>"`) into the ship's JSON; values are
    /// outfit IDs. Unspecified slots fall back to the JSON's default
    /// `weapon` field for that mount.
    var mountAssignments: [String: String] = [:]

    // Timestamps
    var createdAtUnix:   TimeInterval
    var lastSavedAtUnix: TimeInterval

    /// Custom decode so the optional `mount_assignments` key can be
    /// absent from older save files without failing the load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version          = try c.decodeIfPresent(Int.self,            forKey: .version) ?? SaveProfile.currentVersion
        mode             = try c.decode(Mode.self,                    forKey: .mode)
        credits          = try c.decode(Int.self,                     forKey: .credits)
        captainName      = try c.decode(String.self,                  forKey: .captainName)
        shipName         = try c.decode(String.self,                  forKey: .shipName)
        currentSystem    = try c.decode(String.self,                  forKey: .currentSystem)
        currentPlanetID  = try c.decode(String.self,                  forKey: .currentPlanetID)
        shipID           = try c.decode(String.self,                  forKey: .shipID)
        installedOutfits = try c.decode([String: Int].self,           forKey: .installedOutfits)
        reputation       = try c.decodeIfPresent([String: Int].self,  forKey: .reputation)       ?? [:]
        mountAssignments = try c.decodeIfPresent([String: String].self, forKey: .mountAssignments) ?? [:]
        createdAtUnix    = try c.decode(TimeInterval.self,            forKey: .createdAtUnix)
        lastSavedAtUnix  = try c.decode(TimeInterval.self,            forKey: .lastSavedAtUnix)
    }

    init(version: Int = SaveProfile.currentVersion,
         mode: Mode,
         captainName: String,
         shipName: String,
         currentSystem: String,
         currentPlanetID: String,
         shipID: String,
         credits: Int,
         installedOutfits: [String: Int],
         reputation: [String: Int] = [:],
         mountAssignments: [String: String] = [:],
         createdAtUnix: TimeInterval,
         lastSavedAtUnix: TimeInterval) {
        self.version          = version
        self.mode             = mode
        self.captainName      = captainName
        self.shipName         = shipName
        self.currentSystem    = currentSystem
        self.currentPlanetID  = currentPlanetID
        self.shipID           = shipID
        self.credits          = credits
        self.installedOutfits = installedOutfits
        self.reputation       = reputation
        self.mountAssignments = mountAssignments
        self.createdAtUnix    = createdAtUnix
        self.lastSavedAtUnix  = lastSavedAtUnix
    }

    /// Explicit snake_case keys so the on-disk format matches the rest of
    /// the game's JSON. **Critical:** we do NOT pair this with a key
    /// decoding/encoding strategy — the strategy applies recursively to
    /// dictionary keys, which would mangle `installed_outfits`'s inner
    /// snake_case outfit IDs (e.g. `heavy_laser_turret`) into camelCase.
    /// Explicit keys here cover the top-level only.
    enum CodingKeys: String, CodingKey {
        case version
        case mode
        case credits
        case reputation
        case captainName       = "captain_name"
        case shipName          = "ship_name"
        case currentSystem     = "current_system"
        case currentPlanetID   = "current_planet_id"
        case shipID            = "ship_id"
        case installedOutfits  = "installed_outfits"
        case mountAssignments  = "mount_assignments"
        case createdAtUnix     = "created_at_unix"
        case lastSavedAtUnix   = "last_saved_at_unix"
    }

    /// Stable on-disk filename derived from the captain name. Spaces and
    /// punctuation collapsed so the OS file system doesn't choke.
    var fileSlug: String { SaveProfile.slug(for: captainName) }

    static func slug(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = lowered.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return String(cleaned).isEmpty ? "captain" : String(cleaned)
    }
}

/// File-backed save store. One JSON per profile under
/// `<Documents>/saves/<mode>/<slug>.json`. The store is intentionally dumb:
/// every call hits disk. Callers cache as needed.
@MainActor
final class SaveProfileStore {

    static let shared = SaveProfileStore()
    private init() {}

    private let fm = FileManager.default

    private func dirURL(for mode: SaveProfile.Mode) -> URL {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir  = docs.appendingPathComponent("saves", isDirectory: true)
                       .appendingPathComponent(mode == .singlePlayer ? "single" : "multi",
                                               isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func fileURL(for profile: SaveProfile) -> URL {
        dirURL(for: profile.mode).appendingPathComponent("\(profile.fileSlug).json")
    }

    /// Lists profiles for a given mode, newest-saved first. JSON keys are
    /// driven entirely by `SaveProfile.CodingKeys` — no
    /// `keyDecodingStrategy` because it would also mangle the inner
    /// outfit-ID keys inside `installed_outfits`.
    func list(mode: SaveProfile.Mode) -> [SaveProfile] {
        let dir = dirURL(for: mode)
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        let decoder = JSONDecoder()
        let profiles = names.compactMap { name -> SaveProfile? in
            guard name.hasSuffix(".json"),
                  let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                  let p    = try? decoder.decode(SaveProfile.self, from: data)
            else { return nil }
            return p
        }
        return profiles.sorted { $0.lastSavedAtUnix > $1.lastSavedAtUnix }
    }

    @discardableResult
    func save(_ profile: SaveProfile) -> Bool {
        var p = profile
        p.lastSavedAtUnix = Date().timeIntervalSince1970
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(p) else { return false }
        do {
            try data.write(to: fileURL(for: p), options: .atomic)
            return true
        } catch {
            print("[SaveProfileStore] write failed: \(error)")
            return false
        }
    }

    func delete(_ profile: SaveProfile) {
        try? fm.removeItem(at: fileURL(for: profile))
    }
}
