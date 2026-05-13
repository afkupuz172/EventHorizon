import { WebSocketServer, WebSocket } from "ws";

// ── Physics constants ──────────────────────────────────────────────────────────
const TICK_RATE        = 20;
const DELTA            = 1 / TICK_RATE;
const TURN_SPEED       = 1.8;           // rad/s
const THRUST           = 150;           // units/s²
const DRAG             = 0.98;
const BOUNDS           = 5000;
const PROJ_SPEED       = 800;           // units/s
const PROJ_TTL         = 60;            // ticks (3 s)
const SHIP_RADIUS      = 30;
const FIRE_COOLDOWN    = 10;            // ticks (0.5 s)
const SHIELD_DMG       = 10;
const HULL_DMG         = 5;
const SHIELD_REGEN     = 0.5 * DELTA * 100;    // per tick
const SHIELD_REGEN_DELAY = 3 * TICK_RATE;       // ticks after last hit
const RESPAWN_MS       = 3000;

// ── Types ──────────────────────────────────────────────────────────────────────
interface Ship {
    x: number; y: number;
    angle: number;
    velX: number; velY: number;
    shields: number; hull: number;
    thrusting: boolean;
    ownerId: string;
    dead: boolean;
    lastFireTick: number;
    lastHitTick: number;
}

interface Projectile {
    x: number; y: number;
    velX: number; velY: number;
    ownerId: string;
    ttl: number;
}

interface Input {
    thrust: boolean;
    turnLeft: boolean;
    turnRight: boolean;
    firing: boolean;
}

interface Player {
    ws: WebSocket;
    sessionId: string;
    input: Input;
    ship: Ship;
}

// ── State ──────────────────────────────────────────────────────────────────────
let tick        = 0;
let projCounter = 0;
const players     = new Map<string, Player>();
const projectiles = new Map<string, Projectile>();

// ── Helpers ────────────────────────────────────────────────────────────────────
function makeId(): string {
    return Math.random().toString(36).slice(2, 10);
}

function spawnShip(sessionId: string): Ship {
    return {
        x: (Math.random() - 0.5) * BOUNDS,
        y: (Math.random() - 0.5) * BOUNDS,
        angle: Math.random() * Math.PI * 2,
        velX: 0, velY: 0,
        shields: 100, hull: 100,
        thrusting: false,
        ownerId: sessionId,
        dead: false,
        lastFireTick: -FIRE_COOLDOWN,
        lastHitTick: -9999,
    };
}

function broadcast(msg: object) {
    const json = JSON.stringify(msg);
    players.forEach(p => {
        if (p.ws.readyState === WebSocket.OPEN) p.ws.send(json);
    });
}

function destroyShip(sessionId: string, killedBy: string) {
    const player = players.get(sessionId);
    if (!player) return;
    player.ship.dead = true;
    player.ship.hull = 0;
    broadcast({ type: "ship_destroyed", sessionId, killedBy });

    setTimeout(() => {
        const p = players.get(sessionId);
        if (!p) return;
        p.ship = spawnShip(sessionId);
        broadcast({ type: "ship_respawned", sessionId });
    }, RESPAWN_MS);
}

// ── Game tick ──────────────────────────────────────────────────────────────────
function gameTick() {
    tick++;

    // Ships
    players.forEach((player, sessionId) => {
        const { ship, input } = player;
        if (ship.dead) return;

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

        if (tick - ship.lastHitTick > SHIELD_REGEN_DELAY && ship.shields < 100) {
            ship.shields = Math.min(100, ship.shields + SHIELD_REGEN);
        }

        if (input.firing && tick - ship.lastFireTick >= FIRE_COOLDOWN) {
            const id = `p${++projCounter}`;
            projectiles.set(id, {
                x: ship.x + Math.cos(ship.angle) * (SHIP_RADIUS + 5),
                y: ship.y + Math.sin(ship.angle) * (SHIP_RADIUS + 5),
                velX: ship.velX + Math.cos(ship.angle) * PROJ_SPEED,
                velY: ship.velY + Math.sin(ship.angle) * PROJ_SPEED,
                ownerId: sessionId,
                ttl: PROJ_TTL,
            });
            ship.lastFireTick = tick;
        }
    });

    // Projectiles + collision
    const toDelete: string[] = [];
    projectiles.forEach((proj, id) => {
        if (toDelete.includes(id)) return;
        proj.x += proj.velX * DELTA;
        proj.y += proj.velY * DELTA;
        proj.ttl--;
        if (proj.ttl <= 0) { toDelete.push(id); return; }

        players.forEach((player, sessionId) => {
            if (sessionId === proj.ownerId || player.ship.dead) return;
            const dx = proj.x - player.ship.x;
            const dy = proj.y - player.ship.y;
            if (dx * dx + dy * dy < SHIP_RADIUS * SHIP_RADIUS) {
                toDelete.push(id);
                player.ship.lastHitTick = tick;
                if (player.ship.shields > 0) {
                    player.ship.shields = Math.max(0, player.ship.shields - SHIELD_DMG);
                } else {
                    player.ship.hull = Math.max(0, player.ship.hull - HULL_DMG);
                }
                if (player.ship.hull <= 0) destroyShip(sessionId, proj.ownerId);
            }
        });
    });
    toDelete.forEach(id => projectiles.delete(id));

    // Snapshot
    const snap: Record<string, any> = { type: "snapshot", tick, ships: {}, projectiles: {} };
    players.forEach((p, id) => {
        const s = p.ship;
        snap.ships[id] = {
            x: s.x, y: s.y, angle: s.angle,
            velX: s.velX, velY: s.velY,
            shields: s.shields, hull: s.hull,
            thrusting: s.thrusting, dead: s.dead,
        };
    });
    projectiles.forEach((proj, id) => {
        snap.projectiles[id] = { x: proj.x, y: proj.y, ownerId: proj.ownerId };
    });
    broadcast(snap);
}

// ── Server ─────────────────────────────────────────────────────────────────────
export function startRawGameServer(port = 2568) {
    const wss = new WebSocketServer({ port });

    wss.on("connection", (ws: WebSocket) => {
        const sessionId = makeId();

        ws.on("message", (data) => {
            try {
                const msg = JSON.parse(data.toString());
                if (msg.type === "join") {
                    players.set(sessionId, {
                        ws, sessionId,
                        input: { thrust: false, turnLeft: false, turnRight: false, firing: false },
                        ship: spawnShip(sessionId),
                    });
                    ws.send(JSON.stringify({ type: "joined", sessionId }));
                    console.log(sessionId, "joined —", players.size, "players");
                } else if (msg.type === "input") {
                    const p = players.get(sessionId);
                    if (p) p.input = { thrust: !!msg.thrust, turnLeft: !!msg.turnLeft, turnRight: !!msg.turnRight, firing: !!msg.firing };
                }
            } catch { /* ignore malformed */ }
        });

        ws.on("close", () => {
            players.delete(sessionId);
            projectiles.forEach((proj, id) => { if (proj.ownerId === sessionId) projectiles.delete(id); });
            broadcast({ type: "player_left", sessionId });
            console.log(sessionId, "left —", players.size, "players");
        });

        ws.on("error", (err) => console.error(sessionId, "ws error:", err.message));
    });

    setInterval(gameTick, 1000 / TICK_RATE);
    console.log(`Game server listening on ws://localhost:${port}`);
}
