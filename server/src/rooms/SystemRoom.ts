import { Room, Client, CloseCode } from "colyseus";
import { GameState, ShipState, ProjectileState } from "../schema/GameState.js";

const TICK_RATE = 20;
const DELTA = 1 / TICK_RATE;
const TURN_SPEED = 1.8;        // rad/s
const THRUST = 150;             // units/s²
const DRAG = 0.98;
const BOUNDS = 5000;
const PROJECTILE_SPEED = 800;  // units/s
const PROJECTILE_TTL = 60;     // ticks (3s at 20Hz)
const SHIP_RADIUS = 30;
const FIRE_COOLDOWN = 10;      // ticks (0.5s)
const SHIELD_DMG = 10;
const HULL_DMG = 5;
const SHIELD_REGEN = 0.5 * DELTA * 100; // per tick
const SHIELD_REGEN_DELAY = 3 * TICK_RATE; // ticks after last hit
const RESPAWN_MS = 3000;

interface Input {
    thrust: boolean;
    turnLeft: boolean;
    turnRight: boolean;
    firing: boolean;
}

interface PlayerMeta {
    input: Input;
    lastFireTick: number;
    lastHitTick: number;
    dead: boolean;
    kills: number;
    deaths: number;
}

export class SystemRoom extends Room {
    maxClients = 16;
    state = new GameState();

    private meta = new Map<string, PlayerMeta>();
    private tick = 0;
    private projCounter = 0;

    onCreate(_options: any) {
        this.onMessage("input", (client: Client, msg: Input) => {
            const m = this.meta.get(client.sessionId);
            if (m && !m.dead) m.input = msg;
        });

        this.setSimulationInterval(() => this.update(), 1000 / TICK_RATE);
        console.log("SystemRoom created");
    }

    onJoin(client: Client, _options: any) {
        const ship = new ShipState();
        ship.x = (Math.random() - 0.5) * BOUNDS;
        ship.y = (Math.random() - 0.5) * BOUNDS;
        ship.angle = Math.random() * Math.PI * 2;
        ship.ownerId = client.sessionId;
        this.state.ships.set(client.sessionId, ship);

        this.meta.set(client.sessionId, {
            input: { thrust: false, turnLeft: false, turnRight: false, firing: false },
            lastFireTick: -FIRE_COOLDOWN,
            lastHitTick: -9999,
            dead: false,
            kills: 0,
            deaths: 0,
        });

        console.log(client.sessionId, "joined —", this.state.ships.size, "ships");
    }

    onLeave(client: Client, _code: CloseCode) {
        this.state.ships.delete(client.sessionId);
        this.meta.delete(client.sessionId);

        // Remove any projectiles owned by this player
        const toDelete: string[] = [];
        this.state.projectiles.forEach((p, id) => {
            if (p.ownerId === client.sessionId) toDelete.push(id);
        });
        toDelete.forEach(id => this.state.projectiles.delete(id));

        console.log(client.sessionId, "left —", this.state.ships.size, "ships");
    }

    onDispose() {
        console.log("SystemRoom disposed");
    }

    private update() {
        this.tick++;

        // --- Ships ---
        this.state.ships.forEach((ship, sessionId) => {
            const m = this.meta.get(sessionId);
            if (!m || m.dead) return;

            const { input } = m;

            if (input.turnLeft)  ship.angle -= TURN_SPEED * DELTA;
            if (input.turnRight) ship.angle += TURN_SPEED * DELTA;

            ship.thrusting = input.thrust;
            if (input.thrust) {
                ship.velX += Math.cos(ship.angle) * THRUST * DELTA;
                ship.velY += Math.sin(ship.angle) * THRUST * DELTA;
            }

            ship.velX *= DRAG;
            ship.velY *= DRAG;

            ship.x = Math.max(-BOUNDS, Math.min(BOUNDS, ship.x + ship.velX * DELTA));
            ship.y = Math.max(-BOUNDS, Math.min(BOUNDS, ship.y + ship.velY * DELTA));

            // Shield regen after delay since last hit
            if (this.tick - m.lastHitTick > SHIELD_REGEN_DELAY && ship.shields < 100) {
                ship.shields = Math.min(100, ship.shields + SHIELD_REGEN);
            }

            // Fire
            if (input.firing && this.tick - m.lastFireTick >= FIRE_COOLDOWN) {
                this.spawnProjectile(ship, sessionId);
                m.lastFireTick = this.tick;
            }
        });

        // --- Projectiles ---
        const toDelete: string[] = [];

        this.state.projectiles.forEach((proj, id) => {
            if (toDelete.includes(id)) return;

            proj.x += proj.velX * DELTA;
            proj.y += proj.velY * DELTA;
            proj.ttl--;

            if (proj.ttl <= 0) { toDelete.push(id); return; }

            // Collision vs ships
            this.state.ships.forEach((ship, sessionId) => {
                if (sessionId === proj.ownerId) return;
                const m = this.meta.get(sessionId);
                if (!m || m.dead) return;

                const dx = proj.x - ship.x;
                const dy = proj.y - ship.y;
                if (dx * dx + dy * dy < SHIP_RADIUS * SHIP_RADIUS) {
                    toDelete.push(id);
                    m.lastHitTick = this.tick;

                    if (ship.shields > 0) {
                        ship.shields = Math.max(0, ship.shields - SHIELD_DMG);
                    } else {
                        ship.hull = Math.max(0, ship.hull - HULL_DMG);
                    }

                    if (ship.hull <= 0) {
                        const killer = this.meta.get(proj.ownerId);
                        if (killer) killer.kills++;
                        this.destroyShip(sessionId, m, proj.ownerId);
                    }
                }
            });
        });

        toDelete.forEach(id => this.state.projectiles.delete(id));
    }

    private spawnProjectile(ship: ShipState, ownerId: string) {
        const id = `p${++this.projCounter}`;
        const proj = new ProjectileState();
        proj.x = ship.x + Math.cos(ship.angle) * (SHIP_RADIUS + 5);
        proj.y = ship.y + Math.sin(ship.angle) * (SHIP_RADIUS + 5);
        proj.velX = ship.velX + Math.cos(ship.angle) * PROJECTILE_SPEED;
        proj.velY = ship.velY + Math.sin(ship.angle) * PROJECTILE_SPEED;
        proj.ownerId = ownerId;
        proj.ttl = PROJECTILE_TTL;
        this.state.projectiles.set(id, proj);
    }

    private destroyShip(sessionId: string, m: PlayerMeta, killerSessionId: string) {
        m.dead = true;
        m.deaths++;

        const ship = this.state.ships.get(sessionId);
        if (ship) { ship.shields = 0; ship.hull = 0; }

        this.broadcast("ship_destroyed", { sessionId, killedBy: killerSessionId });

        setTimeout(() => {
            if (!this.meta.has(sessionId)) return;
            const ship = this.state.ships.get(sessionId);
            if (!ship) return;
            ship.x = (Math.random() - 0.5) * BOUNDS;
            ship.y = (Math.random() - 0.5) * BOUNDS;
            ship.angle = Math.random() * Math.PI * 2;
            ship.velX = 0;
            ship.velY = 0;
            ship.shields = 100;
            ship.hull = 100;
            m.dead = false;
            m.lastHitTick = -9999;
            this.broadcast("ship_respawned", { sessionId });
        }, RESPAWN_MS);
    }
}
