# Symphony GitHub Projects and Claude Integration

## Status

Accepted implementation specification.

## Target

This specification targets the Elixir implementation in
[`afarnham/symphony`](https://github.com/afarnham/symphony), forked
from [`openai/symphony`](https://github.com/openai/symphony), based on the
architecture present at commit
`f8e8b8a670c799f6e0ade7a8c25c4bf4a4a56ec7` or a compatible later revision.

The implementation is a superset of Symphony's current behavior. Existing
Codex workflows remain valid and continue to use Codex unless a different
backend is selected explicitly.

## Summary

Add two integrated capabilities:

1. A GitHub Projects tracker adapter that treats a project's `Status`
   single-select field as the authoritative workflow state. Moving an item
   from `Backlog` to `Ready` makes it eligible for dispatch. No GitHub label is
   required or mutated to represent workflow state.
2. A first-class Claude Code backend behind the same runtime contract as the
   Codex backend. Claude and Codex receive the same prompt, workspace,
   tracker tools, lifecycle handling, SSH support, observability, retry
   semantics, and secret isolation.

The work also introduces the shared abstractions needed to keep backend and
tracker behavior provider-neutral:

- `AgentBackend` owns agent-session startup, turns, continuation, cancellation,
  and shutdown.
- `AgentEvent` is the normalized event stream consumed by the orchestrator and
  observability layers.
- `TrackerToolBroker` owns tracker-tool schemas, authorization, execution, and
  result normalization.
- The Codex backend binds broker tools through Codex dynamic tools.
- The Claude backend binds the same broker tools through MCP.

## Goals

- Make GitHub Project status changes the dispatch control surface.
- Ignore project items in `Backlog` without requiring a label.
- Move a claimed `Ready` item to `In Progress` before starting its agent.
- Continue or recover work whose item remains in an active project state.
- Preserve existing terminal-state cancellation and workspace-cleanup rules.
- Make Claude a peer backend, not a reduced shell-command fallback.
- Preserve tracker credentials on the orchestrator host.
- Support Claude and Codex on local and SSH worker hosts.
- Present backend-neutral sessions, activity, usage, failures, and blocked
  states in logs, APIs, and the dashboard.
- Keep existing Codex configuration and workflows backward compatible.

## Non-goals

- GitHub labels will not be used as workflow-state aliases.
- The adapter will not infer state from whether an issue is open or closed when
  a project status is available.
- One daemon will not coordinate more than one GitHub Project.
- Multiple daemons targeting the same project are not supported as an
  exactly-once dispatch topology.
- Draft project items and pull-request project items will not be dispatched.
- Project items belonging to repositories other than the configured repository
  will not be dispatched.
- This change will not add automatic pull-request merging.
- This change will not remove or deprecate Codex app-server support.
- This change will not expose GitHub or other tracker credentials directly to
  agent subprocesses or SSH worker hosts.

## Design Decisions

### GitHub Projects is a separate tracker kind

Add `github_project` rather than overloading the existing `github` adapter.
The existing adapter retains native issue `open`/`closed` semantics. The new
adapter owns project-item identity, project field discovery, project status,
and project field mutations.

### Project status is authoritative

The configured `Status` field is the sole workflow-state source for project
items. Issue labels remain metadata and may still be used by
`tracker.required_labels`, but labels do not select or transition workflow
state.

### The orchestrator owns the initial claim transition

Before an agent starts, the orchestrator moves the item from a configured
ready state to `working_state`. If the transition or confirmation read fails,
the agent is not started.

Completion transitions remain explicit agent workflow actions through the
provider-neutral tracker tool. A normally completed model turn does not by
itself prove that the issue is ready for review.

### Backend-specific protocols end at `AgentBackend`

The orchestrator must not understand Codex JSON-RPC methods, Claude
stream-JSON records, CLI flags, or backend-specific session identifiers.
Each backend converts its native protocol into `AgentEvent` and
`AgentTurnResult` values.

### Tracker tools are backend-neutral

Tracker tool definitions and execution move out of the Codex app-server
integration. The same tool names, JSON schemas, authorization rules, and
result envelopes are exposed to every backend.

### Remote Claude tools use an authenticated reverse tunnel

For SSH-hosted Claude sessions, the orchestrator exposes a loopback-only,
session-scoped MCP endpoint and creates an SSH reverse tunnel to it. Claude
connects to the remote loopback end of that tunnel. Only a short-lived session
token crosses to the worker; the underlying tracker token stays on the
orchestrator.

## Configuration Contract

### GitHub Project tracker

```yaml
tracker:
  kind: github_project
  provider:
    owner: GHW-Consulting
    owner_type: organization
    project_number: 123
    repository: GHW-Consulting/app-tastemap
    status_field: Status
    token: $GITHUB_TOKEN
  active_states:
    - Ready
    - In Progress
  terminal_states:
    - Done
    - Cancelled
  working_state: In Progress
  blocked_state: Blocked
  completion_state: In Review
  required_labels: []
```

Provider fields:

| Field | Required | Contract |
|---|---:|---|
| `owner` | Yes | GitHub organization or user login that owns the project. |
| `owner_type` | Yes | `organization` or `user`. Determines the Projects API route. |
| `project_number` | Yes | Project number visible in the GitHub Project URL. |
| `repository` | Yes | Exact `owner/repo` whose issues are dispatchable. |
| `status_field` | No | Project single-select field name. Defaults to `Status`. |
| `token` | No | Host-side token or `$ENV_NAME`; defaults to `GITHUB_TOKEN`. |
| `api_url` | No | GitHub API root. Defaults to `https://api.github.com`. |

Tracker fields:

| Field | Required | Contract |
|---|---:|---|
| `active_states` | Yes | Project status options in which claimed work may run or resume. |
| `terminal_states` | Yes | Project status options that stop work and permit cleanup. |
| `working_state` | Yes | Status assigned by the orchestrator before agent startup. Must be active. |
| `blocked_state` | Yes | Non-active, non-terminal status assigned when an agent needs human intervention. |
| `completion_state` | No | Status available to the tracker transition tool for review handoff. |
| `required_labels` | No | Additional issue-label routing constraint; never a state proxy. |

Startup and workflow reload validation must confirm that:

- The project exists and is readable.
- The configured repository exists and is readable.
- `status_field` resolves to exactly one single-select project field.
- Every configured active, terminal, working, blocked, and completion state resolves to
  exactly one option on that field, case-insensitively.
- `working_state` is included in `active_states`.
- Active and terminal state sets do not overlap.
- `blocked_state` is neither active nor terminal, and differs from `completion_state`.
- The token can read project items and repository issues.
- Project-item listing is included in startup preflight so item-read authority
  is confirmed before polling begins.
- GitHub exposes no non-mutating write-capability probe for this endpoint. The
  initial confirmed Ready-to-working-state claim is therefore the write check,
  and it completes before workspace creation or agent startup.

The resolved project ID, status field ID, and option IDs are cached in the
loaded configuration snapshot. Existing runs retain their dispatch-time
snapshot across a workflow reload; new runs use the new snapshot.

### Agent backend selection

```yaml
agent:
  backend: claude
  max_concurrent_agents: 3
  max_turns: 20
  max_retry_backoff_ms: 300000

claude:
  command: claude
  model: claude-opus-4-6
  permission_mode: bypassPermissions
  read_timeout_ms: 5000
  turn_timeout_ms: 3600000
  stall_timeout_ms: 300000

codex:
  command: codex app-server
```

Rules:

- Add `agent.backend` with allowed values `codex` and `claude`.
- Default `agent.backend` to `codex` for backward compatibility.
- Keep concurrency, retry, and maximum-turn settings under `agent` because
  they are backend-neutral.
- Keep protocol and CLI settings under their backend section.
- A backend must reject configuration that would let callers override required
  machine-readable output flags.
- Backend configuration is snapshotted when a run starts.

Claude fields:

| Field | Required | Contract |
|---|---:|---|
| `command` | No | Claude executable or command prefix. Defaults to `claude`. |
| `model` | No | Model passed to the Claude CLI when set. |
| `permission_mode` | No | Explicit non-interactive permission policy. |
| `read_timeout_ms` | No | Maximum wait for the next stream record. |
| `turn_timeout_ms` | No | Hard limit for one agent turn. |
| `stall_timeout_ms` | No | No-progress threshold used by reconciliation. |

## GitHub Project Adapter

### API surface

Use GitHub's versioned Projects REST endpoints documented under:

- [Project items](https://docs.github.com/en/rest/projects/items?apiVersion=2026-03-10)
- [Project fields](https://docs.github.com/en/rest/projects/fields?apiVersion=2026-03-10)
- [Projects](https://docs.github.com/en/rest/projects/projects?apiVersion=2026-03-10)

Send `X-GitHub-Api-Version: 2026-03-10` for Projects requests. Repository
issue operations may continue to use the existing supported API version.

The client must support both route families:

```text
/orgs/{owner}/projectsV2/{project_number}/...
/users/{owner}/projectsV2/{project_number}/...
```

### Field discovery

At validation and reload:

1. Fetch the project.
2. Page through its fields.
3. Resolve `status_field` by normalized name.
4. Require `data_type: single_select`.
5. Build normalized option-name to option-ID and option-ID to option-name maps.
6. Reject missing, duplicate, or ambiguous configured state names.

Field and option IDs must never be hard-coded in `WORKFLOW.md`.

### Candidate polling

For each poll:

1. List non-archived project items with the status field and any project
   fields needed for normalization.
2. Follow all pagination cursors or links.
3. Retain only items whose content type is `Issue`.
4. Retain only issues from `provider.repository`.
5. Exclude closed issues unless their project status is terminal and the item
   is being refreshed for cleanup.
6. Resolve the item state from the configured status field option.
7. Enrich missing issue metadata through the existing repository-issue
   client when the project response is incomplete.
8. Apply `required_labels`, active-state, terminal-state, blocked, claim,
   retry, and concurrency rules through the existing generic scheduler.

Backlog and unset-status items are visible to diagnostics but are not
dispatch candidates.

### Normalized issue identity

Use the project item as the stable scheduled object:

```elixir
%Issue{
  id: "456",
  identifier: "GH-<issue-number>",
  state: "Ready",
  native_ref: %{
    "project_id" => 123,
    "project_number" => 123,
    "project_item_id" => 456,
    "status_field_id" => 789,
    "status_option_id" => "option-id",
    "repository" => "GHW-Consulting/app-tastemap",
    "issue_id" => 42,
    "issue_node_id" => "I_example",
    "issue_number" => 123
  }
}
```

`native_ref` contains no credential or bearer token and is safe to render into
an agent prompt when the workflow requires it.

### Fetch by IDs

`fetch_issues_by_ids/1` receives project item IDs, not repository issue
numbers. It must:

- Fetch the current project item and requested status field.
- Return no issue for a deleted item.
- Return a non-dispatchable issue for an archived item.
- Refresh the underlying issue metadata.
- Preserve terminal items so the orchestrator can cancel work and clean the
  recorded workspace.
- Return an error rather than stale state when project status cannot be read.

### State transition

Add a tracker callback for provider-neutral transitions:

```elixir
@callback update_issue_state(Issue.t(), String.t(), keyword()) ::
            {:ok, Issue.t()} | {:error, term()}

@optional_callbacks update_issue_state: 3
```

`Tracker.update_issue_state/3` delegates to this callback when implemented and
returns `{:error, :state_transition_not_supported}` otherwise, so existing
tracker adapters remain valid.

The GitHub Project implementation must:

1. Resolve the target option ID from the run's configuration snapshot.
2. PATCH the owner-specific
   `/projectsV2/{project_number}/items/{item_id}` route with
   `{"fields":[{"id":<status-field-id>,"value":"<option-id>"}]}`.
3. Re-fetch the project item.
4. Confirm that its normalized state equals the requested state.
5. Return the refreshed issue.

The transition is idempotent when the item already has the requested state.
The client must preserve GitHub rate-limit metadata and return structured
authentication, authorization, not-found, validation, rate-limit, transport,
and payload errors.

### Claim behavior

Immediately before worker creation:

1. Re-fetch the item.
2. Confirm it remains routable and active.
3. If its state is not `working_state`, update it to `working_state`.
4. Confirm the update.
5. Record the refreshed issue in the running entry.
6. Only then create the workspace and start the backend.

If any step fails, retain the retry state and do not start an agent process.

### Lifecycle behavior

- Moving an item from `Backlog` to `Ready` makes it eligible at the next poll.
- Moving a running item to a non-active, non-terminal state stops the backend
  and preserves its workspace.
- Moving a running item to a terminal state stops the backend and runs the
  existing terminal cleanup path.
- Removing or archiving a running project item stops the backend and preserves
  the workspace unless the last confirmed state was terminal.
- A project API outage pauses new dispatch and prevents state-dependent
  continuation. The daemon must not guess from cached state.
- On daemon restart, active `In Progress` items are eligible for recovery in
  their existing workspaces.

## Shared Agent Backend Architecture

### Behavior

Introduce `SymphonyElixir.AgentBackend`:

```elixir
@callback name() :: atom()
@callback validate_config(map()) :: :ok | {:error, term()}
@callback validate_host(map(), String.t() | nil) :: :ok | {:error, term()}
@callback start_session(Path.t(), Issue.t(), ToolSession.t(), keyword()) ::
            {:ok, session()} | {:error, term()}
@callback run_turn(session(), String.t(), Issue.t(), keyword()) ::
            {:ok, AgentTurnResult.t(), session()}
            | {:blocked, AgentTurnResult.t(), session()}
            | {:error, term(), session()}
@callback stop_session(session(), term()) :: :ok
```

The orchestrator and `AgentRunner` resolve the configured backend once per run.
They invoke only this behavior and never branch on backend-specific protocol
events.

### Normalized events

Introduce `SymphonyElixir.AgentEvent` with these event kinds:

- `session_started`
- `turn_started`
- `assistant_text`
- `reasoning_update`
- `action_started`
- `action_completed`
- `tool_call_started`
- `tool_call_completed`
- `usage_updated`
- `input_required`
- `turn_completed`
- `turn_failed`
- `session_stopped`

Every event includes:

```elixir
%AgentEvent{
  backend: :claude,
  issue_id: "...",
  session_id: "...",
  turn_id: "...",
  timestamp: DateTime.utc_now(),
  payload: %{},
  metadata: %{
    worker_host: nil,
    workspace_path: "...",
    os_pid: "..."
  }
}
```

Backend-specific raw payloads may be included under `payload.raw` for debug
logging, but public presenters must consume normalized fields.

### Turn result

Introduce a shared result containing:

- Backend and session identity.
- Final assistant text and all assistant text blocks.
- Input, cached-input, and output token counts when reported.
- Completed/failed/blocked terminal classification.
- Failure text and structured failure reason.
- Whether explicit human input is required.
- Backend-native metadata stored only for diagnostics.

Unknown or unavailable usage values remain `nil`; they must not be presented
as zero usage.

### Orchestrator integration

Rename Codex-specific process messages and state fields to agent-neutral names:

```text
codex_worker_update  -> agent_worker_update
codex_update_recipient -> agent_update_recipient
codex_app_server_pid -> agent_process_pid
```

The dashboard, JSON API, logging, retry classification, stall reconciliation,
and status snapshots must include `backend` and operate on normalized events.

## Codex Backend

Wrap the existing `SymphonyElixir.Codex.AppServer` in an `AgentBackend`
implementation without changing its external behavior.

The wrapper must preserve:

- JSON-RPC initialization and thread startup.
- Persistent app-server sessions across continuation turns.
- Approval and sandbox policies.
- Dynamic tool calls.
- Input-required and approval-required detection.
- Usage and session metadata.
- Local and SSH process launch.
- Timeout, cancellation, and cleanup behavior.

Codex dynamic tool requests delegate to `TrackerToolBroker`; provider-specific
execution must no longer live inside the app-server module.

## Claude Backend

### CLI protocol

The Claude backend launches Claude Code non-interactively with mandatory
streaming JSON output. It owns required CLI flags and rejects configuration
that conflicts with them.

The command contract follows Anthropic's current
[Claude Code CLI reference](https://docs.anthropic.com/en/docs/claude-code/cli-usage)
and
[MCP integration contract](https://docs.anthropic.com/en/docs/claude-code/mcp).

First turn:

```text
claude -p --input-format text --output-format stream-json --verbose \
  --permission-mode <mode> \
  --mcp-config <session-mcp-config> \
  --allowedTools <session-tool-names> \
  [--model <model>]
```

Continuation turn:

```text
claude -p --input-format text --output-format stream-json --verbose \
  --resume <session-id> \
  --permission-mode <mode> \
  --mcp-config <session-mcp-config> \
  --allowedTools <session-tool-names> \
  [--model <model>]
```

The backend writes the prompt to stdin and closes stdin; prompt text is never a
shell fragment or command-line argument. Configured model and permission-policy
flags are inserted by the backend. `permission_mode` accepts only `default`,
`acceptEdits`, `plan`, and `bypassPermissions`. The generated
`--allowedTools` value explicitly names each `mcp__symphony_tracker__*` tool
advertised for the session; it does not use a wildcard or grant access to an
entire unrelated MCP server. Direct argument execution is preferred locally;
shell execution is permitted only for an explicitly configured command prefix
and must use a reviewed quoting helper.

The MCP configuration path and required flags are reserved. A user-provided
command prefix may not set `-p`, `--print`, `--input-format`,
`--output-format`, `--resume`, `--continue`, `--mcp-config`, `--allowedTools`,
`--permission-mode`, or `--dangerously-skip-permissions`. This prevents a
configuration override from weakening stream parsing, session identity, tool
scope, or the selected permission policy.

### Session behavior

- `start_session/4` validates the workspace, CLI, authentication, tool
  transport, and worker host but does not require a persistent Claude process.
- The first `run_turn/4` captures the Claude session ID from the stream.
- Subsequent turns use `--resume` with that exact ID.
- A missing session ID after a successful first turn is a protocol error.
- A failed resume is not silently retried as a new session.
- Session ID and backend are recorded in the running state and observability
  snapshot.

### Stream parsing

Parse newline-delimited JSON records incrementally with a bounded line size.
Normalize:

- System/session records.
- Assistant text blocks.
- Tool-use blocks and their inputs.
- Result success and error records.
- Per-message and final usage records.
- Claude subagent activity when present.

Malformed JSON is logged with bounded, redacted context. A malformed record
that is not required to determine turn state may be skipped; malformed session
or terminal records fail the turn.

The parser must avoid double-counting usage reported in both intermediate and
terminal records. Tests must pin the accounting rule against representative
Claude stream fixtures.

### Input required

Both backends support the provider-neutral sentinel:

```html
<!-- symphony:needs-input -->
```

The workflow instructs agents to emit it on its own line followed by one
concise question. The detector ignores sentinel examples inside fenced code
blocks.

Claude also maps explicit CLI result errors for approvals, user input, or
interactive confirmation to `input_required`. A blocked result enters the same
orchestrator blocked state and dashboard representation as Codex. For a GitHub
Project tracker, the orchestrator first confirms the item in `blocked_state` and
then stops the live worker. If the worker has already exited, it retains the
in-memory block and retries the status transition during reconciliation. A human
requeues the item by moving it from `blocked_state` to an active state other than
`working_state`, normally `Ready`.

### Process supervision

- Launch each turn in its own OS process group.
- Cancellation terminates the process group, not only its parent shell.
- Always reap the child process.
- Enforce read, turn, and stall timeouts independently.
- Drain stdout and bounded stderr without deadlock.
- Redact secrets from command, environment, stderr, and logs.
- Preserve the workspace after backend failure for retry and inspection.

## Shared Tracker Tool Broker

### Responsibilities

`TrackerToolBroker` owns:

- Provider tool discovery and schemas.
- A configuration snapshot bound to one agent session.
- Session-scoped authorization.
- Tool execution on the orchestrator host.
- Secret removal from agent environments.
- Structured success and failure envelopes.
- Audit logging with issue, backend, session, tool, and duration metadata.

At minimum, expose provider-neutral tools:

| Tool | Purpose |
|---|---|
| `tracker_get_issue` | Refresh the current normalized issue and project status. |
| `tracker_add_comment` | Add a comment to the underlying GitHub issue. |
| `tracker_update_state` | Set the project item's Status option. |

The existing provider-native `github_api` tool remains available for workflows
that need raw GitHub REST operations. It uses the same session-bound token and
relative-path validation under both backends.

`tracker_update_state` accepts a state name, resolves it through the bound
configuration snapshot, updates the field, confirms the result, and returns
the refreshed normalized issue. The tool refuses states outside the configured
active, terminal, working, blocked, and completion set.

### Codex binding

The Codex backend translates broker tool specifications into app-server
`dynamicTools`. Tool calls execute directly against the broker and translate
the common result envelope back into the app-server response shape.

### Claude MCP binding

The Claude backend generates an ephemeral MCP configuration outside the issue
workspace. The MCP server exposes the same broker tool specifications and
results.

The generated configuration contains one server and obtains its bearer token
from a session-only environment variable:

```json
{
  "mcpServers": {
    "symphony_tracker": {
      "type": "http",
      "url": "${SYMPHONY_TRACKER_MCP_URL}",
      "headers": {
        "Authorization": "Bearer ${SYMPHONY_TRACKER_MCP_TOKEN}"
      }
    }
  }
}
```

The backend passes `--mcp-config` on every first and resumed invocation and
passes only the generated `mcp__symphony_tracker__<tool>` names through
`--allowedTools`. Startup fails if Claude's `system/init` record does not list
`symphony_tracker` as connected or does not advertise the expected tool set.

Local sessions connect to a loopback-only Streamable HTTP MCP endpoint.
Remote sessions connect through a reverse SSH tunnel:

```text
remote Claude -> remote 127.0.0.1:<session-port>
              -> SSH reverse tunnel
              -> orchestrator 127.0.0.1:<broker-port>
```

Each session receives a cryptographically random bearer token scoped to:

- One issue ID.
- One backend session.
- One configured tool set.
- The lifetime of the running session.

The endpoint rejects expired tokens, other issue IDs, unadvertised tools,
oversized payloads, and non-loopback direct binds. Tokens are never written to
the workspace, tracker, or logs.

Tunnel startup and MCP health checks complete before Claude starts. Tunnel
loss fails the current turn with a retryable transport error and terminates the
Claude process group.

## SSH Backend Parity

Both backends use the existing worker selection, capacity accounting,
workspace creation, path validation, lifecycle hooks, and cleanup paths.

Backend host validation must verify:

- Non-interactive SSH connectivity.
- Required shell availability.
- Selected backend executable availability.
- Selected backend authentication.
- Git and repository bootstrap prerequisites required by hooks.
- Reverse forwarding availability when Claude tracker tools are enabled.

Remote agent launch must:

- Run from the canonical remote issue workspace.
- Use the same run-bound backend and tracker configuration snapshot.
- Remove tracker secret environment variables.
- Preserve backend authentication variables required by the selected CLI.
- Carry only the session-scoped tool token and MCP endpoint metadata.
- Report worker host and remote workspace in every normalized event.

No failed remote launch may silently fall back to local execution or another
host inside the same worker attempt. Host retry remains orchestrator-owned.

## Security Requirements

- `GITHUB_TOKEN` and referenced tracker token variables remain host-side.
- Agent subprocess environments explicitly unset tracker secret variables.
- MCP tokens are random, session-scoped, revocable, and redacted.
- MCP binds only to loopback and requires bearer authentication.
- Project and issue API paths are constructed from validated configuration or
  validated relative paths.
- Project status tools allow only known configured option names.
- Workflow reloads cannot change the tool authority of an existing session.
- Logs cap and redact raw model output, tool arguments, HTTP bodies, and
  command stderr.
- Workspace path checks remain mandatory locally and remotely.
- Claude permission bypass is an explicit configuration choice and is
  documented as trusted-environment execution.
- Project write access uses the narrowest token permissions compatible with
  project field updates, issue comments, branch pushes, and pull requests.

## Failure and Recovery Semantics

| Failure | Required behavior |
|---|---|
| Project polling fails | Start no new work; retain current runtime state; retry through normal polling. |
| Claim transition fails | Do not create a workspace or start an agent; enqueue retry. |
| Status confirmation differs | Treat as transition failure and do not dispatch. |
| Item leaves active states | Cancel the backend and preserve the workspace. |
| Item enters terminal state | Cancel the backend and run terminal cleanup. |
| Item is archived or removed | Cancel the backend; preserve workspace unless terminal state was confirmed. |
| Agent CLI is missing or unauthenticated | Fail host validation before dispatch. |
| Agent process exits unexpectedly | Return a structured backend failure and use normal retry policy. |
| MCP broker is unavailable | Fail the turn as retryable; never expose the tracker token as fallback. |
| SSH tunnel drops | Stop the remote agent and return a retryable transport failure. |
| Daemon restarts | Rediscover active items and reuse their existing workspaces; start new backend sessions. |
| Workflow reload is invalid | Keep the last known good configuration and report the validation error. |

## Observability

Update the JSON API, LiveView dashboard, and logs to show:

- Selected backend for every running, retrying, and blocked item.
- Backend session and turn identifiers.
- GitHub Project item ID and current project status.
- Worker host and workspace path.
- Normalized assistant activity and tool activity.
- Input, cached-input, and output usage when reported.
- MCP broker and tunnel health for Claude sessions.
- Structured tracker, backend, SSH, timeout, and tool failures.

User-facing text must use “agent” unless a backend distinction is materially
useful. Existing Codex-specific API field names are retained as deprecated
read aliases only if compatibility requires them; all new writes and internal
state use agent-neutral names.

## Implementation Map

### New modules

```text
elixir/lib/symphony_elixir/agent_backend.ex
elixir/lib/symphony_elixir/agent_backend/codex.ex
elixir/lib/symphony_elixir/agent_backend/claude.ex
elixir/lib/symphony_elixir/agent_event.ex
elixir/lib/symphony_elixir/agent_turn_result.ex
elixir/lib/symphony_elixir/claude/stream_parser.ex
elixir/lib/symphony_elixir/claude/session.ex
elixir/lib/symphony_elixir/github_project/adapter.ex
elixir/lib/symphony_elixir/github_project/client.ex
elixir/lib/symphony_elixir/github_project/normalizer.ex
elixir/lib/symphony_elixir/tracker_tool_broker.ex
elixir/lib/symphony_elixir/tracker_mcp.ex
elixir/lib/symphony_elixir/tracker_mcp/handle.ex
elixir/lib/symphony_elixir/tracker_mcp/router.ex
elixir/lib/symphony_elixir/tracker_mcp/server.ex
```

### Modified modules

- `config/schema.ex`, `config.ex`, `workflow.ex`, and `workflow_store.ex`: add
  tracker lifecycle fields, `agent.backend`, Claude configuration, validation,
  secret resolution, and reload snapshot handling.
- `tracker.ex`: register `github_project`, add the optional state-transition
  callback, and bind provider tools through `TrackerToolBroker`.
- `agent_runner.ex`: depend only on `AgentBackend` and normalized results.
- `codex/app_server.ex` and `codex/dynamic_tool.ex`: delegate tool execution and
  event normalization without changing the Codex wire protocol.
- Existing tracker adapters advertise their provider-native tools through the
  shared broker without changing their tool implementations.
- `orchestrator.ex`: perform the confirmed claim transition and consume generic
  agent events.
- `ssh.ex`: add backend host validation and reverse-tunnel lifecycle support.
- `status_dashboard.ex` and the web presenter: use generic backend/session
  fields while retaining Codex compatibility aliases.
- `README.md`, `elixir/README.md`, and the example GitHub Project + Claude
  workflow: document both backends and project configuration.

## Verification Strategy

### Shared backend contract tests

Define a reusable backend conformance suite and run it against Codex and Claude
test implementations. It must verify:

- Host and configuration validation.
- Local session startup and shutdown.
- SSH session startup and shutdown.
- Text, action, tool, usage, and terminal event normalization.
- Multi-turn continuation with stable session identity.
- Explicit input-required handling.
- Read timeout, turn timeout, cancellation, and unexpected exit.
- Process cleanup and workspace preservation.
- Tracker tool schema and result parity.
- Secret removal and log redaction.

Claude tests use a fake executable that records arguments and environment,
emits representative stream-JSON fixtures, supports resume, simulates partial
lines, stalls, malformed records, failures, subagent activity, and signal
handling.

### GitHub Project adapter tests

Use a controllable HTTP test server to cover:

- Organization- and user-owned project routes.
- Project and field discovery pagination.
- Status field and option validation.
- Project item pagination.
- Repository filtering.
- Draft, pull-request, archived, closed, deleted, and malformed items.
- Ready, active, inactive, terminal, and unset status normalization.
- Required issue-label filtering without state labels.
- Fetch-by-project-item-ID behavior.
- Idempotent and confirmed state transitions.
- Authentication, authorization, validation, rate-limit, transport, and payload
  errors.
- Workflow reload field and option changes.

### Tool broker tests

- Identical tool names and schemas for Codex and Claude.
- Session snapshot isolation across workflow reloads.
- State allowlist enforcement.
- Issue and session scope enforcement.
- Expired and incorrect bearer tokens.
- Payload bounds and malformed JSON.
- Local MCP health and execution.
- SSH reverse-tunnel startup, loss, and cleanup using a fake SSH executable.
- Proof that tracker tokens are absent from agent environments and command
  lines.

### Orchestrator tests

- Ready-to-In-Progress transition precedes workspace creation.
- Failed transition prevents agent startup.
- Backlog items never dispatch.
- In Progress items recover after restart.
- Active-to-inactive movement cancels without cleanup.
- Terminal movement cancels and cleans up.
- Archived and removed items follow the specified preservation rule.
- Backend selection is snapshotted per run.
- Claude and Codex events produce the same scheduler state changes.
- Retry and stall behavior is backend-independent.

### Live integration tests

Provide opt-in live tests using a disposable GitHub Project and scratch
repository:

1. Create or identify `Backlog`, `Ready`, `In Progress`, `In Review`, `Done`,
   and `Cancelled` status options.
2. Add a scratch issue to the project in `Backlog` and prove it is not
   dispatched.
3. Move it to `Ready` and prove the orchestrator changes it to `In Progress`
   before starting the backend.
4. Run a workspace-producing turn and use `tracker_update_state` to move it to
   `In Review`.
5. Repeat the flow once with Codex and once with Claude.
6. Repeat backend startup through an SSH worker.
7. Confirm no workflow-state labels were added or removed.
8. Confirm tracker credentials were absent from both agent environments.

The repository quality gate remains `make all`, supplemented by the explicit
live-test command documented for each backend and tracker combination.

## Backward Compatibility

- A workflow without `agent.backend` continues to select Codex.
- Existing `codex` settings retain their current meaning.
- Existing tracker kinds retain their current behavior.
- The existing `github` tracker continues to use issue state and does not
  silently switch to Projects behavior.
- Existing workflow prompt bindings remain available.
- Add `agent.backend` and project-item `issue.native_ref` bindings without
  removing existing fields.
- Generic observability fields are additive. Any deprecated Codex-named JSON
  aliases are documented and covered by compatibility tests.

## Documentation Deliverables

- A GitHub Projects setup guide covering project owner, number, status field,
  state options, token permissions, and repository filtering.
- A Claude backend setup guide covering CLI installation, authentication,
  permission mode, MCP tools, and SSH worker prerequisites.
- A backend comparison limited to configuration and supported capabilities.
- Updated workflow examples for local Codex, local Claude, SSH Codex, and SSH
  Claude.
- Operational guidance for token rotation, MCP session failures, SSH tunnel
  failures, project field renames, and daemon restart recovery.
- A migration note explaining that GitHub Issues and GitHub Projects are
  separate tracker kinds.

## Acceptance Criteria

### GitHub Projects

- [ ] A project item in `Backlog` is not dispatched.
- [ ] Moving that item to `Ready` makes it dispatchable without adding a
  GitHub label.
- [ ] The item is confirmed as `In Progress` before its agent process starts.
- [ ] No issue label is added, removed, or interpreted as workflow state.
- [ ] Only issue items from the configured repository are dispatchable.
- [ ] Drafts, pull requests, archived items, and unset-status items are not
  dispatched.
- [ ] Active items recover after daemon restart using their existing
  workspaces.
- [ ] Non-active and terminal transitions produce the specified cancellation
  and cleanup behavior.
- [ ] Project field and option renames fail configuration validation rather
  than silently changing routing.

### Claude parity

- [ ] `agent.backend: claude` runs Claude Code without changing scheduler or
  workspace configuration.
- [ ] Claude supports local and SSH workspaces, hooks, retries, cancellation,
  continuation turns, blocked state, and terminal cleanup.
- [ ] Claude resumes the same CLI session across continuation turns.
- [ ] Claude and Codex expose identical tracker tool names, input schemas,
  authorization, and normalized results.
- [ ] Claude can comment on the issue and update project status through the
  host-side broker locally and over SSH.
- [ ] GitHub credentials are absent from Claude's environment, arguments,
  workspace, and logs.
- [ ] Claude text, tool activity, usage, failures, and input-required state are
  visible through the same dashboard and API fields as Codex.
- [ ] Claude cancellation terminates the complete local or remote process
  group and leaves no orphaned worker.

### Codex regression safety

- [ ] Existing Codex workflows run without configuration changes.
- [ ] Codex app-server session, approval, sandbox, tool, timeout, and SSH
  behavior remain covered by passing regression tests.
- [ ] Codex uses the shared tracker tool broker and normalized event pipeline.
- [ ] Backend-neutral refactoring does not change retry, claim, continuation,
  blocked, or cleanup semantics.

### Integrated flow

- [ ] The live GitHub Project flow passes with Codex locally and over SSH.
- [ ] The live GitHub Project flow passes with Claude locally and over SSH.
- [ ] Both backends move the same project item through the same project
  statuses using the same tracker-tool contract.
- [ ] The full repository quality gate passes.
