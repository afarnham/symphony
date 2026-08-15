# Assignee-aware executor routing

## Purpose

Allow one Symphony orchestrator to dispatch GitHub Project tickets to credential-isolated
workers owned by different GitHub users. By default, the assignee who moves a ticket to `Ready`
selects the credential profile. An optional trusted release actor can instead move an assigned
ticket to `Ready` without using the worker owner's GitHub credential. An optional Project
single-select field selects Claude or Codex; when the field is unset, the profile's configured
default applies.

This routing does not use labels or additional workflow states.

## Project workflow

The GitHub Project retains the existing Status flow and adds one single-select field:

- `Executor`
  - `Claude`
  - `Codex`

The daily workflow is:

1. A user assigns the issue to themselves.
2. The user optionally sets `Executor` to override their default backend.
3. The same user moves the item to `Ready`.

Symphony resolves the Ready-transition actor to a configured execution profile, confirms that
the actor is an issue assignee, resolves the backend, and claims the item as `In Progress`.

For an automated release, a configured trusted actor moves the item to `Ready`. Symphony selects
the only current issue assignee whose login is also a configured execution profile. The trusted
actor authorizes release; the assigned profile owns the worker and credentials.

## Configuration

Routing is opt-in and lives under `agent.routing`. Profile keys are normalized GitHub logins.

```yaml
agent:
  backend: codex
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
```

`agent.backend` remains the backend for workflows without routing profiles. It is not a fallback
when routing is enabled.

Routing validation requires:

- a non-empty `ready_state` that is active and differs from `tracker.working_state`;
- a non-empty `executor_field`;
- at least one profile;
- unique, non-empty GitHub login keys;
- a supported `default_backend` for every profile;
- at least one unique SSH worker host for every profile; and
- no worker host shared by two profiles.

`trusted_release_actors` is optional. Entries are case-insensitive GitHub logins, normalized to
lowercase, and must be unique. These actors are release governors, not execution profiles. They do
not need to be assigned to the issue and do not select a worker by their own identity.

## Add a trusted release actor

Use these steps for each bot, service account, or human governor that may release assigned work:

1. Create or select a dedicated GitHub identity. Give its token only the repository issue and
   organization Project permissions required to assign the worker owner and move Project Status
   to `Ready`. Do not give the governor a worker owner's personal token.
2. Add the normalized GitHub login to `agent.routing.trusted_release_actors`:

   ```yaml
   agent:
     routing:
       trusted_release_actors:
         - thor-claw
         - another-governor
   ```

3. Keep each target issue assigned to exactly one login present under
   `agent.routing.profiles`. Other assignees are allowed only when they are not configured
   profiles.
4. Install or deploy the updated workflow and reload Symphony. A workflow reload applies the new
   allowlist to future dispatches; it does not change a route already captured by a running job.
5. Test with a low-risk item: have the new identity move it to `Ready`, then confirm the route
   records the governor as `ready_actor` and the assigned worker owner as `profile`.

The governor cannot name an arbitrary profile. Symphony derives the worker owner from current
issue assignment and fails closed when zero or more than one configured profile is assigned. In
those cases the item remains in `Ready` with a visible routing error. Leaving `Executor` unset uses
the assigned profile's default backend; setting `Claude` or `Codex` changes only the backend.

## Normalized tracker data

The GitHub Project adapter reads:

- every issue assignee login;
- the configured Executor field value; and
- for dispatch revalidation only, the latest status-change event for the configured Project whose
  destination is `ready_state`.

The status event records its actor and whether GitHub classified it as automated. Event discovery
pages backward through status-change events and fails closed when the matching event cannot be
identified.

Regular polling and running-issue reconciliation do not fetch timeline events. The extra request
is made only when an issue is being considered for a new dispatch route.

## Route resolution

A route contains:

- normalized profile login;
- selected backend;
- the profile's eligible worker hosts; and
- the Ready event identity used to authorize the route.

Direct human routing succeeds only if:

