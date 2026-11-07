// Optional TCP port for the bridge, beside its unix socket, so a client on the
// Docker host can reach it. Publish it on the host's loopback only.
export function bridgePort(env = process.env) {
  const raw = env.SYMPHONY_LINKEDIN_BRIDGE_PORT?.trim();
  if (!raw) return null;
  const port = Number(raw);
  if (!/^\d+$/.test(raw) || port < 1 || port > 65535) {
    throw new Error(`SYMPHONY_LINKEDIN_BRIDGE_PORT must be a TCP port, got "${raw}".`);
  }
  return port;
}
