/**
 * IMPORTANT:
 * ---------
 * Do not manually edit this file if you'd like to host your server on Colyseus Cloud
 *
 * If you're self-hosting, you can see "Raw usage" from the documentation.
 * 
 * See: https://docs.colyseus.io/server
 */
import { listen } from "@colyseus/tools";
import app from "./app.config.js";
import { startRawGameServer } from "./rawserver/RawGameServer.js";

listen(app);
startRawGameServer(2568);
