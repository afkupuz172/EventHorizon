import Foundation
import CoreGraphics

/// Single-player NPC simulation. Owns every non-player ship in the
/// system: spawning, AI, projectile firing, damage bookkeeping.
/// Produces `ShipSnapshot` and `ProjectileSnapshot` dicts that GameScene
/// merges into its render pipeline alongside `OfflineSim`'s own output.
@MainActor
final class NPCManager {

    // MARK: – Tunables

    /// Hull fraction at which a ship becomes immobilised but not yet
    /// destroyed. Disabled ships drift, can't fire, and can't manoeuvre.
    private let DISABLED_HULL_PCT: Float = 0.15
    /// Seconds an NPC sits at 0 hull (showing its hull as 0 in the
    /// snapshot) before being removed and exploded.
    private let DEATH_DELAY: TimeInterval = 0.35
    /// Time from spawn until rising animation completes.
    private let RISE_DURATION: TimeInterval = 1.6
    /// Time from start-of-landing to despawn.
    private let LAND_DURATION: TimeInterval = 1.6
    /// Maximum NPCs in the system at once.
    private let MAX_CONCURRENT: Int = 8
    /// Same physics constants as OfflineSim.
    private let DRAG: Float = 0.98
    private let THRUST_ACCEL: Float = 95
    private let TURN_RATE: Float = 1.6
    private let PROJ_SPEED: Float = 600
    private let PROJ_TTL: TimeInterval = 1.8

    // MARK: – State types

    enum AIState {
        case rising(target: CGPoint, t0: TimeInterval)
        case patrolling(waypoint: CGPoint, until: TimeInterval)
        case engaging(targetSessionId: String)
        case fleeing(target: CGPoint)
        case landing(target: CGPoint, t0: TimeInterval)
        case dying(t0: TimeInterval)
    }

    struct NPCState {
        let sessionId:   String
        let shipID:      String
        let faction:     String
        let personality: PersonalityDef
        let weaponID:    String?       // first weapon from the ship's default loadout
        let spawnAnchor: CGPoint        // origin planet position (or edge entry point)
        var x: Float
        var y: Float
        var angle: Float
        var velX: Float
        var velY: Float
        var hull: Float
        var maxHull: Float
        var shields: Float
        var maxShields: Float
        var thrusting: Bool
        var visualScale: Float
        var disabled: Bool
        var aiState: AIState
        var nextFireTime: TimeInterval
        /// Damage taken from each session-id this run — used to attribute
        /// the killing blow when the ship explodes (player-only for now,
        /// but the dict generalises if NPC-vs-NPC kills get rep deltas
        /// later).
        var damageByOwner: [String: Float]
    }

    struct Projectile {
        let id: String
        var x: Float
        var y: Float
        let velX: Float
        let velY: Float
        let expiresAt: TimeInterval
        let ownerId: String
        let weaponName: String?
    }

    /// Destruction event: NPC removed this step, with where and to whom
    /// to attribute the kill. GameScene drains these every tick to spawn
    /// FX and apply reputation deltas.
    struct Destruction {
        let sessionId: String
        let position:  CGPoint
        let faction:   String
        let killerOwnerId: String?
    }

    // MARK: – Storage

    private var npcs:        [String: NPCState]   = [:]
    private var projectiles: [String: Projectile] = [:]
    private var spawnAccumulators: [String: Double] = [:]
    private var consumedProjectiles: Set<String> = []
    private(set) var recentDestructions: [Destruction] = []

    private let fleetRefs: [SystemFleetRef]
    private let systemBounds: Float = 5000
    private let playerSessionId: String
    private weak var solarSystem: SolarSystem?
    private var npcCounter = 0
    private var projCounter = 0

    init(systemConfig: SolarSystemConfig,
         solarSystem: SolarSystem,
         playerSessionId: String) {
        self.fleetRefs = systemConfig.fleets ?? []
        self.solarSystem = solarSystem
        self.playerSessionId = playerSessionId
    }

