---
tracker:
  kind: github_project
  provider:
    owner: GHW-Consulting
    owner_type: organization
    project_number: 2
    repository: GHW-Consulting/app-tastemap
    status_field: Status
    token: file:///run/secrets/github_project_token
  required_labels: []
  active_states:
    - Ready
    - In Progress
  terminal_states:
    - Done
    - Cancelled
  working_state: In Progress
  blocked_state: Blocked
  completion_state: In Review
polling:
  interval_ms: 5000
server:
  host: 0.0.0.0
workspace:
  root: /workspaces
hooks:
  after_create: |
    git clone --depth 1 https://github.com/GHW-Consulting/app-tastemap.git .
    pnpm install --frozen-lockfile
agent:
  backend: codex
  max_concurrent_agents: 3
  max_turns: 20
  max_retry_backoff_ms: 300000
  routing:
    ready_state: Ready
    executor_field: Executor
    profiles:
      afarnham:
        default_backend: codex
        worker_hosts:
          - worker@agent-worker-afarnham
      karbas:
        default_backend: claude
        worker_hosts:
          - worker@agent-worker-karbas
worker:
  ssh_hosts:
    - worker@agent-worker-afarnham
    - worker@agent-worker-karbas
  max_concurrent_agents_per_host: 3
codex:
  approval_policy: never
  thread_sandbox: danger-full-access
  turn_sandbox_policy:
    type: dangerFullAccess
claude:
  command: claude
  permission_mode: bypassPermissions
  read_timeout_ms: 5000
  turn_timeout_ms: 3600000
  stall_timeout_ms: 300000
---

You are working on GitHub Project item `{{ issue.identifier }}`.

Title: {{ issue.title }}
Current project status: {{ issue.state }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description was provided.
{% endif %}

Work only in the provided repository workspace.

Whenever these instructions say to emit the input-required sentinel, put the exact line
`<!-- symphony:needs-input -->` on a line by itself in your final response. Do not merely describe
the sentinel.

1. Use `tracker_get_issue` before any exploration, implementation, or repository edits. Treat its
   refreshed issue fields and `native_ref` as authoritative. Write the JSON object contained in
   the tracker tool result's `output` field—the normalized `tracker_get_issue payload` with a
   top-level `issue` object containing `description`, `labels`, and `native_ref`—unchanged to
   `/tmp/symphony-ticket.json`. Do not unwrap or reconstruct the issue, and do not fetch it with
   `gh` or another GitHub API call.
2. Route every ticket before doing any other repository work:

   ```sh
   pnpm wine-dive -- route-ticket \
     --ticket-file /tmp/symphony-ticket.json \
     --project-item-id <native_ref.project_item_id>
   ```

   Substitute the refreshed native values. If `native_ref.project_item_id` is absent, omit that
   option. Remove the temporary ticket file after the command returns. The command must exit
   successfully and print exactly one recognized route:
   `SYMPHONY_ROUTE=generic` or `SYMPHONY_ROUTE=wine-dive-graph`. On failure or ambiguous output,
   add a tracker comment containing the command failure, emit the input-required sentinel, and
   stop. A ticket labeled `wine dive` must not fall through to generic implementation.
3. For `SYMPHONY_ROUTE=generic`, investigate, implement, and validate the requested change
   autonomously. Add a concise durable tracker comment when useful. After the implementation and
   validation are complete, use `tracker_update_state` to move the item to `In Review`.
4. For `SYMPHONY_ROUTE=wine-dive-graph`, use the printed `WINE_DIVE_RUN_ID` as the durable run
   receipt. Comment that receipt on the ticket, run
   `pnpm wine-dive -- status --id <WINE_DIVE_RUN_ID>`, and execute only the next legal graph node
   shown by the checkpoint. Record every completed graph transition with
   `pnpm wine-dive -- record --id <WINE_DIVE_RUN_ID> --event <event-json-file>`. Do not invoke the
   manual `dive wine` selector or the generic implementation path. The graph owns discovery, the
   ticket-authorized band prefix, sequential producer work, validation, apply, PR/merge tracking,
   deferred-work persistence, and closeout. Keep the Project item `In Progress` between band PRs;
   do not move it to `In Review` merely because one band or agent turn finishes. Only after the
   graph reports `complete`, all selected band merges are confirmed, and its closeout artifacts
   are durable should you close the GitHub issue and use `tracker_update_state` to move the item to
   `Done`. In other words: move the item to `Done` only at terminal graph closeout.
5. For either route, if a real external blocker prevents further legal work, add a concise tracker
   comment with the exact checkpoint and required human action, emit the input-required sentinel,
   and stop. Symphony moves the item to `Blocked`; after resolution, a human moves it back to
   `Ready` and the next run resumes from durable state.
