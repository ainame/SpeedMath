// Preloaded with `node --import`: workerd APIs that Node 24 lacks, plus the loader hooks.
import { register } from "node:module";
import { timingSafeEqual } from "node:crypto";

Uint8Array.prototype.toHex ??= function () { return Buffer.from(this).toString("hex"); };
Uint8Array.fromHex ??= hex => new Uint8Array(Buffer.from(hex, "hex"));
crypto.subtle.timingSafeEqual ??= (a, b) => a.byteLength === b.byteLength && timingSafeEqual(a, b);
register("./loader.mjs", import.meta.url);
