import Foundation

/// Single-player physics — mirrors the server's RawGameServer constants
/// so flight feel is identical between online and offline modes.
final class OfflineSim {

    // Physics constants — keep in sync with server/src/rawserver/RawGameServer.ts
    private let TICK_RATE: Float    = 20
    private let DRAG: Float         = 0.98
    private let BOUNDS: Float       = 5000
    private let PROJ_SPEED: Float   = 800
    private let PROJ_TTL: Int       = 60
    private let SHIP_RADIUS: Float  = 30
    private let FIRE_COOLDOWN: Int  = 10

    /// Scaling factors that translate JSON `thrust` / `turn` (force-style
    /// numbers) into the per-second acceleration / rotation the sim
    /// applies. Tuned so an empty ringship with a single Plasma Thruster
    /// + Plasma Steering feels comparable to the previous hard-coded
    /// values.
    private let THRUST_TO_ACCEL: Float = 4000
    private let TURN_TO_RADPS:   Float = 50

    /// Runtime values derived from the active ship + installed outfits.
    /// Set via `configureShipParams` from the main actor. With no engines
    /// installed both are 0, which keeps the ship immobile.
    private var totalThrust: Float = 150     // legacy fallback
    private var totalTurn:   Float = 1.8
    private var totalMass:   Float = 1.0     // never zero — divides into force

    /// Per-second active drains, applied only while the matching input is
    /// held. Heat counterparts add to the heat pool when active.
    private var thrustingEnergyDrain: Float = 0
    private var thrustingHeatGen:     Float = 0
    private var turningEnergyDrain:   Float = 0
    private var turningHeatGen:       Float = 0
    /// Always-on contributions from systems / shield generators.
    private var passiveEnergyDrain:   Float = 0
    private var passiveHeatGen:       Float = 0

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
    private var shields:        Float = 100
    private var hull:           Float = 100
    private var maxShields:     Float = 100
    private var maxHull:        Float = 100
    /// Per-second shield regeneration — sourced from ship base + outfits
    /// (e.g. Shield Generator contributes 1/s each). 0 means no regen.
    private var shieldRecharge: Float = 0

    /// Energy pool — regenerated at `energyRecharge`/sec, drained by
    /// firing (and eventually other systems). Capped at `maxEnergy`.
    private var energy:         Float = 100
    private var maxEnergy:      Float = 100
    private var energyRecharge: Float = 1

    /// Heat pool — added to by firing, dissipated at
    /// `heatDissipationRate`/sec. Displayed as `heat / maxHeat`.
    private var heat:                Float = 0
    private var maxHeat:             Float = 1000
    /// `ship.mass × ship.heat_dissipation` worth of heat shed per second.
    /// Pre-multiplied so the per-tick math stays a simple subtract.
    private var heatDissipationRate: Float = 100

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

