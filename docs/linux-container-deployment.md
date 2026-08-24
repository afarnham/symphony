# Deploy Symphony to a Linux VM

This runbook deploys Symphony as three long-running containers on a single, trusted Linux VM:

- `symphony` polls the tracker, owns scheduling, and serves the host-loopback dashboard.
- `agent-worker-afarnham` and `agent-worker-karbas` accept SSH sessions from Symphony. Each has
  isolated Claude, Codex, workspace, cache, and local-state volumes.

A third `volume-init` service runs once with only the `CHOWN` capability, no network, and no
secrets; it prepares the named volumes for the unprivileged services and exits.

The separation is a security boundary. The orchestrator receives the GitHub Project tracker
credential. Both workers receive the same repository-scoped GitHub credential, but each worker has
its own coding-agent credentials. Do not collapse the model-authentication volumes or mount one
profile's volumes into the other profile.

The checked-in operator interface is:

```text
/opt/symphony/compose.yaml                 Compose definition
/etc/symphony/deployment.env              non-secret Compose settings
/etc/symphony/WORKFLOW.md                  non-secret Symphony workflow
/etc/symphony/secrets/                     root-only secret source files
/usr/local/sbin/symphony-admin             secret and login utility
/etc/systemd/system/symphony.service       boot lifecycle
```

The deployment is portable across Linux distributions that provide a current rootful Docker
Engine, Docker Compose v2, and systemd. The images are standard OCI images, but this runbook's
secret ownership and lifecycle have not been adapted for Podman, rootless Docker, Kubernetes, or
other orchestrators.

## Security model

This profile is for a single-tenant VM, trusted repositories, and trusted operators. Coding agents
execute repository-controlled commands. A malicious repository, dependency, or prompt can access
the worker's repository credential and coding-agent credentials. Use a dedicated worker and
dedicated credentials for each trust domain.

The stack enforces these boundaries:

| Asset | Mounted into `symphony` | Mounted into each worker |
|---|---:|---:|
| GitHub Project tracker token | Yes | No |
| Worker repository token | No | Yes |
| Worker SSH private key | Yes | No |
| Worker SSH authorized key | No | Yes |
| Worker SSH host public key | Yes | No |
| Worker SSH host private key | No | Yes |
| Claude/Codex authentication | No | Yes, profile-specific |
| Workspace volume | No | Yes, profile-specific |
| Docker socket | No | No |

Symphony exposes only a session-scoped tracker MCP token to a running agent. The long-lived Project
token remains in the orchestrator. The generated SSH host public key pins both worker endpoints;
Symphony
does not trust a fresh network keyscan at each restart. Compose publishes the dashboard to host
`127.0.0.1` by default; do not publish it to a public interface without an authenticated TLS reverse
proxy or a private overlay network.

The HTTP server binds `0.0.0.0` *inside* the orchestrator container so Docker's host port forwarding
can reach it. The worker shares the application bridge and can therefore reach the unauthenticated
state, issue, and refresh endpoints directly. Those endpoints do not expose the tracker token, but
the dashboard is not a security boundary from the worker. Treat the worker as trusted and do not
put secrets in issue content or observable runtime metadata.

### Plaintext-at-rest limitation

Plain Docker Compose `secrets` are read-only file mounts, not Docker Swarm's encrypted secret
store. Their source files under `/etc/symphony/secrets` remain plaintext on the VM. Claude and
Codex login caches in Docker named volumes are also plaintext files on Linux. Root and anyone with
control of the Docker daemon can read them.

Use an encrypted VM disk, restrict root and `docker` group membership, and prefer a secret manager
that materializes credentials only during provisioning. For a stronger design, use a platform
secret store with workload identity instead of host files. Do not put secrets in image layers,
Compose YAML, `deployment.env`, `WORKFLOW.md`, command arguments, shell history, tickets, or logs.

## Prerequisites

Prepare a Linux VM with:

- `amd64` or `arm64` architecture matching a published image.
- Rootful Docker Engine without daemon user-namespace remapping, plus the Docker Compose v2 plugin.
- systemd for the provided boot unit.
- Git, curl, and an OpenSSH client (`ssh-keygen` is used during secret initialization).
- Outbound DNS and HTTPS access to the image registry, GitHub, and the selected model provider.
- Accurate time synchronization; OAuth and TLS validation depend on it.
- SSH access for administration. No inbound application port is required by default.
- An encrypted persistent disk for Docker volumes and `/etc/symphony`.

