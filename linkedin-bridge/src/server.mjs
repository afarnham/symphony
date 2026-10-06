import { timingSafeEqual } from "node:crypto";
import http from "node:http";

import { BrowserAccessError } from "./browser.mjs";
import { sanitizeEmptyExperienceDiagnostics } from "./extraction.mjs";

const MAX_BODY_BYTES = 4_096;

export function createBridgeServer({ service, token }) {
  if (typeof token !== "string" || token.length < 32) {
    throw new Error("The bridge token must contain at least 32 characters.");
  }
  return http.createServer(async (request, response) => {
    response.setHeader("content-type", "application/json; charset=utf-8");
    response.setHeader("cache-control", "no-store");
    if (!authorized(request.headers.authorization, token)) {
      return send(response, 401, { status: "rejected", reason: "unauthorized" });
    }
    if (request.method !== "POST" || request.url !== "/v1/linkedin/profile-experience") {
      return send(response, 404, { status: "rejected", reason: "not_found" });
    }

    try {
      const body = await readBody(request);
      if (
        !body ||
        typeof body !== "object" ||
        Array.isArray(body) ||
        Object.keys(body).length !== 1 ||
        !("profileUrl" in body)
      ) {
        throw new TypeError("The request must contain only profileUrl.");
      }
      return send(response, 200, await service.lookup(body.profileUrl));
    } catch (error) {
      if (error instanceof TypeError || error?.code === "BODY_TOO_LARGE") {
        return send(response, error?.code === "BODY_TOO_LARGE" ? 413 : 400, {
          status: "rejected",
          reason: "out_of_scope",
          message: error.message,
        });
      }
      if (error instanceof BrowserAccessError) {
        const diagnostics = sanitizeEmptyExperienceDiagnostics(error.diagnostics);
        return send(response, 503, {
          status: "human_action_required",
          profileUrl: error.profileUrl,
          reason: error.reason,
          action: error.action,
          message: error.message,
          ...(diagnostics ? { diagnostics } : {}),
        });
      }
      console.error("LinkedIn bridge lookup failed without response details.");
      return send(response, 503, {
        status: "human_action_required",
        reason: "browser_unavailable",
        action: "Read the symphony-linkedin-bridge service log on Thor.",
        message: "The scoped browser lookup failed.",
      });
    }
  });
}

function authorized(header, token) {
  if (typeof header !== "string" || !header.startsWith("Bearer ")) return false;
  const supplied = Buffer.from(header.slice(7));
  const expected = Buffer.from(token);
  return supplied.length === expected.length && timingSafeEqual(supplied, expected);
}

async function readBody(request) {
  let size = 0;
  const chunks = [];
  for await (const chunk of request) {
    size += chunk.length;
    if (size > MAX_BODY_BYTES) {
      const error = new Error("The request body is too large.");
      error.code = "BODY_TOO_LARGE";
      throw error;
    }
    chunks.push(chunk);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    throw new TypeError("The request body must be JSON.");
  }
}

function send(response, status, body) {
  response.statusCode = status;
  response.end(`${JSON.stringify(body)}\n`);
}
