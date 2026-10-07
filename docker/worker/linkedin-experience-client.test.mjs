import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import http from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

const client = new URL("./linkedin-experience-client.mjs", import.meta.url);
const runbook = new URL("../../docs/linkedin-browser-bridge.md", import.meta.url);

test("CLI sends the token through a Unix socket and prints bridge JSON", async () => {
  await withBridge(async ({ directory, socket, tokenFile, token }) => {
    const result = await run(["https://www.linkedin.com/in/example"], { socket, tokenFile });
    assert.equal(result.code, 0);
    assert.equal(JSON.parse(result.stdout).status, "ok");
    assert.equal(await readFile(tokenFile, "utf8"), `${token}\n`);
    assert.equal(result.stderr, "");
    assert.ok(directory);
  });
});

test("MCP advertises and calls only the scoped lookup tool", async () => {
  await withBridge(async ({ socket, tokenFile }) => {
    const child = spawn(process.execPath, [client.pathname, "--mcp"], {
      env: environment(socket, tokenFile),
      stdio: ["pipe", "pipe", "pipe"],
    });
    const messages = [];
    let buffer = "";
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      buffer += chunk;
      while (buffer.includes("\n")) {
        const index = buffer.indexOf("\n");
        messages.push(JSON.parse(buffer.slice(0, index)));
        buffer = buffer.slice(index + 1);
      }
    });
    for (const message of [
      { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18" } },
      { jsonrpc: "2.0", id: 2, method: "tools/list", params: {} },
      { jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "lookup_profile_experience", arguments: { profileUrl: "https://www.linkedin.com/in/example" } } },
      { jsonrpc: "2.0", id: 4, method: "tools/call", params: { name: "browser_control", arguments: {} } },
    ]) child.stdin.write(`${JSON.stringify(message)}\n`);
    child.stdin.end();
    await new Promise((resolve, reject) => {
      child.once("exit", resolve);
      child.once("error", reject);
    });
    assert.deepEqual(messages[1].result.tools.map((tool) => tool.name), ["lookup_profile_experience"]);
    assert.equal(messages[2].result.structuredContent.status, "ok");
    assert.equal(messages[3].error.code, -32602);
  });
});

test("CLI rejects non-profile LinkedIn destinations without contacting the bridge", async () => {
  const result = await run(["https://www.linkedin.com/messaging/"], {
    socket: "/not-used/bridge.sock",
    tokenFile: "/not-used/token",
  });
  assert.equal(result.code, 1);
  assert.equal(JSON.parse(result.stdout).reason, "out_of_scope");
});

test("CLI turns a rejected bridge credential into one operator action", async () => {
  await withBridge(async ({ socket, tokenFile }) => {
    const result = await run(["https://www.linkedin.com/in/example"], { socket, tokenFile });
    assert.equal(result.code, 2);
    const response = JSON.parse(result.stdout);
    assert.equal(response.reason, "bridge_unavailable");
    assert.match(response.action, /token mount/);
  }, { responseStatus: 401 });
});

test("CLI exits after a human-action response while its stdin pipe remains open", async () => {
  const humanAction = {
    status: "human_action_required",
    profileUrl: "https://www.linkedin.com/in/example/details/experience/",
    reason: "linkedin_page_changed",
    action: "Use the dedicated Thor profile.",
    message: "No scoped evidence.",
    diagnostics: {
      schemaVersion: 1,
      classification: "experience_section_missing",
      mainPresent: true,
      mainVisible: true,
      experienceHeadingPresent: false,
      experienceSectionPresent: false,
      experienceSectionHasNonHeadingText: false,
      visibleExperienceItemCount: 0,
      datedCandidateCount: 0,
      loadingIndicatorPresent: false,
      unavailableMarkerPresent: false,
    },
  };
  await withBridge(async ({ socket, tokenFile }) => {
    const child = spawn(process.execPath, [client.pathname, "https://www.linkedin.com/in/example"], {
      env: environment(socket, tokenFile),
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    const result = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("CLI did not exit after its response.")), 1_000);
      child.once("error", (error) => {
        clearTimeout(timer);
        reject(error);
      });
      child.once("exit", (code, signal) => {
        clearTimeout(timer);
        resolve({ code, signal });
      });
    });
    assert.deepEqual(result, { code: 2, signal: null });
    assert.deepEqual(JSON.parse(stdout), humanAction);
    assert.equal(stderr, "");
    assert.equal(child.stdin.writableEnded, false);
    child.stdin.destroy();
  }, { responseStatus: 503, responseBody: humanAction });
});

test("runbook worker checks disable both TTY and interactive stdin", async () => {
  const contents = await readFile(runbook, "utf8");
  const commands = contents.match(/docker compose[^\n]+exec -T --interactive=false/g) ?? [];
  assert.equal(commands.length, 2);
});

async function withBridge(callback, { responseStatus = 200, responseBody } = {}) {
  const directory = await mkdtemp(join(tmpdir(), "linkedin-client-test-"));
  const socket = join(directory, "bridge.sock");
  const tokenFile = join(directory, "token");
  const token = "0123456789abcdef0123456789abcdef";
  await writeFile(tokenFile, `${token}\n`, { mode: 0o400 });
  const server = http.createServer(async (request, response) => {
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    assert.equal(request.headers.authorization, `Bearer ${token}`);
    const body = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    response.setHeader("content-type", "application/json");
    response.statusCode = responseStatus;
    if (responseBody) {
      response.end(JSON.stringify(responseBody));
      return;
    }
    if (responseStatus !== 200) {
      response.end(JSON.stringify({ status: "rejected", reason: "unauthorized" }));
      return;
    }
    response.end(JSON.stringify({
      status: "ok",
      profileUrl: body.profileUrl,
      retrievedAt: "2026-10-05T00:00:00.000Z",
      accessMethod: "test",
      evidence: [],
    }));
  });
  await new Promise((resolve) => server.listen(socket, resolve));
  try {
    await callback({ directory, socket, tokenFile, token });
  } finally {
    await new Promise((resolve) => server.close(resolve));
    await rm(directory, { recursive: true, force: true });
  }
}

function run(args, { socket, tokenFile }) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [client.pathname, ...args], {
      env: environment(socket, tokenFile),
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.once("error", reject);
    child.once("exit", (code) => resolve({ code, stdout, stderr }));
  });
}

function environment(socket, tokenFile) {
  return {
    ...process.env,
    SYMPHONY_LINKEDIN_BRIDGE_SOCKET: socket,
    SYMPHONY_LINKEDIN_BRIDGE_TOKEN_FILE: tokenFile,
  };
}