Confirm the runtime before copying credentials:

```bash
docker version
docker compose version
docker compose up --help | grep -- --wait
systemctl is-active docker
uname -m
```

Do not add the routine administration account to the `docker` group merely for convenience. Docker
daemon access is effectively root access; use `sudo` for the commands in this runbook.

## Credentials and permissions

Create separate GitHub credentials. Never reuse the tracker token as the worker token.

The tracker credential is used only by `symphony` and should be limited to:

- The target organization and Project, with Projects read/write access.
- The target repository, with Issues read/write and Metadata read access.

The worker credential is used only by the two worker services for HTTPS Git and pull-request operations. It
should be a fine-grained token limited to the target repository, with Contents read/write, Pull
requests read/write, and Metadata read access. Add other repository permissions only when a real
workflow requires them. The worker does not need organization Projects permission; tracker comments
and status changes go through Symphony's session-scoped tools. Repository workflows must reuse the
normalized `tracker_get_issue` payload for issue routing instead of granting the worker a second
issue-read path.

For unattended use, prefer short-lived GitHub App installation tokens when an installation-token
credential helper is available. The initial Compose profile also supports dedicated fine-grained
personal access tokens.

## Install pinned deployment artifacts

Keep the deployment checkout root-owned. Select a reviewed release tag or commit rather than a
moving branch:

```bash
sudo install -d -o root -g root -m 0755 /opt/symphony
sudo git clone https://github.com/afarnham/symphony.git /opt/symphony
sudo git -C /opt/symphony checkout --detach REPLACE_WITH_RELEASE_TAG_OR_COMMIT
```

If `/opt/symphony` already contains a checkout, fetch and detach at the reviewed revision instead:

```bash
sudo git -C /opt/symphony fetch --tags origin
sudo git -C /opt/symphony checkout --detach REPLACE_WITH_RELEASE_TAG_OR_COMMIT
```

Production should run images by immutable digest. Copy the non-secret example and replace both
placeholder digests with the digests published for that release:

```bash
sudo install -d -o root -g root -m 0750 /etc/symphony
sudo install -o root -g root -m 0644 \
  /opt/symphony/deploy/examples/deployment.env.example \
  /etc/symphony/deployment.env
sudoedit /etc/symphony/deployment.env
```

The production `compose.yaml` is image-only and its built-in references use an intentionally
unpullable zero digest. A deployment cannot silently fall back to a mutable `latest` tag or a local
source build when `deployment.env` is missing or incomplete.

Use the multi-architecture image-index digest for each release, not an architecture-specific child
manifest. Docker then selects `linux/amd64` or `linux/arm64` for the VM while the deployment remains
pinned to one reviewed release. Inspect a published index when Buildx is available:

```bash
sudo docker buildx imagetools inspect IMAGE@sha256:RELEASE_INDEX_DIGEST
```

Prefer publicly readable release images. If the registry is private, use a dedicated read-only
pull credential or the VM platform's workload identity; do not reuse either runtime GitHub token.
Pass a static credential over standard input, never as a command argument:

```bash
registry-secret-command-that-prints-one-value | \
  sudo docker login REGISTRY --username READ_ONLY_PULL_IDENTITY --password-stdin
```

Without a Docker credential helper, `docker login` stores recoverable credential material in
root's Docker configuration. Protect and rotate that state as another deployment credential.

Then pull exactly those images:

```bash
cd /opt/symphony
sudo docker compose --env-file /etc/symphony/deployment.env pull
```

Production uses `pull_policy: missing`: explicit install and upgrade steps pull the selected digest,
while a routine reboot can start from the already verified local cache during a registry outage.
Because the reference is digest-pinned, cache reuse cannot silently select a different image.

The environment file contains no secrets, but still keep it root-owned. Record its image digests
and the `SYMPHONY_DIVE_CODEX_MODEL` and `SYMPHONY_DIVE_CLAUDE_MODEL` values in configuration
management with the change ticket so rollback does not depend on a mutable registry tag. These
settings are passed only to worker containers and into their SSH agent sessions. They select the
bounded dining-graph research model that matches the ticket's executor. A new deployment defaults
to `gpt-5.6` for Codex and `sonnet` for Claude;
change either value in `deployment.env` without editing the workflow prompt. If the project
publishes signatures or provenance, verify them before the pull.

For development only, the checked-in build override can build from the local checkout:

