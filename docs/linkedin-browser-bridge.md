# Operate the scoped LinkedIn browser bridge on Thor

This runbook enables `agent-worker-afarnham` to read visible employment evidence from one exact
LinkedIn profile. It uses a dedicated persistent Chrome data directory at
`/var/lib/symphony-linkedin-chrome-aaron`. Aaron signs in to LinkedIn once in that profile; a
headless systemd service then reuses the session after service and host restarts. Aaron's ordinary
Chrome profile at `/home/aaron/.config/google-chrome` and all of its tabs and cookies remain
untouched.

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

The dedicated browser asks the kernel for a random DevTools port and binds it only to
`127.0.0.1`. A host systemd service discovers the endpoint through the profile's
`DevToolsActivePort` file and exposes a token-authenticated Unix socket at
`/run/symphony-linkedin/bridge.sock`. Compose mounts the socket directory and token only into
`agent-worker-afarnham`. The Karbas worker receives neither item. The nested Codex research process
remains in its read-only sandbox and reaches the socket only through the fixed stdio MCP broker
started outside that sandbox.

Chrome's automatic default-profile connection asks for permission on every new debugging session.
This deployment does not suppress or automate that prompt. Instead it uses Chrome's supported
manual remote-debugging mode with a non-default data directory, so the prompt does not exist. The
DevTools socket never leaves Thor and is not mounted into a worker.

The bridge serializes profile reads. It creates a new tab for each read, marks that tab as bridge
owned, and closes it after the read. On reconnect, it removes only orphaned tabs with that marker.
It never closes an unrelated tab and never closes Chrome. A bridge restart disconnects from Chrome
without ending the browser session.

The token is an authorization secret, not a LinkedIn credential. Keep it out of commands, logs,
tickets, and environment files. LinkedIn cookies stay in the dedicated Chrome data directory.
Because no desktop keyring is unlocked during headless boot, Chrome runs with
`--password-store=basic`. The profile is therefore protected at rest by its root-managed location,
Aaron-only ownership, mode `0700`, and the host's disk/access controls rather than a desktop
keyring. The service also sets Chrome's `HOME` to that private state directory so Chrome can create
its launcher and crash-handler state while the real `/home` tree remains hidden by systemd.
Do not place unrelated accounts or browsing data in this profile.

## Pinned runtime

The bridge requires Node.js 22.12 or newer. `linkedin-bridge/package-lock.json` pins
`puppeteer-core` and all indirect packages. Install with `npm ci`; do not use an unpinned global
browser package.

## Install and sign in once

Use the reviewed Symphony checkout at `/opt/symphony`. Install both host units before bootstrapping
the dedicated profile:

```bash
cd /opt/symphony/linkedin-bridge
sudo npm ci --omit=dev --ignore-scripts
sudo install -o root -g root -m 0644 \
  /opt/symphony/deploy/systemd/symphony-linkedin-chrome@.service \
  /etc/systemd/system/symphony-linkedin-chrome@.service
sudo install -o root -g root -m 0644 \
  /opt/symphony/deploy/systemd/symphony-linkedin-bridge@.service \
  /etc/systemd/system/symphony-linkedin-bridge@.service
sudo install -o root -g root -m 0755 \
  /opt/symphony/deploy/symphony-admin /usr/local/sbin/symphony-admin
sudo symphony-admin secrets init
sudo symphony-admin secrets verify
sudo systemctl daemon-reload
```

`secrets init` creates `/etc/symphony/secrets/linkedin_bridge_token` once and preserves an existing
nonempty token. The system manager presents it to the unprivileged bridge through a private
credential file.

Create the persistent state directory, then stop the headless browser before opening the same
profile interactively:

```bash
sudo systemctl start symphony-linkedin-chrome@aaron.service
sudo systemctl stop symphony-linkedin-chrome@aaron.service
```

From Aaron's graphical/VNC terminal, start a separate visible Chrome with the exact same storage
mode as the boot service:

```bash
google-chrome \
  --user-data-dir=/var/lib/symphony-linkedin-chrome-aaron \
  --password-store=basic \
  --no-first-run \
  --no-default-browser-check \
  https://www.linkedin.com/login
```

Sign in to LinkedIn, open one profile experience page to confirm the session, and then close this
dedicated Chrome window completely. Do not copy the ordinary Chrome profile or its cookies. If the
machine has no active graphical/VNC session, start the existing private VNC session for this
one-time login; do not expose Chrome or DevTools on a network interface.

Enable the headless browser and bridge at boot:

```bash
sudo systemctl enable --now symphony-linkedin-chrome@aaron.service
sudo systemctl enable --now symphony-linkedin-bridge@aaron.service
```