    // MARK: – Public API

    /// Returns the NPC's faction (or nil if `sid` isn't an NPC).
    func faction(of sid: String) -> String? { npcs[sid]?.faction }

    /// Whether the given session corresponds to one of our NPCs.
    func isNPC(_ sid: String) -> Bool { npcs[sid] != nil }

    /// Per-NPC AI state — exposed for HUD/debug only.
    func state(of sid: String) -> AIState? { npcs[sid]?.aiState }

    /// Apply damage attributed to a specific shooter. The owner ID
    /// drives reputation accounting on kill.
    func applyDamage(toSessionId sid: String,
                     shieldDamage: Float,
                     hullDamage: Float,
                     ownerId: String) {
        guard var npc = npcs[sid] else { return }
        var sd = shieldDamage
        if npc.shields > 0 {
            let absorbed = min(npc.shields, sd)
            npc.shields -= absorbed
            sd -= absorbed
        }
        // Damage past shields bleeds into hull at 50% (matches OfflineSim).
        let leftover = sd * 0.5
        npc.hull -= (hullDamage + leftover)
        npc.hull = max(0, npc.hull)
        npc.damageByOwner[ownerId, default: 0] += hullDamage + leftover
        // Disabled threshold — keep the hull non-zero but freeze the
        // ship. At exactly zero we enter the dying transition.
        if npc.hull <= 0 {
            if case .dying = npc.aiState { } else {
                npc.aiState = .dying(t0: Date().timeIntervalSince1970)
                npc.thrusting = false
            }
        } else if npc.hull / npc.maxHull <= DISABLED_HULL_PCT {
            npc.disabled = true
            npc.thrusting = false
        }
        npcs[sid] = npc
    }

    /// GameScene calls this when a projectile is consumed by a contact
    /// (hit or absorbed). Mirrors OfflineSim.markProjectileConsumed.
    func markProjectileConsumed(_ id: String) {
        consumedProjectiles.insert(id)
    }

    /// Advance one sim step. Returns the ship + projectile snapshots
    /// owned by this manager. Caller is expected to merge these into the
    /// final `GameSnapshot` it feeds to the scene.
    func step(dt: TimeInterval,
              now: TimeInterval,
              playerPosition: CGPoint,
              playerFaction: String,
              playerReputation: [String: Int]) -> (
                ships: [String: ShipSnapshot],
                projectiles: [String: ProjectileSnapshot]
              ) {
        // 1. Spawn rolls
        rollSpawns(dt: dt, now: now)
        // 2. Drain consumed projectiles from prior tick
        for id in consumedProjectiles {
            projectiles.removeValue(forKey: id)
        }
        consumedProjectiles.removeAll()
        // 3. Tick each NPC
        recentDestructions.removeAll()
        for sid in npcs.keys {
            tickNPC(sid: sid, dt: dt, now: now,
                    playerPosition: playerPosition,
                    playerFaction: playerFaction,
                    playerReputation: playerReputation)
        }
        // 4. Tick projectiles (advance + expire)
        var stillLive: [String: Projectile] = [:]
        for (id, var p) in projectiles {
            if p.expiresAt < now { continue }
            p.x += p.velX * Float(dt)
            p.y += p.velY * Float(dt)
            stillLive[id] = p
        }
        projectiles = stillLive

        // 5. Build snapshot dicts
        var shipOut: [String: ShipSnapshot] = [:]
        var toRemove: [String] = []
        for (sid, npc) in npcs {
            // Dying NPCs explode after a brief delay then despawn.
            if case .dying(let t0) = npc.aiState, now - t0 >= DEATH_DELAY {
                recentDestructions.append(.init(
                    sessionId: sid,
                    position:  CGPoint(x: CGFloat(npc.x), y: CGFloat(npc.y)),
                    faction:   npc.faction,
                    killerOwnerId: dominantAttacker(npc.damageByOwner)
                ))
                toRemove.append(sid)
                continue
            }
            // Landing NPCs despawn when their scale collapses.
            if case .landing(_, let t0) = npc.aiState, now - t0 >= LAND_DURATION {
                toRemove.append(sid)
                continue
            }
            shipOut[sid] = ShipSnapshot(
                x: npc.x, y: npc.y, angle: npc.angle,
                velX: npc.velX, velY: npc.velY,
                shields: npc.shields, maxShields: npc.maxShields,
                hull: npc.hull, maxHull: npc.maxHull,
                energy: 0, maxEnergy: 0, heat: 0, maxHeat: 0,
                thrusting: npc.thrusting, dead: npc.hull <= 0,
                shipID: npc.shipID, faction: npc.faction,
                scale: npc.visualScale, disabled: npc.disabled
            )
        }
        for sid in toRemove { npcs.removeValue(forKey: sid) }

        var projOut: [String: ProjectileSnapshot] = [:]
        for (id, p) in projectiles {
            projOut[id] = ProjectileSnapshot(
                x: p.x, y: p.y,
                ownerId: p.ownerId,
                weaponName: p.weaponName,
                kind: "standard"
            )
        }
        return (shipOut, projOut)
    }

