#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import http from "node:http";
import { createInterface } from "node:readline";

const socketPath = process.env.SYMPHONY_LINKEDIN_BRIDGE_SOCKET ?? "/run/symphony-linkedin/bridge.sock";
const tokenFile = process.env.SYMPHONY_LINKEDIN_BRIDGE_TOKEN_FILE ?? "/run/secrets/linkedin_bridge_token";

if (process.argv[2] === "--mcp") {
  await runMcp();
} else {
  await runCli();
}

async function lookup(profileUrl) {
  const token = (await readFile(tokenFile, "utf8")).trim();
  return new Promise((resolve, reject) => {
    const request = http.request({
      socketPath,
      path: "/v1/linkedin/profile-experience",
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
      },
      timeout: 45_000,
    }, (response) => {
      const chunks = [];
      let size = 0;
      response.on("data", (chunk) => {
        size += chunk.length;
        if (size > 256 * 1_024) response.destroy(new Error("Bridge response is too large."));
        else chunks.push(chunk);
      });
      response.on("end", () => {
        try {
          const body = JSON.parse(Buffer.concat(chunks).toString("utf8"));
          if (response.statusCode === 401 || response.statusCode === 403) {
            resolve({
              status: "human_action_required",
              profileUrl,
              reason: "bridge_unavailable",
              action: "Verify the Afarnham worker token mount and recreate the worker container.",
              message: "The scoped LinkedIn bridge rejected the worker credential.",
            });
          } else {
            resolve(body);
          }
        } catch {
          reject(new Error("Bridge returned invalid JSON."));
        }
      });
    });
    request.on("timeout", () => request.destroy(new Error("Bridge request timed out.")));
    request.on("error", reject);
    request.end(JSON.stringify({ profileUrl }));
  });
}

async function runCli() {
  const profileUrl = process.argv[2];
  if (!profileUrl || process.argv.length !== 3) {
    console.error("Usage: symphony-linkedin-experience <https://www.linkedin.com/in/...>");
    process.exit(64);
  }
  let canonicalUrl;
  try {
    canonicalUrl = canonicalizeProfileUrl(profileUrl);
    const result = await lookup(canonicalUrl);
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    process.exitCode = result.status === "ok" ? 0 : result.status === "human_action_required" ? 2 : 1;
  } catch (error) {
    if (error instanceof TypeError) {
      process.stdout.write(`${JSON.stringify({
        status: "rejected",
        reason: "out_of_scope",
        message: error.message,
      }, null, 2)}\n`);
      process.exitCode = 1;
      return;
    }
    process.stdout.write(`${JSON.stringify({
      status: "human_action_required",
      profileUrl: canonicalUrl,
      reason: "bridge_unavailable",
      action: "Start or repair the symphony-linkedin-bridge service on Thor.",
      message: "The worker cannot reach the scoped LinkedIn bridge.",
    }, null, 2)}\n`);
    process.exitCode = 2;
  }
}

async function runMcp() {
  const lines = createInterface({ input: process.stdin, crlfDelay: Infinity });
  for await (const line of lines) {
    if (line.trim()) await handleMcpLine(line);
  }
}

async function handleMcpLine(line) {
  let message;
  try {
    message = JSON.parse(line);
  } catch {
    return;
  }
  if (message.id === undefined) return;
  try {
    if (message.method === "initialize") {
      return respond(message.id, {
        protocolVersion: message.params?.protocolVersion ?? "2025-06-18",
        capabilities: { tools: {} },
        serverInfo: { name: "symphony-linkedin", version: "1.0.0" },
      });
    }
    if (message.method === "ping") return respond(message.id, {});
    if (message.method === "tools/list") {
      return respond(message.id, { tools: [{
        name: "lookup_profile_experience",
        title: "Read LinkedIn profile experience",
        description: "Read visible role, employer, and date evidence from one LinkedIn /in/ profile through Thor's signed-in Chrome session.",
        inputSchema: {
          type: "object",
          properties: { profileUrl: { type: "string", format: "uri" } },
          required: ["profileUrl"],
          additionalProperties: false,
        },
        annotations: {
          readOnlyHint: true,
          destructiveHint: false,
          idempotentHint: true,
          openWorldHint: false,
        },
      }] });
    }
    if (message.method === "tools/call") {
      if (message.params?.name !== "lookup_profile_experience") {
        return respondError(message.id, -32602, "Unknown tool.");
      }
      const profileUrl = message.params?.arguments?.profileUrl;
      if (typeof profileUrl !== "string" || Object.keys(message.params?.arguments ?? {}).length !== 1) {
        return respondError(message.id, -32602, "profileUrl is required and must be the only argument.");
      }
      let result;
      let canonicalUrl;
      try {
        canonicalUrl = canonicalizeProfileUrl(profileUrl);
        result = await lookup(canonicalUrl);
      } catch (error) {
        if (error instanceof TypeError) {
          result = {
            status: "rejected",
            reason: "out_of_scope",
            message: error.message,
          };
        } else {
          result = {
            status: "human_action_required",
            profileUrl: canonicalUrl,
            reason: "bridge_unavailable",
            action: "Start or repair the symphony-linkedin-bridge service on Thor.",
            message: "The worker cannot reach the scoped LinkedIn bridge.",
          };
        }
      }
      return respond(message.id, {
        content: [{ type: "text", text: JSON.stringify(result) }],
        structuredContent: result,
        isError: false,
      });
    }
    return respondError(message.id, -32601, "Method not found.");
  } catch {
    return respondError(message.id, -32603, "The scoped LinkedIn tool failed.");
  }
}

function respond(id, result) {
  process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id, result })}\n`);
}

function respondError(id, code, message) {
  process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id, error: { code, message } })}\n`);
}

function canonicalizeProfileUrl(value) {
  let input;
  try {
    input = new URL(value);
  } catch {
    throw new TypeError("profileUrl must be an absolute URL.");
  }
  const match = input.pathname.match(/^\/in\/([^/]+?)(?:\/details\/experience)?\/?$/);
  const slug = match?.[1];
  if (
    input.protocol !== "https:" ||
    input.hostname.toLowerCase() !== "www.linkedin.com" ||
    input.username ||
    input.password ||
    input.port ||
    !slug ||
    slug.length > 200 ||
    !/^[A-Za-z0-9._%~-]+$/.test(slug) ||
    /%(?:2f|5c)/i.test(slug)
  ) {
    throw new TypeError("profileUrl must identify one https://www.linkedin.com/in/ profile.");
  }
  return `https://www.linkedin.com/in/${slug}/details/experience/`;
}