```bash
docker compose -f compose.yaml -f compose.build.yaml build
```

Do not pass `compose.build.yaml` to systemd or a production command. Do not treat a locally built,
unrecorded image as a reproducible production release. The Dockerfiles pin top-level base-image
digests and agent CLI versions, but `apt`, npm/Hex transitive artifacts, and other upstream build
inputs can still change or disappear. Production promotion should use the published digest,
retained provenance, and any available SBOM rather than rebuilding an old source revision and
assuming byte-for-byte equivalence.

A local `up` still requires a complete non-secret environment file plus safe external workflow and
secret source files; the build override does not weaken the runtime secret contract.

## Install the administration utility

Install the checked-in utility and initialize the root-only secrets directory:

```bash
sudo install -o root -g root -m 0755 \
  /opt/symphony/deploy/symphony-admin /usr/local/sbin/symphony-admin
sudo symphony-admin secrets init
```

`secrets init` creates root-owned `/etc/symphony/secrets` with mode `0700` and generates two
Ed25519 keypairs if they are not already present: a client pair for orchestrator access and a host
pair that pins the worker's SSH identity. It does not overwrite an existing pair.

Secret source files are owned by UID/GID `10001:10001` with mode `0400`, matching the fixed
unprivileged user in both images. Local Docker Compose implements file secrets as bind mounts and
does not remap ownership, so root-owned `0600` files would be unreadable in these containers. The
root-owned `0700` parent directory prevents a host process running as UID 10001 from traversing to
the source files, while the Docker daemon can mount each exact file into its intended container.
The checked-in deployment fixes this identity at `10001:10001`. Changing it requires one reviewed
change across the images, volume initializer, SSH tmpfs ownership, and the admin utility; changing
only file ownership will break startup. `SYMPHONY_SECRET_UID` and `SYMPHONY_SECRET_GID` control the
admin utility and its systemd preflight, and the non-secret values are recorded in `deployment.env`.
Check metadata without printing values:

```bash
sudo symphony-admin secrets list
sudo find /etc/symphony/secrets -maxdepth 1 -printf '%M %u:%g %f\n'
```

This ownership scheme assumes standard rootful Docker without rootless or daemon-level user
namespace remapping. File-backed Compose secrets cannot remap UID/mode. A rootless or
`userns-remap` deployment therefore needs a separately designed secret-injection mechanism; do not
make the files broadly readable as a workaround. The two images intentionally reuse numeric UID
10001, but their secret and data mounts remain disjoint.

On a host with enforcing SELinux or another mandatory-access-control policy, apply the
distribution's narrowly scoped container-read labels/policy to the exact mounted files if required.
Do not disable the policy or recursively relabel `/etc`. A `permission denied` error with correct
numeric ownership should be investigated at this layer before permissions are relaxed.

## Provision runtime secrets

The utility reads secret values with terminal echo disabled and writes them atomically. Run these
on the VM and paste each value when prompted:

```bash
sudo symphony-admin secrets set github_project_token
sudo symphony-admin secrets set github_worker_token
sudo symphony-admin secrets verify
```

`secrets verify` checks presence and file metadata, not remote API authority. It never prints the
values. Avoid commands such as `symphony-admin secrets set NAME VALUE`: a value in an argument is
visible in shell history and process listings, and the utility intentionally does not support that
form.

An external secret manager can provide a value through standard input:

```bash
secret-manager-command-that-prints-one-value | \
  sudo symphony-admin secrets set github_project_token --stdin
```

Protect the pipe from tracing and command logging, and make sure the source command emits only the
secret. Do not assign the value to a shell variable first.

Compose mounts these sources selectively:

- `github_project_token` and `worker_ssh_private_key` into `symphony`.
- `worker_ssh_host_public_key` into `symphony` for strict host verification.
- `github_worker_token`, `worker_ssh_authorized_key`, and `worker_ssh_host_private_key` into both
  workers.
- `afarnham_*` model-provider secrets only into `agent-worker-afarnham`, and `karbas_*` secrets
  only into `agent-worker-karbas`.

The workflow refers to the tracker credential by file URI:

```yaml
tracker:
  provider:
    token: file:///run/secrets/github_project_token
```

This keeps the value out of both the workflow and the container's declared environment.

## Configure a workflow

For the Provenance Map deployment, install the checked-in canonical workflow:

```bash
sudo install -o root -g root -m 0644 \
  /opt/symphony/deploy/workflows/app-tastemap.WORKFLOW.md \
  /etc/symphony/WORKFLOW.md
sudoedit /etc/symphony/WORKFLOW.md
```

