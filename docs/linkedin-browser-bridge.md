# Operate the scoped LinkedIn browser bridge on Thor

This runbook enables `agent-worker-afarnham` to read visible employment evidence from one exact
LinkedIn profile. It uses Aaron's existing signed-in Chrome profile at
`/home/aaron/.config/google-chrome`. It does not copy cookies into a container and does not give an
agent general browser control.

The worker receives one MCP tool and one equivalent command:

```text
lookup_profile_experience(profileUrl)
symphony-linkedin-experience https://www.linkedin.com/in/<profile>
```

Both interfaces accept only an HTTPS `www.linkedin.com/in/...` profile. The host bridge converts
the URL to its experience page and returns the canonical profile URL, visible role, organization,
and date text, the retrieval time, and `signed_in_chrome_devtools` as the access method. It cannot
open search, messaging, contact, company, or arbitrary web pages.

## Security boundary

Chrome listens for DevTools only on `127.0.0.1`. A host systemd service connects to that endpoint
and exposes a token-authenticated Unix socket at `/run/symphony-linkedin/bridge.sock`. Compose
mounts the socket directory and token only into `agent-worker-afarnham`. The Karbas worker receives
neither item. The nested Codex research process remains in its read-only sandbox and reaches the
socket only through the fixed stdio MCP broker started outside that sandbox.

The bridge serializes profile reads. It creates a new tab for each read, marks that tab as bridge
owned, and closes it after the read. On reconnect, it removes only orphaned tabs with that marker.
It never closes an unrelated tab and never closes Chrome. A service restart disconnects from
Chrome without ending the browser session.

The token is an authorization secret, not a LinkedIn credential. Keep it out of commands, logs,
tickets, and environment files. LinkedIn cookies stay in the existing Chrome profile.

## Pinned runtime

The bridge requires Node.js 22.12 or newer. `linkedin-bridge/package-lock.json` pins
`puppeteer-core` and all indirect packages. Install with `npm ci`; do not use an unpinned global
browser package.

## Prepare Chrome

1. Start the normal Google Chrome desktop session as `aaron` with
   `/home/aaron/.config/google-chrome`.
2. Open `chrome://inspect/#remote-debugging`.
3. Enable remote debugging for this browser. Keep the listener on loopback.
4. Confirm that `/home/aaron/.config/google-chrome/DevToolsActivePort` exists and that its port is
   bound only to `127.0.0.1`.
5. Keep LinkedIn signed in in this profile.

Chrome can show one local permission dialog when the bridge first connects. Approve that dialog
only when you initiated this setup. The bridge reports `permission_required` instead of retrying.

Check the listener without exposing the DevTools URL:

```bash
port=$(head -n 1 /home/aaron/.config/google-chrome/DevToolsActivePort)
ss -ltn "sport = :$port"
```

The local address must be `127.0.0.1` or `::1`. Stop if it is a LAN or public address.

## Install

Use the reviewed Symphony checkout at `/opt/symphony`.

```bash
cd /opt/symphony/linkedin-bridge
sudo npm ci --omit=dev --ignore-scripts
sudo install -o root -g root -m 0644 \
  /opt/symphony/deploy/systemd/symphony-linkedin-bridge@.service \
  /etc/systemd/system/symphony-linkedin-bridge@.service
sudo install -o root -g root -m 0755 \
  /opt/symphony/deploy/symphony-admin /usr/local/sbin/symphony-admin
sudo symphony-admin secrets init
sudo symphony-admin secrets verify
sudo systemctl daemon-reload
sudo systemctl enable --now symphony-linkedin-bridge@aaron.service
```

`secrets init` creates `/etc/symphony/secrets/linkedin_bridge_token` once. It preserves an existing
nonempty token. The system manager presents that token to the unprivileged bridge through a
private credential file.

Install the updated workflow and deploy the worker image and Compose definition from the same
reviewed release. Start the bridge before recreating the worker because Compose requires the host
socket directory to exist.

```bash
sudo install -o root -g root -m 0644 \
  /opt/symphony/deploy/workflows/app-tastemap.WORKFLOW.md \
  /etc/symphony/WORKFLOW.md
cd /opt/symphony
sudo docker compose --env-file /etc/symphony/deployment.env config --quiet
sudo systemctl restart symphony.service
```

