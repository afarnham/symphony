defmodule SymphonyElixir.AgentBackend.Claude do
  @moduledoc """
  `AgentBackend` implementation for non-interactive Claude Code sessions.

  Claude runs one OS process per turn. The first successful turn captures the
  native session identifier; later turns resume that exact session.
  """

  @behaviour SymphonyElixir.AgentBackend

  alias SymphonyElixir.{AgentEvent, AgentTurnResult, Claude.Session, Config, PathSafety, SSH}
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.TrackerMCP
  alias SymphonyElixir.TrackerMCP.Handle, as: MCPHandle

  @permission_modes ["default", "acceptEdits", "plan", "bypassPermissions"]
  @reserved_command_flags [
    "-p",
    "--print",
    "--input-format",
    "--output-format",
    "--resume",
    "--continue",
    "--mcp-config",
    "--model",
    "--allowedTools",
    "--allowed-tools",
    "--permission-mode",
    "--dangerously-skip-permissions",
    "--verbose"
  ]
  @max_auth_status_timeout_ms 5_000

  @type session :: %{
          required(:pid) => pid(),
          required(:issue_id) => String.t(),
          required(:on_event) => (AgentEvent.t() -> term()),
          required(:session_id) => String.t() | nil,
          required(:tool_session) => map() | nil,
          required(:turn_number) => non_neg_integer(),
          required(:workspace) => Path.t(),
          required(:worker_host) => String.t() | nil,
          optional(:mcp_handle) => MCPHandle.t() | nil,
          optional(:mcp_config_dir) => Path.t() | nil,
          optional(:mcp_enabled) => boolean(),
          optional(:mcp_transport) => :none | :local_http | :ssh_reverse_tunnel,
          optional(:expected_mcp_tools) => [String.t()]
        }

  @impl true
  def name, do: :claude

  @impl true
  def validate_config(%{claude: claude}) when is_map(claude) do
    with :ok <- validate_non_blank(Map.get(claude, :command), :invalid_claude_command),
         :ok <- validate_command_tokens(Map.get(claude, :command)),
         :ok <- validate_reserved_command_flags(Map.get(claude, :command)),
         :ok <- validate_optional_non_blank(Map.get(claude, :model), :invalid_claude_model),
         :ok <- validate_permission_mode(Map.get(claude, :permission_mode)),
         :ok <-
           validate_positive_timeout(
             Map.get(claude, :turn_timeout_ms),
             :invalid_claude_turn_timeout
           ) do
      validate_positive_timeout(
        Map.get(claude, :read_timeout_ms),
        :invalid_claude_read_timeout
      )
    end
  end

  def validate_config(_settings), do: {:error, :missing_claude_config}

  @impl true
  def validate_host(%{claude: %{command: command, read_timeout_ms: read_timeout_ms}}, nil) do
    with {:ok, executable, command_args} <- resolve_executable(command) do
      validate_authentication(
        executable,
        command_args,
        min(read_timeout_ms, @max_auth_status_timeout_ms)
      )
    end
  end

  def validate_host(
        %{claude: %{command: command, read_timeout_ms: read_timeout_ms}},
        worker_host
      )
      when is_binary(worker_host) do
    timeout_ms = min(read_timeout_ms, @max_auth_status_timeout_ms)

    with {:ok, [executable | command_args]} <- parse_command_argv(command) do
      auth_command =
        Enum.map_join([executable | command_args] ++ ["auth", "status"], " ", &shell_escape/1)

      script =
        [
          "command -v bash >/dev/null 2>&1 || exit 41",
          "command -v curl >/dev/null 2>&1 || exit 43",
          "command -v #{shell_escape(executable)} >/dev/null 2>&1 || exit 42",
          "exec #{auth_command}"
        ]
        |> Enum.join("\n")

      case validate_remote_dependencies(worker_host, executable, script, timeout_ms) do
        :ok -> validate_remote_port_forwarding(worker_host, timeout_ms)
        {:error, _reason} = error -> error
      end
    end
  end

  @impl true
  def start_session(workspace, %Issue{} = issue, tool_session, opts) do
    settings = Keyword.get_lazy(opts, :settings, &Config.settings!/0)
    on_event = Keyword.get(opts, :on_event, &default_on_event/1)
    worker_host = Keyword.get(opts, :worker_host)

    with :ok <- validate_config(settings),
         {:ok, executable, command_args} <-
           resolve_executable(settings.claude.command, worker_host),
         {:ok, canonical_workspace} <- validate_workspace_cwd(workspace, settings, worker_host),
         {:ok, mcp_context} <- resolve_mcp_context(tool_session, issue, opts) do
      runtime = %{
        tool_session: tool_session,
        on_event: on_event,
        mcp_context: mcp_context,
        worker_host: worker_host,
        command_args: command_args,
        remote_port_candidates: Keyword.get(opts, :remote_port_candidates)
      }

      start_claude_session(
        canonical_workspace,
        executable,
        settings,
        issue,
        runtime
      )
    end
  end

  @impl true
  def run_turn(session, prompt, %Issue{} = issue, opts \\ []) when is_binary(prompt) do
    turn_number = session.turn_number + 1
    turn_id = "turn-#{turn_number}"
    on_event = Keyword.get(opts, :on_event, session.on_event)

    updated_session = %{session | turn_number: turn_number, on_event: on_event}

    case Session.run_turn(
           session.pid,
           prompt,
           issue,
           turn_id,
           session.session_id,
           on_event
         ) do
      {:ok, %AgentTurnResult{status: :completed} = result} ->
        with :ok <- validate_mcp_initialization(updated_session, result),
             {:ok, resumed_session} <- bind_session_id(updated_session, result.session_id) do
          {:ok, result, resumed_session}
        else
          {:error, reason} -> {:error, reason, updated_session}
        end

      {:ok, %AgentTurnResult{status: :blocked} = result} ->
        case validate_mcp_initialization(updated_session, result) do
          :ok ->
            blocked_session = maybe_bind_session_id(updated_session, result.session_id)
            {:blocked, result, blocked_session}

          {:error, reason} ->
            {:error, reason, updated_session}
        end

      {:ok, %AgentTurnResult{status: :failed} = result} ->
        case validate_mcp_initialization(updated_session, result) do
          :ok ->
            failed_session = maybe_bind_session_id(updated_session, result.session_id)
            {:error, {:claude_turn_failed, result}, failed_session}

          {:error, reason} ->
            {:error, reason, updated_session}
        end

      {:error, reason} ->
        {:error, reason, updated_session}
    end
  end

  @impl true
  def stop_session(session, reason) do
    if Process.alive?(session.pid) do
      transport_metadata = stopped_transport_metadata(session)
      result = Session.stop(session.pid, reason)
      stop_mcp_context(session)

      session.on_event.(%AgentEvent{
        kind: :session_stopped,
        backend: :claude,
        issue_id: session.issue_id,
        session_id: session.session_id,
        turn_id: last_turn_id(session.turn_number),
        timestamp: DateTime.utc_now(),
        payload: %{reason: reason, cleanup_result: result},
        metadata:
          Map.merge(
            %{worker_host: session.worker_host, workspace_path: session.workspace},
            transport_metadata
          )
      })

      result
    else
      stop_mcp_context(session)
      :ok
    end
  end

  defp start_claude_session(workspace, executable, settings, issue, runtime) do
    case Session.start_link(
           workspace: workspace,
           executable: executable,
           claude: settings.claude,
           command_args: runtime.command_args,
           tool_session: runtime.tool_session,
           mcp_options: runtime.mcp_context.options,
           worker_host: runtime.worker_host,
           remote_port_candidates: runtime.remote_port_candidates
         ) do
      {:ok, pid} ->
        {:ok,
         %{
           pid: pid,
           issue_id: issue.id,
           on_event: runtime.on_event,
           session_id: nil,
           tool_session: runtime.tool_session,
           turn_number: 0,
           workspace: workspace,
           worker_host: runtime.worker_host,
           mcp_handle: runtime.mcp_context.handle,
           mcp_config_dir: runtime.mcp_context.config_dir,
           mcp_enabled: not is_nil(runtime.mcp_context.options),
           mcp_transport: mcp_transport(runtime.mcp_context.options, runtime.worker_host),
           expected_mcp_tools: runtime.mcp_context.expected_tools
         }}

      {:error, reason} ->
        stop_mcp_context(runtime.mcp_context)
        {:error, reason}
    end
  end

  defp resolve_mcp_context(tool_session, issue, opts) do
    cond do
      Keyword.has_key?(opts, :mcp_options_resolver) ->
        with {:ok, options} <- resolve_mcp_options(tool_session, opts) do
          {:ok, external_mcp_context(options)}
        end

      Keyword.has_key?(opts, :mcp_options) ->
        {:ok, external_mcp_context(Keyword.get(opts, :mcp_options))}

      advertised_tools(tool_session) == [] ->
        {:ok, external_mcp_context(nil)}

      true ->
        start_tracker_mcp(tool_session, issue)
    end
  end

  defp external_mcp_context(options) do
    %{options: options, handle: nil, config_dir: nil, expected_tools: []}
  end

  defp start_tracker_mcp(tool_session, issue) do
    allowed_tools = advertised_tools(tool_session)

    case TrackerMCP.start_session(tool_session,
           issue_id: issue.id,
           backend: :claude,
           allowed_tools: allowed_tools
         ) do
      {:ok, handle} ->
        with :ok <- tracker_mcp_health(handle),
             {:ok, config_dir, config_path} <- write_mcp_config() do
          {:ok,
           %{
             options: %{
               config: config_path,
               allowed_tools: TrackerMCP.claude_tool_names(handle),
               env: TrackerMCP.environment(handle)
             },
             handle: handle,
             config_dir: config_dir,
             expected_tools: TrackerMCP.claude_tool_names(handle)
           }}
        else
          {:error, reason} ->
            TrackerMCP.stop_session(handle)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp advertised_tools(%{tool_specs: tool_specs}) when is_list(tool_specs) do
    Enum.flat_map(tool_specs, fn
      %{"name" => name} when is_binary(name) -> [name]
      _tool_spec -> []
    end)
  end

  defp advertised_tools(_tool_session), do: []

  defp tracker_mcp_health(handle) do
    case Req.get(TrackerMCP.health_url(handle),
           headers: [{"authorization", "Bearer #{handle.token}"}],
           receive_timeout: 5_000
         ) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status}} -> {:error, {:tracker_mcp_health_failed, status}}
      {:error, reason} -> {:error, {:tracker_mcp_health_failed, reason}}
    end
  end

  defp write_mcp_config do
    config_dir =
      Path.join(
        System.tmp_dir!(),
        "symphony-claude-mcp-#{Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)}"
      )

    config_path = Path.join(config_dir, "mcp.json")

    config = %{
      "mcpServers" => %{
        "symphony_tracker" => %{
          "type" => "http",
          "url" => "${SYMPHONY_TRACKER_MCP_URL}",
          "headers" => %{
            "Authorization" => "Bearer ${SYMPHONY_TRACKER_MCP_TOKEN}"
          }
        }
      }
    }

    with :ok <- File.mkdir(config_dir),
         :ok <- File.chmod(config_dir, 0o700),
         :ok <- File.write(config_path, Jason.encode!(config)),
         :ok <- File.chmod(config_path, 0o600) do
      {:ok, config_dir, config_path}
    else
      {:error, reason} ->
        File.rm_rf(config_dir)
        {:error, {:claude_mcp_config_failed, reason}}
    end
  end

  defp validate_mcp_initialization(%{expected_mcp_tools: []}, _result), do: :ok

  defp validate_mcp_initialization(session, result) do
    init = get_in(result.metadata, [:init]) || %{}
    available_tools = MapSet.new(Map.get(init, :tools, []))

    connected? =
      Enum.any?(Map.get(init, :mcp_servers, []), fn server ->
        name = Map.get(server, "name") || Map.get(server, :name)
        status = Map.get(server, "status") || Map.get(server, :status)
        name == "symphony_tracker" and status == "connected"
      end)

    missing_tools = Enum.reject(session.expected_mcp_tools, &MapSet.member?(available_tools, &1))

    if connected? and missing_tools == [] do
      :ok
    else
      {:error, {:claude_mcp_initialization_failed, %{connected: connected?, missing_tools: missing_tools}}}
    end
  end

  defp stop_mcp_context(%{mcp_handle: handle, mcp_config_dir: config_dir}),
    do: stop_mcp_context(%{handle: handle, config_dir: config_dir})

  defp stop_mcp_context(%{handle: handle, config_dir: config_dir}) do
    if match?(%MCPHandle{}, handle), do: TrackerMCP.stop_session(handle)
    if is_binary(config_dir), do: File.rm_rf(config_dir)
    :ok
  end

  defp stopped_transport_metadata(session) do
    remote_port = session_transport_info(session)[:remote_port]
    mcp_enabled = Map.get(session, :mcp_enabled, false)

    %{
      mcp: %{
        enabled: mcp_enabled,
        health: if(mcp_enabled, do: :stopped, else: :disabled),
        transport: Map.get(session, :mcp_transport, :none)
      },
      ssh_tunnel: %{
        health: if(is_integer(remote_port), do: :stopped, else: :disabled),
        remote_port: remote_port
      }
    }
  end

  defp session_transport_info(session) do
    Session.transport_info(session.pid)
  catch
    :exit, _reason -> %{}
  end

  defp mcp_transport(nil, _worker_host), do: :none
  defp mcp_transport(_options, nil), do: :local_http
  defp mcp_transport(_options, _worker_host), do: :ssh_reverse_tunnel

  defp resolve_mcp_options(tool_session, opts) do
    case Keyword.fetch(opts, :mcp_options_resolver) do
      {:ok, resolver} when is_function(resolver, 1) -> resolver.(tool_session)
      {:ok, _resolver} -> {:error, :invalid_claude_mcp_options_resolver}
      :error -> {:ok, Keyword.get(opts, :mcp_options)}
    end
  end

  defp validate_workspace_cwd(workspace, settings, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Config.local_workspace_root(settings)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, _settings, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      Path.type(workspace) != :absolute ->
        {:error, {:invalid_workspace_cwd, :not_absolute, workspace}}

      String.contains?(workspace, ["\0", "\n", "\r"]) ->
        {:error, {:invalid_workspace_cwd, :invalid_path, workspace}}

      true ->
        script = "set -eu\ncd #{shell_escape(workspace)}\npwd -P"

        case run_remote_bounded(worker_host, script, @max_auth_status_timeout_ms) do
          {:ok, {output, 0}} ->
            validate_remote_canonical_workspace(output)

          {:ok, {output, status}} ->
            {:error, {:invalid_workspace_cwd, :remote_unreadable, worker_host, status, output}}

          {:error, reason} ->
            {:error, {:invalid_workspace_cwd, :remote_preflight_failed, worker_host, reason}}
        end
    end
  end

  defp validate_workspace_cwd(workspace, _settings, _worker_host),
    do: {:error, {:invalid_workspace_cwd, :invalid_path, workspace}}

  defp validate_remote_canonical_workspace(output) do
    canonical_workspace = String.trim(output)

    if Path.type(canonical_workspace) == :absolute do
      {:ok, canonical_workspace}
    else
      {:error, {:invalid_workspace_cwd, :invalid_remote_canonical_path, output}}
    end
  end

  defp bind_session_id(%{session_id: nil} = session, session_id) when is_binary(session_id),
    do: {:ok, %{session | session_id: session_id}}

  defp bind_session_id(%{session_id: session_id} = session, session_id) when is_binary(session_id),
    do: {:ok, session}

  defp bind_session_id(%{session_id: expected}, actual) do
    {:error, {:claude_session_id_mismatch, expected, actual}}
  end

  defp maybe_bind_session_id(%{session_id: nil} = session, session_id) when is_binary(session_id),
    do: %{session | session_id: session_id}

  defp maybe_bind_session_id(session, _session_id), do: session

  defp resolve_executable(command, nil) when is_binary(command) do
    with {:ok, [program | args]} <- parse_command_argv(command) do
      case System.find_executable(program) do
        nil -> {:error, {:claude_executable_not_found, program}}
        executable -> {:ok, executable, args}
      end
    end
  end

  defp resolve_executable(command, worker_host)
       when is_binary(command) and is_binary(worker_host) do
    with {:ok, [program | args]} <- parse_command_argv(command) do
      {:ok, program, args}
    end
  end

  defp resolve_executable(command, _worker_host),
    do: {:error, {:claude_executable_not_found, command}}

  defp resolve_executable(command), do: resolve_executable(command, nil)

  defp validate_non_blank(value, reason) when is_binary(value) do
    if String.trim(value) == "", do: {:error, reason}, else: :ok
  end

  defp validate_non_blank(_value, reason), do: {:error, reason}

  defp validate_optional_non_blank(nil, _reason), do: :ok

  defp validate_optional_non_blank(value, reason) when is_binary(value) do
    if String.trim(value) == "", do: {:error, reason}, else: :ok
  end

  defp validate_optional_non_blank(_value, reason), do: {:error, reason}

  defp validate_permission_mode(mode) when mode in @permission_modes, do: :ok
  defp validate_permission_mode(mode), do: {:error, {:invalid_claude_permission_mode, mode}}

  defp validate_reserved_command_flags(command) when is_binary(command) do
    with {:ok, argv} <- parse_command_argv(command) do
      case Enum.find_value(argv, &reserved_command_flag/1) do
        nil -> :ok
        flag -> {:error, {:reserved_claude_command_flag, flag}}
      end
    end
  end

  defp validate_reserved_command_flags(_command), do: :ok

  defp reserved_command_flag(token) do
    Enum.find(@reserved_command_flags, fn flag ->
      token == flag or String.starts_with?(token, flag <> "=")
    end)
  end

  defp validate_authentication(executable, command_args, timeout_ms) do
    task =
      Task.async(fn ->
        System.cmd(executable, command_args ++ ["auth", "status"], stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, status}} -> classify_auth_status(output, status)
      {:exit, reason} -> {:error, {:claude_auth_status_failed, {:process_exit, reason}}}
      nil -> {:error, {:claude_auth_status_failed, :timeout}}
    end
  end

  defp validate_remote_dependencies(worker_host, executable, script, timeout_ms) do
    case run_remote_bounded(worker_host, script, timeout_ms) do
      {:ok, {output, 0}} -> classify_auth_status(output, 0)
      {:ok, {_output, 41}} -> {:error, {:remote_bash_not_found, worker_host}}
      {:ok, {_output, 42}} -> {:error, {:remote_claude_executable_not_found, worker_host, executable}}
      {:ok, {_output, 43}} -> {:error, {:remote_curl_not_found, worker_host}}
      {:ok, {output, status}} -> classify_auth_status(output, status)
      {:error, reason} -> {:error, {:claude_remote_preflight_failed, worker_host, reason}}
    end
  end

  defp validate_remote_port_forwarding(worker_host, timeout_ms) do
    case SSH.probe_reverse_tunnel(worker_host, timeout_ms) do
      :ok -> :ok
      {:error, reason} -> {:error, {:claude_remote_port_forwarding_failed, worker_host, reason}}
    end
  end

  defp validate_command_tokens(command) do
    case parse_command_argv(command) do
      {:ok, [_program | _args]} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp parse_command_argv(command) when is_binary(command) do
    case OptionParser.split(command) do
      [] -> {:error, :invalid_claude_command}
      argv -> {:ok, argv}
    end
  rescue
    RuntimeError -> {:error, :invalid_claude_command_syntax}
  end

  defp parse_command_argv(_command), do: {:error, :invalid_claude_command}

  defp run_remote_bounded(worker_host, script, timeout_ms) do
    task =
      Task.async(fn ->
        SSH.run(worker_host, script, stderr_to_stdout: true, noninteractive: true)
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:ssh_process_exit, reason}}
      nil -> {:error, :timeout}
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp classify_auth_status(output, status) do
    case Jason.decode(output) do
      {:ok, %{"loggedIn" => true}} when status == 0 ->
        :ok

      {:ok, %{"loggedIn" => logged_in} = auth_status} when is_boolean(logged_in) ->
        {:error,
         {:claude_authentication_failed,
          %{
            api_provider: auth_status["apiProvider"],
            auth_method: auth_status["authMethod"],
            exit_status: status,
            logged_in: logged_in
          }}}

      _other ->
        {:error,
         {:claude_auth_status_failed,
          %{
            exit_status: status,
            reason: :invalid_response
          }}}
    end
  end

  defp validate_positive_timeout(value, _reason) when is_integer(value) and value > 0, do: :ok
  defp validate_positive_timeout(_value, reason), do: {:error, reason}

  defp last_turn_id(0), do: nil
  defp last_turn_id(turn_number), do: "turn-#{turn_number}"

  defp default_on_event(_event), do: :ok
end