The workflow uses GitHub Project 2 and repository `GHW-Consulting/app-tastemap`. Add a Project
single-select field named `Executor` with exactly `Claude` and `Codex` options. Its Status flow is:

| Status | Meaning |
|---|---|
| `Backlog` | Not eligible; Symphony ignores it. |
| `Ready` | Eligible on the next poll. No routing label is required. |
| `In Progress` | Claimed and running. |
| `Blocked` | Agent needs human intervention; move it back to `Ready` after resolution. |
| `In Review` | Generic implementation complete and handed to a human. Wine graph runs do not stop here between bands. |
| `Done` / `Cancelled` | Terminal. |

The app-tastemap workflow installs repository dependencies and then requires every claimed ticket
to pass through the repository's neutral `pnpm dive-graph -- route-ticket` command before
exploration or edits. It serializes the normalized `tracker_get_issue` output to a temporary ticket
file, avoiding a second GitHub issue read with the narrower worker credential. Generic tickets
follow the ordinary `In Progress` to `In Review` lifecycle. Tickets routed to the wine- or
dining-dive graph remain `In Progress` across their sequential band PRs and move directly to `Done`
only after terminal graph closeout. A router error or malformed labeled dive ticket fails closed
through the normal `Blocked` flow; it never falls through to generic implementation.

Do not install or restart Symphony with this workflow until app-tastemap's `main` accepts the
normalized tracker payload in `dive-graph -- route-ticket --ticket-file`. The original wine ticket
and graph router changes landed in app-tastemap PRs #587 and #591; the neutral wine/dining router
and dining runtime landed in PR #608. The mandatory router is deliberately a deployment dependency:
without matching app-side support, claimed tickets block before any repository work.

The workflow maps `afarnham` to a Codex-default worker and `karbas` to a Claude-default worker. A
worker owner can assign and move their own item to `Ready`. The workflow also lists `thor-claw` as
a trusted release actor: it can move an item to `Ready` with its own token, and Symphony routes the
item to the only assigned configured profile. The governor does not need the worker owner's token.
Leaving Executor blank uses the selected profile's default; setting it overrides the backend
without changing whose credentials run the ticket. Do not put GitHub credentials in the clone
URL. The worker entrypoint supplies the shared repository credential to Git's credential helper.