The bridge unit orders itself before `symphony.service` when both services start during boot. Its
runtime directory stays in place across bridge restarts so the container's bind mount remains
valid.

## Verify from the real worker

Do not test this path through the orchestrator's SSH wrapper. Run the client in the actual worker:

```bash
cd /opt/symphony
sudo docker compose --env-file /etc/symphony/deployment.env exec -T \
  agent-worker-afarnham \
  symphony-linkedin-experience https://www.linkedin.com/in/<approved-profile>
```

A successful result has `status: "ok"`, a canonical `profileUrl`, a nonempty `evidence` array,
`retrievedAt`, and `accessMethod: "signed_in_chrome_devtools"`.

Confirm the worker boundary:

```bash
sudo docker compose --env-file /etc/symphony/deployment.env exec -T \
  agent-worker-karbas sh -lc \
  'test ! -e /run/secrets/linkedin_bridge_token && test ! -e /run/symphony-linkedin/bridge.sock'
```

Run one normal managed dining task with Codex on the Afarnham worker. The agent must use public
sources first. It may call the LinkedIn tool once only when a required role-specific date remains
missing and it has the exact profile URL. Inspect the saved restaurant artifact for raw
`linkedinEvidence`. Do not accept inferred dates.

## Human-action results

The bridge returns a typed action and no low-level diagnostics:

| Reason | Required action |
|---|---|
| `bridge_unavailable` | Start or repair the host bridge service. |
| `browser_unavailable` | Start Chrome and enable remote debugging in the Chrome UI. |
| `permission_required` | Approve the local Chrome debugging prompt. |
| `login_required` | Sign in to LinkedIn in the existing Chrome profile. |
| `linkedin_challenge` | Complete the visible LinkedIn security challenge in Chrome. |
| `linkedin_page_changed` | Open the experience page and confirm that entries are visible. |

The worker saves completed research and the access issue. Validation blocks without consuming a
repair pass. After the action is complete and the Project item returns to `Ready`, the workflow
runs `reopen-linkedin` once. That command saves recovered evidence and resumes the existing repair
packet. It does not restart the dining run.

## Restart and diagnose

Restarting the bridge does not restart Chrome:

```bash
sudo systemctl restart symphony-linkedin-bridge@aaron.service
sudo systemctl status symphony-linkedin-bridge@aaron.service --no-pager
sudo journalctl -u symphony-linkedin-bridge@aaron.service --since today
```

The journal records service state and generic failures. It must not contain tokens, cookies,
profile evidence, DevTools URLs, or Chrome profile contents.

If Chrome restarts, confirm its loopback listener and sign-in state. The next authorized lookup
reconnects automatically. If a prior bridge tab survived a crash, reconnect cleanup closes only
tabs marked as bridge owned.

If the socket is present but a lookup fails, check these items in order:

1. `systemctl is-active symphony-linkedin-bridge@aaron.service`.
2. The Chrome process and loopback DevTools listener.
3. A pending Chrome permission dialog.
4. The LinkedIn sign-in or challenge page in the visible browser.
5. The worker token and socket mounts.

Do not loosen URL validation, expose the DevTools port, mount the whole Chrome profile into a
container, or add a general browser MCP server to solve an outage.

## Roll back

Drain active Symphony work first. Restore the prior reviewed Symphony revision and prior worker
image digest, then recreate the stack. Stop and disable the bridge only after the old Compose
definition no longer mounts its runtime directory.

```bash
cd /opt/symphony
sudo docker compose --env-file /etc/symphony/deployment.env config --quiet
sudo systemctl restart symphony.service
sudo systemctl disable --now symphony-linkedin-bridge@aaron.service
sudo rm -f /etc/systemd/system/symphony-linkedin-bridge@.service
sudo systemctl daemon-reload
```

Keep `/etc/symphony/secrets/linkedin_bridge_token` protected during a temporary rollback. After a
permanent retirement, remove it through the approved secret-destruction process. Rollback does
not modify the Chrome profile, cookies, or ordinary browser tabs.