    /// Hand the sim the ship's full runtime configuration. Called by
    /// `GameScene` after looking up the current `ShipDef` + installed
    /// outfits (which can't be done from this struct since it lives off
    /// the main actor). All values arrive pre-aggregated across outfits.
    func configureShipParams(maxEnergy: Float,
                              energyRecharge: Float,
                              maxHeat: Float,
                              heatDissipationRate: Float,
                              maxShields: Float,
                              shieldRecharge: Float,
                              maxHull:     Float,
                              totalThrust: Float,
                              totalTurn:   Float,
                              totalMass:   Float,
                              thrustingEnergyDrain: Float = 0,
                              thrustingHeatGen:     Float = 0,
                              turningEnergyDrain:   Float = 0,
                              turningHeatGen:       Float = 0,
                              passiveEnergyDrain:   Float = 0,
                              passiveHeatGen:       Float = 0) {
        self.maxEnergy            = maxEnergy
        self.energy               = maxEnergy          // start fully charged
        self.energyRecharge       = energyRecharge
        self.maxHeat              = maxHeat
        self.heatDissipationRate  = heatDissipationRate
        self.maxShields           = maxShields
        self.shields              = maxShields         // start at full shields
        self.shieldRecharge       = shieldRecharge
        self.maxHull              = maxHull
        self.hull                 = maxHull
        self.totalThrust          = totalThrust
        self.totalTurn            = totalTurn
        self.totalMass            = max(0.0001, totalMass)
        self.thrustingEnergyDrain = thrustingEnergyDrain
        self.thrustingHeatGen     = thrustingHeatGen
        self.turningEnergyDrain   = turningEnergyDrain
        self.turningHeatGen       = turningHeatGen
        self.passiveEnergyDrain   = passiveEnergyDrain
        self.passiveHeatGen       = passiveHeatGen
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

        // Effective per-second rotation + acceleration. With no engines,
        // both forces are zero and the ship can neither turn nor thrust.
        let turnRate: Float  = totalTurn   * TURN_TO_RADPS   / totalMass
        let accel:    Float  = totalThrust * THRUST_TO_ACCEL / totalMass

        // Steering is energy-gated: if we can't afford the per-tick cost,
        // the turn doesn't happen. Same for thrust.
        // When the input carries a `targetHeading`, slew toward it and
        // clamp the per-tick step to whatever's remaining — that's what
        // prevents the joystick from wobbling: the sim physically can't
        // rotate past the target in one tick.
        let turnCost: Float = turningEnergyDrain * dt
        let canTurnEnergy   = (turnRate > 0) && (energy >= turnCost)
        var didTurn         = false
        if canTurnEnergy, let target = input.targetHeading {
            let raw   = target - angle
            let diff  = atan2(sin(raw), cos(raw))   // shortest signed delta
            let maxStep = turnRate * dt
            if abs(diff) > 0.0001 {
                if abs(diff) <= maxStep { angle = target }
                else                    { angle += diff > 0 ? maxStep : -maxStep }
                didTurn = true
            }
        } else if canTurnEnergy && (input.turnLeft || input.turnRight) {
            if input.turnLeft  { angle -= turnRate * dt }
            if input.turnRight { angle += turnRate * dt }
            didTurn = true
        }
        if didTurn {
            energy -= turnCost
            heat   = min(maxHeat, heat + turningHeatGen * dt)
        }
        // Keep heading bounded to (−π, π]. Otherwise after enough ticks the
        // angle drifts to large values, hurting floating-point precision and
        // forcing the joystick's angular-diff math to wrap many times.
        if angle >  .pi { angle -= 2 * .pi }
        if angle < -.pi { angle += 2 * .pi }

        let thrustCost: Float = thrustingEnergyDrain * dt
        thrusting = input.thrust && accel > 0 && energy >= thrustCost
        if thrusting {
            velX += cos(angle) * accel * dt
            velY += sin(angle) * accel * dt
            energy -= thrustCost
            heat   = min(maxHeat, heat + thrustingHeatGen * dt)
        }
        velX *= DRAG
        velY *= DRAG
        x = max(-BOUNDS, min(BOUNDS, x + velX * dt))
        y = max(-BOUNDS, min(BOUNDS, y + velY * dt))

        // Passive energy/heat updates. Recharge runs every tick; passive
        // drains (shield generators, etc.) chip away at the pool whether
        // we're using anything else or not. Passive heat sources (reactors)
        // add a small constant trickle.
        energy = min(maxEnergy, energy + energyRecharge * dt)
        energy = max(0,         energy - passiveEnergyDrain * dt)
        heat   = max(0,         heat   - heatDissipationRate * dt)
        heat   = min(maxHeat,   heat   + passiveHeatGen * dt)

        // Shield regen — only while shields aren't fully topped off.
        if shields < maxShields {
            shields = min(maxShields, shields + shieldRecharge * dt)
        }

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
            // Per-shot energy/heat cost = per-second rate × reload (so the
            // weapon's stated "per second" stays constant across fire
            // rates). Bail out of the shot if there's not enough juice.
            let reload    = Float(weapon?.reload ?? 1)
            let shotEnergy = Float(weapon?.firingEnergy ?? 0) * reload
            let shotHeat   = Float(weapon?.firingHeat   ?? 0) * reload
            if energy < shotEnergy {
                lastFireTick = tick   // still consume the cooldown click so
                                      // the player isn't spam-firing each frame
            } else {
                energy -= shotEnergy
                heat   = min(maxHeat, heat + shotHeat)

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
                                shields: shields, maxShields: maxShields,
                                hull: hull,       maxHull: maxHull,
                                energy: energy,   maxEnergy: maxEnergy,
                                heat: heat,       maxHeat: maxHeat,
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

    /// Beam weapons fire continuously, so they consume their `firing_energy`
    /// and emit `firing_heat` per *frame* (scaled by `dt`). Returns `true`
    /// when the costs were applied — `false` means energy hit zero and the
    /// caller should stop drawing the beam for this frame.
    @discardableResult
    func applyBeamFiringCost(firingEnergy: Float,
                             firingHeat:   Float,
                             dt:           Float) -> Bool {
        let need = firingEnergy * dt
        guard energy >= need else { return false }
        energy -= need
        heat   = min(maxHeat, heat + firingHeat * dt)
        return true
    }
}
