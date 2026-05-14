import Foundation
import Network

// ── Snapshot types ─────────────────────────────────────────────────────────────

struct ShipSnapshot {
    let x: Float
    let y: Float
    let angle: Float
    let velX: Float
    let velY: Float
    let shields: Float
    let hull: Float
    let thrusting: Bool
    let dead: Bool
}

struct ProjectileSnapshot {
    let x: Float
    let y: Float
    let ownerId: String
    /// Name of the outfit/weapon that fired this round. Lets the client
    /// look up `OutfitRegistry` stats on contact (damage, hit force, blast).
    /// Optional for backwards compat with old snapshots — `nil` falls back
    /// to a generic small-arms profile.
    let weaponName: String?
    /// `ProjectileKind.standard` | `.flare`. Drives collision categories.
    let kind: String
}

struct GameSnapshot {
    let tick: Int
    let ships: [String: ShipSnapshot]
    let projectiles: [String: ProjectileSnapshot]
}

// ── Delegate ───────────────────────────────────────────────────────────────────

protocol NetworkManagerDelegate: AnyObject {
    func didConnect(mySessionId: String)
    func didReceiveSnapshot(_ snapshot: GameSnapshot, mySessionId: String)
    func didShipDestroyed(sessionId: String, killedBy: String)
    func didShipRespawned(sessionId: String)
    func didPlayerLeft(sessionId: String)
    func didDisconnect()
}

// ── Input ──────────────────────────────────────────────────────────────────────

struct InputState {
    var thrust    = false
    var turnLeft  = false
    var turnRight = false
    var firing    = false
}

// ── NetworkManager ─────────────────────────────────────────────────────────────

final class NetworkManager {

    static let shared = NetworkManager()

    weak var delegate: NetworkManagerDelegate?
    var input = InputState()

    private var task: URLSessionWebSocketTask?
    private var sessionId: String?
    private var listenTask: Task<Void, Never>?
    private var inputTask:  Task<Void, Never>?
    private let session = URLSession(configuration: .default)

    // MARK: – Public

    func connect(to urlString: String = "ws://localhost:2568") {
        guard let url = URL(string: urlString) else { return }
        task = session.webSocketTask(with: url)
        task?.resume()
        sendRaw(["type": "join"])
        listenTask = Task { [weak self] in await self?.listenLoop() }
    }

    /// Lightweight TCP-only check that the server's port accepts connections.
    /// Caller-facing API for "Multiplayer requires a live server" gating —
    /// avoids dragging a full WebSocket handshake into the menu flow.
    /// Default endpoint matches `connect(to:)`. `completion` is invoked on
    /// the main thread exactly once.
    static func probeServer(host: String = "localhost",
                            port: UInt16 = 2568,
                            timeout: TimeInterval = 2.5,
                            completion: @escaping (Bool) -> Void) {
        let conn = NWConnection(
            host:   NWEndpoint.Host(host),
            port:   NWEndpoint.Port(integerLiteral: port),
            using:  .tcp
        )
        var done = false
        let finish: (Bool) -> Void = { ok in
            DispatchQueue.main.async {
                guard !done else { return }
                done = true
                conn.cancel()
                completion(ok)
            }
        }
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:                       finish(true)
            case .failed, .cancelled, .waiting(_): finish(false)
            default: break
            }
        }
        conn.start(queue: .global())
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            finish(false)
        }
    }

    func disconnect() {
        listenTask?.cancel()
        inputTask?.cancel()
        listenTask = nil
        inputTask  = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task      = nil
        sessionId = nil
    }

    // MARK: – Private

    private func listenLoop() async {
        guard let wsTask = task else { return }
        do {
            while !Task.isCancelled {
                let message = try await wsTask.receive()
                if case .string(let text) = message {
                    await MainActor.run { [weak self] in self?.handle(text) }
                }
            }
        } catch {
            await MainActor.run { [weak self] in self?.delegate?.didDisconnect() }
        }
    }

    private func startInputLoop() {
        inputTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self else { return }
                let i = await MainActor.run { self.input }
                self.sendRaw([
                    "type":      "input",
                    "thrust":    i.thrust,
                    "turnLeft":  i.turnLeft,
                    "turnRight": i.turnRight,
                    "firing":    i.firing,
                ])
            }
        }
    }

    private func sendRaw(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }

    @MainActor
    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {

        case "joined":
            guard let sid = json["sessionId"] as? String else { return }
            sessionId = sid
            startInputLoop()
            delegate?.didConnect(mySessionId: sid)

        case "snapshot":
            guard let sid  = sessionId,
                  let tick = json["tick"] as? Int,
                  let shipsRaw = json["ships"] as? [String: [String: Any]],
                  let projsRaw = json["projectiles"] as? [String: [String: Any]] else { return }

            var ships: [String: ShipSnapshot] = [:]
            for (id, s) in shipsRaw {
                guard let x       = (s["x"]       as? Double).map({ Float($0) }),
                      let y       = (s["y"]       as? Double).map({ Float($0) }),
                      let angle   = (s["angle"]   as? Double).map({ Float($0) }),
                      let velX    = (s["velX"]    as? Double).map({ Float($0) }),
                      let velY    = (s["velY"]    as? Double).map({ Float($0) }),
                      let shields = (s["shields"] as? Double).map({ Float($0) }),
                      let hull    = (s["hull"]    as? Double).map({ Float($0) }),
                      let thrust  = s["thrusting"] as? Bool,
                      let dead    = s["dead"]      as? Bool
                else { continue }
                ships[id] = ShipSnapshot(x: x, y: y, angle: angle,
                                         velX: velX, velY: velY,
                                         shields: shields, hull: hull,
                                         thrusting: thrust, dead: dead)
            }

            var projs: [String: ProjectileSnapshot] = [:]
            for (id, p) in projsRaw {
                guard let x       = (p["x"] as? Double).map({ Float($0) }),
                      let y       = (p["y"] as? Double).map({ Float($0) }),
                      let ownerId = p["ownerId"] as? String else { continue }
                let weapon = p["weapon"] as? String
                let kind   = (p["kind"] as? String) ?? ProjectileKind.standard
                projs[id] = ProjectileSnapshot(x: x, y: y, ownerId: ownerId,
                                               weaponName: weapon, kind: kind)
            }

            delegate?.didReceiveSnapshot(GameSnapshot(tick: tick, ships: ships, projectiles: projs),
                                         mySessionId: sid)

        case "ship_destroyed":
            if let sid = json["sessionId"] as? String,
               let by  = json["killedBy"]  as? String {
                delegate?.didShipDestroyed(sessionId: sid, killedBy: by)
            }

        case "ship_respawned":
            if let sid = json["sessionId"] as? String {
                delegate?.didShipRespawned(sessionId: sid)
            }

        case "player_left":
            if let sid = json["sessionId"] as? String {
                delegate?.didPlayerLeft(sessionId: sid)
            }

        default: break
        }
    }
}
