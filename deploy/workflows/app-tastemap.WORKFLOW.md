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
  max_turns: 40
  max_retry_backoff_ms: 300000
  routing:
    ready_state: Ready
    executor_field: Executor
    trusted_release_actors:
      - thor-claw
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
   pnpm dive-graph -- route-ticket \
     --ticket-file /tmp/symphony-ticket.json \
     --project-item-id <native_ref.project_item_id>
   ```

   Substitute the refreshed native values. If `native_ref.project_item_id` is absent, omit that
   option. Remove the temporary ticket file after the command returns. The command must exit
   successfully and print exactly one recognized route:
   `SYMPHONY_ROUTE=generic`, `SYMPHONY_ROUTE=wine-dive-graph`, or
   `SYMPHONY_ROUTE=dining-dive-graph`. On failure or ambiguous output,
   add a tracker comment containing the command failure, emit the input-required sentinel, and
   stop. A ticket labeled `wine dive` or `dining dive` must not fall through to generic implementation.
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
5. For `SYMPHONY_ROUTE=dining-dive-graph`, use the printed `DINING_DIVE_RUN_ID` as the durable
   receipt and set `DINING_RUN_DIR=data/sources/_dining-dive-runs/$DINING_DIVE_RUN_ID`. Comment the
   run ID on the ticket once. Before each action, run
   `pnpm dining-dive -- status --id "$DINING_DIVE_RUN_ID"`; the checkpoint is authoritative. Run
   only the command group for the current node below, then end the turn so a continuation resumes
   from disk. Never use the manual `dive dining` selector and never edit seed JSON directly.

   - `preflight`: run `pnpm dining-dive -- preflight --id "$DINING_DIVE_RUN_ID"`.
   - `discovery`: run `pnpm dive-discovery -- prepare --domain dining --run-dir "$DINING_RUN_DIR"
     --preflight-ref artifacts/preflight.json`. Then run one bounded read-only research worker with
     `pnpm dining-dive-agent` and all required arguments: use `run-codex` when this Symphony run
     uses Codex or `run-claude` when it uses Claude; `--run-dir "$DINING_RUN_DIR"`;
     `--request-ref artifacts/discovery/request.json`; new numbered relative paths for
     `--response-ref` and `--receipt-ref` under `artifacts/discovery/`;
     `--artifact-ref artifacts/discovery/result.json`; `--kind discovery`; `--task-id discovery`;
     the matching `SYMPHONY_DIVE_CODEX_MODEL` or `SYMPHONY_DIVE_CLAUDE_MODEL` value as `--model`;
     and `--reasoning-level high`. Accept with `pnpm dive-discovery -- accept --domain dining
     --run-dir "$DINING_RUN_DIR" --response "$DINING_RUN_DIR/<response-ref>"`, then record the
     measured draft with `pnpm dining-dive-publish -- record-receipt --run-dir
     "$DINING_RUN_DIR" --receipt "$DINING_RUN_DIR/<receipt-ref>"`.
     Never invent or estimate token counts.
   - `persist_deferred_bands`: run
     `pnpm dining-dive -- persist-deferred --id "$DINING_DIVE_RUN_ID"`.
   - `prepare_band`: run `pnpm dining-dive-dispatch -- prepare --run-dir "$DINING_RUN_DIR"`.
   - `run_restaurant_dives`: run `pnpm dining-dive-dispatch -- ready --run-dir
     "$DINING_RUN_DIR"`, choose one printed ready task ID, and run
     `pnpm dining-dive-dispatch -- start --run-dir "$DINING_RUN_DIR" --task-id <task-id>`. Use the printed attempt request as
     `--request-ref` for the matching `pnpm dining-dive-agent` backend. Pass `--run-dir
     "$DINING_RUN_DIR"`, new response and receipt-draft refs in that attempt directory, the exact
     future attempt `result.json` as `--artifact-ref`, `--kind restaurant`, `--band <active-band>`,
     `--task-id <task-id>`, the matching configured `--model`, and `--reasoning-level high`. Run
     `pnpm dining-dive-dispatch -- complete --run-dir "$DINING_RUN_DIR" --task-id <task-id>
     --response "$DINING_RUN_DIR/<response-ref>"`, then run
     `pnpm dining-dive-publish -- record-receipt --run-dir "$DINING_RUN_DIR" --receipt "$DINING_RUN_DIR/<receipt-ref>"`. A
     rejected typed response consumes the graph attempt and must not receive an accepted receipt.
   - `validate_proposals`: run `pnpm dining-dive-validate -- validate --run-dir
     "$DINING_RUN_DIR"`.
   - `repair_proposals`: choose one prepared repair request and pass its relative path to the same
     read-only worker. Pass `--run-dir "$DINING_RUN_DIR"`, new response and receipt-draft refs next
     to that request, the exact future repair `result.json` as `--artifact-ref`, `--kind repair`,
     `--band <active-band>`, `--task-id <task-id>`, the matching configured `--model`, and
     `--reasoning-level high`. Run `pnpm dining-dive-validate -- accept-repair --run-dir
     "$DINING_RUN_DIR" --task-id <task-id> --response "$DINING_RUN_DIR/<response-ref>"`, then run
     `pnpm dining-dive-publish -- record-receipt --run-dir "$DINING_RUN_DIR" --receipt
     "$DINING_RUN_DIR/<receipt-ref>"`. Continue until every request in that repair pass is accepted.
   - `stage_patch`: run `pnpm dining-dive-validate -- stage --run-dir "$DINING_RUN_DIR"`.
   - `verify_patch`: first run `pnpm dining-dive-validate -- apply --run-dir "$DINING_RUN_DIR"`,
     then `pnpm dining-dive-validate -- verify --run-dir "$DINING_RUN_DIR" --repo-dir .`.
   - `publish_band_pr`: run `pnpm dining-dive-publish -- publish --run-dir "$DINING_RUN_DIR"
     --repo-dir . --repo GHW-Consulting/app-tastemap`. This path has no routine human gate.
   - `awaiting_band_merge`: run `pnpm dining-dive-publish -- confirm-merge --run-dir
     "$DINING_RUN_DIR" --repo-dir . --repo GHW-Consulting/app-tastemap`. The command
     requests squash auto-merge when the PR is open and records a transition only after GitHub reports the
     merge. If GitHub still reports the PR open, leave the item `In Progress` and end the turn
     without emitting the blocker sentinel.
   - `finalize_run`: run `pnpm dining-dive-publish -- closeout --run-dir "$DINING_RUN_DIR"
     --repo-dir . --repo GHW-Consulting/app-tastemap --tracker-managed`. Confirm the graph now
     reports `complete`. Read `artifacts/closeout.json`, then use the orchestrator tools—not the
     worker's `gh` credential—for ticket lifecycle: use `github_api` to list the issue comments;
     if the marker `<!-- dining-dive-closeout:<run-id> -->` is absent, add the standard closeout
     text plus that marker once with `tracker_add_comment`; use `github_api` to PATCH
     `/repos/GHW-Consulting/app-tastemap/issues/<issue-number>` with `{"state":"closed"}`; confirm
     the issue is closed; then use `tracker_update_state` to move the Project item to `Done`.
   - `complete`: idempotently ensure the marked closeout comment and closed issue are present with
     the same orchestrator tools, then move the Project item to `Done` if needed. Never grant or
     require Issues permission on the worker credential for this closeout.
   - `awaiting_band_selection` or `awaiting_approval` in Symphony mode is an invalid checkpoint;
     report it as a blocker instead of supplying a human gate.
   - `blocked`: report the exact checkpoint and required human action, emit the input-required
     sentinel, and stop.

   Keep the Project item `In Progress` through discovery, every restaurant task, every band PR,
   and every inter-band merge. Do not move it to `In Review`. Only terminal graph closeout moves it
   to `Done`.
6. For any route, if a real external blocker prevents further legal work, add a concise tracker
   comment with the exact checkpoint and required human action, emit the input-required sentinel,
   and stop. Symphony moves the item to `Blocked`; after resolution, a human moves it back to
   `Ready` and the next run resumes from durable state.
