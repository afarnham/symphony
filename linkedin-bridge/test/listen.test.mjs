import assert from "node:assert/strict";
import test from "node:test";

import { bridgePort } from "../src/listen.mjs";

test("the TCP listener is off unless a port is set", () => {
  assert.equal(bridgePort({}), null);
  assert.equal(bridgePort({ SYMPHONY_LINKEDIN_BRIDGE_PORT: " " }), null);
  assert.equal(bridgePort({ SYMPHONY_LINKEDIN_BRIDGE_PORT: "6081" }), 6081);
});

test("an invalid port fails at startup", () => {
  for (const value of ["0", "65536", "6081x", "-1", "1.5"]) {
    assert.throws(() => bridgePort({ SYMPHONY_LINKEDIN_BRIDGE_PORT: value }), /must be a TCP port/);
  }
});
