import { defineServer, defineRoom, monitor, playground } from "colyseus";
import { SystemRoom } from "./rooms/SystemRoom.js";

const server = defineServer({
    rooms: {
        system_room: defineRoom(SystemRoom),
    },
    express: (app) => {
        app.use("/monitor", monitor());
        if (process.env.NODE_ENV !== "production") {
            app.use("/", playground());
        }
    },
});

export default server;