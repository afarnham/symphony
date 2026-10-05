import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import http from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { BrowserAccessError } from "../src/browser.mjs";
import { createBridgeServer } from "../src/server.mjs";

const token = "0123456789abcdef0123456789abcdef";

test("authenticates requests and returns structured evidence", async () => {
  const directory = await mkdtemp(join(tmpdir(), "linkedin-bridge-test-"));
  const socket = join(directory, "bridge.sock");
  let active = 0;
  let maximum = 0;
  const service = {
    async lookup(profileUrl) {
      active += 1;
      maximum = Math.max(maximum, active);
      await new Promise((resolve) => setTimeout(resolve, 20));
      active -= 1;
      return { status: "ok", profileUrl, retrievedAt: "2026-10-05T00:00:00.000Z", accessMethod: "test", evidence: [] };
    },
  };
  const server = createBridgeServer({ service, token });
  await new Promise((resolve) => server.listen(socket, resolve));
  try {
    const unauthorized = await request(socket, "bad", "https://www.linkedin.com/in/example");
    assert.equal(unauthorized.statusCode, 401);
    const responses = await Promise.all([
      request(socket, token, "https://www.linkedin.com/in/one"),
      request(socket, token, "https://www.linkedin.com/in/two"),
    ]);
    assert.deepEqual(responses.map((response) => response.statusCode), [200, 200]);
    // The real service owns serialization because it also owns browser pages.
    assert.equal(maximum, 2);
  } finally {
    await new Promise((resolve) => server.close(resolve));
    await rm(directory, { recursive: true, force: true });
  }
});

test("reports browser human action without diagnostics or credentials", async () => {
  const directory = await mkdtemp(join(tmpdir(), "linkedin-bridge-test-"));
  const socket = join(directory, "bridge.sock");
  const service = {
    async lookup() {
      const error = new BrowserAccessError("login_required", "Sign in.", "Session expired.");
      error.profileUrl = "https://www.linkedin.com/in/example/details/experience/";
      throw error;
    },
  };
  const server = createBridgeServer({ service, token });
  await new Promise((resolve) => server.listen(socket, resolve));
  try {
    const response = await request(socket, token, "https://www.linkedin.com/in/example");
    assert.equal(response.statusCode, 503);
    assert.deepEqual(response.body, {
      status: "human_action_required",
      profileUrl: "https://www.linkedin.com/in/example/details/experience/",
      reason: "login_required",
      action: "Sign in.",
      message: "Session expired.",
    });
    assert.doesNotMatch(JSON.stringify(response.body), new RegExp(token));
  } finally {
    await new Promise((resolve) => server.close(resolve));
    await rm(directory, { recursive: true, force: true });
  }
});

function request(socketPath, bearer, profileUrl) {
  return new Promise((resolve, reject) => {
    const request = http.request({
      socketPath,
      path: "/v1/linkedin/profile-experience",
      method: "POST",
      headers: {
        authorization: `Bearer ${bearer}`,
        "content-type": "application/json",
      },
    }, (response) => {
      const chunks = [];
      response.on("data", (chunk) => chunks.push(chunk));
      response.on("end", () => resolve({
        statusCode: response.statusCode,
        body: JSON.parse(Buffer.concat(chunks).toString("utf8")),
      }));
    });
    request.on("error", reject);
    request.end(JSON.stringify({ profileUrl }));
  });
}
