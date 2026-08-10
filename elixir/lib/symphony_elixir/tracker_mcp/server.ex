defmodule SymphonyElixir.TrackerMCP.Server do
  @moduledoc false

  use GenServer

  require Logger

  alias SymphonyElixir.TrackerMCP.{Handle, Router}
  alias SymphonyElixir.TrackerToolBroker

  @default_ttl_ms :timer.hours(24)
  @maximum_ttl_ms :timer.hours(24)
  @default_execute_timeout_ms :timer.seconds(60)
  @maximum_execute_timeout_ms :timer.minutes(5)
  @default_max_body_bytes 1_048_576
  @maximum_body_bytes 4_194_304
  @token_bytes 32
  @session_bytes 24
  @supported_protocol_versions ["2025-11-25", "2025-06-18", "2025-03-26"]

  @type rpc_result ::
          {:response, map(), [{String.t(), String.t()}]}
          | {:execute, reference(), pos_integer()}
          | :accepted
          | {:error, :unauthorized | :expired | :scope_mismatch | :missing_session | :unknown_session}

  @spec start_link(TrackerToolBroker.binding(), keyword()) :: GenServer.on_start()
  def start_link(binding, opts) do
    with {:ok, settings} <- normalize_settings(binding, opts) do
      GenServer.start_link(__MODULE__, settings)
    end
  end

  @spec take_handle(pid()) :: {:ok, Handle.t()} | {:error, :already_taken}
  def take_handle(pid), do: GenServer.call(pid, :take_handle)

  @spec health(pid(), binary(), map()) :: :ok | {:error, atom()}
  def health(pid, credential_digest, identity) do
    GenServer.call(pid, {:health, credential_digest, identity})
  end

  @spec authorize_transport(pid(), binary(), map()) :: :ok | {:error, atom()}
  def authorize_transport(pid, credential_digest, identity) do
    GenServer.call(pid, {:authorize_transport, credential_digest, identity})
  end

  @spec rpc(pid(), binary(), map(), map()) :: rpc_result()
  def rpc(pid, credential_digest, identity, request) do
    GenServer.call(pid, {:rpc, credential_digest, identity, request})
  end

  @spec await_execution(pid(), reference(), pos_integer()) :: {:ok, map()} | {:error, atom()}
  def await_execution(server, execution_ref, timeout_ms) do
    monitor = Process.monitor(server)

    receive do
      {:tracker_mcp_execution, ^server, ^execution_ref, response} ->
        Process.demonitor(monitor, [:flush])
        {:ok, response}

      {:DOWN, ^monitor, :process, ^server, _reason} ->
        {:error, :server_stopped}
    after
      timeout_ms ->
        Process.demonitor(monitor, [:flush])
        cancel_execution(server, execution_ref)
        {:error, :execution_timeout}
    end
  end

  @impl true
  def init(settings) do
    case start_bandit(settings.max_body_bytes) do
      {:ok, bandit_pid, port} ->
        token = random_token(@token_bytes)

        owner_monitor = Process.monitor(settings.owner)

        state =
          settings
          |> Map.merge(%{
            bandit_pid: bandit_pid,
            port: port,
            token: token,
            token_digest: token_digest(token),
            mcp_session_id: random_token(@session_bytes),
            initialized?: false,
            owner_monitor: owner_monitor,
            executions: %{}
          })
          |> schedule_expiry()

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:take_handle, _from, %{token: nil} = state) do
    {:reply, {:error, :already_taken}, state}
  end

  def handle_call(:take_handle, _from, state) do
    handle = %Handle{
      pid: self(),
      url: "http://127.0.0.1:#{state.port}/mcp",
      token: state.token,
      issue_id: state.issue_id,
      backend: state.backend,
      session_id: state.session_id,
      tool_names: Enum.map(state.tool_specs, & &1["name"])
    }

    {:reply, {:ok, handle}, %{state | token: nil}}
  end

  def handle_call({:health, credential_digest, identity}, _from, state) do
    case authorize(state, credential_digest, identity, :health) do
      :ok -> {:reply, :ok, schedule_expiry(state)}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:authorize_transport, credential_digest, identity}, _from, state) do
    case authorize(state, credential_digest, identity, :request) do
      :ok -> {:reply, :ok, schedule_expiry(state)}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:rpc, credential_digest, identity, request}, {caller, _tag}, state) do
    authorization_mode = if initialize_request?(request), do: :initialize, else: :request

    with :ok <- authorize(state, credential_digest, identity, authorization_mode),
         {:ok, result, next_state} <- dispatch_rpc(request, caller, state) do
      {:reply, result, schedule_expiry(next_state)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:cancel_execution, execution_ref, outcome}, _from, state) do
    {:reply, :ok, stop_execution(state, execution_ref, outcome)}
  end

  @impl true
  def handle_info({:DOWN, owner_monitor, :process, _owner, _reason}, %{owner_monitor: owner_monitor} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:execution_finished, execution_ref, outcome, duration_ms, response}, state) do
    {:noreply, finish_execution(state, execution_ref, outcome, duration_ms, response)}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    {:noreply, fail_execution_by_monitor(state, monitor)}
  end

  def handle_info({:expire, expiry_ref}, %{expiry_ref: expiry_ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:expire, _stale_ref}, state), do: {:noreply, state}

  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:state, state} -> {:state, safe_status_state(state)}
      {:message, _message} -> {:message, :redacted}
      key_value -> key_value
    end)
  end

  @impl true
  def terminate(_reason, %{bandit_pid: bandit_pid} = state) when is_pid(bandit_pid) do
    cancel_timer(state.expiry_timer)
    Enum.each(state.executions, fn {_ref, execution} -> cancel_running_execution(execution, "cancelled") end)
    stop_bandit(bandit_pid)

    :ok
  catch
    :exit, _reason -> :ok
  end

  defp normalize_settings(binding, opts) do
    with {:ok, issue_id} <- required_string(opts, :issue_id),
         {:ok, backend} <- normalize_backend(Keyword.get(opts, :backend)),
         {:ok, session_id} <- optional_session_id(opts),
         {:ok, ttl_ms} <- bounded_positive_integer(opts, :ttl_ms, @default_ttl_ms, @maximum_ttl_ms),
         {:ok, max_body_bytes} <-
           bounded_positive_integer(opts, :max_body_bytes, @default_max_body_bytes, @maximum_body_bytes),
         {:ok, execute_timeout_ms} <-
           bounded_positive_integer(
             opts,
             :execute_timeout_ms,
             @default_execute_timeout_ms,
             @maximum_execute_timeout_ms
           ),
         {:ok, owner} <- owner_pid(opts),
         {:ok, tool_specs} <- allowed_tool_specs(binding, Keyword.get(opts, :allowed_tools)),
         {:ok, execute_opts} <- execute_options(opts) do
      {:ok,
       %{
         binding: binding,
         issue_id: issue_id,
         backend: backend,
         session_id: session_id,
         ttl_ms: ttl_ms,
         max_body_bytes: max_body_bytes,
         execute_timeout_ms: execute_timeout_ms,
         owner: owner,
         tool_specs: tool_specs,
         tool_names: MapSet.new(tool_specs, & &1["name"]),
         execute_opts: execute_opts
       }}
    end
  end

  defp required_string(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:invalid_option, key}}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, {:invalid_option, key}}
    end
  end

  defp normalize_backend(nil), do: {:error, {:invalid_option, :backend}}
  defp normalize_backend(value) when is_atom(value), do: normalize_backend(Atom.to_string(value))

  defp normalize_backend(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, {:invalid_option, :backend}}
      backend -> {:ok, backend}
    end
  end

  defp normalize_backend(_value), do: {:error, {:invalid_option, :backend}}

  defp optional_session_id(opts) do
    case Keyword.get(opts, :session_id) do
      nil -> {:ok, random_token(@session_bytes)}
      _value -> required_string(opts, :session_id)
    end
  end

  defp bounded_positive_integer(opts, key, default, maximum) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 and value <= maximum -> {:ok, value}
      _value -> {:error, {:invalid_option, key}}
    end
  end

  defp allowed_tool_specs(%{tool_specs: tool_specs}, nil) when is_list(tool_specs), do: {:ok, tool_specs}

  defp allowed_tool_specs(%{tool_specs: tool_specs}, allowed_tools)
       when is_list(tool_specs) and is_list(allowed_tools) do
    requested = MapSet.new(allowed_tools)
    available = MapSet.new(tool_specs, & &1["name"])

    case Enum.find(requested, &(not MapSet.member?(available, &1))) do
      nil -> {:ok, Enum.filter(tool_specs, &MapSet.member?(requested, &1["name"]))}
      unknown -> {:error, {:unknown_tool, unknown}}
    end
  end

  defp allowed_tool_specs(_binding, _allowed_tools), do: {:error, {:invalid_option, :allowed_tools}}

  defp execute_options(opts) do
    case Keyword.get(opts, :execute_opts, []) do
      execute_opts when is_list(execute_opts) ->
        if Keyword.keyword?(execute_opts), do: {:ok, execute_opts}, else: {:error, {:invalid_option, :execute_opts}}

      _execute_opts ->
        {:error, {:invalid_option, :execute_opts}}
    end
  end

  defp owner_pid(opts) do
    case Keyword.get(opts, :owner) do
      owner when is_pid(owner) -> {:ok, owner}
      _owner -> {:error, {:invalid_option, :owner}}
    end
  end

  defp start_bandit(max_body_bytes) do
    opts = [
      plug: {Router, server: self(), max_body_bytes: max_body_bytes},
      scheme: :http,
      ip: {127, 0, 0, 1},
      port: 0,
      startup_log: false,
      http_options: [log_protocol_errors: false, log_client_closures: false],
      thousand_island_options: [shutdown_timeout: 250]
    ]

    with {:ok, pid} <- Bandit.start_link(opts),
         {:ok, {{127, 0, 0, 1}, port}} <- ThousandIsland.listener_info(pid) do
      {:ok, pid, port}
    end
  end

  defp authorize(state, credential_digest, identity, mode) do
    cond do
      not valid_token_digest?(state.token_digest, credential_digest) -> {:error, :unauthorized}
      monotonic_ms() >= state.expires_at_ms -> {:error, :expired}
      not matching_scope?(state, identity) -> {:error, :scope_mismatch}
      mode in [:health, :initialize] -> :ok
      not state.initialized? -> {:error, :missing_session}
      blank?(identity.session_id) -> {:error, :missing_session}
      not secure_equal?(state.mcp_session_id, identity.session_id) -> {:error, :unknown_session}
      true -> :ok
    end
  end

  defp matching_scope?(state, identity) do
    matches_if_present?(state.issue_id, identity.issue_id) and
      matches_if_present?(state.backend, identity.backend) and
      matches_if_present?(state.session_id, identity.backend_session_id)
  end

  defp matches_if_present?(_expected, nil), do: true
  defp matches_if_present?(expected, actual), do: secure_equal?(expected, actual)

  defp dispatch_rpc(%{"jsonrpc" => "2.0", "id" => id, "method" => "initialize"} = request, _caller, state)
       when is_binary(id) or is_integer(id) do
    version =
      request
      |> get_in(["params", "protocolVersion"])
      |> negotiate_protocol_version()

    result = %{
      "protocolVersion" => version,
      "capabilities" => %{"tools" => %{"listChanged" => false}},
      "serverInfo" => %{"name" => "symphony_tracker", "version" => "1.0.0"}
    }

    response = success_response(id, result)
    headers = [{"mcp-session-id", state.mcp_session_id}]
    {:ok, {:response, response, headers}, %{state | initialized?: true}}
  end

  defp dispatch_rpc(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"}, _caller, state) do
    {:ok, :accepted, state}
  end

  defp dispatch_rpc(%{"jsonrpc" => "2.0", "method" => method} = request, _caller, state)
       when not is_map_key(request, "id") and is_binary(method) do
    {:ok, :accepted, state}
  end

  defp dispatch_rpc(%{"jsonrpc" => "2.0", "id" => id, "method" => "ping"}, _caller, state)
       when is_binary(id) or is_integer(id) do
    {:ok, {:response, success_response(id, %{}), []}, state}
  end

  defp dispatch_rpc(%{"jsonrpc" => "2.0", "id" => id, "method" => "tools/list"}, _caller, state)
       when is_binary(id) or is_integer(id) do
    {:ok, {:response, success_response(id, %{"tools" => state.tool_specs}), []}, state}
  end

  defp dispatch_rpc(
         %{
           "jsonrpc" => "2.0",
           "id" => id,
           "method" => "tools/call",
           "params" => %{"name" => name} = params
         },
         caller,
         state
       )
       when (is_binary(id) or is_integer(id)) and is_binary(name) do
    arguments = Map.get(params, "arguments", %{})

    cond do
      not MapSet.member?(state.tool_names, name) ->
        response = error_response(id, -32_602, "Tool is not authorized for this session.")
        {:ok, {:response, response, []}, state}

      not is_map(arguments) ->
        response = error_response(id, -32_602, "Tool arguments must be a JSON object.")
        {:ok, {:response, response, []}, state}

      true ->
        start_execution(id, name, arguments, caller, state)
    end
  end

  defp dispatch_rpc(%{"jsonrpc" => "2.0", "id" => id, "method" => method}, _caller, state)
       when (is_binary(id) or is_integer(id)) and is_binary(method) do
    {:ok, {:response, error_response(id, -32_601, "Method not found."), []}, state}
  end

  defp dispatch_rpc(%{"id" => id}, _caller, state) when is_binary(id) or is_integer(id) do
    {:ok, {:response, error_response(id, -32_600, "Invalid Request."), []}, state}
  end

  defp dispatch_rpc(_request, _caller, state) do
    {:ok, {:response, error_response(nil, -32_600, "Invalid Request."), []}, state}
  end

  defp mcp_tool_result(%{"success" => success} = result) when is_boolean(success) do
    text = normalize_tool_output(result)
    %{"content" => [%{"type" => "text", "text" => text}], "isError" => not success}
  end

  defp mcp_tool_result(_result) do
    text = Jason.encode!(%{"error" => "Tracker tool returned an invalid response."})
    %{"content" => [%{"type" => "text", "text" => text}], "isError" => true}
  end

  defp normalize_tool_output(%{"output" => output}) when is_binary(output), do: output

  defp normalize_tool_output(%{"contentItems" => items}) when is_list(items) do
    items
    |> Enum.flat_map(fn
      %{"text" => text} when is_binary(text) -> [text]
      _item -> []
    end)
    |> Enum.join("\n")
  end

  defp normalize_tool_output(result), do: Jason.encode!(result)

  defp start_execution(id, name, arguments, caller, state) do
    execution_ref = make_ref()
    server = self()
    context = Map.take(state, [:issue_id, :backend, :session_id])

    {:ok, pid} =
      Task.start(fn ->
        {response, outcome, duration_ms} =
          execute_tool(id, name, arguments, state.binding, state.execute_opts)

        send(server, {:execution_finished, execution_ref, outcome, duration_ms, response})
      end)

    monitor = Process.monitor(pid)

    execution = %{
      pid: pid,
      monitor: monitor,
      caller: caller,
      context: context,
      name: name,
      started_at: monotonic_ms()
    }

    next_state = put_in(state, [:executions, execution_ref], execution)
    {:ok, {:execute, execution_ref, state.execute_timeout_ms}, next_state}
  end

  defp execute_tool(id, name, arguments, binding, execute_opts) do
    started_at = monotonic_ms()

    {result, outcome} =
      try do
        broker_result = TrackerToolBroker.execute(binding, name, arguments, execute_opts)
        {mcp_tool_result(broker_result), broker_outcome(broker_result)}
      rescue
        _error -> {failed_tool_result("Tracker tool execution failed."), "failed"}
      catch
        _kind, _reason -> {failed_tool_result("Tracker tool execution failed."), "failed"}
      end

    duration_ms = max(monotonic_ms() - started_at, 0)
    {success_response(id, result), outcome, duration_ms}
  end

  defp failed_tool_result(message) do
    text = Jason.encode!(%{"error" => message})
    %{"content" => [%{"type" => "text", "text" => text}], "isError" => true}
  end

  defp broker_outcome(%{"success" => true}), do: "completed"
  defp broker_outcome(_result), do: "failed"

  defp audit_tool_execution(context, name, duration_ms, outcome) do
    Logger.info(
      "Tracker MCP tool #{outcome} issue_id=#{log_value(context.issue_id)} " <>
        "backend=#{log_value(context.backend)} session_id=#{log_value(context.session_id)} " <>
        "tool=#{log_value(name)} duration_ms=#{duration_ms}"
    )
  end

  defp log_value(value) do
    value
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9._:-]/u, "_")
    |> String.slice(0, 128)
  end

  defp success_response(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp error_response(id, code, message) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
  end

  defp initialize_request?(%{"jsonrpc" => "2.0", "method" => "initialize"}), do: true
  defp initialize_request?(_request), do: false

  defp negotiate_protocol_version(version) when version in @supported_protocol_versions, do: version
  defp negotiate_protocol_version(_version), do: hd(@supported_protocol_versions)

  defp valid_token_digest?(_digest, credential_digest) when not is_binary(credential_digest), do: false
  defp valid_token_digest?(digest, credential_digest), do: secure_equal?(digest, credential_digest)

  defp secure_equal?(left, right) when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right) do
    Plug.Crypto.secure_compare(left, right)
  end

  defp secure_equal?(_left, _right), do: false

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp token_digest(token), do: :crypto.hash(:sha256, token)

  defp schedule_expiry(state) do
    cancel_timer(Map.get(state, :expiry_timer))
    expiry_ref = make_ref()
    expiry_timer = Process.send_after(self(), {:expire, expiry_ref}, state.ttl_ms)

    Map.merge(state, %{
      expiry_ref: expiry_ref,
      expiry_timer: expiry_timer,
      expires_at_ms: monotonic_ms() + state.ttl_ms
    })
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer) do
    Process.cancel_timer(timer, async: true, info: false)
    :ok
  end

  defp cancel_execution(server, execution_ref) do
    GenServer.call(server, {:cancel_execution, execution_ref, "timed_out"}, 1_000)
  catch
    :exit, _reason -> :ok
  end

  defp stop_execution(state, execution_ref, outcome) do
    case Map.pop(state.executions, execution_ref) do
      {nil, _executions} ->
        state

      {%{pid: pid, monitor: monitor}, executions} ->
        Process.demonitor(monitor, [:flush])
        Process.exit(pid, :kill)
        audit_running_execution(Map.fetch!(state.executions, execution_ref), outcome)
        %{state | executions: executions}
    end
  end

  defp finish_execution(state, execution_ref, outcome, duration_ms, response) do
    case Map.pop(state.executions, execution_ref) do
      {nil, _executions} ->
        state

      {execution, executions} ->
        Process.demonitor(execution.monitor, [:flush])
        audit_tool_execution(execution.context, execution.name, duration_ms, outcome)
        send(execution.caller, {:tracker_mcp_execution, self(), execution_ref, response})
        %{state | executions: executions}
    end
  end

  defp fail_execution_by_monitor(state, monitor) do
    case Enum.find(state.executions, fn {_ref, execution} -> execution.monitor == monitor end) do
      nil ->
        state

      {execution_ref, execution} ->
        audit_running_execution(execution, "failed")
        %{state | executions: Map.delete(state.executions, execution_ref)}
    end
  end

  defp cancel_running_execution(execution, outcome) do
    Process.demonitor(execution.monitor, [:flush])
    Process.exit(execution.pid, :kill)
    audit_running_execution(execution, outcome)
  end

  defp audit_running_execution(execution, outcome) do
    duration_ms = max(monotonic_ms() - execution.started_at, 0)
    audit_tool_execution(execution.context, execution.name, duration_ms, outcome)
  end

  defp stop_bandit(bandit_pid) do
    if Process.alive?(bandit_pid) do
      Process.unlink(bandit_pid)

      try do
        ThousandIsland.stop(bandit_pid, 500)
      catch
        :exit, _reason -> Process.exit(bandit_pid, :kill)
      end
    end

    :ok
  end

  defp safe_status_state(state) do
    Map.take(state, [
      :issue_id,
      :backend,
      :session_id,
      :tool_names,
      :initialized?,
      :expires_at_ms
    ])
  end

  defp random_token(byte_count) do
    byte_count
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