    // MARK: – Spawn rolls

    private func rollSpawns(dt: TimeInterval, now: TimeInterval) {
        guard npcs.count < MAX_CONCURRENT else { return }
        for ref in fleetRefs {
            spawnAccumulators[ref.fleet, default: 0] += dt * ref.spawnsPerMinute / 60
            while (spawnAccumulators[ref.fleet] ?? 0) >= 1 {
                spawnAccumulators[ref.fleet]! -= 1
                spawnFleet(id: ref.fleet, now: now)
                if npcs.count >= MAX_CONCURRENT { return }
            }
        }
    }

    private func spawnFleet(id: String, now: TimeInterval) {
        guard let fleet = FleetRegistry.shared.fleet(id: id) else { return }
        let count = Int.random(in: fleet.minCount...max(fleet.minCount, fleet.maxCount))
        // All ships in a fleet share an entry point so they group up.
        let anchor: CGPoint
        let source = fleet.defaultSource ?? "planet"
        if source == "planet", let p = randomPlanet() {
            anchor = p
        } else {
            anchor = randomEdgePoint()
        }
        for _ in 0..<count {
            guard let pick = fleet.pickShip(randomUnit: Double.random(in: 0..<1))
            else { continue }
            spawnShip(faction:     fleet.faction,
                      shipID:      pick.ship,
                      personalityID: pick.personality,
                      anchor:      anchor,
                      source:      source,
                      now:         now)
            if npcs.count >= MAX_CONCURRENT { return }
        }
    }

    private func spawnShip(faction: String,
                           shipID: String,
                           personalityID: String,
                           anchor: CGPoint,
                           source: String,
                           now: TimeInterval) {
        guard let personality = PersonalityRegistry.shared.personality(id: personalityID),
              let def = ShipRegistry.shared.def(for: shipID)
        else { return }
        npcCounter += 1
        let sid = "npc_\(npcCounter)"
        // Loadout — pick the first installed weapon as their fire-source.
        // Falls back to nil (no firing) if none recognised.
        let weaponID: String? = (def.outfits ?? []).map(\.name)
            .first(where: { OutfitRegistry.shared.outfit(id: $0)?.weapon != nil })
        let scatter: CGFloat = source == "planet" ? 30 : 80
        let startX = Float(anchor.x + CGFloat.random(in: -scatter...scatter))
        let startY = Float(anchor.y + CGFloat.random(in: -scatter...scatter))
        let aiState: AIState
        let initialScale: Float
        switch source {
        case "edge":
            // Warp-in: full size immediately, but moving toward system
            // centre at speed so the entry reads as a hyperspace arrival.
            aiState = .patrolling(
                waypoint: CGPoint(x: 0, y: 0),
                until: now + Double.random(in: 6...12))
            initialScale = 1
        default:
            aiState = .rising(target: anchor, t0: now)
            initialScale = 0
        }
        let maxHull    = Float(def.attributes.hull)
        let maxShields = Float(def.attributes.shields)
        let state = NPCState(
            sessionId: sid, shipID: shipID, faction: faction,
            personality: personality, weaponID: weaponID,
            spawnAnchor: anchor,
            x: startX, y: startY,
            angle: Float.random(in: 0..<2 * .pi),
            velX: 0, velY: 0,
            hull: maxHull, maxHull: maxHull,
            shields: maxShields, maxShields: maxShields,
            thrusting: false,
            visualScale: initialScale,
            disabled: false,
            aiState: aiState,
            nextFireTime: now + Double.random(in: 0.5...1.5),
            damageByOwner: [:]
        )
        npcs[sid] = state
    }

