import assert from "assert";
import { ColyseusTestServer, boot } from "@colyseus/testing";

import appConfig from "../src/app.config.js";
import { GameState } from "../src/schema/GameState.js";

describe("SystemRoom", () => {
  let colyseus: ColyseusTestServer<typeof appConfig>;

  before(async () => colyseus = await boot(appConfig));
  after(async () => colyseus.shutdown());
  beforeEach(async () => await colyseus.cleanup());

  it("client joins and gets a ship", async () => {
    const room = await colyseus.createRoom<GameState>("system_room", {});
    const client1 = await colyseus.connectTo(room);

    assert.strictEqual(client1.sessionId, room.clients[0].sessionId);
    await room.waitForNextPatch();

    assert.strictEqual(room.state.ships.size, 1);
    assert.ok(room.state.ships.has(client1.sessionId));
  });

  it("second client joins and both get ships", async () => {
    const room = await colyseus.createRoom<GameState>("system_room", {});
    const client1 = await colyseus.connectTo(room);
    const client2 = await colyseus.connectTo(room);

    await room.waitForNextPatch();

    assert.strictEqual(room.state.ships.size, 2);
  });
});
