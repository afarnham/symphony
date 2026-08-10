defmodule SymphonyElixir.TrackerMCP do
  @moduledoc """
  Starts a session-scoped, loopback-only MCP transport for tracker tools.

  Each server owns one frozen `TrackerToolBroker` binding, one tool allowlist,
  and one short-lived bearer token. The token is returned only in the session
  handle and is redacted by the handle's `Inspect` implementation.
  """

  alias SymphonyElixir.TrackerMCP.{Handle, Server}
  alias SymphonyElixir.TrackerToolBroker

  @type start_error ::
          {:invalid_option, atom()}
          | {:unknown_tool, String.t()}
          | term()

  @doc """
  Starts an MCP server for one issue and backend session.

  Required options are `:issue_id` and `:backend`. `:session_id` may be
  supplied when the backend already has a stable run identifier; otherwise a
  random identifier is generated. The listener address is fixed to
  `127.0.0.1` and cannot be overridden.

  `:allowed_tools` narrows the frozen broker specifications. `:ttl_ms` is a
  sliding inactivity lifetime, and `:execute_timeout_ms` bounds individual
  tool calls. The caller owns the session by default; `:owner` may provide a
  different long-lived process whose exit must revoke the endpoint.
  """
  @spec start_session(TrackerToolBroker.binding(), keyword()) ::
          {:ok, Handle.t()} | {:error, start_error()}
  def start_session(binding, opts) when is_map(binding) and is_list(opts) do
    opts = Keyword.put_new(opts, :owner, self())

    with {:ok, pid} <- Server.start_link(binding, opts) do
      case Server.take_handle(pid) do
        {:ok, handle} ->
          {:ok, handle}

        {:error, reason} ->
          stop_server(pid)
          {:error, reason}
      end
    end
  end

  @doc """
  Stops the session server and revokes its bearer token.
  """
  @spec stop_session(Handle.t() | pid()) :: :ok
  def stop_session(%Handle{pid: pid}), do: stop_server(pid)
  def stop_session(pid) when is_pid(pid), do: stop_server(pid)

  @doc """
  Returns the environment values expected by the generated Claude MCP config.
  """
  @spec environment(Handle.t()) :: %{required(String.t()) => String.t()}
  def environment(%Handle{url: url, token: token}) do
    %{
      "SYMPHONY_TRACKER_MCP_URL" => url,
      "SYMPHONY_TRACKER_MCP_TOKEN" => token
    }
  end

  @doc """
  Returns the authenticated health-check URL for a session server.
  """
  @spec health_url(Handle.t()) :: String.t()
  def health_url(%Handle{url: url}), do: String.replace_suffix(url, "/mcp", "/health")

  @doc """
  Returns the fully-qualified Claude tool names granted to this session.
  """
  @spec claude_tool_names(Handle.t()) :: [String.t()]
  def claude_tool_names(%Handle{tool_names: tool_names}) do
    Enum.map(tool_names, &"mcp__symphony_tracker__#{&1}")
  end

  defp stop_server(pid) do
    monitor = Process.monitor(pid)
    Process.unlink(pid)

    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 2_000)
      catch
        :exit, _reason -> force_stop(pid)
      end
    end

    await_stopped(pid, monitor)
  end

  defp force_stop(pid) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)
    :ok
  end

  defp await_stopped(pid, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    after
      1_000 ->
        force_stop(pid)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
        after
          1_000 -> :ok
        end
    end
  end
end
