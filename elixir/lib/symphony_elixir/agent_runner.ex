defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single tracker work item with the configured agent backend.
  """

  require Logger
  alias SymphonyElixir.{AgentBackend, AgentEvent, AgentTurnResult, Config, PromptBuilder, Tracker, Workspace}
  alias SymphonyElixir.Tracker.Issue

  @type worker_host :: String.t() | nil
  @cancellation_timeout_ms 15_000

  @spec cancel(pid() | nil, term(), timeout()) :: :ok | {:error, term()}
  def cancel(cancellation_pid, reason, timeout \\ @cancellation_timeout_ms) do
    if is_pid(cancellation_pid) and is_integer(timeout) and timeout > 0 do
      do_cancel(cancellation_pid, reason, timeout)
    else
      :ok
    end
  end

  defp do_cancel(cancellation_pid, reason, timeout) do
    request_ref = make_ref()
    monitor_ref = Process.monitor(cancellation_pid)
    send(cancellation_pid, {:cancel_agent_session, self(), request_ref, reason})

    receive do
      {:agent_session_cancelled, ^request_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        normalize_stop_result(result)

      {:DOWN, ^monitor_ref, :process, ^cancellation_pid, reason} ->
        {:error, {:cancellation_guardian_down, reason}}
    after
      timeout ->
        Process.demonitor(monitor_ref, [:flush])
        {:error, :cancellation_timeout}
    end
  end

  @doc false
  @spec continue_with_issue_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:continue, Issue.t()} | {:done, Issue.t()} | {:error, term()}
  def continue_with_issue_for_test(%Issue{} = issue, issue_state_fetcher)
      when is_function(issue_state_fetcher, 1) do
    continue_with_issue?(issue, issue_state_fetcher)
  end

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, agent_update_recipient \\ nil, opts \\ []) do
    settings = Keyword.get_lazy(opts, :settings_snapshot, &Config.settings!/0)
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), settings.worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    result =
      with {:ok, backend} <- selected_backend(settings, opts),
           :ok <- backend.validate_config(settings),
           :ok <- backend.validate_host(settings, worker_host) do
        run_on_worker_host(
          issue,
          agent_update_recipient,
          opts,
          worker_host,
          backend,
          settings
        )
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, agent_update_recipient, opts, worker_host, backend, settings) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(
          agent_update_recipient,
          issue,
          worker_host,
          workspace,
          backend.name()
        )

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_agent_turns(
              workspace,
              issue,
              agent_update_recipient,
              opts,
              worker_host,
              backend,
              settings
            )
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp agent_event_handler(recipient, issue) do
    fn %AgentEvent{} = event ->
      send_agent_update(recipient, issue, event)
    end
  end

  defp send_agent_update(recipient, %Issue{id: issue_id}, %AgentEvent{} = event)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:agent_worker_update, issue_id, event})
    :ok
  end

  defp send_agent_update(_recipient, _issue, _event), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace, backend)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace,
         backend: backend
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace, _backend), do: :ok

  defp run_agent_turns(workspace, issue, agent_update_recipient, opts, worker_host, backend, settings) do
    max_turns = Keyword.get(opts, :max_turns, settings.agent.max_turns)
    on_event = agent_event_handler(agent_update_recipient, issue)
    tool_session = AgentBackend.bind_tracker_tools(issue, settings.tracker)

    issue_state_fetcher =
      Keyword.get(opts, :issue_state_fetcher, fn issue_ids ->
        Tracker.fetch_bound_issues_by_ids(tool_session, issue_ids)
      end)

    backend_opts =
      opts
      |> Keyword.get(:backend_options, [])
      |> Keyword.put(:worker_host, worker_host)
      |> Keyword.put(:on_event, on_event)
      |> Keyword.put(:settings, settings)

    run_context = %{
      workspace: workspace,
      agent_update_recipient: agent_update_recipient,
      opts: opts,
      issue_state_fetcher: issue_state_fetcher,
      max_turns: max_turns,
      backend: backend,
      on_event: on_event,
      tracker_settings: settings.tracker
    }

    with {:ok, session} <- backend.start_session(workspace, issue, tool_session, backend_opts) do
      cancellation_pid = start_cancellation_guardian(backend, session)
      send_cancellation_ready(agent_update_recipient, issue, cancellation_pid)

      try do
        case do_run_agent_turns(session, issue, 1, run_context) do
          {:ok, final_session} ->
            stop_session(backend, final_session, :normal, cancellation_pid)

          {:error, reason, final_session} ->
            case stop_session(backend, final_session, reason, cancellation_pid) do
              :ok -> {:error, reason}
              {:error, cleanup_reason} -> {:error, {reason, {:backend_cleanup_failed, cleanup_reason}}}
            end
        end
      rescue
        exception ->
          _ = stop_session(backend, session, {:exception, exception}, cancellation_pid)
          reraise exception, __STACKTRACE__
      catch
        kind, reason ->
          _ = stop_session(backend, session, {kind, reason}, cancellation_pid)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    end
  end

  defp start_cancellation_guardian(backend, session) do
    owner = self()

    cancellation_pid =
      spawn(fn ->
        owner_ref = Process.monitor(owner)
        cancellation_guardian_loop(owner_ref, backend, session)
      end)

    detach_session_process(session)
    cancellation_pid
  end

  defp detach_session_process(%{pid: session_pid}) when is_pid(session_pid) do
    Process.unlink(session_pid)
    :ok
  end

  defp detach_session_process(_session), do: :ok

  defp cancellation_guardian_loop(owner_ref, backend, session) do
    receive do
      {:cancel_agent_session, caller, request_ref, reason}
      when is_pid(caller) and is_reference(request_ref) ->
        result = safe_stop_session(backend, session, reason)
        send(caller, {:agent_session_cancelled, request_ref, result})
        Process.demonitor(owner_ref, [:flush])

      {:disarm_cancellation_guardian, caller, request_ref}
      when is_pid(caller) and is_reference(request_ref) ->
        send(caller, {:cancellation_guardian_disarmed, request_ref})
        Process.demonitor(owner_ref, [:flush])

      {:DOWN, ^owner_ref, :process, _owner, reason} ->
        _ = safe_stop_session(backend, session, {:runner_down, reason})
        :ok
    end
  end

  defp stop_session(backend, session, reason, cancellation_pid) do
    result = safe_stop_session(backend, session, reason)
    disarm_cancellation_guardian(cancellation_pid)
    normalize_stop_result(result)
  end

  defp safe_stop_session(backend, session, reason) do
    backend.stop_session(session, reason)
  rescue
    exception -> {:error, {:exception, exception}}
  catch
    kind, caught_reason -> {:error, {kind, caught_reason}}
  end

  defp disarm_cancellation_guardian(cancellation_pid) when is_pid(cancellation_pid) do
    request_ref = make_ref()
    monitor_ref = Process.monitor(cancellation_pid)
    send(cancellation_pid, {:disarm_cancellation_guardian, self(), request_ref})

    receive do
      {:cancellation_guardian_disarmed, ^request_ref} ->
        Process.demonitor(monitor_ref, [:flush])
        :ok

      {:DOWN, ^monitor_ref, :process, ^cancellation_pid, _reason} ->
        :ok
    after
      1_000 ->
        Process.demonitor(monitor_ref, [:flush])
        :ok
    end
  end

  defp normalize_stop_result(:ok), do: :ok
  defp normalize_stop_result({:error, reason}), do: {:error, reason}
  defp normalize_stop_result(other), do: {:error, {:invalid_backend_stop_result, other}}

  defp send_cancellation_ready(recipient, %Issue{id: issue_id}, cancellation_pid)
       when is_binary(issue_id) and is_pid(recipient) and is_pid(cancellation_pid) do
    send(recipient, {:agent_cancellation_ready, issue_id, cancellation_pid})
    :ok
  end

  defp send_cancellation_ready(_recipient, _issue, _cancellation_pid), do: :ok

  defp do_run_agent_turns(session, issue, turn_number, context) do
    prompt = build_turn_prompt(issue, context.opts, turn_number, context.max_turns)

    case context.backend.run_turn(session, prompt, issue, on_event: context.on_event) do
      {:ok, %AgentTurnResult{} = result, updated_session} ->
        Logger.info(
          "Completed agent run for #{issue_context(issue)} backend=#{context.backend.name()} session_id=#{result.session_id} workspace=#{context.workspace} turn=#{turn_number}/#{context.max_turns}"
        )

        case continue_with_issue?(
               issue,
               context.issue_state_fetcher,
               context.tracker_settings
             ) do
          {:continue, refreshed_issue} when turn_number < context.max_turns ->
            Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{context.max_turns}")

            do_run_agent_turns(
              updated_session,
              refreshed_issue,
              turn_number + 1,
              context
            )

          {:continue, refreshed_issue} ->
            Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")
            send_agent_completion(context.agent_update_recipient, issue, result)
            {:ok, updated_session}

          {:done, _refreshed_issue} ->
            send_agent_completion(context.agent_update_recipient, issue, result)
            {:ok, updated_session}

          {:error, reason} ->
            send_agent_completion(context.agent_update_recipient, issue, result)
            {:error, reason, updated_session}
        end

      {:blocked, %AgentTurnResult{} = result, updated_session} ->
        send_agent_completion(context.agent_update_recipient, issue, result)
        {:error, result.failure_reason || :input_required, updated_session}

      {:error, reason, updated_session} ->
        {:error, reason, updated_session}
    end
  end

  defp send_agent_completion(recipient, %Issue{id: issue_id}, %AgentTurnResult{} = result)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:agent_worker_completed, issue_id, result})
    :ok
  end

  defp send_agent_completion(_recipient, _issue, _result), do: :ok

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous agent turn completed normally, but the tracker work item is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    continue_with_issue?(issue, issue_state_fetcher, Config.settings!().tracker)
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp continue_with_issue?(
         %Issue{id: issue_id} = issue,
         issue_state_fetcher,
         tracker_settings
       )
       when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state, tracker_settings) and
             issue_routable?(refreshed_issue, tracker_settings) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher, _tracker_settings), do: {:done, issue}

  defp active_issue_state?(state_name, tracker_settings) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    tracker_settings.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name, _tracker_settings), do: false

  defp issue_routable?(%Issue{} = issue, tracker_settings) do
    Issue.routable?(issue, tracker_settings.required_labels)
  end

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp selected_backend(settings, opts) do
    case Keyword.get(opts, :backend_module) do
      backend when is_atom(backend) and not is_nil(backend) -> {:ok, backend}
      _ -> AgentBackend.resolve(settings)
    end
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
