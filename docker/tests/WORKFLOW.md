---
tracker:
  kind: memory
polling:
  interval_ms: 1000
workspace:
  root: /workspaces
worker:
  ssh_hosts:
    - agent-worker
  max_concurrent_agents_per_host: 1
agent:
  backend: codex
  max_concurrent_agents: 1
server:
  host: 0.0.0.0
  port: 4000
---

Container smoke-test workflow. The memory tracker remains empty; this test verifies startup,
health, isolation, credentials wiring, and the SSH reverse-forwarding transport.
