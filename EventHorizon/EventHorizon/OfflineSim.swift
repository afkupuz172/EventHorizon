import Foundation

/// Single-player physics — mirrors the server's RawGameServer constants
/// so flight feel is identical between online and offline modes.
final class OfflineSim {

    // Physics constants — keep in sync with server/src/rawserver/RawGameServer.ts
    private let TICK_RATE: Float    = 20
    private let TURN_SPEED: Float   = 1.8
    private let THRUST: Float       = 150
    private let DRAG: Float         = 0.98
    private let BOUNDS: Float       = 5000
    private let PROJ_SPEED: Float   = 800
    private let PROJ_TTL: Int       = 60
    private let SHIP_RADIUS: Float  = 30
    private let FIRE_COOLDOWN: Int  = 10

    private struct LocalProjectile {
        var x: Float
        var y: Float
        var velX: Float
        var velY: Float
        var ttl: Int
        var weaponName: String?     // for damage lookup on contact
        var kind:       String       // "standard" | "flare"
    }

    let sessionId = "offline-player"

    private var x: Float
    private var y: Float
    private var angle: Float = .pi / 2          // start facing up
    private var velX: Float = 0
    private var velY: Float = 0
    private var thrusting   = false
    /// Player's damage state. Mutated by `applyDamage(...)` from the
    /// scene's contact handler. `dead` snapshots flip to true at 0 hull.
    private var shields: Float = 100
    private var hull:    Float = 100

    private var tick         = 0
    private var lastFireTick = -10_000
    private var projCounter  = 0
    private var projectiles: [String: LocalProjectile] = [:]

    /// Names of projectile IDs the scene's contact system reported as
    /// "consumed" (hit something / intercepted). Drained on the next tick
    /// so the snapshot stops including them.
    private var consumedProjectiles: Set<String> = []

    init(spawnAt: CGPoint? = nil) {
        if let p = spawnAt {
            x = Float(p.x)
            y = Float(p.y)
        } else {
            x = Float.random(in: -200...200)
            y = Float.random(in: -200...200)
        }
    }

    /// Advance one server-equivalent tick (1/TICK_RATE seconds) and return the snapshot.
    /// `weapon` is the player's currently-equipped firing weapon (looked up
    /// once per tick on the main actor by the caller so this struct can
    /// stay actor-agnostic). When nil, the sim falls back to its built-in
    /// laser-bolt defaults so firing always produces a projectile.
    func step(input: InputState,
              weaponName: String? = nil,
              weapon: OutfitDef.WeaponStats? = nil) -> GameSnapshot {
        let dt = 1 / TICK_RATE
        tick += 1

        if input.turnLeft  { angle -= TURN_SPEED * dt }
        if input.turnRight { angle += TURN_SPEED * dt }
        // Keep heading bounded to (−π, π]. Otherwise after enough ticks the
        // angle drifts to large values, hurting floating-point precision and
        // forcing the joystick's angular-diff math to wrap many times.
        if angle >  .pi { angle -= 2 * .pi }
        if angle < -.pi { angle += 2 * .pi }

        thrusting = input.thrust
        if thrusting {
            velX += cos(angle) * THRUST * dt
            velY += sin(angle) * THRUST * dt
        }
        velX *= DRAG
        velY *= DRAG
        x = max(-BOUNDS, min(BOUNDS, x + velX * dt))
        y = max(-BOUNDS, min(BOUNDS, y + velY * dt))

        // Reload-driven fire rate. `reload` is the JSON-side cooldown in
        // seconds (and the per-second→per-shot multiplier for the damage
        // stats). `reload >= 1` flags the weapon as a beam: the scene
        // renders + applies damage continuously, no projectile spawned.
        // `reload < 1` fires individual bolts every `reload` seconds.
        let isBeam = (weapon != nil) && (weapon?.reload ?? 0) >= 1.0
        let cooldownTicks: Int = {
            guard let r = weapon?.reload, r > 0 else { return FIRE_COOLDOWN }
            return max(1, Int((r * Double(TICK_RATE)).rounded(.up)))
        }()
        if !isBeam && input.firing && tick - lastFireTick >= cooldownTicks {
            projCounter += 1
            let id = "p\(projCounter)"
            // Velocity / lifetime come from the equipped weapon's stats
            // when present; otherwise fall back to sim defaults so firing
            // never breaks if the player has no weapons installed.
            let muzzle = Float(weapon?.velocity ?? Double(PROJ_SPEED))
            let life   = Int(weapon?.lifetime ?? Double(PROJ_TTL))
            projectiles[id] = LocalProjectile(
                x:    x + cos(angle) * (SHIP_RADIUS + 5),
                y:    y + sin(angle) * (SHIP_RADIUS + 5),
                velX: velX + cos(angle) * muzzle,
                velY: velY + sin(angle) * muzzle,
                ttl:  life,
                weaponName: weaponName,
                kind:       weapon?.kind ?? ProjectileKind.standard
            )
            lastFireTick = tick
        }

        var expired: [String] = []
        for (id, var p) in projectiles {
            if consumedProjectiles.contains(id) { expired.append(id); continue }
            p.x += p.velX * dt
            p.y += p.velY * dt
            p.ttl -= 1
            if p.ttl <= 0 {
                expired.append(id)
            } else {
                projectiles[id] = p
            }
        }
        for id in expired { projectiles.removeValue(forKey: id) }
        consumedProjectiles.removeAll(keepingCapacity: true)

        let ship = ShipSnapshot(x: x, y: y, angle: angle,
                                velX: velX, velY: velY,
                                shields: shields, hull: hull,
                                thrusting: thrusting, dead: hull <= 0)

        var projs: [String: ProjectileSnapshot] = [:]
        for (id, p) in projectiles {
            projs[id] = ProjectileSnapshot(x: p.x, y: p.y, ownerId: sessionId,
                                           weaponName: p.weaponName, kind: p.kind)
        }

        return GameSnapshot(tick: tick,
                            ships: [sessionId: ship],
                            projectiles: projs)
    }

    // MARK: – Contact callbacks (called by `GameScene`)

    /// Apply weapon damage to the player ship — shields first, then hull.
    /// `force` is an impulse (world units / sec²) applied along `direction`.
    func applyDamage(shieldDamage: Float, hullDamage: Float,
                     force: Float, direction: (dx: Float, dy: Float)) {
        var s = shieldDamage
        if shields > 0 {
            let absorbed = min(shields, s)
            shields -= absorbed
            s       -= absorbed
        }
        // Bleed-through to hull happens when shields are insufficient OR
        // depleted; bolts that meet a shield are wholly absorbed by the
        // shield damage stat — only their hull-damage component remains.
        if s > 0 || shields <= 0 {
            hull -= hullDamage
            if hull < 0 { hull = 0 }
        }
        // Knockback nudges sim velocity directly.
        velX += direction.dx * force * 0.01
        velY += direction.dy * force * 0.01
    }

    func markProjectileConsumed(_ id: String) {
        consumedProjectiles.insert(id)
    }
}
