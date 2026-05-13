import { Schema, MapSchema, type } from "@colyseus/schema";

export class ShipState extends Schema {
    @type("float32") x: number = 0;
    @type("float32") y: number = 0;
    @type("float32") angle: number = 0;
    @type("float32") velX: number = 0;
    @type("float32") velY: number = 0;
    @type("float32") shields: number = 100;
    @type("float32") hull: number = 100;
    @type("boolean") thrusting: boolean = false;
    @type("string") ownerId: string = "";
}

export class ProjectileState extends Schema {
    @type("float32") x: number = 0;
    @type("float32") y: number = 0;
    @type("float32") velX: number = 0;
    @type("float32") velY: number = 0;
    @type("string") ownerId: string = "";
    @type("int16") ttl: number = 0;
}

export class GameState extends Schema {
    @type({ map: ShipState }) ships = new MapSchema<ShipState>();
    @type({ map: ProjectileState }) projectiles = new MapSchema<ProjectileState>();
}