    // MARK: – AI tick

    private func tickNPC(sid: String, dt: TimeInterval, now: TimeInterval,
                         playerPosition: CGPoint,
                         playerFaction: String,
                         playerReputation: [String: Int]) {
        guard var npc = npcs[sid] else { return }
        defer { npcs[sid] = npc }

        // Dying ships freeze and stop thrusting; their snapshot still
        // renders the wreck for DEATH_DELAY seconds.
        if case .dying = npc.aiState {
            applyPhysics(&npc, dt: dt)
            return
        }
        // Disabled ships drift only.
        if npc.disabled {
            applyPhysics(&npc, dt: dt)
            return
        }

        // Re-evaluate AI state every tick. State transitions are
        // priority-ordered: dying > landing > fleeing > engaging > patrol.
        let rep = playerReputation[npc.faction] ?? 0
        let towardPlayer = FactionRegistry.shared.stance(
            of: npc.faction, toward: "player", playerReputation: rep)
        let hullPct = npc.hull / max(1, npc.maxHull)
        let playerInRange = distance(npc.x, npc.y,
                                     Float(playerPosition.x),
                                     Float(playerPosition.y))
                            <= npc.personality.engagementRange

        // Stay in current state if landing/rising — those are timed
        // transitions handled below.
        switch npc.aiState {
        case .rising(let target, let t0):
            let elapsed = now - t0
            npc.visualScale = Float(min(elapsed / RISE_DURATION, 1.0))
            // Drift outward from planet during rise so we clear the
            // surface visibly.
            let dx = npc.x - Float(target.x)
            let dy = npc.y - Float(target.y)
            let len = max(0.001, sqrt(dx * dx + dy * dy))
            npc.velX += (dx / len) * 60 * Float(dt)
            npc.velY += (dy / len) * 60 * Float(dt)
            if elapsed >= RISE_DURATION {
                npc.visualScale = 1
                npc.aiState = pickPatrolWaypoint(for: &npc, now: now)
            }
            applyPhysics(&npc, dt: dt)
            return
        case .landing(let target, let t0):
            let elapsed = now - t0
            npc.visualScale = Float(max(0, 1 - elapsed / LAND_DURATION))
            // Vector toward the planet centre at gentle speed.
            steer(&npc, toward: target, dt: dt, intensity: 0.6)
            applyPhysics(&npc, dt: dt)
            return
        default:
            break
        }

        // Flee — low hull or stance says "flee" and player is close.
        if hullPct <= npc.personality.fleeHullPct
           || (towardPlayer == "flee" && playerInRange) {
            if let planet = nearestPlanet(to: CGPoint(x: CGFloat(npc.x), y: CGFloat(npc.y))) {
                npc.aiState = .fleeing(target: planet)
                steer(&npc, toward: planet, dt: dt,
                      intensity: npc.personality.thrustIntensity)
                // If we're already nearly there, transition to landing.
                if distance(npc.x, npc.y, Float(planet.x), Float(planet.y)) < 200 {
                    npc.aiState = .landing(target: planet, t0: now)
                }
                applyPhysics(&npc, dt: dt)
                return
            }
        }

        // Engage — hostile target inside range.
        if towardPlayer == "hostile" && playerInRange
           && npc.personality.engagementRange > 0 {
            engagePlayer(&npc, dt: dt, now: now, playerPos: playerPosition)
            applyPhysics(&npc, dt: dt)
            return
        }

        // Patrol — wander toward current waypoint, repick when reached
        // or timed out.
        switch npc.aiState {
        case .patrolling(let wp, let until):
            steer(&npc, toward: wp, dt: dt,
                  intensity: npc.personality.thrustIntensity * 0.7)
            let reached = distance(npc.x, npc.y, Float(wp.x), Float(wp.y)) < 120
            if reached || now > until {
                npc.aiState = pickPatrolWaypoint(for: &npc, now: now)
            }
        default:
            npc.aiState = pickPatrolWaypoint(for: &npc, now: now)
        }
        applyPhysics(&npc, dt: dt)
    }