- the Ready actor is present and is not an automated transition;
- the Ready actor names a configured profile;
- the actor appears in the issue's current assignee list; and
- the Executor value is unset, `Claude`, or `Codex`.

An unset Executor uses the profile default. An explicit Executor overrides the default.

Multiple issue assignees are supported. The Ready actor selects which assigned execution profile
owns the run. A user who is not assigned cannot route the issue merely by moving it to Ready.

Unknown users, missing history, unsupported Executor values, automation, and assignee mismatches
leave the item in Ready. Symphony records a visible routing reason and never falls back to another
profile or the legacy global backend.

Trusted release routing succeeds only if:

- the Ready actor is present in `trusted_release_actors`;
- exactly one current issue assignee names a configured profile; and
- the Executor value is unset, `Claude`, or `Codex`.

GitHub may classify a trusted actor's Ready transition as automated. The explicit allowlist is the
authorization check for that path. Automated transitions from identities not on the allowlist
remain rejected.

## Dispatch and lifecycle invariants

Symphony resolves and validates the route before transitioning Ready to In Progress. It then
selects capacity only from the route's eligible hosts.

The resolved profile, backend, eligible hosts, and selected host are captured with the run. They
remain unchanged across:

- task startup;
- continuation turns;
- retries;
- blocked reconciliation;
- cancellation and cleanup; and
- workflow configuration reloads.

AgentRunner resolves the backend from the captured route, not from live configuration. Retry and
blocked entries retain the route. Existing runs therefore cannot switch accounts or backends.

After a restart, an active item without captured in-memory state is treated as a new dispatch and
must resolve from the most recent matching Ready transition. The later Symphony-generated In
Progress transition does not replace the Ready actor used for ownership.

## Worker isolation

Each profile runs in a separate worker container with distinct:

- Claude authentication volume;
- Codex authentication volume;
- workspace volume;
- cache and local-state volumes; and
- SSH endpoint.

The current two-profile Compose deployment shares only the GitHub worker credential and
orchestrator-to-worker SSH trust material. Model authentication, workspaces, and mutable tool state
are never mounted across profiles.

The worker image may be shared. Authentication and writable volumes may not be shared. The
orchestrator and tracker credential remain shared. The existing repository-scoped GitHub worker
credential may be shared unless a deployment explicitly requires separate GitHub authorship.

The deployment utility exposes profile-aware commands for the profiles declared in Compose and
`SYMPHONY_WORKER_PROFILES`:

```text
symphony-admin workers list
symphony-admin workers auth <profile> claude
symphony-admin workers auth <profile> codex
symphony-admin workers status <profile>
```

Secrets are never passed in command arguments or written to generated Compose environment values.

## Observability

Dashboard and API snapshots expose, for running, retry, and blocked entries:

- routing profile;
- Ready actor;
- selected backend;
- eligible worker hosts;
- selected worker host; and
- routing failure reason for unclaimed Ready items.

Logs include the issue identifier and normalized profile/backend but never authentication data.

## Compatibility

Workflows without `agent.routing` preserve the existing global backend and flat worker-host
behavior. Existing tracker adapters do not need to manufacture GitHub routing metadata. Routing
configuration is rejected for unsupported tracker kinds rather than silently ignored.

## Validation

Coverage includes:

- profile schema normalization and semantic validation;
- all-assignee and Executor normalization;
- Ready event pagination and Project filtering;
- default and overridden backend selection;
- multiple assignees resolved by the Ready actor;
- trusted release selection of the only assigned configured profile;
- trusted release rejection with zero or multiple assigned configured profiles;
- missing, unknown, automated, and unassigned actors;
- route snapshot preservation across retries, blocking, and reloads;
- worker capacity constrained to the selected profile;
- backend-specific host validation and execution;
- independent worker authentication, workspace, cache, and local-state volumes;
- profile-aware admin authentication and status commands; and
- a container smoke test proving one worker cannot read another profile's authentication data.
