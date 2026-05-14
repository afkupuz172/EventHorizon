import SpriteKit
import UIKit

/// A single in-flight projectile. Owns its visual (a glowing capsule) and
/// a contact-only physics body keyed to `CollisionCategory.projectileStandard`
/// or `.projectileFlare`. The scene's `SKPhysicsContactDelegate` looks up
/// these by `name` (which is the snapshot's projectile ID) to resolve
/// damage and source weapon on impact.
@MainActor
final class ProjectileNode: SKShapeNode {

    /// Snapshot-side ID — also the scene-level `name`. Used by the contact
    /// handler to mark the corresponding sim projectile as consumed.
    let projectileID: String

    /// ID of the ship that fired this round. Player-friend or hostile is
    /// decided in `GameScene` against the local sessionId.
    let ownerId: String

    /// Name of the firing weapon (lookup key into `OutfitRegistry`).
    /// `nil` for legacy projectiles → fall back to a tiny default profile.
    let weaponName: String?

    /// `CollisionCategory` value driving contact gating.
    let categoryBit: UInt32

    init(id: String, ownerId: String, weaponName: String?,
         kind: String, isOwn: Bool) {
        self.projectileID = id
        self.ownerId      = ownerId
        self.weaponName   = weaponName

        let category: UInt32
        let contactMask: UInt32
        switch kind {
        case ProjectileKind.flare:
            // Flares ONLY interact with standard projectiles (rule 5).
            category    = CollisionCategory.projectileFlare
            contactMask = CollisionCategory.projectileStandard
        default:
            category    = CollisionCategory.projectileStandard
            // Hit ships, asteroids, or be intercepted by flares.
            contactMask = CollisionCategory.ship
                        | CollisionCategory.asteroid
                        | CollisionCategory.projectileFlare
        }
        self.categoryBit = category

        super.init()
        name = id

        // Beam-bolt look: a long thin energy bolt with a bright white core
        // and a coloured outer halo. Procedural so we don't depend on the
        // missing `Art/projectile/2x heavy laser` asset.
        let bolt = CGSize(width: 3, height: 22)
        path = CGPath(roundedRect: CGRect(x: -bolt.width / 2, y: -bolt.height / 2,
                                          width: bolt.width, height: bolt.height),
                      cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)

        let coreColor: UIColor
        let glowColor: UIColor
        switch kind {
        case ProjectileKind.flare:
            coreColor = .white
            glowColor = UIColor(red: 1.0, green: 0.55, blue: 0.20, alpha: 1)
        default:
            coreColor = .white
            glowColor = isOwn
                ? UIColor(red: 0.55, green: 0.95, blue: 1.0, alpha: 1)    // cyan
                : UIColor(red: 1.0,  green: 0.35, blue: 0.35, alpha: 1)    // red
        }
        fillColor   = coreColor
        strokeColor = .clear
        glowWidth   = 10
        blendMode   = .add

        // Outer halo — wider, additive, in the weapon's accent colour.
        let halo         = SKShapeNode(
            rect: CGRect(x: -bolt.width * 1.4, y: -bolt.height * 0.6,
                         width: bolt.width * 2.8, height: bolt.height * 1.2),
            cornerRadius: bolt.width * 1.2
        )
        halo.fillColor   = glowColor.withAlphaComponent(0.42)
        halo.strokeColor = .clear
        halo.blendMode   = .add
        halo.zPosition   = -0.1
        addChild(halo)

        // Tiny round muzzle "spark" at the tip for extra punch.
        let spark         = SKShapeNode(circleOfRadius: 4)
        spark.fillColor   = glowColor.withAlphaComponent(0.55)
        spark.strokeColor = .clear
        spark.blendMode   = .add
        spark.position    = CGPoint(x: 0, y: bolt.height / 2)
        spark.zPosition   = -0.1
        addChild(spark)

        let body = SKPhysicsBody(circleOfRadius: 4)
        body.isDynamic          = false
        body.affectedByGravity  = false
        body.categoryBitMask    = category
        body.collisionBitMask   = 0
        body.contactTestBitMask = contactMask
        physicsBody = body
    }

    required init?(coder aDecoder: NSCoder) { fatalError() }
}
