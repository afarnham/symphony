---
tracker:
  kind: github_project
  provider:
    owner: GHW-Consulting
    owner_type: organization
    project_number: 123
    repository: GHW-Consulting/your-repository
    status_field: Status
    token: $GITHUB_TOKEN
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
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    git clone --depth 1 git@github.com:GHW-Consulting/your-repository.git .
agent:
  backend: claude
  max_concurrent_agents: 3
  max_turns: 20
  max_retry_backoff_ms: 300000
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

1. Use `tracker_get_issue` before implementation to refresh the issue and project status.
2. Investigate, implement, and validate the requested change autonomously.
3. Use `tracker_add_comment` for a concise durable progress or blocker note when useful.
4. After the implementation and required validation are complete, use `tracker_update_state` to
   move the item to `In Review`.
5. If a real external blocker prevents completion, record the blocker with `tracker_add_comment`
   and emit the input-required sentinel. Symphony moves the item to `Blocked`; a human moves it
   back to `Ready` after resolving the blocker.
