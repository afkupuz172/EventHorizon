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
    }

    let sessionId = "offline-player"

    private var x: Float
    private var y: Float
    private var angle: Float = .pi / 2          // start facing up
    private var velX: Float = 0
    private var velY: Float = 0
    private var thrusting   = false

    private var tick         = 0
    private var lastFireTick = -10_000
    private var projCounter  = 0
    private var projectiles: [String: LocalProjectile] = [:]

    init() {
        x = Float.random(in: -200...200)
        y = Float.random(in: -200...200)
    }

    /// Advance one server-equivalent tick (1/TICK_RATE seconds) and return the snapshot.
    func step(input: InputState) -> GameSnapshot {
        let dt = 1 / TICK_RATE
        tick += 1

        if input.turnLeft  { angle -= TURN_SPEED * dt }
        if input.turnRight { angle += TURN_SPEED * dt }

        thrusting = input.thrust
        if thrusting {
            velX += cos(angle) * THRUST * dt
            velY += sin(angle) * THRUST * dt
        }
        velX *= DRAG
        velY *= DRAG
        x = max(-BOUNDS, min(BOUNDS, x + velX * dt))
        y = max(-BOUNDS, min(BOUNDS, y + velY * dt))

        if input.firing && tick - lastFireTick >= FIRE_COOLDOWN {
            projCounter += 1
            let id = "p\(projCounter)"
            projectiles[id] = LocalProjectile(
                x:    x + cos(angle) * (SHIP_RADIUS + 5),
                y:    y + sin(angle) * (SHIP_RADIUS + 5),
                velX: velX + cos(angle) * PROJ_SPEED,
                velY: velY + sin(angle) * PROJ_SPEED,
                ttl:  PROJ_TTL
            )
            lastFireTick = tick
        }

        var expired: [String] = []
        for (id, var p) in projectiles {
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

        let ship = ShipSnapshot(x: x, y: y, angle: angle,
                                velX: velX, velY: velY,
                                shields: 100, hull: 100,
                                thrusting: thrusting, dead: false)

        var projs: [String: ProjectileSnapshot] = [:]
        for (id, p) in projectiles {
            projs[id] = ProjectileSnapshot(x: p.x, y: p.y, ownerId: sessionId)
        }

        return GameSnapshot(tick: tick,
                            ships: [sessionId: ship],
                            projectiles: projs)
    }
}
