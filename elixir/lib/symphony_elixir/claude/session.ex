defmodule SymphonyElixir.Claude.Session do
  @moduledoc """
  Owns local or SSH-hosted Claude CLI processes and their incremental stream parser.

  The optional `mcp_options` map is the integration seam for the tracker MCP
  transport. It accepts `:config`, `:allowed_tools`, and `:env`; this module
  only translates an already-authorized binding into CLI arguments and child
  environment entries.
  """

  use GenServer

  alias SymphonyElixir.AgentEvent
  alias SymphonyElixir.AgentTurnResult
  alias SymphonyElixir.Claude.StreamParser
  alias SymphonyElixir.SSH
  alias SymphonyElixir.SSH.Tunnel
  alias SymphonyElixir.Tracker.Issue

  @launcher_script ~S'''
  set -m
  prompt_file=$1
  stderr_file=$2
  shift 2
  exec 2>> "$stderr_file"
  wrapper_pid=$$
  child=
  monitor=
  killer=

  cleanup() {
    trap - TERM INT HUP EXIT
    if [ -n "$monitor" ]; then
      kill "$monitor" 2>/dev/null || true
      wait "$monitor" 2>/dev/null || true
    fi
    if [ -n "$child" ]; then
      kill -TERM -- "-$child" 2>/dev/null || true
      (
        sleep 0.2
        kill -KILL -- "-$child" 2>/dev/null || true
      ) &
      killer=$!
      wait "$child" 2>/dev/null || true
      kill "$killer" 2>/dev/null || true
      wait "$killer" 2>/dev/null || true
    fi
  }

  trap 'cleanup; exit 143' TERM INT HUP

  (
    while IFS= read -r _line; do :; done
    kill -TERM "$wrapper_pid" 2>/dev/null || true
  ) &
  monitor=$!

  "$@" < "$prompt_file" 2> "$stderr_file" &
  child=$!
  wait "$child"
  status=$?

  kill "$monitor" 2>/dev/null || true
  wait "$monitor" 2>/dev/null || true
  trap - TERM INT HUP EXIT
  exit "$status"
  '''

  @max_stderr_bytes 8_192
  @remote_stage_timeout_ms 10_000
  @default_remote_port_attempts 5

  @type mcp_options :: %{
          optional(:config) => String.t(),
          optional(:allowed_tools) => [String.t()],
          optional(:env) => %{optional(String.t()) => String.t()}
        }

  @type active_turn :: %{
          required(:from) => GenServer.from(),
          required(:on_event) => (AgentEvent.t() -> term()),
          required(:parser) => StreamParser.t(),
          required(:port) => port(),
          required(:read_timer) => reference(),
          required(:resume_session_id) => String.t() | nil,
          required(:stderr_path) => Path.t(),
          required(:temp_dir) => Path.t(),
          required(:token) => reference(),
          required(:turn_id) => String.t(),
          required(:turn_timer) => reference()
        }

  @type state :: %{
          required(:active) => active_turn() | nil,
          required(:claude) => map(),
          required(:command_args) => [String.t()],
          required(:executable) => Path.t(),
          required(:mcp_options) => mcp_options() | nil,
          required(:tool_session) => map() | nil,
          required(:workspace) => Path.t(),
          optional(:remote_env_path) => Path.t() | nil,
          optional(:remote_staging_dir) => Path.t() | nil,
          optional(:transport_error) => term() | nil,
          optional(:tunnel) => Tunnel.t() | nil,
          optional(:worker_host) => String.t() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    case GenServer.start(__MODULE__, opts) do
      {:ok, pid} ->
        Process.link(pid)
        {:ok, pid}

      {:error, _reason} = error ->
        error
    end
  end

  @spec run_turn(
          pid(),
          String.t(),
          Issue.t(),
          String.t(),
          String.t() | nil,
          (AgentEvent.t() -> term())
        ) :: {:ok, AgentTurnResult.t()} | {:error, term()}
  def run_turn(pid, prompt, %Issue{} = issue, turn_id, resume_session_id, on_event)
      when is_pid(pid) and is_binary(prompt) and is_binary(turn_id) and is_function(on_event, 1) do
    GenServer.call(
      pid,
      {:run_turn, prompt, issue, turn_id, resume_session_id, on_event},
      :infinity
    )
  end

  @spec stop(pid(), term()) :: :ok | {:error, term()}
  def stop(pid, reason) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.call(pid, {:stop, reason}, :infinity)
      catch
        :exit, {:noproc, _details} -> :ok
        :exit, {:normal, _details} -> :ok
      end
    else
      :ok
    end
  end

  @spec transport_info(pid()) :: map()
  def transport_info(pid) when is_pid(pid), do: GenServer.call(pid, :transport_info)

  @impl true
  def init(opts) do
    initial_state = %{
      active: nil,
      claude: Keyword.fetch!(opts, :claude),
      executable: Keyword.fetch!(opts, :executable),
      command_args: Keyword.get(opts, :command_args, []),
      mcp_options: Keyword.get(opts, :mcp_options),
      tool_session: Keyword.get(opts, :tool_session),
      workspace: Keyword.fetch!(opts, :workspace),
      worker_host: Keyword.get(opts, :worker_host),
      remote_staging_dir: nil,
      remote_env_path: nil,
      tunnel: nil,
      transport_error: nil
    }

    with :ok <- validate_mcp_options(initial_state.mcp_options),
         {:ok, state} <- prepare_transport(initial_state, opts) do
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(
        {:run_turn, prompt, issue, turn_id, resume_session_id, on_event},
        from,
        %{active: nil, transport_error: nil} = state
      ) do
    case start_turn(state, prompt, issue, turn_id, resume_session_id, on_event, from) do
      {:ok, next_state} -> {:noreply, next_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:run_turn, _prompt, _issue, _turn_id, _session_id, _on_event},
        _from,
        %{transport_error: reason} = state
      )
      when not is_nil(reason) do
    {:reply, {:error, reason}, state}
  end

  def handle_call({:run_turn, _prompt, _issue, _turn_id, _session_id, _on_event}, _from, state) do
    {:reply, {:error, :claude_turn_already_running}, state}
  end

  def handle_call({:stop, reason}, _from, state) do
    state = cancel_active(state, {:claude_cancelled, reason})
    {state, cleanup_result} = cleanup_transport(state)
    {:stop, :normal, cleanup_result, state}
  end

  def handle_call(:transport_info, _from, state) do
    {:reply,
     %{
       remote_port: tunnel_remote_port(state.tunnel),
       remote_staging_dir: state.remote_staging_dir,
       worker_host: state.worker_host,
       workspace: state.workspace
     }, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{active: %{port: port} = active} = state) do
    active = reset_read_timer(active, state.claude.read_timeout_ms)

    case StreamParser.push(active.parser, data) do
      {:ok, parser, events} ->
        parser = refresh_parser_transport_metadata(parser)
        active = %{active | parser: parser}
        emit_parser_events(active, events)
        {:noreply, %{state | active: active}}

      {:error, reason, parser, events} ->
        parser = refresh_parser_transport_metadata(parser)
        active = %{active | parser: parser}
        emit_parser_events(active, events)
        state = %{state | active: active}
        {:noreply, fail_active(state, {:claude_stream_error, reason})}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{active: %{port: port} = active} = state) do
    state = finish_active(state, active, status)
    {:noreply, state}
  end

  def handle_info({:claude_read_timeout, token}, %{active: %{token: token}} = state) do
    {:noreply, fail_active(state, :claude_read_timeout)}
  end

  def handle_info({:claude_turn_timeout, token}, %{active: %{token: token}} = state) do
    {:noreply, fail_active(state, :claude_turn_timeout)}
  end

  def handle_info(
        {:ssh_reverse_tunnel_exit, owner, status},
        %{tunnel: %Tunnel{owner: owner}} = state
      ) do
    reason = {:ssh_tunnel_lost, status}
    tunnel = state.tunnel
    state = if state.active, do: fail_active(state, reason), else: state
    :ok = SSH.stop_reverse_tunnel(tunnel)
    {:noreply, %{state | transport_error: reason, tunnel: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    state = cancel_active(state, :claude_session_terminated, reply: false)
    {_state, _cleanup_result} = cleanup_transport(state)
    :ok
  end

  defp start_turn(state, prompt, issue, turn_id, resume_session_id, on_event, from) do
    with {:ok, temp_dir, prompt_path, stderr_path} <- write_prompt(state, prompt, turn_id),
         {:ok, port} <-
           open_turn_port(state, resume_session_id, prompt_path, stderr_path, temp_dir) do
      token = make_ref()
      metadata = process_metadata(port, state)

      parser =
        StreamParser.new(
          issue_id: issue.id,
          turn_id: turn_id,
          metadata: metadata
        )

      emit_event(on_event, :turn_started, issue.id, resume_session_id, turn_id, %{}, metadata)

      active = %{
        from: from,
        on_event: on_event,
        parser: parser,
        port: port,
        read_timer: Process.send_after(self(), {:claude_read_timeout, token}, state.claude.read_timeout_ms),
        resume_session_id: resume_session_id,
        stderr_path: stderr_path,
        temp_dir: temp_dir,
        token: token,
        turn_id: turn_id,
        turn_timer: Process.send_after(self(), {:claude_turn_timeout, token}, state.claude.turn_timeout_ms)
      }

      {:ok, %{state | active: active}}
    else
      {:error, reason, temp_dir} ->
        cleanup_turn(state, temp_dir)
        {:error, reason}
    end
  end

  defp open_turn_port(state, resume_session_id, prompt_path, stderr_path, temp_dir) do
    case open_port(state, resume_session_id, prompt_path, stderr_path) do
      {:ok, port} -> {:ok, port}
      {:error, reason} -> {:error, reason, temp_dir}
    end
  end

  defp write_prompt(%{worker_host: nil}, prompt, _turn_id) do
    temp_dir =
      Path.join(
        System.tmp_dir!(),
        "symphony-claude-#{Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)}"
      )

    prompt_path = Path.join(temp_dir, "prompt")
    stderr_path = Path.join(temp_dir, "stderr")

    with :ok <- File.mkdir(temp_dir),
         :ok <- File.chmod(temp_dir, 0o700),
         :ok <- File.write(prompt_path, prompt, [:binary]),
         :ok <- File.chmod(prompt_path, 0o600),
         :ok <- File.write(stderr_path, "", [:binary]),
         :ok <- File.chmod(stderr_path, 0o600) do
      {:ok, temp_dir, prompt_path, stderr_path}
    else
      {:error, reason} -> {:error, {:claude_prompt_file_failed, reason}, temp_dir}
    end
  end

  defp write_prompt(%{worker_host: worker_host, remote_staging_dir: staging_dir}, prompt, turn_id)
       when is_binary(worker_host) and is_binary(staging_dir) do
    turn_dir = Path.join(staging_dir, turn_id)
    prompt_path = Path.join(turn_dir, "prompt")
    stderr_path = Path.join(turn_dir, "stderr")

    setup =
      "set -eu\numask 077\nmkdir -p #{shell_escape(turn_dir)}\nchmod 700 #{shell_escape(turn_dir)}"

    with {:ok, {_output, 0}} <- remote_run(worker_host, setup),
         {:ok, {_output, 0}} <- stage_remote_file(worker_host, prompt_path, prompt),
         {:ok, {_output, 0}} <- stage_remote_file(worker_host, stderr_path, "") do
      {:ok, turn_dir, prompt_path, stderr_path}
    else
      {:ok, {output, status}} ->
        {:error, {:claude_remote_prompt_failed, status, redact(output)}, turn_dir}

      {:error, reason} ->
        {:error, {:claude_remote_prompt_failed, reason}, turn_dir}
    end
  end

  defp open_port(%{worker_host: nil} = state, resume_session_id, prompt_path, stderr_path) do
    with {:ok, bash} <- find_bash() do
      args =
        [
          "-c",
          @launcher_script,
          "symphony-claude-launcher",
          prompt_path,
          stderr_path,
          state.executable
        ] ++ state.command_args ++ cli_args(state.claude, resume_session_id, state.mcp_options)

      port_options = [
        :binary,
        :exit_status,
        args: Enum.map(args, &String.to_charlist/1),
        cd: String.to_charlist(state.workspace),
        env: child_environment(state.tool_session, state.mcp_options)
      ]

      try do
        {:ok, Port.open({:spawn_executable, String.to_charlist(bash)}, port_options)}
      rescue
        error in ArgumentError -> {:error, {:claude_process_start_failed, Exception.message(error)}}
      end
    end
  end

  defp open_port(
         %{worker_host: worker_host} = state,
         resume_session_id,
         prompt_path,
         stderr_path
       )
       when is_binary(worker_host) do
    launcher_args =
      [
        "symphony-claude-launcher",
        prompt_path,
        stderr_path,
        state.executable
      ] ++ state.command_args ++ cli_args(state.claude, resume_session_id, state.mcp_options)

    command =
      [
        "set -eu",
        "cd #{shell_escape(state.workspace)}",
        remote_environment_command(state.remote_env_path),
        remote_secret_unsets(state.tool_session),
        "exec bash -c #{shell_escape(@launcher_script)} " <>
          Enum.map_join(launcher_args, " ", &shell_escape/1)
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    case SSH.start_port(worker_host, command, noninteractive: true) do
      {:ok, port} -> {:ok, port}
      {:error, reason} -> {:error, {:claude_remote_process_start_failed, reason}}
    end
  end

  defp cli_args(claude, resume_session_id, mcp_options) do
    [
      "-p",
      "--input-format",
      "text",
      "--output-format",
      "stream-json",
      "--verbose"
    ]
    |> append_resume(resume_session_id)
    |> Kernel.++(["--permission-mode", claude.permission_mode])
    |> append_mcp_options(mcp_options)
    |> append_model(claude.model)
  end

  defp append_resume(args, nil), do: args
  defp append_resume(args, session_id), do: args ++ ["--resume", session_id]

  defp append_mcp_options(args, nil), do: args

  defp append_mcp_options(args, mcp_options) do
    args = args ++ ["--mcp-config", mcp_options.config]

    case mcp_options.allowed_tools do
      [] -> args
      tools -> args ++ ["--allowedTools", Enum.join(tools, ",")]
    end
  end

  defp append_model(args, nil), do: args
  defp append_model(args, model), do: args ++ ["--model", model]

  defp child_environment(tool_session, mcp_options) do
    mcp_environment =
      case mcp_options do
        %{env: env} -> Enum.map(env, fn {name, value} -> {String.to_charlist(name), String.to_charlist(value)} end)
        _ -> []
      end

    secret_environment =
      tool_session
      |> secret_environment_names()
      |> Enum.map(fn name -> {String.to_charlist(name), false} end)

    mcp_environment ++ secret_environment
  end

  defp secret_environment_names(%{secret_environment_names: names}) when is_list(names) do
    Enum.filter(names, &valid_environment_name?/1)
  end

  defp secret_environment_names(_tool_session), do: []

  defp valid_environment_name?(name) when is_binary(name),
    do: String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)

  defp valid_environment_name?(_name), do: false

  defp validate_mcp_options(nil), do: :ok

  defp validate_mcp_options(%{config: config, allowed_tools: allowed_tools} = options)
       when is_binary(config) and is_list(allowed_tools) do
    env = Map.get(options, :env, %{})

    cond do
      String.trim(config) == "" ->
        {:error, :invalid_claude_mcp_config}

      not Enum.all?(allowed_tools, &valid_tracker_tool_name?/1) ->
        {:error, :invalid_claude_mcp_allowed_tools}

      not is_map(env) ->
        {:error, :invalid_claude_mcp_environment}

      not Enum.all?(env, fn {name, value} ->
        valid_environment_name?(name) and is_binary(value)
      end) ->
        {:error, :invalid_claude_mcp_environment}

      true ->
        :ok
    end
  end

  defp validate_mcp_options(_options), do: {:error, :invalid_claude_mcp_options}

  defp valid_tracker_tool_name?(name) when is_binary(name) do
    String.starts_with?(name, "mcp__symphony_tracker__") and
      String.trim_leading(name, "mcp__symphony_tracker__") != ""
  end

  defp valid_tracker_tool_name?(_name), do: false

  defp prepare_transport(%{worker_host: nil} = state, _opts), do: {:ok, state}

  defp prepare_transport(%{worker_host: worker_host} = state, opts)
       when is_binary(worker_host) do
    with {:ok, remote_staging_dir} <- create_remote_staging_dir(worker_host, state.workspace),
         {:ok, remote_mcp} <-
           prepare_remote_mcp(
             worker_host,
             remote_staging_dir,
             state.mcp_options,
             Keyword.get(opts, :remote_port_candidates)
           ) do
      {:ok,
       %{
         state
         | mcp_options: remote_mcp.options,
           remote_env_path: remote_mcp.env_path,
           remote_staging_dir: remote_staging_dir,
           tunnel: remote_mcp.tunnel
       }}
    else
      {:error, reason, remote_staging_dir, tunnel} ->
        if match?(%Tunnel{}, tunnel), do: SSH.stop_reverse_tunnel(tunnel)
        _ = cleanup_remote_staging(worker_host, remote_staging_dir)
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_remote_staging_dir(worker_host, workspace) do
    script =
      "set -eu\numask 077\n" <>
        ~S|dir=$(mktemp -d "/tmp/symphony-claude.XXXXXX")| <>
        "\n" <>
        "chmod 700 \"$dir\"\nprintf '%s\\n' \"$dir\""

    case remote_run(worker_host, script) do
      {:ok, {output, 0}} ->
        path = String.trim(output)

        if valid_remote_staging_dir?(path) and not path_within?(path, workspace) do
          {:ok, path}
        else
          {:error, {:claude_remote_staging_invalid, path}}
        end

      {:ok, {output, status}} ->
        {:error, {:claude_remote_staging_failed, status, redact(output)}}

      {:error, reason} ->
        {:error, {:claude_remote_staging_failed, reason}}
    end
  end

  defp valid_remote_staging_dir?(path) when is_binary(path) do
    Path.type(path) == :absolute and
      String.starts_with?(Path.basename(path), "symphony-claude.") and
      not String.contains?(path, ["\0", "\n", "\r"])
  end

  defp path_within?(path, parent) do
    path == parent or String.starts_with?(path <> "/", String.trim_trailing(parent, "/") <> "/")
  end

  defp prepare_remote_mcp(_worker_host, _staging_dir, nil, _port_candidates) do
    {:ok, %{options: nil, env_path: nil, tunnel: nil}}
  end

  defp prepare_remote_mcp(worker_host, staging_dir, mcp_options, port_candidates) do
    with {:ok, local_port, token} <- remote_mcp_endpoint(mcp_options),
         {:ok, config} <- read_mcp_config(mcp_options.config),
         :ok <- validate_remote_mcp_config(config, token),
         {:ok, tunnel} <- start_remote_tunnel(worker_host, local_port, port_candidates) do
      config_path = Path.join(staging_dir, "mcp.json")
      env_path = Path.join(staging_dir, "session.env")
      remote_url = "http://127.0.0.1:#{tunnel.remote_port}/mcp"
      env = remote_mcp_environment(remote_url, token)

      with {:ok, {_output, 0}} <- stage_remote_file(worker_host, config_path, config),
           {:ok, {_output, 0}} <- stage_remote_file(worker_host, env_path, env),
           {:ok, {_output, 0}} <- remote_mcp_health(worker_host, env_path, tunnel.remote_port) do
        {:ok,
         %{
           options: %{config: config_path, allowed_tools: mcp_options.allowed_tools, env: %{}},
           env_path: env_path,
           tunnel: tunnel
         }}
      else
        {:ok, {output, status}} ->
          {:error, {:claude_remote_mcp_staging_failed, status, redact(output)}, staging_dir, tunnel}

        {:error, reason} ->
          {:error, {:claude_remote_mcp_staging_failed, reason}, staging_dir, tunnel}
      end
    else
      {:error, reason} -> {:error, reason, staging_dir, nil}
    end
  end

  defp remote_mcp_endpoint(%{env: env}) when is_map(env) do
    url = Map.get(env, "SYMPHONY_TRACKER_MCP_URL")
    token = Map.get(env, "SYMPHONY_TRACKER_MCP_TOKEN")

    with {:ok, port} <- remote_mcp_port(url),
         {:ok, token} <- remote_mcp_token(token) do
      {:ok, port, token}
    end
  end

  defp remote_mcp_endpoint(_mcp_options), do: {:error, :invalid_claude_remote_mcp_environment}

  defp remote_mcp_port(url) when is_binary(url) do
    uri = URI.parse(url)

    if uri.scheme == "http" and uri.host in ["127.0.0.1", "localhost", "::1"] and
         is_integer(uri.port) and uri.port in 1..65_535 do
      {:ok, uri.port}
    else
      {:error, :invalid_claude_remote_mcp_url}
    end
  end

  defp remote_mcp_port(_url), do: {:error, :invalid_claude_remote_mcp_url}

  defp remote_mcp_token(token) when is_binary(token) and token != "", do: {:ok, token}
  defp remote_mcp_token(_token), do: {:error, :invalid_claude_remote_mcp_token}

  defp read_mcp_config(path) when is_binary(path) do
    case File.read(path) do
      {:ok, config} -> {:ok, config}
      {:error, reason} -> {:error, {:claude_mcp_config_read_failed, reason}}
    end
  end

  defp validate_remote_mcp_config(config, token) do
    if String.contains?(config, token) do
      {:error, :claude_remote_mcp_config_contains_token}
    else
      :ok
    end
  end

  defp start_remote_tunnel(worker_host, local_port, nil) do
    first_port = 40_000 + rem(System.unique_integer([:positive, :monotonic]), 20_000)
    candidates = Enum.map(0..(@default_remote_port_attempts - 1), &(40_000 + rem(first_port + &1, 20_000)))
    start_remote_tunnel(worker_host, local_port, candidates)
  end

  defp start_remote_tunnel(worker_host, local_port, candidates) when is_list(candidates) do
    do_start_remote_tunnel(worker_host, local_port, Enum.uniq(candidates), [])
  end

  defp start_remote_tunnel(_worker_host, _local_port, _candidates),
    do: {:error, :invalid_claude_remote_port_candidates}

  defp do_start_remote_tunnel(_worker_host, _local_port, [], errors) do
    {:error, {:claude_ssh_tunnel_failed, Enum.reverse(errors)}}
  end

  defp do_start_remote_tunnel(worker_host, local_port, [remote_port | rest], errors) do
    case SSH.start_reverse_tunnel(worker_host, remote_port, local_port,
           startup_timeout: 2_000,
           poll_interval: 10
         ) do
      {:ok, tunnel} ->
        {:ok, tunnel}

      {:error, reason} ->
        do_start_remote_tunnel(worker_host, local_port, rest, [{remote_port, reason} | errors])
    end
  end

  defp stage_remote_file(worker_host, path, contents) do
    script = "set -eu\numask 077\ncat > #{shell_escape(path)}\nchmod 600 #{shell_escape(path)}"

    SSH.run_with_input(worker_host, script, contents,
      noninteractive: true,
      stderr_to_stdout: true,
      timeout: @remote_stage_timeout_ms
    )
  end

  defp remote_mcp_environment(url, token) do
    [
      "export SYMPHONY_TRACKER_MCP_URL=#{shell_escape(url)}",
      "export SYMPHONY_TRACKER_MCP_TOKEN=#{shell_escape(token)}"
    ]
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp remote_mcp_health(worker_host, env_path, remote_port) do
    health_url = "http://127.0.0.1:#{remote_port}/health"

    script =
      [
        "# SYMPHONY_MCP_HEALTH",
        "set -eu",
        ". #{shell_escape(env_path)}",
        "command -v curl >/dev/null 2>&1 || exit 43",
        "status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' " <>
          "--max-time 5 --header \"Authorization: Bearer $SYMPHONY_TRACKER_MCP_TOKEN\" " <>
          shell_escape(health_url) <> ")",
        "test \"$status\" = 200"
      ]
      |> Enum.join("\n")

    remote_run(worker_host, script)
  end

  defp remote_environment_command(nil), do: ""

  defp remote_environment_command(path) when is_binary(path) do
    ". #{shell_escape(path)}"
  end

  defp remote_secret_unsets(tool_session) do
    tool_session
    |> secret_environment_names()
    |> Enum.map_join("\n", &"unset #{&1}")
  end

  defp remote_run(worker_host, script) do
    task =
      Task.async(fn ->
        SSH.run(worker_host, script, stderr_to_stdout: true, noninteractive: true)
      end)

    case Task.yield(task, @remote_stage_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:ssh_command_failed, reason}}
      nil -> {:error, {:ssh_command_timeout, @remote_stage_timeout_ms}}
    end
  rescue
    error -> {:error, {:ssh_command_failed, Exception.message(error)}}
  end

  defp finish_active(state, active, status) do
    cancel_timers(active)

    reply =
      case StreamParser.finish(active.parser) do
        {:ok, result, events} ->
          emit_parser_events(active, events)
          finish_result(result, status, active.stderr_path, state)

        {:error, reason, events} ->
          emit_parser_events(active, events)
          {:error, {:claude_stream_error, reason, process_failure(status, active.stderr_path, state)}}
      end

    GenServer.reply(active.from, reply)
    cleanup_turn(state, active.temp_dir)
    %{state | active: nil}
  end

  defp finish_result(%AgentTurnResult{status: :completed} = result, 0, _stderr_path, _state),
    do: {:ok, put_process_status(result, 0)}

  defp finish_result(%AgentTurnResult{status: status} = result, exit_status, _stderr_path, _state)
       when status in [:blocked, :failed],
       do: {:ok, put_process_status(result, exit_status)}

  defp finish_result(%AgentTurnResult{}, exit_status, stderr_path, state),
    do: {:error, {:claude_process_exit, exit_status, stderr_summary(stderr_path, state)}}

  defp put_process_status(result, status) do
    %{result | metadata: Map.put(result.metadata, :process_exit_status, status)}
  end

  defp process_failure(0, _stderr_path, _state), do: nil

  defp process_failure(status, stderr_path, state) do
    %{exit_status: status, stderr: stderr_summary(stderr_path, state)}
  end

  defp fail_active(%{active: active} = state, reason) do
    cancel_timers(active)
    close_port(active.port)

    emit_event(
      active.on_event,
      :turn_failed,
      active.parser.issue_id,
      active.parser.session_id,
      active.turn_id,
      %{reason: reason},
      failure_transport_metadata(active.parser.metadata, reason)
    )

    GenServer.reply(active.from, {:error, reason})
    cleanup_turn(state, active.temp_dir)
    %{state | active: nil}
  end

  defp cancel_active(state, reason, opts \\ [])

  defp cancel_active(%{active: nil} = state, _reason, _opts), do: state

  defp cancel_active(%{active: active} = state, reason, opts) do
    cancel_timers(active)
    close_port(active.port)

    if Keyword.get(opts, :reply, true) do
      GenServer.reply(active.from, {:error, reason})
    end

    cleanup_turn(state, active.temp_dir)
    %{state | active: nil}
  end

  defp reset_read_timer(active, timeout_ms) do
    cancel_timer(active.read_timer)

    %{
      active
      | read_timer: Process.send_after(self(), {:claude_read_timeout, active.token}, timeout_ms)
    }
  end

  defp cancel_timers(active) do
    cancel_timer(active.read_timer)
    cancel_timer(active.turn_timer)
  end

  defp cancel_timer(timer) when is_reference(timer) do
    _ = Process.cancel_timer(timer, async: true, info: false)
    :ok
  end

  defp close_port(port) when is_port(port) do
    if Port.info(port) do
      try do
        Port.close(port)
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  defp cleanup_temp_dir(path) when is_binary(path) do
    _ = File.rm_rf(path)
    :ok
  end

  defp cleanup_turn(%{worker_host: nil}, path), do: cleanup_temp_dir(path)

  defp cleanup_turn(%{worker_host: worker_host}, path)
       when is_binary(worker_host) and is_binary(path) do
    cleanup_remote_staging(worker_host, path)
  end

  defp cleanup_transport(state) do
    if match?(%Tunnel{}, state.tunnel), do: SSH.stop_reverse_tunnel(state.tunnel)

    cleanup_result =
      if is_binary(state.worker_host) and is_binary(state.remote_staging_dir) do
        cleanup_remote_staging(state.worker_host, state.remote_staging_dir)
      else
        :ok
      end

    {%{state | tunnel: nil, remote_staging_dir: nil, remote_env_path: nil}, cleanup_result}
  end

  defp cleanup_remote_staging(worker_host, path) do
    if valid_remote_cleanup_path?(path) do
      case remote_run(worker_host, "rm -rf -- #{shell_escape(path)}") do
        {:ok, {_output, 0}} -> :ok
        {:ok, {output, status}} -> {:error, {:claude_remote_cleanup_failed, status, redact(output)}}
        {:error, reason} -> {:error, {:claude_remote_cleanup_failed, reason}}
      end
    else
      {:error, {:claude_remote_cleanup_refused, path}}
    end
  end

  defp valid_remote_cleanup_path?(path) when is_binary(path) do
    Path.type(path) == :absolute and
      not String.contains?(path, ["\0", "\n", "\r"]) and
      Enum.any?(Path.split(path), &String.starts_with?(&1, "symphony-claude."))
  end

  defp tunnel_remote_port(%Tunnel{remote_port: remote_port}), do: remote_port
  defp tunnel_remote_port(_tunnel), do: nil

  defp find_bash do
    case System.find_executable("bash") do
      nil -> {:error, :bash_not_found}
      executable -> {:ok, executable}
    end
  end

  defp process_metadata(port, state) do
    %{
      workspace_path: state.workspace,
      worker_host: state.worker_host,
      mcp: mcp_transport_metadata(state),
      ssh_tunnel: ssh_tunnel_metadata(state)
    }
    |> maybe_put_os_pid(port)
  end

  defp mcp_transport_metadata(%{mcp_options: nil}) do
    %{enabled: false, health: :disabled, transport: :none}
  end

  defp mcp_transport_metadata(%{worker_host: nil}) do
    %{enabled: true, health: :initializing, transport: :local_http}
  end

  defp mcp_transport_metadata(%{tunnel: %Tunnel{}}) do
    %{enabled: true, health: :initializing, transport: :ssh_reverse_tunnel}
  end

  defp mcp_transport_metadata(_state) do
    %{enabled: true, health: :unhealthy, transport: :ssh_reverse_tunnel}
  end

  defp ssh_tunnel_metadata(%{tunnel: %Tunnel{remote_port: remote_port}}) do
    %{health: :healthy, remote_port: remote_port}
  end

  defp ssh_tunnel_metadata(_state), do: %{health: :disabled, remote_port: nil}

  defp refresh_parser_transport_metadata(%StreamParser{init: nil} = parser), do: parser

  defp refresh_parser_transport_metadata(%StreamParser{} = parser) do
    metadata =
      update_in(parser.metadata, [:mcp], fn
        %{enabled: true} = mcp -> %{mcp | health: mcp_init_health(parser.init)}
        mcp -> mcp
      end)

    %{parser | metadata: metadata}
  end

  defp mcp_init_health(%{mcp_servers: servers}) when is_list(servers) do
    if Enum.any?(servers, &connected_mcp_server?/1), do: :healthy, else: :unhealthy
  end

  defp mcp_init_health(_init), do: :unhealthy

  defp connected_mcp_server?(server) when is_map(server) do
    (Map.get(server, "status") || Map.get(server, :status)) == "connected"
  end

  defp connected_mcp_server?(_server), do: false

  defp failure_transport_metadata(metadata, {:ssh_tunnel_lost, _status}) do
    metadata
    |> update_in([:mcp], fn
      %{enabled: true} = mcp -> %{mcp | health: :unhealthy}
      mcp -> mcp
    end)
    |> update_in([:ssh_tunnel], &%{&1 | health: :unhealthy})
  end

  defp failure_transport_metadata(metadata, _reason), do: metadata

  defp maybe_put_os_pid(metadata, port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> Map.put(metadata, :os_pid, to_string(os_pid))
      _ -> metadata
    end
  end

  defp emit_parser_events(active, events) do
    events
    |> maybe_suppress_resumed_session_start(active.resume_session_id)
    |> Enum.map(&put_event_transport_metadata(&1, active.parser.metadata))
    |> Enum.each(active.on_event)
  end

  defp put_event_transport_metadata(event, metadata) do
    transport_metadata = Map.take(metadata, [:mcp, :ssh_tunnel])
    %{event | metadata: Map.merge(event.metadata, transport_metadata)}
  end

  defp maybe_suppress_resumed_session_start(events, nil), do: events

  defp maybe_suppress_resumed_session_start(events, _resume_session_id) do
    Enum.reject(events, &(&1.kind == :session_started))
  end

  defp emit_event(on_event, kind, issue_id, session_id, turn_id, payload, metadata) do
    on_event.(%AgentEvent{
      kind: kind,
      backend: :claude,
      issue_id: issue_id,
      session_id: session_id,
      turn_id: turn_id,
      timestamp: DateTime.utc_now(),
      payload: payload,
      metadata: metadata
    })
  end

  defp stderr_summary(path, %{worker_host: nil}) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        try do
          file
          |> IO.binread(@max_stderr_bytes)
          |> normalize_stderr()
        after
          File.close(file)
        end

      {:error, _reason} ->
        nil
    end
  end

  defp stderr_summary(path, %{worker_host: worker_host}) when is_binary(worker_host) do
    command = "if [ -f #{shell_escape(path)} ]; then tail -c #{@max_stderr_bytes} #{shell_escape(path)}; fi"

    case remote_run(worker_host, command) do
      {:ok, {stderr, 0}} -> normalize_stderr(stderr)
      _other -> nil
    end
  end

  defp normalize_stderr(:eof), do: nil

  defp normalize_stderr(stderr) when is_binary(stderr) do
    case String.trim(stderr) do
      "" -> nil
      output -> redact(output)
    end
  end

  defp redact(value) do
    value
    |> String.replace(~r/(Bearer\s+)[A-Za-z0-9._~+\/=:-]+/i, "\\1[REDACTED]")
    |> String.replace(
      ~r/((?:api[_-]?key|access[_-]?token|token|secret|password)\s*[=:]\s*)\S+/i,
      "\\1[REDACTED]"
    )
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
