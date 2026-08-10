defmodule SymphonyElixir.AgentBackend.Codex do
  @moduledoc """
  `AgentBackend` implementation for the existing Codex app-server client.

  The wrapper normalizes lifecycle values while preserving the app-server's
  public API and native protocol behavior.
  """

  @behaviour SymphonyElixir.AgentBackend

  alias SymphonyElixir.{AgentEvent, AgentTurnResult, Codex.AppServer}
  alias SymphonyElixir.Tracker.Issue

  @impl true
  def name, do: :codex

  @impl true
  def validate_config(%{codex: %{command: command}}) when is_binary(command) do
    if String.trim(command) == "", do: {:error, :invalid_codex_command}, else: :ok
  end

  def validate_config(_settings), do: {:error, :missing_codex_config}

  @impl true
  def validate_host(_settings, _worker_host), do: :ok

  @impl true
  def start_session(workspace, %Issue{} = issue, tool_session, opts) do
    app_server_module = Keyword.get(opts, :app_server_module, AppServer)
    on_event = Keyword.get(opts, :on_event, &default_on_event/1)

    app_server_opts =
      opts
      |> Keyword.drop([:app_server_module, :on_event])
      |> Keyword.put(:dynamic_tool_binding, tool_session)

    case app_server_module.start_session(workspace, app_server_opts) do
      {:ok, app_session} ->
        session_id = app_session[:thread_id]

        session = %{
          app_server_module: app_server_module,
          app_session: app_session,
          issue_id: issue.id,
          on_event: on_event,
          session_id: session_id,
          thread_usage: nil,
          turn_id: nil,
          tool_session: tool_session
        }

        emit_event(on_event, :session_started, issue.id, session_id, nil, %{}, metadata(app_session))
        {:ok, session}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def run_turn(session, prompt, %Issue{} = issue, opts) do
    on_event = Keyword.get(opts, :on_event, session.on_event)
    collector_key = {__MODULE__, make_ref()}
    Process.put(collector_key, new_turn_state(session))

    native_handler = fn message ->
      normalize_native_event(on_event, issue, session, collector_key, message)
    end

    app_server_opts = opts |> Keyword.drop([:on_event]) |> Keyword.put(:on_message, native_handler)

    try do
      case session.app_server_module.run_turn(session.app_session, prompt, issue, app_server_opts) do
        {:ok, native_result} ->
          turn_state = Process.get(collector_key, new_turn_state(session)) |> finalize_text()
          updated_session = update_session(session, native_result, turn_state)
          result = completed_result(updated_session, native_result, turn_state)

          emit_event(
            on_event,
            :turn_completed,
            issue.id,
            updated_session.session_id,
            updated_session.turn_id,
            terminal_payload(result),
            metadata(updated_session.app_session)
          )

          {:ok, result, updated_session}

        {:error, reason}
        when is_tuple(reason) and elem(reason, 0) in [:turn_input_required, :approval_required] ->
          turn_state = Process.get(collector_key, new_turn_state(session)) |> finalize_text()
          updated_session = update_session(session, %{}, turn_state)
          result = blocked_result(updated_session, reason, turn_state)
          {:blocked, result, updated_session}

        {:error, reason} ->
          turn_state = Process.get(collector_key, new_turn_state(session))
          {:error, reason, update_session(session, %{}, turn_state)}
      end
    after
      Process.delete(collector_key)
    end
  end

  @impl true
  def stop_session(session, reason) do
    result = session.app_server_module.stop_session(session.app_session)

    emit_event(
      session.on_event,
      :session_stopped,
      session.issue_id,
      session.session_id,
      session.turn_id,
      %{reason: reason},
      metadata(session.app_session)
    )

    result
  end

  defp completed_result(session, native_result, turn_state) do
    usage = turn_state.usage

    %AgentTurnResult{
      backend: :codex,
      session_id: session.session_id,
      turn_id: session.turn_id,
      status: :completed,
      final_text: List.last(turn_state.text_blocks),
      text_blocks: turn_state.text_blocks,
      input_tokens: usage_value(usage, :input_tokens),
      cached_input_tokens: usage_value(usage, :cached_input_tokens),
      output_tokens: usage_value(usage, :output_tokens),
      metadata: %{
        legacy_session_id: native_result[:session_id],
        native_result: native_result[:result],
        native_terminal: turn_state.terminal_native,
        native_usage: turn_state.native_usage,
        usage_source: turn_state.usage_source
      }
    }
  end

  defp blocked_result(session, reason, turn_state) do
    usage = turn_state.usage

    %AgentTurnResult{
      backend: :codex,
      session_id: session.session_id,
      turn_id: session.turn_id,
      status: :blocked,
      final_text: List.last(turn_state.text_blocks),
      text_blocks: turn_state.text_blocks,
      input_tokens: usage_value(usage, :input_tokens),
      cached_input_tokens: usage_value(usage, :cached_input_tokens),
      output_tokens: usage_value(usage, :output_tokens),
      failure_text: "Codex requires operator input",
      failure_reason: reason,
      input_required: true,
      metadata: %{
        native_reason: reason,
        native_usage: turn_state.native_usage,
        usage_source: turn_state.usage_source
      }
    }
  end

  defp update_session(session, native_result, turn_state) do
    %{
      session
      | session_id: native_result[:thread_id] || session.session_id,
        thread_usage: turn_state.latest_thread_usage || session.thread_usage,
        turn_id: native_result[:turn_id] || turn_state.turn_id || session.turn_id
    }
  end

  defp new_turn_state(session) do
    %{
      assistant_buffer: "",
      latest_thread_usage: nil,
      native_usage: nil,
      text_blocks: [],
      thread_usage_baseline: session.thread_usage,
      terminal_native: nil,
      turn_id: session.turn_id,
      usage: nil,
      usage_source: nil
    }
  end

  defp normalize_native_event(on_event, issue, session, collector_key, native) do
    turn_state = Process.get(collector_key, new_turn_state(session))
    {turn_state, events} = native_events(turn_state, native)
    Process.put(collector_key, turn_state)

    Enum.each(events, fn {kind, payload} ->
      emit_native_event(on_event, issue, session, turn_state, native, kind, payload)
    end)

    :ok
  end

  defp native_events(turn_state, %{event: :session_started} = native) do
    turn_id = native[:turn_id] || turn_state.turn_id
    turn_state = %{turn_state | turn_id: turn_id}
    {turn_state, [{:turn_started, %{native: native}}]}
  end

  defp native_events(turn_state, %{event: event} = native)
       when event in [:turn_input_required, :approval_required] do
    payload = %{
      failure_reason: native_failure_reason(native),
      input_required: true,
      native: native,
      questions: native_questions(native)
    }

    {turn_state, [{:input_required, payload}]}
  end

  defp native_events(turn_state, %{event: event} = native)
       when event in [:turn_failed, :turn_cancelled, :turn_ended_with_error, :startup_failed] do
    payload = %{
      error: native_failure_text(native),
      failure_reason: native_failure_reason(native),
      native: native
    }

    {turn_state, [{:turn_failed, payload}]}
  end

  defp native_events(turn_state, %{event: event} = native)
       when event in [:tool_call_completed, :tool_call_failed, :unsupported_tool_call] do
    status = if event == :tool_call_completed, do: :completed, else: :failed
    payload = tool_payload(native, status) |> Map.put(:native, native)
    {turn_state, [{:tool_call_completed, payload}]}
  end

  defp native_events(turn_state, %{event: :turn_completed} = native) do
    usage_events(%{turn_state | terminal_native: native}, native)
  end

  defp native_events(turn_state, %{event: :notification} = native) do
    native_notification_events(turn_state, native, native_method(native))
  end

  defp native_events(turn_state, native) do
    {turn_state, [{:backend_message, %{native: native}}]}
  end

  defp native_notification_events(turn_state, native, method)
       when method in ["item/agentMessage/delta", "codex/event/agent_message_delta", "codex/event/agent_message_content_delta"] do
    case assistant_text(native) do
      text when is_binary(text) and text != "" ->
        turn_state = %{turn_state | assistant_buffer: turn_state.assistant_buffer <> text}
        {turn_state, [{:assistant_text, %{delta: true, native: native, text: text}}]}

      _ ->
        {turn_state, [{:backend_message, %{native: native}}]}
    end
  end

  defp native_notification_events(turn_state, native, "item/completed") do
    case native_item(native) do
      %{} = item -> completed_item_events(turn_state, native, item)
      _ -> {turn_state, [{:backend_message, %{native: native}}]}
    end
  end

  defp native_notification_events(turn_state, native, "item/started") do
    case native_item(native) do
      %{} = item -> lifecycle_item_events(turn_state, native, item, :started)
      _ -> {turn_state, [{:backend_message, %{native: native}}]}
    end
  end

  defp native_notification_events(turn_state, native, method)
       when method in [
              "item/reasoning/summaryTextDelta",
              "item/reasoning/summaryPartAdded",
              "item/reasoning/textDelta",
              "codex/event/agent_reasoning",
              "codex/event/agent_reasoning_delta",
              "codex/event/reasoning_content_delta"
            ] do
    payload = %{native: native} |> maybe_put(:text, reasoning_text(native))
    {turn_state, [{:reasoning_update, payload}]}
  end

  defp native_notification_events(turn_state, native, method)
       when method in ["codex/event/exec_command_begin", "codex/event/mcp_tool_call_begin"] do
    kind = if String.contains?(method, "mcp_tool"), do: :tool_call_started, else: :action_started
    {turn_state, [{kind, action_payload(native, :started) |> Map.put(:native, native)}]}
  end

  defp native_notification_events(turn_state, native, method)
       when method in ["codex/event/exec_command_end", "codex/event/mcp_tool_call_end"] do
    kind = if String.contains?(method, "mcp_tool"), do: :tool_call_completed, else: :action_completed
    {turn_state, [{kind, action_payload(native, :completed) |> Map.put(:native, native)}]}
  end

  defp native_notification_events(turn_state, native, _method) do
    case usage_events(turn_state, native) do
      {^turn_state, []} ->
        payload = %{native: native} |> maybe_put(:rate_limits, native_rate_limits(native))
        {turn_state, [{:backend_message, payload}]}

      usage_result ->
        usage_result
    end
  end

  defp completed_item_events(turn_state, native, item) do
    case normalized_item_type(item) do
      "agentmessage" ->
        complete_assistant_message(turn_state, native, item)

      type when type in ["mcptoolcall", "dynamictoolcall", "toolcall", "websearch"] ->
        lifecycle_item_events(turn_state, native, item, :completed)

      _ ->
        lifecycle_item_events(turn_state, native, item, :completed)
    end
  end

  defp lifecycle_item_events(turn_state, native, item, state) do
    payload = item_payload(item, state) |> Map.put(:native, native)

    kind =
      if normalized_item_type(item) in ["mcptoolcall", "dynamictoolcall", "toolcall", "websearch"] do
        if state == :started, do: :tool_call_started, else: :tool_call_completed
      else
        if state == :started, do: :action_started, else: :action_completed
      end

    {turn_state, [{kind, payload}]}
  end

  defp complete_assistant_message(turn_state, native, item) do
    text = item_text(item)
    streamed? = turn_state.assistant_buffer != ""

    cond do
      is_binary(text) and text != "" ->
        turn_state = %{
          turn_state
          | assistant_buffer: "",
            text_blocks: turn_state.text_blocks ++ [text]
        }

        events = [
          {:assistant_text,
           %{
             delta: false,
             native: native,
             replaces_stream: streamed?,
             text: text
           }}
        ]

        {turn_state, events}

      turn_state.assistant_buffer != "" ->
        text = turn_state.assistant_buffer

        {%{
           turn_state
           | assistant_buffer: "",
             text_blocks: turn_state.text_blocks ++ [text]
         }, [{:backend_message, %{native: native}}]}

      true ->
        {turn_state, [{:backend_message, %{native: native}}]}
    end
  end

  defp finalize_text(%{assistant_buffer: ""} = turn_state), do: turn_state

  defp finalize_text(turn_state) do
    %{turn_state | assistant_buffer: "", text_blocks: turn_state.text_blocks ++ [turn_state.assistant_buffer]}
  end

  defp usage_events(turn_state, native) do
    case native_usage(native) do
      {:thread, usage, native_usage} ->
        baseline = turn_state.thread_usage_baseline || empty_usage()
        turn_usage = subtract_usage(usage, baseline)

        updated_state = %{
          turn_state
          | latest_thread_usage: usage,
            native_usage: native_usage,
            usage: turn_usage,
            usage_source: :thread_total
        }

        {updated_state, [usage_event(turn_usage, native_usage, :thread_total, native)]}

      {:turn, usage, native_usage} ->
        updated_state = %{
          turn_state
          | native_usage: native_usage,
            usage: usage,
            usage_source: :turn
        }

        {updated_state, [usage_event(usage, native_usage, :turn, native)]}

      nil ->
        {turn_state, []}
    end
  end

  defp usage_event(usage, native_usage, source, native) do
    rate_limits = native_rate_limits(native)

    {:usage_updated,
     %{
       accounting: :absolute,
       native: native,
       native_usage: native_usage,
       rate_limits: rate_limits,
       source: source,
       usage: usage
     }}
  end

  defp native_usage(native) do
    payload = native_payload(native)

    thread_usage =
      map_at_any_path(payload, [
        ["params", "msg", "payload", "info", "total_token_usage"],
        [:params, :msg, :payload, :info, :total_token_usage],
        ["params", "msg", "info", "total_token_usage"],
        [:params, :msg, :info, :total_token_usage],
        ["params", "tokenUsage", "total"],
        [:params, :tokenUsage, :total],
        ["tokenUsage", "total"],
        [:tokenUsage, :total]
      ])

    turn_usage =
      if native_method(native) in ["turn/completed", :turn_completed] do
        map_at_any_path(payload, [
          ["usage"],
          [:usage],
          ["params", "usage"],
          [:params, :usage],
          ["params", "tokenUsage"],
          [:params, :tokenUsage]
        ])
      end

    cond do
      is_map(thread_usage) and valid_usage?(thread_usage) ->
        {:thread, normalize_usage(thread_usage), thread_usage}

      is_map(turn_usage) and valid_usage?(turn_usage) ->
        {:turn, normalize_usage(turn_usage), turn_usage}

      true ->
        nil
    end
  end

  defp normalize_usage(usage) do
    %{
      input_tokens: usage_integer(usage, input_token_keys()),
      cached_input_tokens: usage_integer(usage, cached_input_token_keys()),
      output_tokens: usage_integer(usage, output_token_keys())
    }
  end

  defp subtract_usage(usage, baseline) do
    %{
      input_tokens: max(0, usage.input_tokens - baseline.input_tokens),
      cached_input_tokens: max(0, usage.cached_input_tokens - baseline.cached_input_tokens),
      output_tokens: max(0, usage.output_tokens - baseline.output_tokens)
    }
  end

  defp empty_usage, do: %{input_tokens: 0, cached_input_tokens: 0, output_tokens: 0}

  defp valid_usage?(usage) do
    Enum.any?(input_token_keys() ++ cached_input_token_keys() ++ output_token_keys(), fn key ->
      not is_nil(integer_like(Map.get(usage, key)))
    end)
  end

  defp input_token_keys,
    do: ["input_tokens", "prompt_tokens", "inputTokens", "promptTokens", :input_tokens, :prompt_tokens, :inputTokens]

  defp cached_input_token_keys,
    do: ["cached_input_tokens", "cache_read_input_tokens", "cachedInputTokens", :cached_input_tokens, :cachedInputTokens]

  defp output_token_keys,
    do: ["output_tokens", "completion_tokens", "outputTokens", "completionTokens", :output_tokens, :completion_tokens, :outputTokens]

  defp usage_integer(usage, keys) do
    Enum.find_value(keys, 0, fn key -> integer_like(Map.get(usage, key)) end)
  end

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil

  defp usage_value(nil, _key), do: nil
  defp usage_value(usage, key), do: Map.fetch!(usage, key)

  defp terminal_payload(result) do
    %{
      final_text: result.final_text,
      input_required: result.input_required,
      native: result.metadata[:native_terminal],
      status: result.status,
      text_blocks: result.text_blocks,
      usage: %{
        cached_input_tokens: result.cached_input_tokens,
        input_tokens: result.input_tokens,
        output_tokens: result.output_tokens
      }
    }
  end

  defp native_method(native) do
    payload = native_payload(native)
    Map.get(payload, "method") || Map.get(payload, :method)
  end

  defp native_payload(native) do
    case native[:payload] do
      %{} = payload -> payload
      _ -> %{}
    end
  end

  defp native_item(native),
    do: map_at_any_path(native_payload(native), [["params", "item"], [:params, :item]])

  defp normalized_item_type(item) do
    item
    |> value(["type", :type])
    |> to_string_or_empty()
    |> String.downcase()
    |> String.replace(~r/[^a-z]/, "")
  end

  defp item_text(item) do
    text = value(item, ["text", :text, "message", :message])
    if is_binary(text), do: text, else: content_text(value(item, ["content", :content]))
  end

  defp content_text(text) when is_binary(text), do: text

  defp content_text(content) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{} = block -> [value(block, ["text", :text])]
      _ -> []
    end)
    |> Enum.filter(&is_binary/1)
    |> Enum.join("")
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp content_text(_content), do: nil

  defp assistant_text(native) do
    payload = native_payload(native)

    map_at_any_path(payload, [
      ["params", "delta"],
      [:params, :delta],
      ["params", "textDelta"],
      [:params, :textDelta],
      ["params", "msg", "delta"],
      [:params, :msg, :delta],
      ["params", "msg", "content"],
      [:params, :msg, :content],
      ["params", "msg", "payload", "delta"],
      [:params, :msg, :payload, :delta],
      ["params", "msg", "payload", "content"],
      [:params, :msg, :payload, :content]
    ])
  end

  defp reasoning_text(native) do
    map_at_any_path(native_payload(native), [
      ["params", "summaryText"],
      [:params, :summaryText],
      ["params", "textDelta"],
      [:params, :textDelta],
      ["params", "delta"],
      [:params, :delta],
      ["params", "msg", "payload", "summaryText"],
      [:params, :msg, :payload, :summaryText],
      ["params", "msg", "payload", "delta"],
      [:params, :msg, :payload, :delta]
    ])
  end

  defp native_questions(native) do
    map_at_any_path(native_payload(native), [["params", "questions"], [:params, :questions]]) || []
  end

  defp native_failure_reason(native) do
    native[:reason] ||
      map_at_any_path(native_payload(native), [
        ["reason"],
        [:reason],
        ["details"],
        [:details],
        ["params", "error"],
        [:params, :error],
        ["params"],
        [:params]
      ])
  end

  defp native_failure_text(native) do
    reason = native_failure_reason(native)

    cond do
      is_binary(reason) -> reason
      is_map(reason) -> value(reason, ["message", :message, "error", :error])
      true -> nil
    end
  end

  defp tool_payload(native, status) do
    payload = native_payload(native)
    params = value(payload, ["params", :params]) || %{}

    %{
      input: value(params, ["arguments", :arguments, "input", :input]) || %{},
      is_error: status == :failed,
      name: value(params, ["tool", :tool, "name", :name]),
      status: status,
      tool_use_id: value(params, ["itemId", :itemId, "id", :id])
    }
  end

  defp action_payload(native, status) do
    payload = native_payload(native)
    params = value(payload, ["params", :params]) || %{}

    %{
      action_id: value(params, ["call_id", :call_id, "id", :id, "itemId", :itemId]),
      name: value(params, ["command", :command, "name", :name, "tool", :tool]),
      status: status
    }
  end

  defp item_payload(item, status) do
    %{
      action_id: value(item, ["id", :id]),
      input: value(item, ["arguments", :arguments, "input", :input]) || %{},
      is_error: status == :completed and value(item, ["status", :status]) in ["failed", :failed],
      name: value(item, ["name", :name, "tool", :tool, "command", :command]),
      native_type: value(item, ["type", :type]),
      status: value(item, ["status", :status]) || status,
      tool_use_id: value(item, ["id", :id])
    }
  end

  defp native_rate_limits(native) do
    find_rate_limits(native_payload(native))
  end

  defp find_rate_limits(payload) when is_map(payload) do
    direct = value(payload, ["rate_limits", :rate_limits, "rateLimits", :rateLimits])

    cond do
      is_map(direct) -> direct
      rate_limits_map?(payload) -> payload
      true -> Enum.find_value(Map.values(payload), &find_rate_limits/1)
    end
  end

  defp find_rate_limits(payload) when is_list(payload), do: Enum.find_value(payload, &find_rate_limits/1)
  defp find_rate_limits(_payload), do: nil

  defp rate_limits_map?(payload) do
    not is_nil(value(payload, ["limit_id", :limit_id, "limit_name", :limit_name])) and
      Enum.any?(["primary", :primary, "secondary", :secondary, "credits", :credits], &Map.has_key?(payload, &1))
  end

  defp map_at_any_path(payload, paths), do: Enum.find_value(paths, &map_at_path(payload, &1))

  defp map_at_path(payload, path) do
    Enum.reduce_while(path, payload, fn key, current ->
      if is_map(current) and Map.has_key?(current, key) do
        {:cont, Map.get(current, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp value(map, keys) when is_map(map), do: Enum.find_value(keys, &Map.get(map, &1))
  defp value(_map, _keys), do: nil

  defp to_string_or_empty(value) when is_binary(value), do: value
  defp to_string_or_empty(value) when is_atom(value), do: Atom.to_string(value)
  defp to_string_or_empty(_value), do: ""

  defp emit_native_event(on_event, issue, session, turn_state, native, kind, payload) do
    session_id = native[:thread_id] || session.session_id
    turn_id = native[:turn_id] || turn_state.turn_id

    on_event.(%AgentEvent{
      kind: kind,
      backend: :codex,
      issue_id: issue.id,
      session_id: session_id,
      turn_id: turn_id,
      timestamp: native[:timestamp] || DateTime.utc_now(),
      payload: payload,
      metadata: native_metadata(native, session.app_session)
    })
  end

  defp emit_event(on_event, kind, issue_id, session_id, turn_id, payload, event_metadata) do
    on_event.(%AgentEvent{
      kind: kind,
      backend: :codex,
      issue_id: issue_id,
      session_id: session_id,
      turn_id: turn_id,
      timestamp: DateTime.utc_now(),
      payload: payload,
      metadata: event_metadata
    })
  end

  defp native_metadata(native, app_session) do
    app_session
    |> metadata()
    |> maybe_put(:os_pid, native[:codex_app_server_pid])
    |> Map.put(:native_event, native[:event])
  end

  defp metadata(app_session) do
    %{
      worker_host: app_session[:worker_host],
      workspace_path: app_session[:workspace]
    }
    |> maybe_put(:os_pid, get_in(app_session, [:metadata, :codex_app_server_pid]))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp default_on_event(_event), do: :ok
end