    private func engagePlayer(_ npc: inout NPCState,
                              dt: TimeInterval,
                              now: TimeInterval,
                              playerPos: CGPoint) {
        npc.aiState = .engaging(targetSessionId: playerSessionId)
        let target = playerPos
        let dx = Float(target.x) - npc.x
        let dy = Float(target.y) - npc.y
        let dist = sqrt(dx * dx + dy * dy)
        // Steer to maintain preferredDistance — approach if too far,
        // back off if too close.
        if dist > npc.personality.preferredDistance + 40 {
            steer(&npc, toward: target, dt: dt,
                  intensity: npc.personality.thrustIntensity)
        } else if dist < npc.personality.preferredDistance - 40 {
            let away = CGPoint(x: CGFloat(npc.x - dx), y: CGFloat(npc.y - dy))
            steer(&npc, toward: away, dt: dt,
                  intensity: npc.personality.thrustIntensity * 0.5)
        } else {
            // In the sweet spot — just face the target.
            faceToward(&npc, target: target, dt: dt)
        }
        // Fire if cooldown ready and weapon resolvable.
        if now >= npc.nextFireTime, let wid = npc.weaponID,
           let def = OutfitRegistry.shared.outfit(id: wid),
           let weapon = def.weapon {
            spawnNPCProjectile(from: &npc, weapon: weapon,
                               weaponName: wid, target: target, now: now)
            let reload = max(0.4, Double(weapon.reload ?? 0.8))
            npc.nextFireTime = now + reload
        }
    }

    // MARK: – Helpers

    private func pickPatrolWaypoint(for npc: inout NPCState, now: TimeInterval) -> AIState {
        let r = CGFloat(npc.personality.patrolRadius)
        let wp = CGPoint(
            x: npc.spawnAnchor.x + CGFloat.random(in: -r...r),
            y: npc.spawnAnchor.y + CGFloat.random(in: -r...r)
        )
        return .patrolling(waypoint: wp, until: now + Double.random(in: 4...9))
    }

    private func steer(_ npc: inout NPCState,
                       toward target: CGPoint,
                       dt: TimeInterval,
                       intensity: Float) {
        faceToward(&npc, target: target, dt: dt)
        // Thrust only when we're roughly pointing at the target.
        let desired = atan2(Float(target.y) - npc.y, Float(target.x) - npc.x)
        let delta = atan2f(sin(desired - npc.angle), cos(desired - npc.angle))
        if abs(delta) < 0.5 {
            npc.thrusting = true
            npc.velX += cos(npc.angle) * THRUST_ACCEL * intensity * Float(dt)
            npc.velY += sin(npc.angle) * THRUST_ACCEL * intensity * Float(dt)
        } else {
            npc.thrusting = false
        }
    }

