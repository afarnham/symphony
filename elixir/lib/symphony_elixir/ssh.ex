defmodule SymphonyElixir.SSH do
  @moduledoc false

  alias __MODULE__.{Tunnel, TunnelServer}

  @max_port 65_535
  @default_tunnel_startup_timeout 10_000
  @default_tunnel_poll_interval 25
  @default_tunnel_control_timeout 1_000
  @default_input_timeout 10_000
  @forward_probe_body "symphony-ssh-forward-probe-ok"
  @forward_probe_attempts 3

  @spec run(String.t(), String.t(), keyword()) :: {:ok, {String.t(), non_neg_integer()}} | {:error, term()}
  def run(host, command, opts \\ []) when is_binary(host) and is_binary(command) do
    with {:ok, executable} <- ssh_executable() do
      command_opts = Keyword.drop(opts, [:noninteractive])
      {:ok, System.cmd(executable, ssh_args(host, command, opts), command_opts)}
    end
  end

  @spec run_with_input(String.t(), String.t(), binary(), keyword()) ::
          {:ok, {String.t(), non_neg_integer()}} | {:error, term()}
  def run_with_input(host, command, input, opts \\ [])
      when is_binary(host) and is_binary(command) and is_binary(input) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, @default_input_timeout)

    with true <- is_integer(timeout) and timeout > 0,
         {:ok, executable} <- ssh_executable(),
         {:ok, bash} <- bash_executable(),
         {:ok, temp_dir, input_path} <- write_private_input(input) do
      try do
        args =
          [
            "-c",
            ~S(input_file=$1; shift; exec "$@" < "$input_file"),
            "symphony-ssh-input",
            input_path,
            executable
          ] ++ ssh_args(host, command, opts)

        command_opts = Keyword.drop(opts, [:noninteractive, :timeout])
        run_bounded_command(bash, args, command_opts, timeout)
      after
        File.rm_rf(temp_dir)
      end
    else
      false -> {:error, {:invalid_ssh_input_timeout, timeout}}
      {:error, _reason} = error -> error
    end
  end

  @spec start_port(String.t(), String.t(), keyword()) :: {:ok, port()} | {:error, term()}
  def start_port(host, command, opts \\ []) when is_binary(host) and is_binary(command) do
    with {:ok, executable} <- ssh_executable() do
      line_bytes = Keyword.get(opts, :line)

      port_opts =
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: Enum.map(ssh_args(host, command, opts), &String.to_charlist/1)
        ]
        |> maybe_put_line_option(line_bytes)

      {:ok, Port.open({:spawn_executable, String.to_charlist(executable)}, port_opts)}
    end
  end

  @spec start_reverse_tunnel(String.t(), integer(), integer()) ::
          {:ok, Tunnel.t()} | {:error, term()}
  def start_reverse_tunnel(host, remote_port, local_port) do
    start_reverse_tunnel(host, remote_port, local_port, [])
  end

  @spec start_reverse_tunnel(String.t(), integer(), integer(), keyword()) ::
          {:ok, Tunnel.t()} | {:error, term()}
  def start_reverse_tunnel(host, remote_port, local_port, opts)
      when is_binary(host) and is_list(opts) do
    startup_timeout = Keyword.get(opts, :startup_timeout, @default_tunnel_startup_timeout)
    poll_interval = Keyword.get(opts, :poll_interval, @default_tunnel_poll_interval)
    control_timeout = Keyword.get(opts, :control_timeout, @default_tunnel_control_timeout)

    with :ok <- validate_tunnel_port(:remote, remote_port),
         :ok <- validate_tunnel_port(:local, local_port),
         :ok <- validate_positive_timeout(:startup_timeout, startup_timeout),
         :ok <- validate_positive_timeout(:poll_interval, poll_interval),
         :ok <- validate_positive_timeout(:control_timeout, control_timeout),
         {:ok, executable} <- ssh_executable(),
         {:ok, control_directory, control_path} <- create_control_path(),
         {:ok, tunnel} <-
           start_tunnel_server(
             executable,
             host,
             remote_port,
             local_port,
             control_directory,
             control_path,
             self(),
             control_timeout
           ) do
      await_tunnel_ready(tunnel, startup_timeout, poll_interval)
    end
  end

  def start_reverse_tunnel(_host, remote_port, local_port, _opts) do
    with :ok <- validate_tunnel_port(:remote, remote_port),
         :ok <- validate_tunnel_port(:local, local_port) do
      {:error, :invalid_tunnel_options}
    end
  end

  @spec reverse_tunnel_health(Tunnel.t()) :: {:ok, map()} | {:error, term()}
  def reverse_tunnel_health(%{__struct__: Tunnel, owner: owner}) when is_pid(owner) do
    if Process.alive?(owner) do
      TunnelServer.health(owner)
    else
      {:error, :tunnel_closed}
    end
  catch
    :exit, _reason -> {:error, :tunnel_closed}
  end

  def reverse_tunnel_health(_tunnel), do: {:error, :invalid_tunnel_handle}

  @spec stop_reverse_tunnel(Tunnel.t()) :: :ok
  def stop_reverse_tunnel(%{__struct__: Tunnel, owner: owner}) when is_pid(owner) do
    if Process.alive?(owner), do: TunnelServer.stop(owner), else: :ok
  catch
    :exit, _reason -> :ok
  end

  def stop_reverse_tunnel(_tunnel), do: :ok

  @spec probe_reverse_tunnel(String.t(), pos_integer()) :: :ok | {:error, term()}
  def probe_reverse_tunnel(host, timeout_ms)
      when is_binary(host) and is_integer(timeout_ms) and timeout_ms > 0 do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    with {:ok, listener} <-
           :gen_tcp.listen(0, [:binary, packet: :raw, active: false, ip: {127, 0, 0, 1}, reuseaddr: true]),
         {:ok, {_address, local_port}} <- :inet.sockname(listener) do
      server = Task.async(fn -> serve_forward_probe(listener, deadline) end)

      try do
        host
        |> do_probe_reverse_tunnel(local_port, forward_probe_ports(), deadline, [])
        |> normalize_forward_probe_result()
      after
        :gen_tcp.close(listener)
        Task.shutdown(server, :brutal_kill)
      end
    else
      {:error, reason} -> {:error, {:ssh_reverse_forward_probe_setup_failed, reason}}
    end
  end

  def probe_reverse_tunnel(_host, timeout_ms),
    do: {:error, {:invalid_ssh_reverse_forward_probe_timeout, timeout_ms}}

  @spec remote_shell_command(String.t()) :: String.t()
  def remote_shell_command(command) when is_binary(command) do
    "bash -lc " <> shell_escape(command)
  end

  defp start_tunnel_server(
         executable,
         host,
         remote_port,
         local_port,
         control_directory,
         control_path,
         notify,
         control_timeout
       ) do
    start_args = reverse_tunnel_args(host, remote_port, local_port, control_path)
    control_args = control_args(host, control_path)

    case TunnelServer.start_link(
           executable: executable,
           start_args: start_args,
           control_args: control_args,
           control_directory: control_directory,
           notify: notify,
           host: host,
           remote_port: remote_port,
           local_port: local_port,
           control_timeout: control_timeout
         ) do
      {:ok, tunnel} ->
        {:ok, tunnel}

      {:error, _reason} = error ->
        File.rm_rf(control_directory)
        error
    end
  end

  defp await_tunnel_ready(tunnel, startup_timeout, poll_interval) do
    deadline = System.monotonic_time(:millisecond) + startup_timeout
    do_await_tunnel_ready(tunnel, deadline, startup_timeout, poll_interval)
  end

  defp do_await_tunnel_ready(tunnel, deadline, startup_timeout, poll_interval) do
    case reverse_tunnel_health(tunnel) do
      {:ok, %{status: :ready}} ->
        {:ok, tunnel}

      {:error, {:ssh_tunnel_not_ready, _output}} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(poll_interval)
          do_await_tunnel_ready(tunnel, deadline, startup_timeout, poll_interval)
        else
          :ok = stop_reverse_tunnel(tunnel)
          {:error, {:ssh_tunnel_start_timeout, tunnel.host, startup_timeout}}
        end

      {:error, reason} ->
        :ok = stop_reverse_tunnel(tunnel)
        {:error, reason}
    end
  end

  defp forward_probe_ports do
    first_port = 40_000 + rem(System.unique_integer([:positive, :monotonic]), 20_000)

    Enum.map(0..(@forward_probe_attempts - 1), fn offset ->
      40_000 + rem(first_port + offset, 20_000)
    end)
  end

  defp do_probe_reverse_tunnel(_host, _local_port, [], _deadline, errors),
    do: {:error, Enum.reverse(errors)}

  defp do_probe_reverse_tunnel(host, local_port, [remote_port | rest], deadline, errors) do
    case remaining_probe_timeout(deadline) do
      0 ->
        {:error, Enum.reverse([:timeout | errors])}

      remaining_timeout ->
        host
        |> probe_reverse_tunnel_candidate(local_port, remote_port, deadline, remaining_timeout)
        |> continue_reverse_tunnel_probe(host, local_port, remote_port, rest, deadline, errors)
    end
  end

  defp probe_reverse_tunnel_candidate(host, local_port, remote_port, deadline, timeout_ms) do
    case start_reverse_tunnel(host, remote_port, local_port,
           startup_timeout: timeout_ms,
           poll_interval: min(10, timeout_ms)
         ) do
      {:ok, tunnel} ->
        try do
          run_forward_probe_request(host, remote_port, deadline)
        after
          stop_reverse_tunnel(tunnel)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp continue_reverse_tunnel_probe(:ok, _host, _local_port, _remote_port, _rest, _deadline, _errors),
    do: :ok

  defp continue_reverse_tunnel_probe(
         {:error, reason},
         host,
         local_port,
         remote_port,
         rest,
         deadline,
         errors
       ) do
    do_probe_reverse_tunnel(host, local_port, rest, deadline, [{remote_port, reason} | errors])
  end

  defp run_forward_probe_request(host, remote_port, deadline) do
    remaining_timeout = remaining_probe_timeout(deadline)
    curl_timeout_seconds = max(1, div(remaining_timeout + 999, 1_000))

    script =
      [
        "# SYMPHONY_SSH_FORWARD_PROBE",
        "set -eu",
        "command -v curl >/dev/null 2>&1 || exit 43",
        "curl --fail --silent --show-error --noproxy '*' --max-time #{curl_timeout_seconds} " <>
          shell_escape("http://127.0.0.1:#{remote_port}/")
      ]
      |> Enum.join("\n")

    case run_bounded_ssh(host, script, remaining_timeout) do
      {:ok, {output, 0}} when output == @forward_probe_body -> :ok
      {:ok, {_output, status}} -> {:error, {:probe_request_failed, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_bounded_ssh(_host, _script, 0), do: {:error, :probe_timeout}

  defp run_bounded_ssh(host, script, timeout_ms) do
    task =
      Task.async(fn ->
        run(host, script, stderr_to_stdout: true, noninteractive: true)
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:probe_process_exit, reason}}
      nil -> {:error, :probe_timeout}
    end
  end

  defp serve_forward_probe(listener, deadline) do
    case :gen_tcp.accept(listener, remaining_probe_timeout(deadline)) do
      {:ok, socket} ->
        response =
          "HTTP/1.1 200 OK\r\n" <>
            "Connection: close\r\n" <>
            "Content-Length: #{byte_size(@forward_probe_body)}\r\n\r\n" <>
            @forward_probe_body

        result = :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp remaining_probe_timeout(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end

  defp normalize_forward_probe_result(:ok), do: :ok

  defp normalize_forward_probe_result({:error, errors}),
    do: {:error, {:ssh_reverse_forward_probe_failed, errors}}

  defp create_control_path do
    directory =
      Path.join(
        System.tmp_dir!(),
        "syssh-#{Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)}"
      )

    with :ok <- File.mkdir(directory),
         :ok <- File.chmod(directory, 0o700) do
      {:ok, directory, Path.join(directory, "c")}
    else
      {:error, reason} ->
        File.rm_rf(directory)
        {:error, {:ssh_tunnel_control_path_failed, reason}}
    end
  end

  defp validate_tunnel_port(_side, port) when is_integer(port) and port in 1..@max_port,
    do: :ok

  defp validate_tunnel_port(side, port), do: {:error, {:invalid_tunnel_port, side, port}}

  defp validate_positive_timeout(_name, timeout) when is_integer(timeout) and timeout > 0, do: :ok

  defp validate_positive_timeout(name, timeout),
    do: {:error, {:invalid_tunnel_option, name, timeout}}

  defp ssh_executable do
    case System.find_executable("ssh") do
      nil -> {:error, :ssh_not_found}
      executable -> {:ok, executable}
    end
  end

  defp bash_executable do
    case System.find_executable("bash") do
      nil -> {:error, :bash_not_found}
      executable -> {:ok, executable}
    end
  end

  defp ssh_args(host, command, opts) do
    %{destination: destination, port: port} = parse_target(host)

    []
    |> maybe_put_config()
    |> Kernel.++(["-T"])
    |> maybe_put_port(port)
    |> maybe_put_noninteractive(Keyword.get(opts, :noninteractive, false))
    |> Kernel.++([destination, remote_shell_command(command)])
  end

  defp write_private_input(input) do
    directory =
      Path.join(
        System.tmp_dir!(),
        "syssh-input-#{Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)}"
      )

    path = Path.join(directory, "input")

    with :ok <- File.mkdir(directory),
         :ok <- File.chmod(directory, 0o700),
         :ok <- File.write(path, input, [:binary]),
         :ok <- File.chmod(path, 0o600) do
      {:ok, directory, path}
    else
      {:error, reason} ->
        File.rm_rf(directory)
        {:error, {:ssh_input_staging_failed, reason}}
    end
  end

  defp run_bounded_command(executable, args, opts, timeout) do
    task = Task.async(fn -> System.cmd(executable, args, opts) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> {:ok, result}
      {:exit, reason} -> {:error, {:ssh_input_process_exit, reason}}
      nil -> {:error, {:ssh_input_timeout, timeout}}
    end
  end

  defp reverse_tunnel_args(host, remote_port, local_port, control_path) do
    %{destination: destination, port: port} = parse_target(host)
    forwarding = "127.0.0.1:#{remote_port}:127.0.0.1:#{local_port}"

    []
    |> maybe_put_config()
    |> Kernel.++(["-T"])
    |> maybe_put_port(port)
    |> Kernel.++([
      "-o",
      "BatchMode=yes",
      "-o",
      "ExitOnForwardFailure=yes",
      "-o",
      "ControlMaster=yes",
      "-o",
      "ControlPersist=no",
      "-o",
      "ServerAliveInterval=15",
      "-o",
      "ServerAliveCountMax=2",
      "-S",
      control_path,
      "-N",
      "-R",
      forwarding,
      destination
    ])
  end

  defp control_args(host, control_path) do
    %{destination: destination, port: port} = parse_target(host)

    []
    |> maybe_put_config()
    |> Kernel.++(["-T"])
    |> maybe_put_port(port)
    |> Kernel.++(["-S", control_path])
    |> then(fn args ->
      %{
        check: args ++ ["-O", "check", destination],
        stop: args ++ ["-O", "exit", destination]
      }
    end)
  end

  defp maybe_put_line_option(port_opts, nil), do: port_opts
  defp maybe_put_line_option(port_opts, line_bytes), do: Keyword.put(port_opts, :line, line_bytes)

  defp maybe_put_config(args) do
    case System.get_env("SYMPHONY_SSH_CONFIG") do
      config_path when is_binary(config_path) and config_path != "" ->
        args ++ ["-F", config_path]

      _ ->
        args
    end
  end

  defp maybe_put_port(args, nil), do: args
  defp maybe_put_port(args, port), do: args ++ ["-p", port]

  defp maybe_put_noninteractive(args, true), do: args ++ ["-o", "BatchMode=yes"]
  defp maybe_put_noninteractive(args, _noninteractive), do: args

  defp parse_target(target) when is_binary(target) do
    trimmed_target = String.trim(target)

    # OpenSSH does not interpret bare "host:port" as "host + port"; it treats the
    # whole value as a hostname and leaves the port at 22. We split that shorthand
    # here so worker config can use "localhost:2222" without requiring ssh:// URIs.
    case Regex.run(~r/^(.*):(\d+)$/, trimmed_target, capture: :all_but_first) do
      [destination, port] ->
        if valid_port_destination?(destination) do
          %{destination: destination, port: port}
        else
          %{destination: trimmed_target, port: nil}
        end

      _ ->
        %{destination: trimmed_target, port: nil}
    end
  end

  defp valid_port_destination?(destination) when is_binary(destination) do
    destination != "" and
      (not String.contains?(destination, ":") or bracketed_host?(destination))
  end

  defp bracketed_host?(destination) when is_binary(destination) do
    # IPv6 literals contain ":" already, so we only accept additional ":port"
    # parsing when the host is explicitly bracketed, e.g. "[::1]:2222".
    String.contains?(destination, "[") and String.contains?(destination, "]")
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end

defmodule SymphonyElixir.SSH.Tunnel do
  @moduledoc false

  @enforce_keys [:owner, :port, :host, :remote_port, :local_port]
  defstruct [:owner, :port, :host, :remote_port, :local_port]

  @type t :: %__MODULE__{
          owner: pid(),
          port: port(),
          host: String.t(),
          remote_port: pos_integer(),
          local_port: pos_integer()
        }
end

defmodule SymphonyElixir.SSH.TunnelServer do
  @moduledoc false

  use GenServer

  alias SymphonyElixir.SSH.Tunnel

  @max_output_bytes 4_096

  @spec start_link(keyword()) :: {:ok, Tunnel.t()} | {:error, term()}
  def start_link(opts) when is_list(opts) do
    with {:ok, owner} <- GenServer.start_link(__MODULE__, opts),
         {:ok, port} <- GenServer.call(owner, :port) do
      {:ok,
       %Tunnel{
         owner: owner,
         port: port,
         host: Keyword.fetch!(opts, :host),
         remote_port: Keyword.fetch!(opts, :remote_port),
         local_port: Keyword.fetch!(opts, :local_port)
       }}
    end
  end

  @spec health(pid()) :: {:ok, map()} | {:error, term()}
  def health(owner) when is_pid(owner), do: GenServer.call(owner, :health)

  @spec stop(pid()) :: :ok
  def stop(owner) when is_pid(owner), do: GenServer.call(owner, :stop)

  @impl true
  def init(opts) do
    executable = Keyword.fetch!(opts, :executable)
    start_args = Keyword.fetch!(opts, :start_args)

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: Enum.map(start_args, &String.to_charlist/1)
        ]
      )

    {:ok,
     %{
       executable: executable,
       control_args: Keyword.fetch!(opts, :control_args),
       control_directory: Keyword.fetch!(opts, :control_directory),
       notify: Keyword.fetch!(opts, :notify),
       host: Keyword.fetch!(opts, :host),
       remote_port: Keyword.fetch!(opts, :remote_port),
       local_port: Keyword.fetch!(opts, :local_port),
       control_timeout: Keyword.fetch!(opts, :control_timeout),
       port: port,
       status: :starting,
       exit_status: nil,
       output: ""
     }}
  rescue
    error -> {:stop, {:ssh_tunnel_start_failed, error}}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, {:ok, state.port}, state}

  def handle_call(:health, _from, %{exit_status: status} = state) when is_integer(status) do
    {:reply, tunnel_exit_error(state), state}
  end

  def handle_call(:health, _from, state) do
    case control_command(state, :check) do
      {_output, 0} ->
        ready_state = %{state | status: :ready}
        {:reply, {:ok, health_snapshot(ready_state)}, ready_state}

      {output, _status} ->
        next_state = collect_pending_exit_status(%{state | output: append_output(state.output, output)})

        if is_integer(next_state.exit_status) do
          {:reply, tunnel_exit_error(next_state), next_state}
        else
          {:reply, {:error, {:ssh_tunnel_not_ready, capped_output(output)}}, next_state}
        end
    end
  end

  def handle_call(:stop, _from, state) do
    _ = control_command(state, :stop)
    close_port(state.port)
    cleanup_control_directory(state.control_directory)
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {:noreply, %{state | output: append_output(state.output, data)}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    notify_exit(state, status)
    {:noreply, %{state | status: :exited, exit_status: status}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    close_port(state.port)
    cleanup_control_directory(state.control_directory)
    :ok
  end

  defp health_snapshot(state) do
    %{
      status: state.status,
      host: state.host,
      remote_port: state.remote_port,
      local_port: state.local_port,
      port: state.port
    }
  end

  defp tunnel_exit_error(state) do
    {:error, {:ssh_tunnel_exited, state.exit_status, capped_output(state.output)}}
  end

  defp control_command(state, action) do
    args = Map.fetch!(state.control_args, action)

    task =
      Task.async(fn ->
        System.cmd(state.executable, args, stderr_to_stdout: true)
      end)

    case Task.yield(task, state.control_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {"ssh control command exited: #{inspect(reason)}", 255}
      nil -> {"ssh control command timed out", 255}
    end
  rescue
    error -> {Exception.message(error), 255}
  end

  defp collect_pending_exit_status(state) do
    receive do
      {port, {:exit_status, status}} when port == state.port ->
        notify_exit(state, status)
        %{state | status: :exited, exit_status: status}

      {port, {:data, data}} when port == state.port ->
        collect_pending_exit_status(%{state | output: append_output(state.output, data)})
    after
      0 -> state
    end
  end

  defp close_port(port) when is_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  catch
    :error, :badarg -> :ok
  end

  defp cleanup_control_directory(directory) when is_binary(directory) do
    File.rm_rf(directory)
    :ok
  end

  defp notify_exit(%{status: :ready} = state, status) do
    send(state.notify, {:ssh_reverse_tunnel_exit, self(), status})
    :ok
  end

  defp notify_exit(_state, _status), do: :ok

  defp append_output(existing, data) when is_binary(existing) and is_binary(data) do
    capped_output(existing <> data)
  end

  defp capped_output(output) when byte_size(output) <= @max_output_bytes, do: output

  defp capped_output(output) do
    binary_part(output, byte_size(output) - @max_output_bytes, @max_output_bytes)
  end
end
