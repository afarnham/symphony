defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls the configured issue tracker and dispatches repository copies to agent workers.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.{
    AgentEvent,
    AgentRunner,
    AgentTurnResult,
    Config,
    ExecutionRoute,
    StatusDashboard,
    Tracker,
    Workspace
  }

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Tracker.Issue

  @continuation_retry_delay_ms 1_000
  @failure_retry_base_ms 10_000
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @empty_agent_totals %{
    input_tokens: 0,
    cached_input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    defstruct [
      :poll_interval_ms,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :tick_timer_ref,
      :tick_token,
      task_supervisor: SymphonyElixir.TaskSupervisor,
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      blocked: %{},
      retry_attempts: %{},
      agent_totals: nil,
      agent_rate_limits: nil,
      codex_totals: nil,
      codex_rate_limits: nil
    ]
  end

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    case Config.settings() do
      {:ok, config} ->
        now_ms = System.monotonic_time(:millisecond)

        state = %State{
          poll_interval_ms: config.polling.interval_ms,
          max_concurrent_agents: config.agent.max_concurrent_agents,
          next_poll_due_at_ms: now_ms,
          poll_check_in_progress: false,
          tick_timer_ref: nil,
          tick_token: nil,
          task_supervisor: Keyword.get(opts, :task_supervisor, SymphonyElixir.TaskSupervisor),
          agent_totals: @empty_agent_totals,
          agent_rate_limits: nil,
          codex_totals: @empty_agent_totals,
          codex_rate_limits: nil
        }

        run_terminal_workspace_cleanup()
        state = schedule_tick(state, 0)

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, state) do
    state = refresh_runtime_config(state)
    state = maybe_dispatch(state)
    state = schedule_tick(state, state.poll_interval_ms)
    state = %{state | poll_check_in_progress: false}

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        {running_entry, state} = pop_running_entry(state, issue_id)
        state = record_session_completion_totals(state, running_entry)
        session_id = running_entry_session_id(running_entry)

        state = handle_agent_down(reason, state, issue_id, running_entry, session_id)

        Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}")

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:worker_runtime_info, issue_id, runtime_info}, %{running: running} = state)
      when is_binary(issue_id) and is_map(runtime_info) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        updated_running_entry =
          running_entry
          |> maybe_put_runtime_value(:worker_host, runtime_info[:worker_host])
          |> maybe_put_runtime_value(:workspace_path, runtime_info[:workspace_path])
          |> maybe_put_runtime_value(:backend, runtime_info[:backend])
          |> maybe_put_runtime_value(:profile, runtime_info[:profile])
          |> maybe_put_runtime_value(:ready_actor, runtime_info[:ready_actor])

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info(
        {:agent_cancellation_ready, issue_id, cancellation_pid},
        %{running: running} = state
      )
      when is_binary(issue_id) and is_pid(cancellation_pid) do
    case Map.get(running, issue_id) do
      nil ->
        _ = AgentRunner.cancel(cancellation_pid, :orchestrator_entry_missing)
        {:noreply, state}

      running_entry ->
        updated_running_entry = Map.put(running_entry, :cancellation_pid, cancellation_pid)
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info(
        {:agent_worker_update, issue_id, %AgentEvent{} = event},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {updated_running_entry, token_delta} = integrate_agent_update(running_entry, event)
        updated_running_entry = sync_backend_read_aliases(updated_running_entry, event)

        state =
          state
          |> apply_agent_token_delta(token_delta)
          |> apply_backend_token_delta(event.backend, token_delta)
          |> apply_agent_rate_limits(event)

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info(
        {:agent_worker_completed, issue_id, %AgentTurnResult{} = completion},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {updated_running_entry, token_delta} = integrate_agent_completion(running_entry, completion)
        updated_running_entry = sync_backend_completion_aliases(updated_running_entry, completion)

        state =
          state
          |> apply_agent_token_delta(token_delta)
          |> apply_backend_token_delta(completion.backend, token_delta)

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info(
        {:codex_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {updated_running_entry, token_delta} = integrate_codex_update(running_entry, update)

        state =
          state
          |> apply_agent_token_delta(token_delta)
          |> apply_codex_token_delta(token_delta)
          |> apply_codex_rate_limits(update)

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info({:codex_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info({:retry_issue, issue_id, retry_token}, state) do
    result =
      case pop_retry_attempt_state(state, issue_id, retry_token) do
        {:ok, attempt, metadata, state} -> handle_retry_issue(state, issue_id, attempt, metadata)
        :missing -> {:noreply, state}
      end

    notify_dashboard()
    result
  end

  def handle_info({:retry_issue, _issue_id}, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp handle_agent_down(:normal, state, issue_id, running_entry, session_id) do
    if input_required_blocker?(running_entry) do
      block_input_required_agent_down(state, issue_id, running_entry, session_id, :normal)
    else
      Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

      state
      |> complete_issue(issue_id)
      |> schedule_issue_retry(
        issue_id,
        1,
        retry_metadata_from_running(running_entry, %{delay_type: :continuation})
      )
    end
  end

  defp handle_agent_down(reason, state, issue_id, running_entry, session_id) do
    if input_required_blocker?(running_entry) do
      block_input_required_agent_down(state, issue_id, running_entry, session_id, reason)
    else
      retry_agent_down(state, issue_id, running_entry, session_id, reason)
    end
  end

  defp block_input_required_agent_down(state, issue_id, running_entry, session_id, reason) do
    error = blocker_error(running_entry, "agent exited: #{inspect(reason)}")

    Logger.warning("Agent task blocked for issue_id=#{issue_id} issue_identifier=#{running_entry.identifier} session_id=#{session_id}: #{error}")

    block_issue_from_entry(state, issue_id, running_entry, error)
  end

  defp retry_agent_down(state, issue_id, running_entry, session_id, reason) do
    Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

    next_attempt = next_retry_attempt_from_running(running_entry)

    schedule_issue_retry(
      state,
      issue_id,
      next_attempt,
      retry_metadata_from_running(running_entry, %{
        error: "agent exited: #{inspect(reason)}"
      })
    )
  end

  defp maybe_dispatch(%State{} = state) do
    state =
      state
      |> reconcile_running_issues()
      |> reconcile_blocked_issues()

    with :ok <- Config.validate!(),
         settings when is_map(settings) <- Config.settings!(),
         {:ok, dispatch_context} <- dispatch_context(settings),
         {:ok, issues} <-
           Tracker.fetch_bound_issues_by_states(
             dispatch_context.tracker_binding,
             settings.tracker.active_states
           ),
         true <- available_slots(state) > 0 do
      choose_issues(issues, state, dispatch_context)
    else
      {:error, :missing_linear_api_token} ->
        Logger.error("Tracker API token missing in WORKFLOW.md")
        state

      {:error, :missing_linear_project_slug} ->
        Logger.error("Tracker project scope missing in WORKFLOW.md")
        state

      {:error, :missing_tracker_kind} ->
        Logger.error("Tracker kind missing in WORKFLOW.md")

        state

      {:error, {:unsupported_tracker_kind, kind}} ->
        Logger.error("Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}")

        state

      {:error, {:invalid_workflow_config, message}} ->
        Logger.error("Invalid WORKFLOW.md config: #{message}")
        state

      {:error, {:missing_workflow_file, path, reason}} ->
        Logger.error("Missing WORKFLOW.md at #{path}: #{inspect(reason)}")
        state

      {:error, :workflow_front_matter_not_a_map} ->
        Logger.error("Failed to parse WORKFLOW.md: workflow front matter must decode to a map")
        state

      {:error, {:workflow_parse_error, reason}} ->
        Logger.error("Failed to parse WORKFLOW.md: #{inspect(reason)}")
        state

      {:error, reason} ->
        Logger.error("Failed to fetch from issue tracker: #{inspect(reason)}")
        state

      false ->
        state
    end
  end

  defp reconcile_running_issues(%State{} = state) do
    state = reconcile_stalled_running_issues(state)

    Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
      reconcile_bound_running_issue(state_acc, issue_id, running_entry)
    end)
  end

  defp reconcile_blocked_issues(%State{} = state) do
    Enum.reduce(state.blocked, state, fn {issue_id, blocked_entry}, state_acc ->
      reconcile_bound_blocked_issue(state_acc, issue_id, blocked_entry)
    end)
  end

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    tracker_settings = Config.settings!().tracker

    reconcile_running_issue_states(
      issues,
      state,
      active_state_set(tracker_settings),
      terminal_state_set(tracker_settings),
      tracker_settings.required_labels
    )
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    tracker_settings = Config.settings!().tracker

    reconcile_running_issue_states(
      issues,
      state,
      active_state_set(tracker_settings),
      terminal_state_set(tracker_settings),
      tracker_settings.required_labels
    )
  end

  @doc false
  @spec reconcile_blocked_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_blocked_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    tracker_settings = Config.settings!().tracker

    reconcile_blocked_issue_states(
      issues,
      state,
      active_state_set(tracker_settings),
      terminal_state_set(tracker_settings),
      tracker_settings.required_labels,
      Map.get(tracker_settings, :working_state),
      Map.get(tracker_settings, :blocked_state)
    )
  end

  @doc false
  @spec handle_retry_issue_lookup_for_test(Issue.t(), term(), String.t(), non_neg_integer(), map()) ::
          term()
  def handle_retry_issue_lookup_for_test(%Issue{} = issue, %State{} = state, issue_id, attempt, metadata)
      when is_binary(issue_id) and is_integer(attempt) and attempt >= 0 and is_map(metadata) do
    {:noreply, updated_state} = handle_retry_issue_lookup(issue, state, issue_id, attempt, metadata)
    updated_state
  end

  @doc false
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state) do
    settings = Config.settings!()

    should_dispatch_issue?(
      issue,
      state,
      active_state_set(settings.tracker),
      terminal_state_set(settings.tracker),
      settings
    )
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch(issue, issue_fetcher, Config.settings!().tracker)
  end

  @doc false
  @spec claim_issue_for_dispatch_for_test(Issue.t(), String.t() | nil, function()) ::
          {:ok, Issue.t()} | {:error, term()}
  def claim_issue_for_dispatch_for_test(%Issue{} = issue, working_state, transitioner)
      when is_function(transitioner, 2) do
    claim_issue_for_dispatch(issue, working_state, transitioner)
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    sort_issues_for_dispatch(issues)
  end

  @doc false
  @spec schedule_claim_failure_for_test(term(), Issue.t(), term()) :: term()
  def schedule_claim_failure_for_test(%State{} = state, %Issue{} = issue, reason) do
    {:ok, current_context} = dispatch_context(Config.settings!())
    schedule_claim_retry(state, issue, nil, nil, reason, current_context)
  end

  @doc false
  @spec select_worker_host_for_test(term(), String.t() | nil) :: String.t() | nil | :no_worker_capacity
  def select_worker_host_for_test(%State{} = state, preferred_worker_host) do
    settings = Config.settings!()
    select_worker_host(state, preferred_worker_host, settings, settings.worker.ssh_hosts)
  end

  @doc false
  @spec reconcile_bound_running_issue_for_test(term(), String.t(), map()) :: term()
  def reconcile_bound_running_issue_for_test(%State{} = state, issue_id, running_entry)
      when is_binary(issue_id) and is_map(running_entry) do
    reconcile_bound_running_issue(state, issue_id, running_entry)
  end

  @doc false
  @spec reconcile_bound_blocked_issue_for_test(term(), String.t(), map()) :: term()
  def reconcile_bound_blocked_issue_for_test(%State{} = state, issue_id, blocked_entry)
      when is_binary(issue_id) and is_map(blocked_entry) do
    reconcile_bound_blocked_issue(state, issue_id, blocked_entry)
  end

  defp reconcile_bound_running_issue(state, issue_id, running_entry) do
    if Map.has_key?(state.running, issue_id) do
      do_reconcile_bound_running_issue(state, issue_id, running_entry)
    else
      state
    end
  end

  defp do_reconcile_bound_running_issue(state, issue_id, running_entry) do
    with {:ok, context} <- dispatch_context_from_entry(running_entry),
         {:ok, issues} <- Tracker.fetch_bound_issues_by_ids(context.tracker_binding, [issue_id]) do
      reconcile_bound_running_result(state, issue_id, issues, context)
    else
      {:error, reason} ->
        Logger.debug("Failed to refresh running issue state issue_id=#{issue_id}: #{inspect(reason)}; keeping active worker")
        state
    end
  end

  defp reconcile_bound_running_result(state, issue_id, issues, context) do
    case find_issue_by_id(issues, issue_id) do
      %Issue{} = issue ->
        tracker_settings = context.settings.tracker

        reconcile_issue_state(
          issue,
          state,
          active_state_set(tracker_settings),
          terminal_state_set(tracker_settings),
          tracker_settings.required_labels
        )

      nil ->
        log_missing_running_issue(state, issue_id)
        terminate_running_issue(state, issue_id, false)
    end
  end

  defp reconcile_bound_blocked_issue(state, issue_id, blocked_entry) do
    if Map.has_key?(state.blocked, issue_id) do
      do_reconcile_bound_blocked_issue(state, issue_id, blocked_entry)
    else
      state
    end
  end

  defp do_reconcile_bound_blocked_issue(state, issue_id, blocked_entry) do
    with {:ok, context} <- dispatch_context_from_entry(blocked_entry),
         {:ok, issues} <- Tracker.fetch_bound_issues_by_ids(context.tracker_binding, [issue_id]) do
      reconcile_bound_blocked_result(state, issue_id, issues, context)
    else
      {:error, reason} ->
        Logger.debug("Failed to refresh blocked issue state issue_id=#{issue_id}: #{inspect(reason)}; keeping blocked issue")
        state
    end
  end

  defp reconcile_bound_blocked_result(state, issue_id, issues, context) do
    case find_issue_by_id(issues, issue_id) do
      %Issue{} = issue ->
        tracker_settings = context.settings.tracker

        case ensure_bound_blocked_state(issue, context) do
          {:ok, %Issue{} = refreshed_issue} ->
            reconcile_blocked_issue_state(
              refreshed_issue,
              state,
              active_state_set(tracker_settings),
              terminal_state_set(tracker_settings),
              tracker_settings.required_labels,
              Map.get(tracker_settings, :working_state),
              Map.get(tracker_settings, :blocked_state)
            )

          {:error, reason} ->
            Logger.warning("Failed to move blocked issue to configured tracker state issue_id=#{issue_id}: #{inspect(reason)}; keeping blocked issue")
            put_blocked_transition_error(state, issue_id, reason)
        end

      nil ->
        Logger.info("Blocked issue no longer visible during state refresh: issue_id=#{issue_id}; releasing block")
        release_issue_claim(state, issue_id)
    end
  end

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states, _required_labels),
    do: state

  defp reconcile_running_issue_states(
         [issue | rest],
         state,
         active_states,
         terminal_states,
         required_labels
       ) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states, required_labels),
      active_states,
      terminal_states,
      required_labels
    )
  end

  defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states, required_labels) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, true)

      !issue_routable?(issue, required_labels) ->
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        terminate_running_issue(state, issue.id, false)

      active_issue_state?(issue.state, active_states) ->
        refresh_running_issue_state(state, issue)

      true ->
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, false)
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states, _required_labels),
    do: state

  defp reconcile_blocked_issue_states(
         [],
         state,
         _active_states,
         _terminal_states,
         _required_labels,
         _working_state,
         _blocked_state
       ),
       do: state

  defp reconcile_blocked_issue_states(
         [issue | rest],
         state,
         active_states,
         terminal_states,
         required_labels,
         working_state,
         blocked_state
       ) do
    reconcile_blocked_issue_states(
      rest,
      reconcile_blocked_issue_state(
        issue,
        state,
        active_states,
        terminal_states,
        required_labels,
        working_state,
        blocked_state
      ),
      active_states,
      terminal_states,
      required_labels,
      working_state,
      blocked_state
    )
  end

  defp reconcile_blocked_issue_state(
         %Issue{} = issue,
         state,
         active_states,
         terminal_states,
         required_labels,
         working_state,
         blocked_state
       ) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Blocked issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; releasing block")
        cleanup_issue_workspace(issue, Map.get(state.blocked, issue.id, %{}))
        release_issue_claim(state, issue.id)

      !issue_routable?(issue, required_labels) ->
        Logger.info("Blocked issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; releasing block")
        release_issue_claim(state, issue.id)

      same_issue_state?(issue.state, blocked_state) ->
        refresh_blocked_issue_state(state, issue)

      present_string?(blocked_state) and active_issue_state?(issue.state, active_states) and
          !same_issue_state?(issue.state, working_state) ->
        Logger.info("Blocked issue moved back to an active queue state: #{issue_context(issue)} state=#{issue.state}; releasing block for retry")
        release_issue_claim(state, issue.id)

      active_issue_state?(issue.state, active_states) ->
        refresh_blocked_issue_state(state, issue)

      true ->
        Logger.info("Blocked issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; releasing block")
        release_issue_claim(state, issue.id)
    end
  end

  defp reconcile_blocked_issue_state(
         _issue,
         state,
         _active_states,
         _terminal_states,
         _required_labels,
         _working_state,
         _blocked_state
       ),
       do: state

  defp log_missing_running_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{identifier: identifier} ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id} issue_identifier=#{identifier}; stopping active agent")

      _ ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
    end
  end

  defp log_missing_running_issue(_state, _issue_id), do: :ok

  defp refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp refresh_blocked_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.blocked, issue.id) do
      %{issue: _} = blocked_entry ->
        %{state | blocked: Map.put(state.blocked, issue.id, %{blocked_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace) do
    case Map.get(state.running, issue_id) do
      nil ->
        release_issue_claim(state, issue_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        state = record_session_completion_totals(state, running_entry)

        stop_running_task(
          pid,
          ref,
          state.task_supervisor,
          Map.get(running_entry, :cancellation_pid),
          {:orchestrator_reconcile, cleanup_workspace}
        )

        if cleanup_workspace do
          cleanup_issue_workspace(Map.get(running_entry, :issue, identifier), running_entry)
        end

        %{
          state
          | running: Map.delete(state.running, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id),
            blocked: Map.delete(state.blocked, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id)
        }

      _ ->
        release_issue_claim(state, issue_id)
    end
  end

  defp reconcile_stalled_running_issues(%State{} = state) do
    if map_size(state.running) == 0 do
      state
    else
      now = DateTime.utc_now()
      legacy_timeout_ms = Config.settings!().codex.stall_timeout_ms

      Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
        reconcile_stalled_entry(
          state_acc,
          issue_id,
          running_entry,
          now,
          legacy_timeout_ms
        )
      end)
    end
  end

  defp reconcile_stalled_entry(state, issue_id, running_entry, now, legacy_timeout_ms) do
    timeout_ms = Map.get(running_entry, :stall_timeout_ms, legacy_timeout_ms)

    if is_integer(timeout_ms) and timeout_ms > 0 do
      maybe_restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms)
    else
      state
    end
  end

  defp maybe_restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    if Map.has_key?(state.blocked, issue_id) do
      state
    else
      restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms)
    end
  end

  defp restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    elapsed_ms = stall_elapsed_ms(running_entry, now)

    if is_integer(elapsed_ms) and elapsed_ms > timeout_ms do
      identifier = Map.get(running_entry, :identifier, issue_id)
      session_id = running_entry_session_id(running_entry)

      if input_required_blocker?(running_entry) do
        error = blocker_error(running_entry, "stalled for #{elapsed_ms}ms after the agent requested operator input")

        Logger.warning("Issue blocked: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; #{error}")

        stop_and_block_issue(state, issue_id, running_entry, error)
      else
        Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; restarting with backoff")

        next_attempt = next_retry_attempt_from_running(running_entry)

        state
        |> terminate_running_issue(issue_id, false)
        |> schedule_issue_retry(
          issue_id,
          next_attempt,
          retry_metadata_from_running(running_entry, %{
            identifier: identifier,
            error: "stalled for #{elapsed_ms}ms without agent activity"
          })
        )
      end
    else
      state
    end
  end

  defp stall_elapsed_ms(running_entry, now) do
    running_entry
    |> last_activity_timestamp()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  defp last_activity_timestamp(running_entry) do
    Map.get(running_entry, :last_agent_timestamp) ||
      Map.get(running_entry, :last_codex_timestamp) ||
      Map.get(running_entry, :started_at)
  end

  defp input_required_blocker?(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_agent_event) == :input_required or
      Map.get(running_entry, :last_codex_event) in [:turn_input_required, :approval_required] or
      not is_nil(input_required_completion_outcome(Map.get(running_entry, :completion))) or
      codex_message_method(Map.get(running_entry, :last_codex_message)) ==
        "mcpServer/elicitation/request"
  end

  defp input_required_blocker?(_running_entry), do: false

  defp input_required_completion_outcome(%AgentTurnResult{status: :blocked}),
    do: :input_required

  defp input_required_completion_outcome(completion) when is_map(completion) do
    outcome = Map.get(completion, :outcome) || Map.get(completion, "outcome")
    normalize_input_required_outcome(outcome)
  end

  defp input_required_completion_outcome(_completion), do: nil

  defp normalize_input_required_outcome(outcome)
       when outcome in [:input_required, :needs_input, :approval_required],
       do: outcome

  defp normalize_input_required_outcome(outcome) when is_binary(outcome) do
    case outcome do
      "input_required" -> :input_required
      "needs_input" -> :needs_input
      "approval_required" -> :approval_required
      _ -> nil
    end
  end

  defp normalize_input_required_outcome(_outcome), do: nil

  defp blocker_error(running_entry, fallback) when is_map(running_entry) do
    codex_event_blocker_error(Map.get(running_entry, :last_codex_event)) ||
      completion_blocker_error(Map.get(running_entry, :completion)) ||
      codex_message_blocker_error(Map.get(running_entry, :last_codex_message)) ||
      fallback
  end

  defp blocker_error(_running_entry, fallback), do: fallback

  defp codex_event_blocker_error(:turn_input_required), do: "codex turn requires operator input"
  defp codex_event_blocker_error(:approval_required), do: "codex turn requires approval"
  defp codex_event_blocker_error(_event), do: nil

  defp completion_blocker_error(%AgentTurnResult{status: :blocked}) do
    "agent turn requires operator input"
  end

  defp completion_blocker_error(completion) do
    case input_required_completion_outcome(completion) do
      outcome when outcome in [:input_required, :needs_input] -> "codex turn requires operator input"
      :approval_required -> "codex turn requires approval"
      nil -> nil
    end
  end

  defp codex_message_blocker_error(message) do
    if codex_message_method(message) == "mcpServer/elicitation/request" do
      "codex MCP elicitation requires operator input"
    end
  end

  defp codex_message_method(%{message: %{"method" => method}}) when is_binary(method), do: method
  defp codex_message_method(%{message: %{method: method}}) when is_binary(method), do: method
  defp codex_message_method(%{"method" => method}) when is_binary(method), do: method
  defp codex_message_method(%{method: method}) when is_binary(method), do: method
  defp codex_message_method(_message), do: nil

  defp terminate_task(pid, task_supervisor) when is_pid(pid) do
    case Task.Supervisor.terminate_child(task_supervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid, _task_supervisor), do: :ok

  defp stop_running_task(pid, ref, task_supervisor, cancellation_pid, reason) do
    case AgentRunner.cancel(cancellation_pid, reason) do
      :ok -> :ok
      {:error, cancel_reason} -> Logger.warning("Agent session cancellation failed: #{inspect(cancel_reason)}")
    end

    if is_pid(pid) do
      terminate_task(pid, task_supervisor)
    end

    if is_reference(ref) do
      Process.demonitor(ref, [:flush])
    end

    :ok
  end

  defp stop_and_block_issue(%State{} = state, issue_id, running_entry, error) do
    case transition_entry_to_blocked(running_entry) do
      {:ok, transitioned_entry} ->
        state = record_session_completion_totals(state, transitioned_entry)

        stop_running_task(
          Map.get(transitioned_entry, :pid),
          Map.get(transitioned_entry, :ref),
          state.task_supervisor,
          Map.get(transitioned_entry, :cancellation_pid),
          {:input_required, error}
        )

        put_blocked_issue(state, issue_id, transitioned_entry, error)

      {:error, reason} ->
        Logger.warning("Failed to move blocked issue to configured tracker state issue_id=#{issue_id}: #{inspect(reason)}; leaving agent running for retry")
        state
    end
  end

  defp block_issue_from_entry(%State{} = state, issue_id, running_entry, error) do
    case transition_entry_to_blocked(running_entry) do
      {:ok, transitioned_entry} ->
        put_blocked_issue(state, issue_id, transitioned_entry, error)

      {:error, reason} ->
        Logger.warning("Failed to move exited blocked issue to configured tracker state issue_id=#{issue_id}: #{inspect(reason)}; retaining blocked issue for transition retry")

        state
        |> put_blocked_issue(issue_id, running_entry, error)
        |> put_blocked_transition_error(issue_id, reason)
    end
  end

  defp put_blocked_issue(%State{} = state, issue_id, running_entry, error) do
    blocked_entry = %{
      issue_id: issue_id,
      identifier: Map.get(running_entry, :identifier, issue_id),
      issue: Map.get(running_entry, :issue),
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path),
      backend: Map.get(running_entry, :backend),
      profile: Map.get(running_entry, :profile),
      ready_actor: Map.get(running_entry, :ready_actor),
      execution_route: Map.get(running_entry, :execution_route),
      settings_snapshot: Map.get(running_entry, :settings_snapshot),
      tracker_binding: Map.get(running_entry, :tracker_binding),
      session_id: running_entry_session_id(running_entry),
      turn_id: Map.get(running_entry, :turn_id),
      error: error,
      blocked_at: DateTime.utc_now(),
      completion: Map.get(running_entry, :completion),
      mcp: Map.get(running_entry, :mcp),
      ssh_tunnel: Map.get(running_entry, :ssh_tunnel),
      last_agent_message: Map.get(running_entry, :last_agent_message),
      last_agent_event: Map.get(running_entry, :last_agent_event),
      last_agent_timestamp: Map.get(running_entry, :last_agent_timestamp),
      last_codex_message: Map.get(running_entry, :last_codex_message),
      last_codex_event: Map.get(running_entry, :last_codex_event),
      last_codex_timestamp: Map.get(running_entry, :last_codex_timestamp)
    }

    %{
      state
      | running: Map.delete(state.running, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id),
        claimed: MapSet.put(state.claimed, issue_id),
        blocked: Map.put(state.blocked, issue_id, blocked_entry)
    }
  end

  defp transition_entry_to_blocked(running_entry) when is_map(running_entry) do
    with {:ok, context} <- dispatch_context_from_entry(running_entry),
         %Issue{} = issue <- Map.get(running_entry, :issue),
         blocked_state when is_binary(blocked_state) and blocked_state != "" <-
           normalized_optional_state(Map.get(context.settings.tracker, :blocked_state)),
         {:ok, %Issue{} = refreshed_issue} <-
           Tracker.update_issue_state(issue, blocked_state,
             adapter: context.tracker_binding.adapter,
             tracker_settings: context.settings.tracker,
             expected_active_states: [Map.get(context.settings.tracker, :working_state)]
           ) do
      {:ok, %{running_entry | issue: refreshed_issue}}
    else
      nil -> {:ok, running_entry}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_blocked_issue_transition_context}
    end
  end

  defp ensure_bound_blocked_state(%Issue{} = issue, context) do
    tracker_settings = context.settings.tracker
    blocked_state = normalized_optional_state(Map.get(tracker_settings, :blocked_state))
    working_state = normalized_optional_state(Map.get(tracker_settings, :working_state))

    cond do
      is_nil(blocked_state) ->
        {:ok, issue}

      same_issue_state?(issue.state, blocked_state) ->
        {:ok, issue}

      same_issue_state?(issue.state, working_state) ->
        Tracker.update_issue_state(issue, blocked_state,
          adapter: context.tracker_binding.adapter,
          tracker_settings: tracker_settings,
          expected_active_states: [working_state]
        )

      true ->
        {:ok, issue}
    end
  end

  defp put_blocked_transition_error(%State{} = state, issue_id, reason) do
    case Map.get(state.blocked, issue_id) do
      blocked_entry when is_map(blocked_entry) ->
        updated_entry = Map.put(blocked_entry, :state_transition_error, inspect(reason))
        %{state | blocked: Map.put(state.blocked, issue_id, updated_entry)}

      _other ->
        state
    end
  end

  defp choose_issues(issues, state, dispatch_context) do
    settings = dispatch_context.settings
    active_states = active_state_set(settings.tracker)
    terminal_states = terminal_state_set(settings.tracker)

    issues
    |> sort_issues_for_dispatch()
    |> Enum.reduce(state, fn issue, state_acc ->
      if should_dispatch_issue?(issue, state_acc, active_states, terminal_states, settings) do
        dispatch_issue(state_acc, issue, nil, nil, dispatch_context)
      else
        state_acc
      end
    end)
  end

  defp sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  defp should_dispatch_issue?(
         %Issue{} = issue,
         %State{
           running: running,
           claimed: claimed,
           blocked: blocked,
           retry_attempts: retry_attempts
         } = state,
         active_states,
         terminal_states,
         settings
       ) do
    candidate_issue?(issue, active_states, terminal_states, settings.tracker.required_labels) and
      !MapSet.member?(claimed, issue.id) and
      !Map.has_key?(running, issue.id) and
      !Map.has_key?(blocked, issue.id) and
      !Map.has_key?(retry_attempts, issue.id) and
      available_slots(state) > 0 and
      state_slots_available?(issue, running, settings) and
      candidate_worker_slots_available?(state, settings)
  end

  defp should_dispatch_issue?(_issue, _state, _active_states, _terminal_states, _settings), do: false

  defp state_slots_available?(%Issue{state: issue_state}, running, settings) when is_map(running) do
    limit = max_concurrent_agents_for_state(settings, issue_state)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  defp state_slots_available?(_issue, _running, _settings), do: false

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}}} ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  defp candidate_issue?(
         %Issue{
           id: id,
           identifier: identifier,
           title: title,
           state: state_name
         } = issue,
         active_states,
         terminal_states,
         required_labels
       )
       when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    Enum.all?([id, identifier, title, state_name], &present_string?/1) and
      issue_routable?(issue, required_labels) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  defp candidate_issue?(_issue, _active_states, _terminal_states, _required_labels), do: false

  defp issue_routable?(%Issue{} = issue, required_labels),
    do: Issue.routable?(issue, required_labels)

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  defp same_issue_state?(state_name, expected_state)
       when is_binary(state_name) and is_binary(expected_state) do
    normalize_issue_state(state_name) == normalize_issue_state(expected_state)
  end

  defp same_issue_state?(_state_name, _expected_state), do: false

  defp normalized_optional_state(state_name) when is_binary(state_name) do
    case String.trim(state_name) do
      "" -> nil
      state -> state
    end
  end

  defp normalized_optional_state(_state_name), do: nil

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  defp normalize_issue_state(_state_name), do: ""

  defp terminal_state_set(tracker_settings) do
    tracker_settings.terminal_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp active_state_set(tracker_settings) do
    tracker_settings.active_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp max_concurrent_agents_for_state(settings, state_name) do
    Map.get(
      settings.agent.max_concurrent_agents_by_state,
      Schema.normalize_issue_state(state_name),
      settings.agent.max_concurrent_agents
    )
  end

  defp dispatch_context(settings) do
    with {:ok, tracker_binding} <- Tracker.bind_config(settings.tracker) do
      {:ok, %{settings: settings, tracker_binding: tracker_binding}}
    end
  end

  defp dispatch_context_from_entry(%{
         settings_snapshot: settings,
         tracker_binding: tracker_binding
       })
       when is_map(settings) and is_map(tracker_binding) do
    {:ok, %{settings: settings, tracker_binding: tracker_binding}}
  end

  defp dispatch_context_from_entry(_entry), do: dispatch_context(Config.settings!())

  defp dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host, dispatch_context) do
    case refresh_issue_for_dispatch(issue, dispatch_context, nil) do
      {:ok, %Issue{} = refreshed_issue, %ExecutionRoute{} = execution_route} ->
        do_dispatch_issue(
          state,
          refreshed_issue,
          attempt,
          preferred_worker_host,
          dispatch_context,
          execution_route
        )

      {:skip, _reason} ->
        state

      {:error, reason, execution_route} ->
        schedule_claim_retry(
          state,
          issue,
          attempt,
          preferred_worker_host,
          reason,
          dispatch_context,
          execution_route
        )

      {:error, reason} ->
        schedule_claim_retry(
          state,
          issue,
          attempt,
          preferred_worker_host,
          reason,
          dispatch_context,
          nil
        )
    end
  end

  defp schedule_claim_retry(
         state,
         issue,
         attempt,
         preferred_worker_host,
         reason,
         dispatch_context,
         execution_route \\ nil
       ) do
    schedule_issue_retry(state, issue.id, attempt, %{
      identifier: issue.identifier,
      issue_url: issue.url,
      error: "claim failed: #{inspect(reason)}",
      backend: route_backend(execution_route, dispatch_context.settings),
      worker_host: preferred_worker_host,
      execution_route: execution_route,
      settings_snapshot: dispatch_context.settings,
      tracker_binding: dispatch_context.tracker_binding
    })
  end

  defp refresh_issue_for_dispatch(issue, dispatch_context, execution_route) do
    issue_fetcher = fn issue_ids ->
      Tracker.fetch_bound_issues_by_ids(
        dispatch_context.tracker_binding,
        issue_ids,
        include_routing: is_nil(execution_route) and ExecutionRoute.enabled?(dispatch_context.settings)
      )
    end

    case revalidate_issue_for_dispatch(
           issue,
           issue_fetcher,
           dispatch_context.settings.tracker
         ) do
      {:ok, %Issue{} = refreshed_issue} ->
        resolve_and_claim_issue(refreshed_issue, dispatch_context, execution_route)

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")
        {:skip, :missing}

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        {:skip, refreshed_issue}

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp resolve_and_claim_issue(refreshed_issue, dispatch_context, execution_route) do
    with {:ok, resolved_route} <-
           resolve_execution_route(refreshed_issue, dispatch_context.settings, execution_route) do
      format_claim_result(
        claim_issue_for_dispatch(refreshed_issue, dispatch_context),
        resolved_route
      )
    end
  end

  defp format_claim_result({:ok, claimed_issue}, resolved_route),
    do: {:ok, claimed_issue, resolved_route}

  defp format_claim_result({:error, reason}, resolved_route),
    do: {:error, reason, resolved_route}

  defp resolve_execution_route(_issue, _settings, %ExecutionRoute{} = execution_route),
    do: {:ok, execution_route}

  defp resolve_execution_route(%Issue{} = issue, settings, nil),
    do: ExecutionRoute.resolve(issue, settings)

  defp claim_issue_for_dispatch(%Issue{} = issue, dispatch_context) do
    tracker_settings = dispatch_context.settings.tracker

    claim_issue_for_dispatch(issue, tracker_settings.working_state, fn candidate, state ->
      Tracker.update_issue_state(candidate, state,
        adapter: dispatch_context.tracker_binding.adapter,
        tracker_settings: tracker_settings,
        expected_active_states: tracker_settings.active_states,
        require_dispatchable: true
      )
    end)
  end

  defp claim_issue_for_dispatch(%Issue{} = issue, working_state, transitioner)
       when is_function(transitioner, 2) do
    normalized_working_state = normalize_issue_state(working_state)

    cond do
      normalized_working_state == "" ->
        {:ok, issue}

      normalize_issue_state(issue.state) == normalized_working_state ->
        {:ok, issue}

      true ->
        issue
        |> then(&transitioner.(&1, working_state))
        |> confirm_claim_transition(normalized_working_state, working_state)
    end
  end

  defp confirm_claim_transition(
         {:ok, %Issue{} = refreshed_issue},
         normalized_working_state,
         working_state
       ) do
    if normalize_issue_state(refreshed_issue.state) == normalized_working_state do
      {:ok, refreshed_issue}
    else
      {:error, {:claim_transition_failed, {:state_confirmation_mismatch, working_state, refreshed_issue.state}}}
    end
  end

  defp confirm_claim_transition({:error, reason}, _normalized_working_state, _working_state),
    do: {:error, {:claim_transition_failed, reason}}

  defp confirm_claim_transition(other, _normalized_working_state, _working_state),
    do: {:error, {:claim_transition_failed, {:invalid_transition_response, other}}}

  defp do_dispatch_issue(
         %State{} = state,
         issue,
         attempt,
         preferred_worker_host,
         dispatch_context,
         %ExecutionRoute{} = execution_route
       ) do
    recipient = self()

    case select_worker_host(
           state,
           preferred_worker_host,
           dispatch_context.settings,
           execution_route.worker_hosts
         ) do
      :no_worker_capacity ->
        Logger.debug("No SSH worker slots available for #{issue_context(issue)} profile=#{execution_route.profile || "default"} preferred_worker_host=#{inspect(preferred_worker_host)}")

        schedule_issue_retry(state, issue.id, attempt, %{
          identifier: issue.identifier,
          issue_url: issue.url,
          error: "no worker capacity for execution profile",
          backend: execution_route.backend,
          worker_host: preferred_worker_host,
          execution_route: execution_route,
          settings_snapshot: dispatch_context.settings,
          tracker_binding: dispatch_context.tracker_binding
        })

      worker_host ->
        spawn_issue_on_worker_host(
          state,
          issue,
          attempt,
          recipient,
          worker_host,
          dispatch_context,
          execution_route
        )
    end
  end

  defp spawn_issue_on_worker_host(
         %State{} = state,
         issue,
         attempt,
         recipient,
         worker_host,
         dispatch_context,
         %ExecutionRoute{} = execution_route
       ) do
    settings = dispatch_context.settings

    case Task.Supervisor.start_child(state.task_supervisor, fn ->
           AgentRunner.run(issue, recipient,
             attempt: attempt,
             worker_host: worker_host,
             execution_route: execution_route,
             settings_snapshot: settings
           )
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        Logger.info(
          "Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} profile=#{execution_route.profile || "default"} backend=#{execution_route.backend} worker_host=#{worker_host || "local"}"
        )

        running =
          Map.put(state.running, issue.id, %{
            pid: pid,
            ref: ref,
            identifier: issue.identifier,
            issue: issue,
            worker_host: worker_host,
            workspace_path: nil,
            session_id: nil,
            turn_id: nil,
            backend: execution_route.backend,
            profile: execution_route.profile,
            ready_actor: execution_route.ready_actor,
            execution_route: execution_route,
            settings_snapshot: settings,
            tracker_binding: dispatch_context.tracker_binding,
            cancellation_pid: nil,
            stall_timeout_ms: backend_stall_timeout(settings, execution_route.backend),
            completion: nil,
            mcp: nil,
            ssh_tunnel: nil,
            last_agent_message: nil,
            last_agent_timestamp: nil,
            last_agent_event: nil,
            agent_process_pid: nil,
            agent_input_tokens: 0,
            agent_cached_input_tokens: 0,
            agent_output_tokens: 0,
            agent_total_tokens: 0,
            agent_usage_turn_id: nil,
            agent_last_reported_input_tokens: 0,
            agent_last_reported_cached_input_tokens: 0,
            agent_last_reported_output_tokens: 0,
            agent_last_reported_total_tokens: 0,
            last_codex_message: nil,
            last_codex_timestamp: nil,
            last_codex_event: nil,
            codex_app_server_pid: nil,
            codex_input_tokens: 0,
            codex_output_tokens: 0,
            codex_total_tokens: 0,
            codex_last_reported_input_tokens: 0,
            codex_last_reported_output_tokens: 0,
            codex_last_reported_total_tokens: 0,
            turn_count: 0,
            retry_attempt: normalize_retry_attempt(attempt),
            started_at: DateTime.utc_now()
          })

        %{
          state
          | running: running,
            claimed: MapSet.put(state.claimed, issue.id),
            retry_attempts: Map.delete(state.retry_attempts, issue.id)
        }

      {:error, reason} ->
        Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        schedule_issue_retry(state, issue.id, next_attempt, %{
          identifier: issue.identifier,
          issue_url: issue.url,
          error: "failed to spawn agent: #{inspect(reason)}",
          backend: execution_route.backend,
          worker_host: worker_host,
          execution_route: execution_route,
          settings_snapshot: settings,
          tracker_binding: dispatch_context.tracker_binding
        })
    end
  end

  defp backend_stall_timeout(%{claude: claude}, "claude"),
    do: claude.stall_timeout_ms

  defp backend_stall_timeout(%{codex: codex}, _backend), do: codex.stall_timeout_ms

  defp revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, tracker_settings)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if retry_candidate_issue?(refreshed_issue, tracker_settings) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _tracker_settings), do: {:ok, issue}

  defp complete_issue(%State{} = state, issue_id) do
    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    delay_ms = retry_delay(next_attempt, metadata)
    old_timer = Map.get(previous_retry, :timer_ref)
    retry_token = make_ref()
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    issue_url = pick_retry_issue_url(previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)
    backend = pick_retry_backend(previous_retry, metadata)
    worker_host = pick_retry_worker_host(previous_retry, metadata)
    workspace_path = pick_retry_workspace_path(previous_retry, metadata)
    execution_route = metadata[:execution_route] || Map.get(previous_retry, :execution_route)
    settings_snapshot = metadata[:settings_snapshot] || Map.get(previous_retry, :settings_snapshot)
    tracker_binding = metadata[:tracker_binding] || Map.get(previous_retry, :tracker_binding)

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)

    error_suffix = if is_binary(error), do: " error=#{error}", else: ""

    Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{next_attempt})#{error_suffix}")

    %{
      state
      | retry_attempts:
          Map.put(state.retry_attempts, issue_id, %{
            attempt: next_attempt,
            timer_ref: timer_ref,
            retry_token: retry_token,
            due_at_ms: due_at_ms,
            identifier: identifier,
            issue_url: issue_url,
            error: error,
            backend: backend,
            worker_host: worker_host,
            workspace_path: workspace_path,
            execution_route: execution_route,
            settings_snapshot: settings_snapshot,
            tracker_binding: tracker_binding
          })
    }
  end

  defp pop_retry_attempt_state(%State{} = state, issue_id, retry_token) when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          issue_url: Map.get(retry_entry, :issue_url),
          error: Map.get(retry_entry, :error),
          backend: Map.get(retry_entry, :backend),
          worker_host: Map.get(retry_entry, :worker_host),
          workspace_path: Map.get(retry_entry, :workspace_path),
          execution_route: Map.get(retry_entry, :execution_route),
          settings_snapshot: Map.get(retry_entry, :settings_snapshot),
          tracker_binding: Map.get(retry_entry, :tracker_binding)
        }

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end

  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    with {:ok, context} <- dispatch_context_from_entry(metadata),
         {:ok, issues} <- Tracker.fetch_bound_issues_by_ids(context.tracker_binding, [issue_id]) do
      issues
      |> find_issue_by_id(issue_id)
      |> handle_retry_issue_lookup(state, issue_id, attempt, Map.put(metadata, :dispatch_context, context))
    else
      {:error, reason} ->
        Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")

        {:noreply,
         schedule_issue_retry(
           state,
           issue_id,
           attempt + 1,
           Map.merge(metadata, %{error: "retry poll failed: #{inspect(reason)}"})
         )}
    end
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    {:ok, context} = retry_dispatch_context(metadata)
    tracker_settings = context.settings.tracker
    terminal_states = terminal_state_set(tracker_settings)

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        cleanup_issue_workspace(issue, metadata)
        {:noreply, release_issue_claim(state, issue_id)}

      retry_candidate_issue?(issue, tracker_settings) ->
        handle_active_retry(state, issue, attempt, metadata, context)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, _metadata) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    {:noreply, release_issue_claim(state, issue_id)}
  end

  defp retry_dispatch_context(%{dispatch_context: context}) when is_map(context),
    do: {:ok, context}

  defp retry_dispatch_context(metadata), do: dispatch_context_from_entry(metadata)

  defp cleanup_issue_workspace(identifier, worker_host \\ nil)

  defp cleanup_issue_workspace(issue_or_identifier, metadata) when is_map(metadata) do
    case Map.get(metadata, :workspace_path) do
      workspace_path when is_binary(workspace_path) and workspace_path != "" ->
        Workspace.remove_recorded(workspace_path, Map.get(metadata, :worker_host))

      _ ->
        cleanup_issue_workspace(issue_or_identifier, Map.get(metadata, :worker_host))
    end
  end

  defp cleanup_issue_workspace(%Issue{} = issue, worker_host) do
    Workspace.remove_issue_workspaces(issue, worker_host)
  end

  defp cleanup_issue_workspace(identifier, worker_host) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier, worker_host)
  end

  defp cleanup_issue_workspace(_issue_or_identifier, _worker_host), do: :ok

  defp run_terminal_workspace_cleanup do
    case Tracker.fetch_issues_by_states(Config.settings!().tracker.terminal_states) do
      {:ok, issues} ->
        issues
        |> Enum.each(fn
          %Issue{} = issue ->
            cleanup_issue_workspace(issue)

          _ ->
            :ok
        end)

      {:error, reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
    end
  end

  defp notify_dashboard do
    StatusDashboard.notify_update()
  end

  defp handle_active_retry(state, issue, attempt, metadata, dispatch_context) do
    execution_route = Map.get(metadata, :execution_route)

    if retry_candidate_issue?(issue, dispatch_context.settings.tracker) and
         dispatch_slots_available?(issue, state, dispatch_context.settings) and
         retry_worker_slots_available?(
           state,
           metadata[:worker_host],
           dispatch_context.settings,
           execution_route
         ) do
      case refresh_issue_for_dispatch(issue, dispatch_context, execution_route) do
        {:ok, %Issue{} = refreshed_issue, %ExecutionRoute{} = resolved_route} ->
          {:noreply,
           do_dispatch_issue(
             state,
             refreshed_issue,
             attempt,
             metadata[:worker_host],
             dispatch_context,
             resolved_route
           )}

        {:skip, :missing} ->
          {:noreply, release_issue_claim(state, issue.id)}

        {:skip, %Issue{} = refreshed_issue} ->
          handle_retry_issue_lookup(refreshed_issue, state, issue.id, attempt, metadata)

        {:error, reason, resolved_route} ->
          {:noreply,
           schedule_issue_retry(
             state,
             issue.id,
             attempt + 1,
             Map.merge(metadata, %{
               identifier: issue.identifier,
               error: "retry dispatch refresh failed: #{inspect(reason)}",
               execution_route: resolved_route
             })
           )}

        {:error, reason} ->
          {:noreply,
           schedule_issue_retry(
             state,
             issue.id,
             attempt + 1,
             Map.merge(metadata, %{
               identifier: issue.identifier,
               error: "retry dispatch refresh failed: #{inspect(reason)}"
             })
           )}
      end
    else
      Logger.debug("No available slots for retrying #{issue_context(issue)}; retrying again")

      {:noreply,
       schedule_issue_retry(
         state,
         issue.id,
         attempt + 1,
         Map.merge(metadata, %{
           identifier: issue.identifier,
           error: "no available orchestrator slots"
         })
       )}
    end
  end

  defp release_issue_claim(%State{} = state, issue_id) do
    %{
      state
      | claimed: MapSet.delete(state.claimed, issue_id),
        blocked: Map.delete(state.blocked, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp retry_delay(attempt, metadata) when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    if metadata[:delay_type] == :continuation and attempt == 1 do
      @continuation_retry_delay_ms
    else
      failure_retry_delay(attempt, retry_max_backoff_ms(metadata))
    end
  end

  defp failure_retry_delay(attempt, max_retry_backoff_ms) do
    max_delay_power = min(attempt - 1, 10)
    min(@failure_retry_base_ms * (1 <<< max_delay_power), max_retry_backoff_ms)
  end

  defp retry_max_backoff_ms(%{
         settings_snapshot: %{agent: %{max_retry_backoff_ms: max_retry_backoff_ms}}
       })
       when is_integer(max_retry_backoff_ms) and max_retry_backoff_ms > 0,
       do: max_retry_backoff_ms

  defp retry_max_backoff_ms(_metadata),
    do: Config.settings!().agent.max_retry_backoff_ms

  defp retry_metadata_from_running(running_entry, extra) do
    Map.merge(
      %{
        identifier: running_entry.identifier,
        issue_url: running_entry.issue.url,
        backend: Map.get(running_entry, :backend),
        worker_host: Map.get(running_entry, :worker_host),
        workspace_path: Map.get(running_entry, :workspace_path),
        execution_route: Map.get(running_entry, :execution_route),
        settings_snapshot: Map.get(running_entry, :settings_snapshot),
        tracker_binding: Map.get(running_entry, :tracker_binding)
      },
      extra
    )
  end

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

  defp next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_issue_url(previous_retry, metadata) do
    metadata[:issue_url] || Map.get(previous_retry, :issue_url)
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp pick_retry_backend(previous_retry, metadata) do
    metadata[:backend] || Map.get(previous_retry, :backend)
  end

  defp pick_retry_worker_host(previous_retry, metadata) do
    metadata[:worker_host] || Map.get(previous_retry, :worker_host)
  end

  defp pick_retry_workspace_path(previous_retry, metadata) do
    metadata[:workspace_path] || Map.get(previous_retry, :workspace_path)
  end

  defp maybe_put_runtime_value(running_entry, _key, nil), do: running_entry

  defp maybe_put_runtime_value(running_entry, key, value) when is_map(running_entry) do
    Map.put(running_entry, key, value)
  end

  defp select_worker_host(%State{} = state, preferred_worker_host, settings, worker_hosts) do
    case worker_hosts do
      [] ->
        nil

      hosts ->
        available_hosts = Enum.filter(hosts, &worker_host_slots_available?(state, &1, settings))

        cond do
          available_hosts == [] ->
            :no_worker_capacity

          preferred_worker_host_available?(preferred_worker_host, available_hosts) ->
            preferred_worker_host

          true ->
            least_loaded_worker_host(state, available_hosts)
        end
    end
  end

  defp preferred_worker_host_available?(preferred_worker_host, hosts)
       when is_binary(preferred_worker_host) and is_list(hosts) do
    preferred_worker_host != "" and preferred_worker_host in hosts
  end

  defp preferred_worker_host_available?(_preferred_worker_host, _hosts), do: false

  defp least_loaded_worker_host(%State{} = state, hosts) when is_list(hosts) do
    hosts
    |> Enum.with_index()
    |> Enum.min_by(fn {host, index} ->
      {running_worker_host_count(state.running, host), index}
    end)
    |> elem(0)
  end

  defp running_worker_host_count(running, worker_host) when is_map(running) and is_binary(worker_host) do
    Enum.count(running, fn
      {_issue_id, %{worker_host: ^worker_host}} -> true
      _ -> false
    end)
  end

  defp worker_slots_available?(%State{} = state, preferred_worker_host, settings) do
    select_worker_host(state, preferred_worker_host, settings, settings.worker.ssh_hosts) !=
      :no_worker_capacity
  end

  defp candidate_worker_slots_available?(%State{} = state, settings) do
    ExecutionRoute.enabled?(settings) or worker_slots_available?(state, nil, settings)
  end

  defp retry_worker_slots_available?(
         %State{} = state,
         preferred_worker_host,
         settings,
         %ExecutionRoute{worker_hosts: worker_hosts}
       ) do
    select_worker_host(state, preferred_worker_host, settings, worker_hosts) != :no_worker_capacity
  end

  defp retry_worker_slots_available?(state, preferred_worker_host, settings, _execution_route),
    do:
      ExecutionRoute.enabled?(settings) or
        worker_slots_available?(state, preferred_worker_host, settings)

  defp route_backend(%ExecutionRoute{backend: backend}, _settings), do: backend
  defp route_backend(_execution_route, settings), do: settings.agent.backend

  defp route_value(%ExecutionRoute{} = route, key), do: Map.get(route, key)
  defp route_value(_execution_route, _key), do: nil

  defp worker_host_slots_available?(%State{} = state, worker_host, settings) when is_binary(worker_host) do
    case settings.worker.max_concurrent_agents_per_host do
      limit when is_integer(limit) and limit > 0 ->
        running_worker_host_count(state.running, worker_host) < limit

      _ ->
        true
    end
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp available_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || Config.settings!().agent.max_concurrent_agents) -
        map_size(state.running),
      0
    )
  end

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if Process.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    running =
      state.running
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: metadata.identifier,
          issue_url: metadata.issue.url,
          state: metadata.issue.state,
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          backend: Map.get(metadata, :backend),
          profile: Map.get(metadata, :profile),
          ready_actor: Map.get(metadata, :ready_actor),
          eligible_worker_hosts: route_value(Map.get(metadata, :execution_route), :worker_hosts),
          session_id: metadata.session_id,
          turn_id: Map.get(metadata, :turn_id),
          agent_process_pid: Map.get(metadata, :agent_process_pid),
          mcp: Map.get(metadata, :mcp),
          ssh_tunnel: Map.get(metadata, :ssh_tunnel),
          agent_input_tokens: agent_metric(metadata, :input_tokens),
          agent_cached_input_tokens: agent_metric(metadata, :cached_input_tokens),
          agent_output_tokens: agent_metric(metadata, :output_tokens),
          agent_total_tokens: agent_metric(metadata, :total_tokens),
          last_agent_timestamp: Map.get(metadata, :last_agent_timestamp) || Map.get(metadata, :last_codex_timestamp),
          last_agent_message: Map.get(metadata, :last_agent_message) || Map.get(metadata, :last_codex_message),
          last_agent_event: Map.get(metadata, :last_agent_event) || Map.get(metadata, :last_codex_event),
          codex_app_server_pid: Map.get(metadata, :codex_app_server_pid),
          codex_input_tokens: Map.get(metadata, :codex_input_tokens, 0),
          codex_output_tokens: Map.get(metadata, :codex_output_tokens, 0),
          codex_total_tokens: Map.get(metadata, :codex_total_tokens, 0),
          turn_count: Map.get(metadata, :turn_count, 0),
          started_at: metadata.started_at,
          last_codex_timestamp: Map.get(metadata, :last_codex_timestamp),
          last_codex_message: Map.get(metadata, :last_codex_message),
          last_codex_event: Map.get(metadata, :last_codex_event),
          runtime_seconds: running_seconds(metadata.started_at, now)
        }
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: Map.get(retry, :identifier),
          issue_url: Map.get(retry, :issue_url),
          error: Map.get(retry, :error),
          backend: Map.get(retry, :backend),
          profile: route_value(Map.get(retry, :execution_route), :profile),
          ready_actor: route_value(Map.get(retry, :execution_route), :ready_actor),
          eligible_worker_hosts: route_value(Map.get(retry, :execution_route), :worker_hosts),
          worker_host: Map.get(retry, :worker_host),
          workspace_path: Map.get(retry, :workspace_path)
        }
      end)

    blocked =
      state.blocked
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: Map.get(metadata, :identifier),
          issue_url: blocked_issue_url(metadata),
          state: blocked_issue_state(metadata),
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          backend: Map.get(metadata, :backend),
          profile: Map.get(metadata, :profile),
          ready_actor: Map.get(metadata, :ready_actor),
          eligible_worker_hosts: route_value(Map.get(metadata, :execution_route), :worker_hosts),
          session_id: Map.get(metadata, :session_id),
          mcp: Map.get(metadata, :mcp),
          ssh_tunnel: Map.get(metadata, :ssh_tunnel),
          error: Map.get(metadata, :error),
          blocked_at: Map.get(metadata, :blocked_at),
          last_agent_timestamp: Map.get(metadata, :last_agent_timestamp) || Map.get(metadata, :last_codex_timestamp),
          last_agent_message: Map.get(metadata, :last_agent_message) || Map.get(metadata, :last_codex_message),
          last_agent_event: Map.get(metadata, :last_agent_event) || Map.get(metadata, :last_codex_event),
          last_codex_timestamp: Map.get(metadata, :last_codex_timestamp),
          last_codex_message: Map.get(metadata, :last_codex_message),
          last_codex_event: Map.get(metadata, :last_codex_event)
        }
      end)

    {:reply,
     %{
       running: running,
       retrying: retrying,
       blocked: blocked,
       agent_totals: state.agent_totals,
       agent_rate_limits: Map.get(state, :agent_rate_limits),
       codex_totals: state.codex_totals,
       rate_limits: Map.get(state, :codex_rate_limits),
       polling: %{
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms
       }
     }, state}
  end

  def handle_call(:request_refresh, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?
    state = if coalesced, do: state, else: schedule_tick(state, 0)

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  defp blocked_issue_state(%{issue: %Issue{state: state}}), do: state
  defp blocked_issue_state(_metadata), do: nil

  defp blocked_issue_url(%{issue: %Issue{url: url}}), do: url
  defp blocked_issue_url(_metadata), do: nil

  defp agent_metric(metadata, :input_tokens) do
    max(Map.get(metadata, :agent_input_tokens, 0), Map.get(metadata, :codex_input_tokens, 0))
  end

  defp agent_metric(metadata, :cached_input_tokens),
    do: Map.get(metadata, :agent_cached_input_tokens, 0)

  defp agent_metric(metadata, :output_tokens) do
    max(Map.get(metadata, :agent_output_tokens, 0), Map.get(metadata, :codex_output_tokens, 0))
  end

  defp agent_metric(metadata, :total_tokens) do
    max(Map.get(metadata, :agent_total_tokens, 0), Map.get(metadata, :codex_total_tokens, 0))
  end

  defp integrate_codex_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = extract_token_delta(running_entry, update)
    codex_input_tokens = Map.get(running_entry, :codex_input_tokens, 0)
    codex_output_tokens = Map.get(running_entry, :codex_output_tokens, 0)
    codex_total_tokens = Map.get(running_entry, :codex_total_tokens, 0)
    codex_app_server_pid = Map.get(running_entry, :codex_app_server_pid)
    last_reported_input = Map.get(running_entry, :codex_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :codex_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :codex_last_reported_total_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)

    {
      Map.merge(running_entry, %{
        last_codex_timestamp: timestamp,
        last_codex_message: summarize_codex_update(update),
        session_id: legacy_compatible_session_id(running_entry, update),
        legacy_session_id: session_id_for_update(Map.get(running_entry, :legacy_session_id), update),
        last_codex_event: event,
        codex_app_server_pid: codex_app_server_pid_for_update(codex_app_server_pid, update),
        codex_input_tokens: codex_input_tokens + token_delta.input_tokens,
        codex_output_tokens: codex_output_tokens + token_delta.output_tokens,
        codex_total_tokens: codex_total_tokens + token_delta.total_tokens,
        codex_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        codex_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        codex_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        turn_count: legacy_compatible_turn_count(running_entry, turn_count, update)
      }),
      token_delta
    }
  end

  defp integrate_agent_update(running_entry, %AgentEvent{} = event) do
    existing_turn_id = Map.get(running_entry, :turn_id)
    turn_count = Map.get(running_entry, :turn_count, 0)

    updated_turn_count =
      if event.kind == :turn_started and is_binary(event.turn_id) and
           event.turn_id != existing_turn_id do
        turn_count + 1
      else
        turn_count
      end

    {running_entry, token_delta} = integrate_agent_usage(running_entry, event)

    updated_entry =
      running_entry
      |> Map.merge(%{
        backend: event.backend,
        last_agent_event: event.kind,
        last_agent_timestamp: event.timestamp,
        last_agent_message: %{
          kind: event.kind,
          payload: event.payload,
          timestamp: event.timestamp
        },
        turn_count: updated_turn_count
      })
      |> maybe_put_runtime_value(:session_id, event.session_id)
      |> maybe_put_runtime_value(:turn_id, event.turn_id)
      |> maybe_put_runtime_value(:agent_process_pid, event.metadata[:os_pid])
      |> maybe_put_runtime_value(:mcp, event.metadata[:mcp])
      |> maybe_put_runtime_value(:ssh_tunnel, event.metadata[:ssh_tunnel])

    {updated_entry, token_delta}
  end

  defp sync_backend_read_aliases(running_entry, %AgentEvent{backend: backend} = event)
       when backend in [:codex, "codex"] do
    native = event_native_payload(event)
    native_event = native_value(native, :event)
    native_session_id = native_value(native, :session_id)

    running_entry
    |> Map.merge(codex_metric_aliases(running_entry))
    |> Map.merge(%{
      codex_app_server_pid: Map.get(running_entry, :agent_process_pid),
      last_codex_event: native_event || event.kind,
      last_codex_message: legacy_codex_message(event, native, native_event),
      last_codex_timestamp: event.timestamp
    })
    |> maybe_put_runtime_value(:legacy_session_id, native_session_id)
  end

  defp sync_backend_read_aliases(running_entry, _event), do: running_entry

  defp event_native_payload(%AgentEvent{payload: payload}) do
    Map.get(payload, :native) || Map.get(payload, "native")
  end

  defp native_value(native, key) when is_map(native),
    do: Map.get(native, key) || Map.get(native, Atom.to_string(key))

  defp native_value(_native, _key), do: nil

  defp legacy_codex_message(event, native, native_event) when is_map(native) do
    %{
      event: native_event || event.kind,
      message: native_value(native, :payload) || native,
      timestamp: event.timestamp
    }
  end

  defp legacy_codex_message(event, _native, _native_event) do
    %{event: event.kind, message: event.payload, timestamp: event.timestamp}
  end

  defp codex_metric_aliases(running_entry) do
    %{
      codex_input_tokens: Map.get(running_entry, :agent_input_tokens, 0),
      codex_last_reported_input_tokens: Map.get(running_entry, :agent_last_reported_input_tokens, 0),
      codex_last_reported_output_tokens: Map.get(running_entry, :agent_last_reported_output_tokens, 0),
      codex_last_reported_total_tokens: Map.get(running_entry, :agent_last_reported_total_tokens, 0),
      codex_output_tokens: Map.get(running_entry, :agent_output_tokens, 0),
      codex_total_tokens: Map.get(running_entry, :agent_total_tokens, 0)
    }
  end

  defp integrate_agent_completion(running_entry, %AgentTurnResult{} = completion) do
    {running_entry, token_delta} = apply_completion_usage(running_entry, completion)

    updated_running_entry =
      running_entry
      |> Map.put(:completion, completion)
      |> maybe_put_runtime_value(:backend, completion.backend)
      |> maybe_put_runtime_value(:session_id, completion.session_id)
      |> maybe_put_runtime_value(:turn_id, completion.turn_id)

    {updated_running_entry, token_delta}
  end

  defp sync_backend_completion_aliases(running_entry, %AgentTurnResult{backend: backend})
       when backend in [:codex, "codex"] do
    Map.merge(running_entry, codex_metric_aliases(running_entry))
  end

  defp sync_backend_completion_aliases(running_entry, _completion), do: running_entry

  defp apply_completion_usage(running_entry, %AgentTurnResult{} = completion) do
    usage_values = [completion.input_tokens, completion.cached_input_tokens, completion.output_tokens]

    if Enum.any?(usage_values, &(is_integer(&1) and &1 >= 0)) do
      previous_input = completion_previous_usage(running_entry, completion.turn_id, :input_tokens)
      previous_cached = completion_previous_usage(running_entry, completion.turn_id, :cached_input_tokens)
      previous_output = completion_previous_usage(running_entry, completion.turn_id, :output_tokens)
      previous_total = completion_previous_usage(running_entry, completion.turn_id, :total_tokens)

      input = known_or_previous(completion.input_tokens, previous_input)
      cached = known_or_previous(completion.cached_input_tokens, previous_cached)
      output = known_or_previous(completion.output_tokens, previous_output)
      total = input + cached + output

      delta = %{
        input_tokens: input - previous_input,
        cached_input_tokens: cached - previous_cached,
        output_tokens: output - previous_output,
        total_tokens: total - previous_total,
        seconds_running: 0
      }

      updated_running_entry =
        Map.merge(running_entry, %{
          agent_input_tokens: max(0, Map.get(running_entry, :agent_input_tokens, 0) + delta.input_tokens),
          agent_cached_input_tokens: max(0, Map.get(running_entry, :agent_cached_input_tokens, 0) + delta.cached_input_tokens),
          agent_output_tokens: max(0, Map.get(running_entry, :agent_output_tokens, 0) + delta.output_tokens),
          agent_total_tokens: max(0, Map.get(running_entry, :agent_total_tokens, 0) + delta.total_tokens),
          agent_usage_turn_id: completion.turn_id,
          agent_completed_usage_turn_id: completion.turn_id,
          agent_last_reported_input_tokens: input,
          agent_last_reported_cached_input_tokens: cached,
          agent_last_reported_output_tokens: output,
          agent_last_reported_total_tokens: total
        })

      {updated_running_entry, delta}
    else
      {running_entry, empty_token_delta()}
    end
  end

  defp completion_previous_usage(running_entry, turn_id, key) do
    if Map.get(running_entry, :agent_usage_turn_id) == turn_id do
      Map.get(running_entry, completion_reported_key(key), 0)
    else
      0
    end
  end

  defp completion_reported_key(:input_tokens), do: :agent_last_reported_input_tokens
  defp completion_reported_key(:cached_input_tokens), do: :agent_last_reported_cached_input_tokens
  defp completion_reported_key(:output_tokens), do: :agent_last_reported_output_tokens
  defp completion_reported_key(:total_tokens), do: :agent_last_reported_total_tokens

  defp known_or_previous(value, _previous) when is_integer(value) and value >= 0, do: value
  defp known_or_previous(_value, previous), do: previous

  defp integrate_agent_usage(running_entry, %AgentEvent{
         kind: :usage_updated,
         turn_id: turn_id,
         payload: payload
       }) do
    if Map.get(running_entry, :agent_completed_usage_turn_id) == turn_id do
      {running_entry, empty_token_delta()}
    else
      case Map.get(payload, :usage) || Map.get(payload, "usage") do
        usage when is_map(usage) -> apply_agent_usage_snapshot(running_entry, usage, turn_id)
        _ -> {running_entry, empty_token_delta()}
      end
    end
  end

  defp integrate_agent_usage(running_entry, _event),
    do: {running_entry, empty_token_delta()}

  defp apply_agent_usage_snapshot(running_entry, usage, turn_id) do
    same_turn? = Map.get(running_entry, :agent_usage_turn_id) == turn_id
    previous_input = if same_turn?, do: Map.get(running_entry, :agent_last_reported_input_tokens, 0), else: 0

    previous_cached =
      if same_turn?, do: Map.get(running_entry, :agent_last_reported_cached_input_tokens, 0), else: 0

    previous_output =
      if same_turn?, do: Map.get(running_entry, :agent_last_reported_output_tokens, 0), else: 0

    previous_total =
      if same_turn?, do: Map.get(running_entry, :agent_last_reported_total_tokens, 0), else: 0

    input = usage_integer(usage, :input_tokens)
    cached = usage_integer(usage, :cached_input_tokens)
    output = usage_integer(usage, :output_tokens)
    total = input + cached + output

    delta = %{
      input_tokens: max(0, input - previous_input),
      cached_input_tokens: max(0, cached - previous_cached),
      output_tokens: max(0, output - previous_output),
      total_tokens: max(0, total - previous_total),
      seconds_running: 0
    }

    updated_entry =
      Map.merge(running_entry, %{
        agent_input_tokens: Map.get(running_entry, :agent_input_tokens, 0) + delta.input_tokens,
        agent_cached_input_tokens: Map.get(running_entry, :agent_cached_input_tokens, 0) + delta.cached_input_tokens,
        agent_output_tokens: Map.get(running_entry, :agent_output_tokens, 0) + delta.output_tokens,
        agent_total_tokens: Map.get(running_entry, :agent_total_tokens, 0) + delta.total_tokens,
        agent_usage_turn_id: turn_id,
        agent_last_reported_input_tokens: max(previous_input, input),
        agent_last_reported_cached_input_tokens: max(previous_cached, cached),
        agent_last_reported_output_tokens: max(previous_output, output),
        agent_last_reported_total_tokens: max(previous_total, total)
      })

    {updated_entry, delta}
  end

  defp usage_integer(usage, key) do
    case Map.get(usage, key) || Map.get(usage, Atom.to_string(key)) do
      value when is_integer(value) and value >= 0 -> value
      _ -> 0
    end
  end

  defp empty_token_delta do
    %{
      input_tokens: 0,
      cached_input_tokens: 0,
      output_tokens: 0,
      total_tokens: 0,
      seconds_running: 0
    }
  end

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_binary(pid),
       do: pid

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp codex_app_server_pid_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  defp legacy_compatible_session_id(running_entry, update) do
    if Map.get(running_entry, :last_agent_timestamp) do
      Map.get(running_entry, :session_id)
    else
      session_id_for_update(Map.get(running_entry, :session_id), update)
    end
  end

  defp legacy_compatible_turn_count(running_entry, existing_count, update) do
    if Map.get(running_entry, :last_agent_event) == :turn_started and
         Map.get(running_entry, :turn_id) == Map.get(update, :turn_id) do
      existing_count
    else
      turn_count_for_update(existing_count, Map.get(running_entry, :session_id), update)
    end
  end

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp summarize_codex_update(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      timestamp: update[:timestamp]
    }
  end

  defp schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    tick_token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, tick_token}, delay_ms)

    %{
      state
      | tick_timer_ref: timer_ref,
        tick_token: tick_token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    runtime_delta = %{
      input_tokens: 0,
      cached_input_tokens: 0,
      output_tokens: 0,
      total_tokens: 0,
      seconds_running: runtime_seconds
    }

    agent_totals = apply_token_delta(state.agent_totals, runtime_delta)

    codex_totals =
      if Map.get(running_entry, :backend) in [:codex, "codex"] do
        apply_token_delta(state.codex_totals, runtime_delta)
      else
        state.codex_totals
      end

    %{state | agent_totals: agent_totals, codex_totals: codex_totals}
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  defp refresh_runtime_config(%State{} = state) do
    config = Config.settings!()

    %{
      state
      | poll_interval_ms: config.polling.interval_ms,
        max_concurrent_agents: config.agent.max_concurrent_agents
    }
  end

  defp retry_candidate_issue?(%Issue{} = issue, tracker_settings) do
    candidate_issue?(
      issue,
      active_state_set(tracker_settings),
      terminal_state_set(tracker_settings),
      tracker_settings.required_labels
    )
  end

  defp dispatch_slots_available?(%Issue{} = issue, %State{} = state, settings) do
    available_slots(state) > 0 and state_slots_available?(issue, state.running, settings)
  end

  defp apply_codex_token_delta(
         %{codex_totals: codex_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | codex_totals: apply_token_delta(codex_totals, token_delta)}
  end

  defp apply_codex_token_delta(state, _token_delta), do: state

  defp apply_backend_token_delta(state, backend, token_delta) when backend in [:codex, "codex"],
    do: apply_codex_token_delta(state, token_delta)

  defp apply_backend_token_delta(state, _backend, _token_delta), do: state

  defp apply_agent_token_delta(
         %{agent_totals: agent_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | agent_totals: apply_token_delta(agent_totals, token_delta)}
  end

  defp apply_agent_token_delta(state, _token_delta), do: state

  defp apply_agent_rate_limits(%State{} = state, %AgentEvent{payload: payload, backend: backend}) do
    case Map.get(payload, :rate_limits) || Map.get(payload, "rate_limits") do
      %{} = rate_limits ->
        state = %{state | agent_rate_limits: rate_limits}

        if backend in [:codex, "codex"] do
          %{state | codex_rate_limits: rate_limits}
        else
          state
        end

      _ ->
        state
    end
  end

  defp apply_codex_rate_limits(%State{} = state, update) when is_map(update) do
    case extract_rate_limits(update) do
      %{} = rate_limits ->
        %{state | codex_rate_limits: rate_limits}

      _ ->
        state
    end
  end

  defp apply_codex_rate_limits(state, _update), do: state

  defp apply_token_delta(codex_totals, token_delta) do
    codex_totals = codex_totals || @empty_agent_totals
    input_tokens = Map.get(codex_totals, :input_tokens, 0) + token_delta.input_tokens

    cached_input_tokens =
      Map.get(codex_totals, :cached_input_tokens, 0) +
        Map.get(token_delta, :cached_input_tokens, 0)

    output_tokens = Map.get(codex_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(codex_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(codex_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      cached_input_tokens: max(0, cached_input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  defp extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    running_entry = running_entry || %{}
    usage = extract_token_usage(update)

    {
      compute_token_delta(
        running_entry,
        :input,
        usage,
        :codex_last_reported_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :output,
        usage,
        :codex_last_reported_output_tokens
      ),
      compute_token_delta(
        running_entry,
        :total,
        usage,
        :codex_last_reported_total_tokens
      )
    }
    |> Tuple.to_list()
    |> then(fn [input, output, total] ->
      %{
        input_tokens: input.delta,
        output_tokens: output.delta,
        total_tokens: total.delta,
        input_reported: input.reported,
        output_reported: output.reported,
        total_reported: total.reported
      }
    end)
  end

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end

  defp extract_token_usage(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      %{}
  end

  defp extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    explicit_map_at_paths(payload, absolute_paths)
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage])

      if is_map(direct) and integer_token_map?(direct), do: direct
    end
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload) do
    Map.values(payload)
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp explicit_map_at_paths(_payload, _paths), do: nil

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_at_path(_payload, _path), do: nil

  defp integer_token_map?(payload) do
    token_fields = [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    token_fields
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  defp get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  defp get_token_usage(usage, :total),
    do:
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ])

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil
end