    private func faceToward(_ npc: inout NPCState,
                            target: CGPoint,
                            dt: TimeInterval) {
        let desired = atan2(Float(target.y) - npc.y, Float(target.x) - npc.x)
        let delta = atan2f(sin(desired - npc.angle), cos(desired - npc.angle))
        let step = TURN_RATE * Float(dt)
        npc.angle += abs(delta) <= step ? delta : (delta > 0 ? step : -step)
    }

    private func applyPhysics(_ npc: inout NPCState, dt: TimeInterval) {
        npc.x += npc.velX * Float(dt)
        npc.y += npc.velY * Float(dt)
        npc.velX *= pow(DRAG, Float(dt) * 60)
        npc.velY *= pow(DRAG, Float(dt) * 60)
        // Clamp inside system bounds — bounce gently off the edge so
        // ships don't escape into the void.
        if abs(npc.x) > systemBounds {
            npc.x = npc.x > 0 ? systemBounds : -systemBounds
            npc.velX = -npc.velX * 0.4
        }
        if abs(npc.y) > systemBounds {
            npc.y = npc.y > 0 ? systemBounds : -systemBounds
            npc.velY = -npc.velY * 0.4
        }
        // Slow shield regen — 2/s flat for now.
        if !npc.disabled && npc.hull > 0 && npc.shields < npc.maxShields {
            npc.shields = min(npc.maxShields, npc.shields + 2 * Float(dt))
        }
    }

    private func spawnNPCProjectile(from npc: inout NPCState,
                                     weapon: OutfitDef.WeaponStats,
                                     weaponName: String,
                                     target: CGPoint,
                                     now: TimeInterval) {
        let dx = Float(target.x) - npc.x
        let dy = Float(target.y) - npc.y
        let aim = atan2(dy, dx) + Float.random(in: -npc.personality.aimJitter ... npc.personality.aimJitter)
        let speed = Float(weapon.velocity ?? Double(PROJ_SPEED))
        let ttl   = TimeInterval(weapon.lifetime ?? Double(PROJ_TTL))
        projCounter += 1
        let id = "\(npc.sessionId)_p\(projCounter)"
        projectiles[id] = Projectile(
            id: id,
            x: npc.x + cos(aim) * 30,
            y: npc.y + sin(aim) * 30,
            velX: cos(aim) * speed,
            velY: sin(aim) * speed,
            expiresAt: now + ttl,
            ownerId: npc.sessionId,
            weaponName: weaponName
        )
    }

    private func randomPlanet() -> CGPoint? {
        guard let planets = solarSystem?.planetPositions, !planets.isEmpty
        else { return nil }
        return planets.randomElement()
    }

    private func nearestPlanet(to point: CGPoint) -> CGPoint? {
        guard let planets = solarSystem?.planetPositions, !planets.isEmpty
        else { return nil }
        return planets.min(by: {
            let d0 = ($0.x - point.x) * ($0.x - point.x) + ($0.y - point.y) * ($0.y - point.y)
            let d1 = ($1.x - point.x) * ($1.x - point.x) + ($1.y - point.y) * ($1.y - point.y)
            return d0 < d1
        })
    }

    private func randomEdgePoint() -> CGPoint {
        let edge = CGFloat(systemBounds) * 0.95
        let side = Int.random(in: 0..<4)
        let t = CGFloat.random(in: -edge...edge)
        switch side {
        case 0: return CGPoint(x: -edge, y: t)
        case 1: return CGPoint(x:  edge, y: t)
        case 2: return CGPoint(x: t, y: -edge)
        default: return CGPoint(x: t, y:  edge)
        }
    }

    private func distance(_ ax: Float, _ ay: Float,
                          _ bx: Float, _ by: Float) -> Float {
        let dx = ax - bx, dy = ay - by
        return sqrt(dx * dx + dy * dy)
    }

    private func dominantAttacker(_ d: [String: Float]) -> String? {
        d.max(by: { $0.value < $1.value })?.key
    }
}
