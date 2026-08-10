defmodule SymphonyElixir.Claude.StreamParser do
  @moduledoc """
  Incremental parser for Claude Code's newline-delimited `stream-json` output.

  The parser keeps incomplete lines between calls, normalizes native records
  into `AgentEvent` values, and produces one `AgentTurnResult` at end of stream.
  Usage events are absolute cumulative snapshots. A terminal result's usage is
  authoritative and replaces the sum derived from assistant messages.
  """

  require Logger

  alias SymphonyElixir.{AgentEvent, AgentTurnResult}

  @default_max_line_bytes 1_048_576
  @default_max_malformed_records 3
  @default_max_malformed_context_bytes 512
  @needs_input_sentinel "<!-- symphony:needs-input -->"
  @usage_keys [:input_tokens, :cached_input_tokens, :output_tokens]

  defstruct backend: :claude,
            issue_id: nil,
            turn_id: nil,
            metadata: %{},
            buffer: "",
            line_number: 0,
            max_line_bytes: @default_max_line_bytes,
            max_malformed_records: @default_max_malformed_records,
            max_malformed_context_bytes: @default_max_malformed_context_bytes,
            malformed_records: [],
            session_id: nil,
            init: nil,
            text_blocks: [],
            message_usages: %{},
            anonymous_usage_sequence: 0,
            usage: nil,
            usage_source: nil,
            native_usage: nil,
            terminal: nil

  @type usage :: %{
          input_tokens: non_neg_integer() | nil,
          cached_input_tokens: non_neg_integer() | nil,
          output_tokens: non_neg_integer() | nil
        }

  @type malformed_record :: %{line_number: pos_integer(), context: String.t()}

  @type t :: %__MODULE__{
          backend: atom(),
          issue_id: String.t() | nil,
          turn_id: String.t() | nil,
          metadata: map(),
          buffer: binary(),
          line_number: non_neg_integer(),
          max_line_bytes: pos_integer(),
          max_malformed_records: non_neg_integer(),
          max_malformed_context_bytes: pos_integer(),
          malformed_records: [malformed_record()],
          session_id: String.t() | nil,
          init: map() | nil,
          text_blocks: [String.t()],
          message_usages: %{optional(String.t()) => usage()},
          anonymous_usage_sequence: non_neg_integer(),
          usage: usage() | nil,
          usage_source: :messages | :result | nil,
          native_usage: map() | nil,
          terminal: map() | nil
        }

  @type push_result ::
          {:ok, t(), [AgentEvent.t()]}
          | {:error, term(), t(), [AgentEvent.t()]}

  @doc "Creates parser state for one Claude turn."
  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts) do
    %__MODULE__{
      backend: Keyword.get(opts, :backend, :claude),
      issue_id: Keyword.get(opts, :issue_id),
      turn_id: Keyword.get(opts, :turn_id),
      metadata: Keyword.get(opts, :metadata, %{}),
      max_line_bytes: positive_option!(opts, :max_line_bytes, @default_max_line_bytes),
      max_malformed_records: non_negative_option!(opts, :max_malformed_records, @default_max_malformed_records),
      max_malformed_context_bytes:
        positive_option!(
          opts,
          :max_malformed_context_bytes,
          @default_max_malformed_context_bytes
        )
    }
  end

  @doc "Consumes a binary stream chunk and returns normalized events from complete lines."
  @spec push(t(), binary()) :: push_result()
  def push(%__MODULE__{terminal: terminal} = state, chunk)
      when not is_nil(terminal) and is_binary(chunk) do
    {:error, :stream_already_terminated, state, []}
  end

  def push(%__MODULE__{} = state, chunk) when is_binary(chunk) do
    data = state.buffer <> chunk
    {lines, buffer} = split_complete_lines(data)
    state = %{state | buffer: buffer}

    case consume_lines(lines, state, []) do
      {:ok, next_state, events} ->
        if byte_size(next_state.buffer) <= next_state.max_line_bytes do
          {:ok, next_state, events}
        else
          {:error, {:line_too_long, next_state.line_number + 1, byte_size(next_state.buffer)}, next_state, events}
        end

      {:error, reason, next_state, events} ->
        {:error, reason, next_state, events}
    end
  end

  @doc "Finishes the stream and returns its normalized terminal result."
  @spec finish(t()) ::
          {:ok, AgentTurnResult.t(), [AgentEvent.t()]}
          | {:error, term(), [AgentEvent.t()]}
  def finish(%__MODULE__{} = state) do
    with {:ok, state, events} <- consume_final_buffer(state),
         :ok <- require_terminal(state),
         :ok <- require_success_session(state) do
      {:ok, build_turn_result(state), events}
    else
      {:error, reason, _state, events} -> {:error, reason, events}
      {:error, reason} -> {:error, reason, []}
    end
  end

  @doc "Parses a complete stream in one call."
  @spec parse(binary(), keyword()) ::
          {:ok, AgentTurnResult.t(), [AgentEvent.t()]}
          | {:error, term(), [AgentEvent.t()]}
  def parse(stream, opts \\ []) when is_binary(stream) and is_list(opts) do
    state = new(opts)

    case push(state, stream) do
      {:ok, state, events} ->
        case finish(state) do
          {:ok, result, final_events} -> {:ok, result, events ++ final_events}
          {:error, reason, final_events} -> {:error, reason, events ++ final_events}
        end

      {:error, reason, _state, events} ->
        {:error, reason, events}
    end
  end

  defp consume_final_buffer(%__MODULE__{buffer: ""} = state), do: {:ok, state, []}

  defp consume_final_buffer(%__MODULE__{} = state) do
    line_number = state.line_number + 1
    line = trim_carriage_return(state.buffer)
    state = %{state | buffer: "", line_number: line_number}

    cond do
      byte_size(line) > state.max_line_bytes ->
        {:error, {:line_too_long, line_number, byte_size(line)}, state, []}

      String.trim(line) == "" ->
        {:ok, state, []}

      true ->
        case Jason.decode(line) do
          {:ok, %{} = record} -> consume_record(record, state)
          _ -> {:error, {:incomplete_record, line_number, malformed_context(state, line)}, state, []}
        end
    end
  end

  defp split_complete_lines(data) do
    parts = :binary.split(data, "\n", [:global])
    {buffer, lines} = List.pop_at(parts, -1)
    {lines, buffer}
  end

  defp consume_lines([], state, reversed_events),
    do: {:ok, state, Enum.reverse(reversed_events)}

  defp consume_lines([line | rest], state, reversed_events) do
    line_number = state.line_number + 1
    line = trim_carriage_return(line)
    state = %{state | line_number: line_number}

    cond do
      byte_size(line) > state.max_line_bytes ->
        {:error, {:line_too_long, line_number, byte_size(line)}, state, Enum.reverse(reversed_events)}

      String.trim(line) == "" ->
        consume_lines(rest, state, reversed_events)

      true ->
        case decode_line(line, state) do
          {:ok, next_state, events} ->
            consume_lines(rest, next_state, Enum.reverse(events, reversed_events))

          {:error, reason, next_state, events} ->
            {:error, reason, next_state, Enum.reverse(events, reversed_events)}
        end
    end
  end

  defp decode_line(line, state) do
    case Jason.decode(line) do
      {:ok, %{} = record} -> consume_record(record, state)
      {:ok, _other} -> handle_malformed_line(state, line)
      {:error, _reason} -> handle_malformed_line(state, line)
    end
  end

  defp handle_malformed_line(state, line) do
    context = malformed_context(state, line)

    case required_record_hint(line) do
      nil -> tolerate_malformed_line(state, context)
      kind -> {:error, {:malformed_required_record, state.line_number, kind, context}, state, []}
    end
  end

  defp tolerate_malformed_line(state, context) do
    malformed_count = length(state.malformed_records) + 1

    if malformed_count > state.max_malformed_records do
      {:error, {:too_many_malformed_records, malformed_count}, state, []}
    else
      Logger.warning("Skipping malformed Claude stream record line=#{state.line_number} context=#{inspect(context)}")

      diagnostic = %{line_number: state.line_number, context: context}
      {:ok, %{state | malformed_records: state.malformed_records ++ [diagnostic]}, []}
    end
  end

  defp consume_record(record, state) do
    with :ok <- ensure_not_terminated(state),
         {:ok, state} <- bind_session_id(state, record) do
      normalize_record(record, state)
    else
      {:error, reason} -> {:error, reason, state, []}
    end
  end

  defp ensure_not_terminated(%__MODULE__{terminal: nil}), do: :ok
  defp ensure_not_terminated(%__MODULE__{}), do: {:error, :record_after_terminal_result}

  defp bind_session_id(state, record) do
    case normalized_string(record["session_id"]) do
      nil ->
        {:ok, state}

      session_id when is_nil(state.session_id) ->
        {:ok, %{state | session_id: session_id}}

      session_id when session_id == state.session_id ->
        {:ok, state}

      session_id ->
        {:error, {:session_id_mismatch, state.session_id, session_id}}
    end
  end

  defp normalize_record(%{"type" => "system", "subtype" => "init"} = record, state) do
    if is_nil(state.session_id) do
      {:error, :missing_session_id, state, []}
    else
      payload = %{
        subtype: "init",
        cwd: record["cwd"],
        model: record["model"],
        tools: list_or_empty(record["tools"]),
        mcp_servers: list_or_empty(record["mcp_servers"]),
        permission_mode: record["permissionMode"] || record["permission_mode"]
      }

      {:ok, %{state | init: payload}, [event(state, :session_started, payload)]}
    end
  end

  defp normalize_record(%{"type" => "assistant"} = record, state) do
    message = map_or_empty(record["message"])
    content = list_or_empty(message["content"])
    {state, content_events} = normalize_assistant_content(content, state, message)
    {state, usage_events} = update_message_usage(state, message)
    {:ok, state, content_events ++ usage_events}
  end

  defp normalize_record(%{"type" => "user"} = record, state) do
    content = record |> Map.get("message", %{}) |> map_or_empty() |> Map.get("content") |> list_or_empty()
    {:ok, state, normalize_tool_results(content, state)}
  end

  defp normalize_record(%{"type" => "result"} = record, state) do
    {state, usage_events} = replace_with_result_usage(state, record)
    terminal = classify_terminal(record, state)
    state = %{state | terminal: terminal}
    terminal_event = terminal_event(state, terminal)
    {:ok, state, usage_events ++ [terminal_event]}
  end

  defp normalize_record(%{"type" => "system", "subtype" => subtype} = record, state) do
    {:ok, state, normalize_system_activity(subtype, record, state)}
  end

  defp normalize_record(%{"type" => "tool_progress"} = record, state) do
    payload = %{
      activity: "tool_progress",
      tool_use_id: record["tool_use_id"],
      tool_name: record["tool_name"],
      elapsed_time_seconds: record["elapsed_time_seconds"]
    }

    {:ok, state, [event(state, :reasoning_update, payload)]}
  end

  defp normalize_record(_record, state), do: {:ok, state, []}

  defp normalize_assistant_content(content, state, message) do
    Enum.reduce(content, {state, []}, fn block, {current_state, events} ->
      case normalize_content_block(block, current_state, message) do
        {:text, text, next_state, event} ->
          {%{next_state | text_blocks: next_state.text_blocks ++ [text]}, events ++ [event]}

        {:event, event} ->
          {current_state, events ++ [event]}

        :ignore ->
          {current_state, events}
      end
    end)
  end

  defp normalize_content_block(%{"type" => "text", "text" => text}, state, message)
       when is_binary(text) do
    payload = %{text: text, message_id: message["id"]}
    {:text, text, state, event(state, :assistant_text, payload)}
  end

  defp normalize_content_block(%{"type" => "thinking", "thinking" => text}, state, message)
       when is_binary(text) do
    {:event, event(state, :reasoning_update, %{text: text, message_id: message["id"]})}
  end

  defp normalize_content_block(%{"type" => "redacted_thinking"} = block, state, message) do
    payload = %{redacted: true, data: block["data"], message_id: message["id"]}
    {:event, event(state, :reasoning_update, payload)}
  end

  defp normalize_content_block(%{"type" => type} = block, state, message)
       when type in ["tool_use", "server_tool_use"] do
    payload = %{
      tool_use_id: block["id"],
      name: block["name"],
      input: map_or_empty(block["input"]),
      message_id: message["id"],
      native_type: type
    }

    {:event, event(state, :tool_call_started, payload)}
  end

  defp normalize_content_block(_block, _state, _message), do: :ignore

  defp normalize_tool_results(content, state) do
    Enum.flat_map(content, fn
      %{"type" => "tool_result"} = block ->
        payload = %{
          tool_use_id: block["tool_use_id"],
          content: block["content"],
          is_error: block["is_error"] == true
        }

        [event(state, :tool_call_completed, payload)]

      _other ->
        []
    end)
  end

  defp normalize_system_activity("task_started", record, state) do
    payload = system_action_payload(record, "subagent")
    [event(state, :action_started, payload)]
  end

  defp normalize_system_activity("task_progress", record, state) do
    payload =
      record
      |> system_action_payload("subagent_progress")
      |> Map.put(:usage, record["usage"])
      |> Map.put(:last_tool_name, record["last_tool_name"])

    [event(state, :reasoning_update, payload)]
  end

  defp normalize_system_activity("task_notification", record, state) do
    payload =
      record
      |> system_action_payload("subagent")
      |> Map.put(:status, record["status"])
      |> Map.put(:summary, record["summary"])
      |> Map.put(:usage, record["usage"])

    [event(state, :action_completed, payload)]
  end

  defp normalize_system_activity(subtype, record, state)
       when subtype in ["hook_started", "hook_progress"] do
    [event(state, :action_started, system_action_payload(record, subtype))]
  end

  defp normalize_system_activity("hook_response" = subtype, record, state) do
    [event(state, :action_completed, system_action_payload(record, subtype))]
  end

  defp normalize_system_activity(_subtype, _record, _state), do: []

  defp system_action_payload(record, activity) do
    %{
      activity: activity,
      action_id: record["task_id"] || record["hook_id"] || record["tool_use_id"],
      tool_use_id: record["tool_use_id"],
      description: record["description"],
      task_type: record["task_type"],
      hook_name: record["hook_name"],
      hook_event: record["hook_event"],
      output: record["output"],
      stdout: record["stdout"],
      stderr: record["stderr"],
      outcome: record["outcome"],
      exit_code: record["exit_code"],
      output_file: record["output_file"]
    }
  end

  defp update_message_usage(state, message) do
    case normalize_usage(message["usage"]) do
      nil ->
        {state, []}

      usage ->
        {usage_id, state} = usage_identity(message, state)
        message_usages = Map.put(state.message_usages, usage_id, usage)
        cumulative = sum_usages(Map.values(message_usages))

        state = %{
          state
          | message_usages: message_usages,
            usage: cumulative,
            usage_source: :messages,
            native_usage: message["usage"]
        }

        {state, [usage_event(state, cumulative, :messages, message["usage"])]}
    end
  end

  defp usage_identity(message, state) do
    case normalized_string(message["id"]) do
      nil ->
        sequence = state.anonymous_usage_sequence + 1
        {"anonymous-#{sequence}", %{state | anonymous_usage_sequence: sequence}}

      message_id ->
        {message_id, state}
    end
  end

  defp replace_with_result_usage(state, record) do
    case normalize_usage(record["usage"]) do
      nil ->
        {state, []}

      usage ->
        state = %{state | usage: usage, usage_source: :result, native_usage: record["usage"]}
        {state, [usage_event(state, usage, :result, record["usage"])]}
    end
  end

  defp normalize_usage(usage) when is_map(usage) do
    normalized = %{
      input_tokens: non_negative_integer(usage["input_tokens"] || usage[:input_tokens]),
      cached_input_tokens:
        non_negative_integer(
          usage["cache_read_input_tokens"] ||
            usage[:cache_read_input_tokens] ||
            usage["cached_input_tokens"] ||
            usage[:cached_input_tokens]
        ),
      output_tokens: non_negative_integer(usage["output_tokens"] || usage[:output_tokens])
    }

    if Enum.any?(@usage_keys, &is_integer(Map.fetch!(normalized, &1))), do: normalized, else: nil
  end

  defp normalize_usage(_usage), do: nil

  defp sum_usages(usages) do
    Enum.reduce(usages, empty_usage(), fn usage, total ->
      Map.new(@usage_keys, fn key -> {key, add_known(total[key], usage[key])} end)
    end)
  end

  defp empty_usage do
    %{input_tokens: nil, cached_input_tokens: nil, output_tokens: nil}
  end

  defp add_known(nil, nil), do: nil
  defp add_known(left, nil), do: left
  defp add_known(nil, right), do: right
  defp add_known(left, right), do: left + right

  defp classify_terminal(record, state) do
    result_text = normalized_string(record["result"])
    error_text = terminal_error_text(record, result_text)
    input_required = needs_input?(state.text_blocks, result_text, error_text)
    failed = record["is_error"] == true or record["subtype"] not in [nil, "success"]

    status =
      cond do
        input_required -> :blocked
        failed -> :failed
        true -> :completed
      end

    %{
      status: status,
      result_text: result_text,
      error_text: if(status == :completed, do: nil, else: error_text || result_text),
      failure_reason: failure_reason(status, record),
      input_required: input_required,
      native: Map.drop(record, ["result", "usage"])
    }
  end

  defp failure_reason(:completed, _record), do: nil

  defp failure_reason(:blocked, record) do
    %{
      type: :input_required,
      subtype: record["subtype"],
      error: record["error"],
      errors: record["errors"]
    }
  end

  defp failure_reason(:failed, record) do
    %{
      type: :claude_result_error,
      subtype: record["subtype"],
      error: record["error"],
      errors: record["errors"]
    }
  end

  defp terminal_error_text(record, result_text) do
    case record["error"] do
      error when is_binary(error) -> normalized_string(error)
      %{"message" => message} when is_binary(message) -> normalized_string(message)
      error when is_map(error) -> inspect(error, limit: 20, printable_limit: 1_000)
      _ -> errors_text(record["errors"]) || if(record["is_error"] == true, do: result_text, else: nil)
    end
  end

  defp errors_text(errors) when is_list(errors) do
    errors
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> nil
      messages -> Enum.join(messages, "\n")
    end
  end

  defp errors_text(_errors), do: nil

  defp needs_input?(text_blocks, result_text, error_text) do
    Enum.any?(text_blocks, &sentinel_outside_fences?/1) or
      sentinel_outside_fences?(result_text) or
      explicit_input_error?(error_text)
  end

  defp sentinel_outside_fences?(text) when is_binary(text) do
    text
    |> String.split(~r/\R/, trim: false)
    |> Enum.reduce_while(nil, fn line, fence ->
      trimmed = String.trim(line)

      cond do
        fence_marker(trimmed) == fence and not is_nil(fence) -> {:cont, nil}
        not is_nil(fence) -> {:cont, fence}
        not is_nil(fence_marker(trimmed)) -> {:cont, fence_marker(trimmed)}
        trimmed == @needs_input_sentinel -> {:halt, :found}
        true -> {:cont, nil}
      end
    end)
    |> Kernel.==(:found)
  end

  defp sentinel_outside_fences?(_text), do: false

  defp fence_marker("```" <> _rest), do: "```"
  defp fence_marker("~~~" <> _rest), do: "~~~"
  defp fence_marker(_line), do: nil

  defp explicit_input_error?(text) when is_binary(text) do
    String.match?(
      text,
      ~r/(approval required|requires? (?:user|human) input|interactive (?:input|confirmation)|waiting for (?:user|human)|permission prompt)/i
    )
  end

  defp explicit_input_error?(_text), do: false

  defp terminal_event(state, %{status: :completed} = terminal) do
    event(state, :turn_completed, terminal_payload(state, terminal))
  end

  defp terminal_event(state, %{status: :blocked} = terminal) do
    event(state, :input_required, terminal_payload(state, terminal))
  end

  defp terminal_event(state, terminal) do
    event(state, :turn_failed, terminal_payload(state, terminal))
  end

  defp terminal_payload(state, terminal) do
    %{
      status: terminal.status,
      result: terminal.result_text,
      error: terminal.error_text,
      failure_reason: terminal.failure_reason,
      usage: state.usage,
      usage_accounting: :absolute,
      native: terminal.native
    }
  end

  defp usage_event(state, usage, source, native_usage) do
    event(state, :usage_updated, %{
      usage: usage,
      source: source,
      accounting: :absolute,
      native: native_usage
    })
  end

  defp event(state, kind, payload) do
    %AgentEvent{
      kind: kind,
      backend: state.backend,
      issue_id: state.issue_id,
      session_id: state.session_id,
      turn_id: state.turn_id,
      timestamp: DateTime.utc_now(),
      payload: payload,
      metadata: state.metadata
    }
  end

  defp require_terminal(%__MODULE__{terminal: nil}), do: {:error, :missing_terminal_result}
  defp require_terminal(%__MODULE__{}), do: :ok

  defp require_success_session(%__MODULE__{terminal: %{status: :completed}, session_id: nil}),
    do: {:error, :missing_session_id}

  defp require_success_session(%__MODULE__{}), do: :ok

  defp build_turn_result(state) do
    terminal = state.terminal
    usage = state.usage || empty_usage()

    %AgentTurnResult{
      backend: state.backend,
      session_id: state.session_id,
      turn_id: state.turn_id,
      status: terminal.status,
      final_text: terminal.result_text || List.last(state.text_blocks),
      text_blocks: state.text_blocks,
      input_tokens: usage.input_tokens,
      cached_input_tokens: usage.cached_input_tokens,
      output_tokens: usage.output_tokens,
      failure_text: terminal.error_text,
      failure_reason: terminal.failure_reason,
      input_required: terminal.input_required,
      metadata: %{
        usage_source: state.usage_source,
        native_usage: state.native_usage,
        malformed_records: state.malformed_records,
        init: state.init,
        native_result: terminal.native
      }
    }
  end

  defp required_record_hint(line) do
    cond do
      Regex.match?(~r/["']type["']\s*:\s*["']result/i, line) ->
        :result

      Regex.match?(~r/["']type["']\s*:\s*["']system/i, line) and
          Regex.match?(~r/["']subtype["']\s*:\s*["']init/i, line) ->
        :session

      true ->
        nil
    end
  end

  defp malformed_context(state, line) do
    line
    |> redact()
    |> truncate_bytes(state.max_malformed_context_bytes)
  end

  defp redact(value) do
    value
    |> String.replace(~r/(Bearer\s+)[A-Za-z0-9._~+\/=:-]+/i, "\\1[REDACTED]")
    |> String.replace(
      ~r/("(?:api[_-]?key|access[_-]?token|token|secret|password)"\s*:\s*")[^"]*/i,
      "\\1[REDACTED]"
    )
  end

  defp truncate_bytes(value, max_bytes) when byte_size(value) <= max_bytes, do: value

  defp truncate_bytes(value, max_bytes) do
    suffix = "...<truncated>"

    if max_bytes <= byte_size(suffix) do
      binary_part(suffix, 0, max_bytes)
    else
      value
      |> binary_part(0, max_bytes - byte_size(suffix))
      |> String.replace_invalid()
      |> Kernel.<>(suffix)
    end
  end

  defp trim_carriage_return(line) do
    case line do
      <<body::binary-size(byte_size(line) - 1), "\r">> when byte_size(line) > 0 -> body
      _ -> line
    end
  end

  defp normalized_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalized_string(_value), do: nil

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: nil

  defp map_or_empty(value) when is_map(value), do: value
  defp map_or_empty(_value), do: %{}

  defp list_or_empty(value) when is_list(value), do: value
  defp list_or_empty(_value), do: []

  defp positive_option!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      value -> raise ArgumentError, "#{key} must be a positive integer, got: #{inspect(value)}"
    end
  end

  defp non_negative_option!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value >= 0 -> value
      value -> raise ArgumentError, "#{key} must be a non-negative integer, got: #{inspect(value)}"
    end
  end
end
