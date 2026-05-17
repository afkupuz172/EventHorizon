import Foundation
import UIKit

/// Static description of a faction: its colour, default stance toward
/// other factions, per-other overrides, and the reputation deltas the
/// player accrues across factions when they kill a member.
///
/// Stance strings recognised by the AI:
///   • `hostile` — engage on sight
///   • `neutral` — ignore unless attacked
///   • `flee`    — try to break contact
struct FactionDef: Decodable {
    let id: String
    let displayName: String
    /// `[r, g, b]` floats in 0..1. Used for HUD chips, mini-map dots, etc.
    let color: [Float]?
    let defaultStance: String?
    /// Per-faction overrides keyed by other-faction-id.
    let stances: [String: String]?
    /// When the player kills a member of THIS faction, add these per-
    /// faction deltas to `PlayerProfile.reputation`. Positive values mean
    /// the named faction *likes* this kill (e.g. pirates approve of
    /// killing civilians); negative values mean they hold a grudge.
    let repDeltaOnKill: [String: Int]?

    var uiColor: UIColor {
        guard let c = color, c.count >= 3 else { return .white }
        return UIColor(red: CGFloat(c[0]), green: CGFloat(c[1]), blue: CGFloat(c[2]), alpha: 1)
    }

    func stance(toward other: String) -> String {
        if let s = stances?[other] { return s }
        return defaultStance ?? "neutral"
    }
}

@MainActor
final class FactionRegistry {

    static let shared = FactionRegistry()
    private init() { load() }

    private(set) var definitions: [String: FactionDef] = [:]

    func faction(id: String) -> FactionDef? { definitions[id] }

    /// Looks up the faction's stance toward another faction. For
    /// `other == "player"` the answer is biased by the player's stored
    /// reputation with the self faction — very low rep flips otherwise-
    /// neutral factions hostile, very high rep can turn hostiles neutral.
    func stance(of self_: String, toward other: String, playerReputation: Int = 0) -> String {
        guard let def = definitions[self_] else { return "neutral" }
        if other == "player" {
            // Reputation thresholds are deliberately mild — a small
            // grudge shouldn't make militia open fire.
            if playerReputation <= -40 { return "hostile" }
            if playerReputation <=  -5 && def.defaultStance != "hostile" { return "neutral" }
            if playerReputation >= 40 && def.defaultStance == "hostile" { return "neutral" }
            return def.defaultStance ?? "neutral"
        }
        return def.stance(toward: other)
    }

    private func load() {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "json",
                                          subdirectory: nil)
        else { return }
        struct Container: Decodable { let factions: [FactionDef]? }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let container = try? decoder.decode(Container.self, from: data),
                  let list = container.factions, !list.isEmpty
            else { continue }
            for f in list { definitions[f.id] = f }
            print("[FactionRegistry] loaded \(list.count) factions from \(url.lastPathComponent)")
        }
    }
}
