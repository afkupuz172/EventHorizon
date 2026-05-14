import Foundation

/// SpriteKit physics-body category bitmasks for the combat layer.
///
/// We use the physics engine purely as a contact detector — every body
/// here sets `collisionBitMask = 0` so nothing actually deflects on
/// contact. The scene's `SKPhysicsContactDelegate` listens for the
/// pairings described in the `contactTestBitMask` columns and performs
/// damage / destruction in code.
enum CollisionCategory {
    /// Player and other live ships (one body per ship).
    static let ship: UInt32                = 1 << 0

    /// Asteroids (hit-able per game rules; selection-gated).
    static let asteroid: UInt32            = 1 << 1

    /// Garden-variety bolts/missiles. Collide with ships + asteroids and
    /// can be intercepted by flares.
    static let projectileStandard: UInt32  = 1 << 2

    /// Counter-projectiles — flares, point-defense, etc. Collide ONLY with
    /// standard projectiles (rule 5).
    static let projectileFlare: UInt32     = 1 << 3
}

/// String constants for `OutfitDef.WeaponStats.kind`. The decoder accepts
/// any string but the contact system only branches on these.
enum ProjectileKind {
    static let standard = "standard"
    static let flare    = "flare"
}
