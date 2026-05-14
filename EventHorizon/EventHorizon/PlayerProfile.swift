import Foundation

/// Lightweight runtime store for the player's persistent state — currently
/// just their chosen ship and a credit balance. A singleton because the data
/// has to survive scene transitions (`GameScene` → `PlanetScene` → new
/// `GameScene`).
///
/// In the future this would be persisted to disk (UserDefaults / a JSON file
/// on the device) so the player keeps their ship and credits across launches.
@MainActor
final class PlayerProfile {

    static let shared = PlayerProfile()
    private init() {}

    /// The hull the local player is currently flying. Read by `ShipNode` when
    /// a new local-player node is constructed (which happens at scene init
    /// and after each dock/disembark cycle).
    var currentShip: ShipMetadata = .ringship

    /// Wallet. Not enforced yet — ships at the shipyard cost 0 credits — but
    /// the field is in place for when the economy comes online.
    var credits: Int = 1000

    /// Hulls the shipyard knows how to sell. Order matters: the shipyard UI
    /// renders rows in this order.
    let availableShips: [ShipMetadata] = [.ringship, .spaceship1]
}
