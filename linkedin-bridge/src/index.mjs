import { chmod, lstat, readFile, unlink } from "node:fs/promises";

import { ChromeSession } from "./browser.mjs";
import { bridgePort } from "./listen.mjs";
import { createBridgeServer } from "./server.mjs";
import { LinkedInExperienceService } from "./service.mjs";

const socketPath = requiredEnvironment("SYMPHONY_LINKEDIN_BRIDGE_SOCKET");
const port = bridgePort();
const tokenFile = process.env.SYMPHONY_LINKEDIN_BRIDGE_TOKEN_FILE?.trim()
  || `${requiredEnvironment("CREDENTIALS_DIRECTORY")}/auth-token`;
const userDataDir = requiredEnvironment("SYMPHONY_LINKEDIN_CHROME_USER_DATA_DIR");
const token = (await readFile(tokenFile, "utf8")).trim();
const chromeSession = new ChromeSession({ userDataDir });
const service = new LinkedInExperienceService({ chromeSession });
const server = createBridgeServer({ service, token });

try {
  const existing = await lstat(socketPath);
  if (!existing.isSocket()) throw new Error(`Refusing to replace a non-socket path: ${socketPath}`);
  await unlink(socketPath);
} catch (error) {
  if (error?.code !== "ENOENT") throw error;
}

server.listen(socketPath, async () => {
  await chmod(socketPath, 0o666);
  console.log("Symphony LinkedIn bridge is ready.");
});

// Same handler and browser session; requests still need the bearer token.
const tcpServer = port === null ? null : createBridgeServer({ service, token });
tcpServer?.listen(port, "0.0.0.0", () => {
  console.log(`Symphony LinkedIn bridge is listening on TCP port ${port}.`);
});

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.once(signal, async () => {
    server.close();
    tcpServer?.close();
    await service.close();
    process.exit(0);
  });
}

function requiredEnvironment(name) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is required.`);
  return value;
}