Confirm that both units are active and that the randomly selected DevTools port is loopback-only:

```bash
sudo systemctl is-active \
  symphony-linkedin-chrome@aaron.service \
  symphony-linkedin-bridge@aaron.service
port=$(sudo head -n 1 \
  /var/lib/symphony-linkedin-chrome-aaron/DevToolsActivePort)
ss -ltn "sport = :$port"
```

The local address must be `127.0.0.1` or `::1`. Stop if it is a LAN or public address. There is no
Chrome approval dialog in this mode.

After the real-worker verification succeeds, disable remote debugging in Aaron's ordinary Chrome
at `chrome://inspect/#remote-debugging`; the default-profile listener is no longer used.

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

The browser and bridge order themselves before `symphony.service` during boot. The bridge runtime
directory stays in place across bridge restarts so the container's bind mount remains valid.

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

The bridge returns a typed action. A failed extraction also includes a bounded diagnostic summary
with an allow-listed classification, booleans, and capped element counts. It never includes page
text, HTML, selectors, cookies, tokens, contacts, or Chrome profile contents.

| Reason | Required action |
|---|---|
| `bridge_unavailable` | Start or repair the host bridge service. |
| `browser_unavailable` | Start or repair the dedicated headless Chrome service. |
| `login_required` | Repeat the one-time sign-in using the dedicated profile. |
| `linkedin_challenge` | Stop the headless unit, complete the challenge in visible Chrome using the dedicated profile, close Chrome, and restart the unit. |
| `linkedin_page_changed` | Open the experience page in the dedicated Symphony LinkedIn Chrome profile on Thor and confirm whether the Experience section and dated entries are visible. |

The failed-extraction `diagnostics.classification` distinguishes `page_not_ready`,
`profile_unavailable`, `experience_section_missing`, `experience_section_empty`,
`experience_entries_unrecognized`, and the defensive `scoped_evidence_rejected` fallback. These
signals explain why extraction stopped; they do not relax the evidence requirement or authorize a
second lookup.

The worker saves completed research and the access issue. Validation blocks without consuming a
repair pass. After the action is complete and the Project item returns to `Ready`, the workflow
runs `reopen-linkedin` once. That command saves recovered evidence and resumes the existing repair
packet. It does not restart the dining run.

## Restart and diagnose

Both services restart automatically after failures and start during boot. Restarting the bridge
does not restart Chrome or discard the LinkedIn session. Stopping the Chrome unit asks the browser
to close through DevTools before systemd terminates any remaining processes, so profile changes are
flushed before a normal service stop or host reboot:

```bash
sudo systemctl restart symphony-linkedin-bridge@aaron.service
sudo systemctl status \
  symphony-linkedin-chrome@aaron.service \
  symphony-linkedin-bridge@aaron.service --no-pager
sudo journalctl \
  -u symphony-linkedin-chrome@aaron.service \
  -u symphony-linkedin-bridge@aaron.service --since today
```

The journal records service state and generic failures. It must not contain tokens, cookies,
profile evidence, DevTools URLs, or Chrome profile contents.

If Chrome restarts, the random loopback port can change. The bridge reads the new
`DevToolsActivePort` file and reconnects automatically; no permission approval is required. If a
prior bridge tab survived a crash, reconnect cleanup closes only tabs marked as bridge owned.

If the socket is present but a lookup fails, check these items in order:

1. Both systemd units are active.
2. The dedicated profile's DevTools port is listening only on loopback.
3. The LinkedIn sign-in or challenge state in the dedicated profile.
4. The worker token and socket mounts.

Do not loosen URL validation, expose the DevTools port, mount the Chrome profile into a container,
or add a general browser MCP server to solve an outage.

## Roll back

Drain active Symphony work first. Restore the prior reviewed Symphony revision and prior worker
image digest, then recreate the stack. Stop and disable the bridge only after the old Compose
definition no longer mounts its runtime directory.

```bash
cd /opt/symphony
sudo docker compose --env-file /etc/symphony/deployment.env config --quiet
sudo systemctl restart symphony.service
sudo systemctl disable --now symphony-linkedin-bridge@aaron.service
sudo systemctl disable --now symphony-linkedin-chrome@aaron.service
sudo rm -f \
  /etc/systemd/system/symphony-linkedin-bridge@.service \
  /etc/systemd/system/symphony-linkedin-chrome@.service
sudo systemctl daemon-reload
```

Keep `/etc/symphony/secrets/linkedin_bridge_token` and
`/var/lib/symphony-linkedin-chrome-aaron` protected during a temporary rollback. After permanent
retirement, remove both through the approved secret-destruction process. Rollback does not modify
Aaron's ordinary Chrome profile, cookies, or tabs.