To add another governor, add its normalized GitHub login under
`agent.routing.trusted_release_actors`, install the changed workflow, and reload Symphony. Give the
governor only the issue and Project permissions needed to assign a worker owner and move Status.
Each released issue must have exactly one configured profile among its assignees; otherwise
Symphony leaves it in `Ready`. Follow the complete checklist in
[`assignee-executor-routing.md`](assignee-executor-routing.md#add-a-trusted-release-actor).

The workflow sets Claude's `permission_mode` to `bypassPermissions` for unattended work. That is an
explicit trust decision: the agent can run commands and change files without an interactive
approval prompt. Use it only with the dedicated worker, a trusted repository, and the narrowly
scoped worker credential. A more restrictive mode may pause unattended work for approval.

The workflow also sets Codex's approval policy to `never`, its thread sandbox to
`danger-full-access`, and its turn policy to `dangerFullAccess`. The `never` policy lets the
unattended app-server approve command requests instead of stopping for input. Codex's normal
`workspace-write` sandbox creates an inner Linux namespace, which is unavailable inside the
capability-free worker container. In this deployment, the worker container is the operating-system
sandbox: it runs as an unprivileged user with a read-only root filesystem, no Linux capabilities,
no Docker socket, and only its profile-specific workspace, cache, authentication, and narrowly
scoped repository credential mounted. Keep Codex's normal approval and `workspace-write` defaults
when Symphony runs outside this isolated container profile.

The workflow is mounted read-only into the orchestrator. The workspace root `/workspaces` is on the
selected profile's worker volume. The configured SSH destinations are
`worker@agent-worker-afarnham` and `worker@agent-worker-karbas`; neither is exposed on a host port.

The workflow's `server.host: 0.0.0.0` is required inside a container: a server bound to container
loopback cannot receive Docker's published-port traffic. Exposure is still restricted on the VM by
`SYMPHONY_BIND_ADDRESS=127.0.0.1` in `deployment.env`.

Validate Compose interpolation and the workflow mount before starting:

```bash
cd /opt/symphony
sudo docker compose --env-file /etc/symphony/deployment.env config --quiet
sudo symphony-admin secrets verify
```

`docker compose config` shows secret source paths and mount names, not secret contents. Still treat
its output as operational information and do not attach it wholesale to public tickets.

## Authenticate Claude

Choose one Claude authentication path. Do not configure both unless you understand Claude's
[credential precedence](https://code.claude.com/docs/en/authentication).

### Unattended subscription token

On a trusted interactive machine, run:

```bash
claude setup-token
```

The command prints a long-lived subscription OAuth token but does not save it. On the VM, store it
using hidden terminal input:

```bash
sudo symphony-admin secrets set afarnham_claude_oauth_token
sudo symphony-admin secrets set karbas_claude_oauth_token
```

Compose mounts the file only into the worker. The Claude launcher reads it and exports
`CLAUDE_CODE_OAUTH_TOKEN` only into the exec'd Claude process at runtime; it is not declared in the
Compose environment. This token uses a Claude subscription rather than Console API billing. Treat
it like a password and revoke it when the VM is retired or compromised.

### Persistent interactive login

If a profile's Claude token is unset, authenticate that profile's disposable worker container:

```bash
sudo symphony-admin workers auth afarnham claude
sudo symphony-admin workers auth karbas claude
```

Open the displayed URL on your normal computer and paste the returned code into the SSH terminal
when prompted. Each temporary container shares only that profile's Claude authentication volume,
so its Linux credential file survives replacement without becoming visible to the other profile.

Check the result without displaying tokens:

```bash
sudo symphony-admin workers status afarnham
sudo symphony-admin workers status karbas
```

The status command checks both installed backends and exits non-zero if either is unauthenticated.
An unused backend may therefore report `not logged in`; the backend selected by `agent.backend` must
report valid authentication.

If both a saved login and the profile's Claude OAuth token exist, the explicit token takes
precedence. Remove or rotate the unused method during a maintenance window rather than assuming
which account is active.

## Authenticate Codex

Choose between ChatGPT subscription authentication and OpenAI API billing. See the official
[Codex authentication guide](https://developers.openai.com/codex/auth) for the policy and billing
differences.

### ChatGPT subscription with device authentication

Run the headless device flow:

```bash
sudo symphony-admin workers auth afarnham codex
sudo symphony-admin workers auth karbas codex
```

Open the displayed URL and enter the one-time code. Device authentication must be enabled in the
ChatGPT account's security settings or by the workspace administrator. The disposable container
shares only that profile's Codex authentication volume. Codex is configured for file-backed
credential storage under `/home/worker/.codex`; treat `auth.json` as a password.

### OpenAI API billing

API-key authentication uses the OpenAI Platform account and standard API usage billing, not the
included ChatGPT plan allowance. Store the key without putting it in an environment file:

```bash
sudo symphony-admin secrets set afarnham_openai_api_key
sudo symphony-admin secrets set karbas_openai_api_key
```

The selected profile's worker consumes `/run/secrets/openai_api_key` by piping it to
`codex login --with-api-key` at
startup with command output suppressed. The key is not placed in Compose environment or command
arguments. Do not also rely on a persisted ChatGPT login: API-key login updates that profile's
Codex authentication volume. Choose one billing identity and, after removing an API key, run the device
login again before expecting subscription authentication. Verify the active method after startup:

```bash
sudo symphony-admin workers status afarnham
sudo symphony-admin workers status karbas
```

For trusted enterprise automation, a managed Codex access token may be preferable when the
workspace enables it. This baseline utility supports device authentication and Platform API keys;
add any enterprise token as a separately reviewed secret type rather than reusing another slot.

## Resource and disk controls

The production example applies CPU, memory, and PID ceilings to both services. Keep those settings
in `deployment.env` so capacity changes remain non-secret and reviewable. A limit that is too low
can terminate an agent during dependency installation or validation, so change limits deliberately
and repeat the smoke test.

| Setting | Checked-in value | Service |
|---|---:|---|
| `SYMPHONY_PIDS_LIMIT` | `256` | Orchestrator |
| `SYMPHONY_MEM_LIMIT` | `2g` | Orchestrator |
| `SYMPHONY_CPUS` | `2.0` | Orchestrator |
| `SYMPHONY_WORKER_PIDS_LIMIT` | `512` | Worker |
| `SYMPHONY_WORKER_MEM_LIMIT` | `8g` | Worker |
| `SYMPHONY_WORKER_CPUS` | `4.0` | Worker |
| `SYMPHONY_TMPFS_SIZE` | `256m` | Orchestrator `/tmp` |
| `SYMPHONY_WORKER_TMPFS_SIZE` | `1g` | Worker `/tmp` |
| `SYMPHONY_LOG_MAX_SIZE` | `10m` | Per-container log segment |
| `SYMPHONY_LOG_MAX_FILES` | `5` | Retained segments per container |

The read-only worker root filesystem uses named volumes for agent authentication, workspaces, and
profile-specific package-manager cache and local-state volumes. Ephemeral SSH files
live in a bounded tmpfs; the stable host identity comes from the provisioned secret pair. Cache
volumes are disposable; authentication volumes are not. The workspace and log volumes can grow
without an application-level quota, and container stdout also consumes host storage. Monitor the
Docker data root and underlying filesystem, configure host disk alerts or filesystem quotas, and
retain only the logs and workspaces required by policy. Compose bounds stdout/stderr with Docker's
`local` log driver and the two log settings above. This does not bound Symphony's separate
`symphony-logs` volume or the workspace volume.

The orchestrator and worker `/tmp` filesystems are memory-backed and reset with their containers.
Their checked-in ceilings are `256m` and `1g`; tmpfs use also competes with each container's memory
limit. Increase a tmpfs limit only alongside the corresponding memory limit when a verified build
needs more temporary space. Persistent work belongs in `/workspaces`, not `/tmp`.

The one-shot `volume-init` service makes all profile-specific writable volumes owned by UID/GID
10001 before the unprivileged services start. It receives no secrets or network and drops every
capability except `CHOWN`. A non-zero exit prevents the long-running services from starting.

Do not solve capacity pressure by mounting the host root, a broad home directory, or the Docker
socket into the worker. Add a narrowly scoped volume or increase a reviewed resource limit.

## Install and start the systemd unit

Install the checked-in unit after configuration and authentication are complete:

```bash
sudo install -o root -g root -m 0644 \
  /opt/symphony/deploy/systemd/symphony.service \
  /etc/systemd/system/symphony.service
sudo systemctl daemon-reload
sudo systemctl enable --now symphony.service
```

The unit is `Type=oneshot` with `RemainAfterExit=yes`. Path conditions require the Compose file,
deployment environment, and workflow; its preflight rejects missing, empty, or unsafe required
secret files before Compose runs. `docker compose up --wait` verifies the container health checks
before systemd marks startup successful. Container restart policies own long-running process
recovery; systemd owns boot ordering and explicit start/stop operations. The unit stops containers
without deleting containers, networks, volumes, or authentication state. Its post-stop cleanup also
runs after a failed `compose up --wait`, preventing restart-policy containers from continuing behind
a failed systemd unit.

Some distributions install Docker outside `/usr/bin/docker`. If `command -v docker` reports a
different absolute path, update all `Exec...` lines in the installed unit before enabling it.

## Health and smoke test

Check every layer:

```bash
sudo systemctl status symphony.service --no-pager
cd /opt/symphony
sudo docker compose --env-file /etc/symphony/deployment.env ps
curl --fail --silent --show-error http://127.0.0.1:4000/api/v1/state
sudo symphony-admin workers status afarnham
sudo symphony-admin workers status karbas
sudo docker compose --env-file /etc/symphony/deployment.env exec symphony \
  ssh -F /tmp/symphony-ssh/config agent-worker-afarnham true
sudo docker compose --env-file /etc/symphony/deployment.env exec symphony \
  ssh -F /tmp/symphony-ssh/config agent-worker-karbas true
```

If the dashboard is needed from an administrator workstation, tunnel it instead of opening the VM
firewall:

```bash
ssh -L 4000:127.0.0.1:4000 admin@symphony-vm
```

Then open `http://127.0.0.1:4000` locally.

After those app-tastemap prerequisites are deployed, run an end-to-end smoke test with low-risk
issues in the configured repository:

1. Add the issue to Project 2 in `Backlog`; confirm Symphony does not claim it.
2. Move only its Status to `Ready`; do not add a routing label.
3. Assign it to `afarnham`, leave Executor blank, and have `afarnham` move it to `Ready`. Confirm
   Codex starts on `agent-worker-afarnham`.
4. Repeat with an issue assigned and readied by `karbas`; confirm Claude starts on
   `agent-worker-karbas`. Then set Executor to the non-default backend and confirm only the backend,
   not the worker profile, changes.
5. Assign an issue only to `afarnham`, then have `thor-claw` move it to `Ready` with its own token.
   Confirm the route records `ready_actor=thor-claw` and `profile=afarnham`. Repeat with zero and
   two configured-profile assignees and confirm both remain in `Ready` with routing errors.
6. Confirm the agent can clone, create a branch, push, and open a pull request using only the worker
   credential.
7. Confirm tracker comments and Status transitions succeed through the session-scoped tools.
8. Use a generic issue and confirm successful work moves to `In Review`.
9. Use a dummy `wine dive` issue in the new ticket format. Confirm the router comments its durable
   run receipt, the graph starts or resumes that run, and the Project item remains `In Progress`
   rather than moving to `In Review` after an intermediate band.
10. Use a malformed `wine dive` issue. Confirm routing stops before generic implementation and the
   item moves to `Blocked`; then correct the ticket and move it back to `Ready` to verify resume.
11. For the generic blocker path, use a test requiring unavailable human input. Confirm it moves to
   `Blocked`, then resolve the input and move it back to `Ready`.
12. Inspect logs for accidental GitHub, Claude, Codex, SSH, or MCP token output before accepting the
   deployment.

Do not retire the prior deployment until this smoke test passes on the VM.

## Logs and diagnostics

The systemd journal contains Compose lifecycle output:

```bash
sudo journalctl -u symphony.service --since today
```

Application and worker output is available through Compose:

```bash
cd /opt/symphony
sudo docker compose --env-file /etc/symphony/deployment.env logs --tail 200 symphony
sudo docker compose --env-file /etc/symphony/deployment.env logs --tail 200 agent-worker-afarnham agent-worker-karbas
sudo docker compose --env-file /etc/symphony/deployment.env logs --follow
```

Symphony's persistent application logs are under `/var/log/symphony` in the `symphony` container
and the `symphony-logs` named volume. Logs can contain issue bodies, repository paths, tool names,
and model output even when known secret formats are redacted. Restrict access and retention
accordingly.

Useful failure isolation order:

1. `symphony-admin secrets verify` for missing or unsafe files.
2. `docker compose config --quiet` for interpolation and mount errors.
3. `docker compose ps` for the failing health check.
4. Service logs for workflow validation, GitHub preflight, SSH, or agent-auth failures.
5. `symphony-admin workers status <profile>` inside each production worker and auth volume.

Do not enable shell tracing (`set -x`) while inspecting entrypoints or authentication.

## Upgrade

Avoid replacing the worker while an agent is running. Stop moving tickets to `Ready`, wait for the
dashboard to show no active agents, and record the current checkout revision and both current image
digests.

1. Fetch and inspect the target release.
2. Pull and verify its immutable image digests.
3. Update `/etc/symphony/deployment.env` with those digests.
4. Detach `/opt/symphony` at the matching reviewed release revision.
5. Reinstall `symphony-admin` and the systemd unit if either changed.
6. Validate and restart:

```bash
cd /opt/symphony
sudo symphony-admin secrets verify
sudo docker compose --env-file /etc/symphony/deployment.env config --quiet
sudo docker compose --env-file /etc/symphony/deployment.env pull
sudo systemctl daemon-reload
sudo systemctl restart symphony.service
```

Repeat the health checks and a bounded smoke test. Never use `docker compose down --volumes` during
an upgrade.

### Rollback

Restore the previous deployment checkout revision and the previous digest-pinned
`deployment.env`, pull those digests, and restart the unit. Named volumes are intentionally retained.
If a release changes a persistent format incompatibly, follow that release's migration and rollback
notes before reusing the volumes; an image rollback alone cannot undo a data migration.

## Rotate or revoke credentials

For a normal GitHub or provider credential rotation:

1. Create the replacement with the same or narrower scope.
2. Wait for active agents to drain.
3. Run `symphony-admin secrets set NAME` to atomically replace the source file.
4. Restart `symphony.service`; Compose secrets are read when containers are created, so changing a
   host source file is not sufficient on its own.
5. Run health and permission checks.
6. Revoke the previous credential at its issuer.

If compromise is suspected, revoke first, accept interrupted work, then replace credentials and
reconcile affected Project items, branches, and pull requests.

`secrets init` deliberately does not overwrite either worker SSH pair. Rotate them in a maintenance
window by preserving the old pairs in encrypted offline storage, removing both sides of the client
pair (`worker_ssh_private_key` and `worker_ssh_authorized_key`) and both sides of the host pair
(`worker_ssh_host_private_key` and `worker_ssh_host_public_key`), rerunning `secrets init`, and
recreating both containers. Verify the new SSH connection before destroying the old encrypted
recovery copy. Never replace only one side of a pair.

After rotating or revoking Claude/Codex subscription credentials, clear the corresponding saved
login if it is no longer authorized. A stale named-volume login can otherwise become active later
when an explicit runtime secret is removed.

The optional secret source files must continue to exist because Compose mounts them even when they
are empty. To switch away from an explicit model credential, revoke it at the provider first, drain
active agents, empty its protected source file, and recreate the stack:

```bash
sudo truncate --size 0 /etc/symphony/secrets/afarnham_claude_oauth_token
sudo truncate --size 0 /etc/symphony/secrets/afarnham_openai_api_key
sudo systemctl restart symphony.service
```

Replace `afarnham` with `karbas` when rotating the other profile. Run only the line for the
credential being removed. If persistent login state must also be cleared,
use a disposable worker container after emptying the explicit secret:

```bash
cd /opt/symphony
sudo docker compose --env-file /etc/symphony/deployment.env run --rm --no-deps \
  agent-worker-afarnham claude auth logout
sudo docker compose --env-file /etc/symphony/deployment.env run --rm --no-deps \
  agent-worker-afarnham codex logout
```

These logout commands remove the saved session from the named authentication volume. Run only the
provider logout that is intended.

## Backup boundaries

Back up these non-secret recovery inputs:

- The exact Symphony release revision and both image digests.
- `/etc/symphony/deployment.env`.
- `/etc/symphony/WORKFLOW.md`.
- Any reviewed systemd override.

Treat these as credentials, not ordinary backups:

- `/etc/symphony/secrets`.
- Every profile-specific Claude and Codex authentication volume.
- Worker Git credential material.
- Root's container-registry login state when private images are used.

The safest disaster-recovery policy is to reissue GitHub/provider credentials and re-authenticate
on a replacement VM. If credential state must be backed up, use a separately encrypted archive
with audited access and a different key-management boundary from the VM disk.

Workspaces are disposable execution state, not the source of truth. Do not back up
`symphony-workspaces` as a substitute for pushed branches and pull requests. The log volume is
optional operational evidence and may contain sensitive repository or issue content; give it an
explicit retention policy.

## Disaster recovery

On a replacement VM:

1. Install the recorded Symphony revision and digest-pinned images.
2. Restore only the non-secret environment, workflow, and unit configuration.
3. Run `symphony-admin secrets init` to generate a new SSH pair.
4. Issue fresh GitHub credentials and re-authenticate Claude/Codex.
5. Inspect every Project item left in `In Progress`. Symphony's in-memory claims and local
   workspaces do not survive; the external branch, pull request, comments, and Project Status do.
6. Reconcile each item deliberately. Move it to `In Review` if work already completed, `Blocked`
   if human action is required, or `Ready` for a clean rerun.
7. Start the service and run the full health and smoke sequence.

Do not blindly resume all `In Progress` items: a prior worker may already have pushed or published
side effects before the VM failed.

## Uninstall

First stop new work, drain active agents, revoke all GitHub and provider credentials, and disable
the service:

```bash
sudo systemctl disable --now symphony.service
cd /opt/symphony
sudo docker compose --env-file /etc/symphony/deployment.env down
```

The `down` command above retains named volumes. Preserve anything required by the backup policy,
then explicitly remove volumes only when their loss is intended:

```bash
sudo docker compose --env-file /etc/symphony/deployment.env down --volumes
```

Finally remove the unit, utility, deployment checkout, and `/etc/symphony` according to the host's
change-control process. Revoke credentials even if files were deleted; secure deletion is not
reliable on all virtual and solid-state disks. Decommission or cryptographically erase the VM disk
when appropriate.

## References

- [Docker Compose secrets](https://docs.docker.com/compose/how-tos/use-secrets/)
- [Docker post-install security warning](https://docs.docker.com/engine/install/linux-postinstall/)
- [Claude Code authentication](https://code.claude.com/docs/en/authentication)
- [Claude Code CLI reference](https://code.claude.com/docs/en/cli-usage)
- [Codex authentication](https://developers.openai.com/codex/auth)
- [GitHub fine-grained personal access
  tokens](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)
