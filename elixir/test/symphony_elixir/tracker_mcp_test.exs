defmodule SymphonyElixir.TrackerMCPTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.TrackerMCP
  alias SymphonyElixir.TrackerMCP.Router

  defmodule FakeAdapter do
    @spec execute_agent_tool(String.t() | nil, term(), keyword()) :: map()
    def execute_agent_tool("raise_tool", arguments, opts) do
      tracker_settings = Keyword.fetch!(opts, :tracker_settings)
      send(tracker_settings.test_pid, {:raising_tool_executed, arguments})
      raise "adapter failed with tracker-super-secret and sensitive-argument"
    end

    def execute_agent_tool("block_tool", arguments, opts) do
      tracker_settings = Keyword.fetch!(opts, :tracker_settings)
      send(tracker_settings.test_pid, {:blocking_tool_started, arguments})
      receive do: (:never_sent -> :ok)
    end

    def execute_agent_tool(tool, arguments, opts) do
      tracker_settings = Keyword.fetch!(opts, :tracker_settings)
      send(tracker_settings.test_pid, {:tool_executed, tool, arguments, opts})

      output = Jason.encode!(%{"arguments" => arguments, "tool" => tool})

      %{
        "success" => true,
        "output" => output,
        "contentItems" => [%{"type" => "inputText", "text" => output}]
      }
    end
  end

  setup do
    binding = %{
      adapter: FakeAdapter,
      tracker_settings: %{api_key: "tracker-super-secret", test_pid: self()},
      tool_specs: [
        %{
          "name" => "echo_tool",
          "description" => "Echo arguments through the bound broker.",
          "inputSchema" => %{"type" => "object", "additionalProperties" => true}
        },
        %{
          "name" => "hidden_tool",
          "description" => "Not granted to the test session.",
          "inputSchema" => %{"type" => "object"}
        },
        %{
          "name" => "raise_tool",
          "description" => "Raise to exercise failure isolation.",
          "inputSchema" => %{"type" => "object"}
        },
        %{
          "name" => "block_tool",
          "description" => "Block to exercise shutdown isolation.",
          "inputSchema" => %{"type" => "object"}
        }
      ],
      secret_environment_names: ["GITHUB_TOKEN"]
    }

    %{binding: binding}
  end

  test "starts on loopback with random redacted credentials and stops cleanly", %{binding: binding} do
    handle = start_session!(binding)
    second_handle = start_session!(binding, session_id: "backend-session-2")

    assert handle.url =~ ~r/^http:\/\/127\.0\.0\.1:\d+\/mcp$/
    assert URI.parse(handle.url).host == "127.0.0.1"
    assert handle.token != second_handle.token
    assert byte_size(handle.token) >= 43
    assert handle.tool_names == ["echo_tool"]

    assert TrackerMCP.environment(handle) == %{
             "SYMPHONY_TRACKER_MCP_URL" => handle.url,
             "SYMPHONY_TRACKER_MCP_TOKEN" => handle.token
           }

    assert TrackerMCP.claude_tool_names(handle) == ["mcp__symphony_tracker__echo_tool"]
    assert TrackerMCP.health_url(handle) == health_url(handle)
    refute inspect(handle) =~ handle.token
    refute inspect(handle) =~ "tracker-super-secret"

    monitor = Process.monitor(handle.pid)
    assert :ok = TrackerMCP.stop_session(handle)
    assert_receive {:DOWN, ^monitor, :process, _pid, :normal}
    assert :ok = TrackerMCP.stop_session(handle)
  end

  test "health requires the session token and expiry revokes the listener", %{binding: binding} do
    handle = start_session!(binding)

    assert health(handle, handle.token).status == 200
    assert health(handle, nil).status == 401
    assert health(handle, "not-the-token").status == 401

    expiring_handle = start_session!(binding, ttl_ms: 100, session_id: "expiring-session")
    monitor = Process.monitor(expiring_handle.pid)

    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}, 1_000
    refute Process.alive?(expiring_handle.pid)
  end

  test "implements initialize, notifications, tools/list, and tools/call", %{binding: binding} do
    handle = start_session!(binding)

    before_initialize = post_rpc(handle, tools_list_request(1), session_id: nil)
    assert before_initialize.status == 400
    assert before_initialize.body == %{"error" => "missing_mcp_session"}

    initialized = initialize(handle)
    assert initialized.response.status == 200
    assert initialized.response.body["result"]["protocolVersion"] == "2025-11-25"
    assert initialized.response.body["result"]["capabilities"] == %{"tools" => %{"listChanged" => false}}
    assert initialized.session_id != ""

    notification =
      post_rpc(
        handle,
        %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
        session_id: initialized.session_id
      )

    assert notification.status == 202
    assert notification.body == ""

    listed = post_rpc(handle, tools_list_request("list-1"), session_id: initialized.session_id)
    assert listed.status == 200
    assert [%{"name" => "echo_tool"}] = listed.body["result"]["tools"]

    called =
      post_rpc(
        handle,
        %{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "tools/call",
          "params" => %{"name" => "echo_tool", "arguments" => %{"value" => 42}}
        },
        session_id: initialized.session_id
      )

    assert called.status == 200
    assert called.body["result"]["isError"] == false

    assert [%{"type" => "text", "text" => output}] = called.body["result"]["content"]
    assert Jason.decode!(output) == %{"arguments" => %{"value" => 42}, "tool" => "echo_tool"}

    assert_receive {:tool_executed, "echo_tool", %{"value" => 42}, execute_opts}
    assert execute_opts[:tracker_settings].api_key == "tracker-super-secret"
  end

  test "rejects unadvertised tools, invalid protocol sessions, and mismatched routing headers", %{
    binding: binding
  } do
    handle = start_session!(binding)
    %{session_id: session_id} = initialize(handle)

    hidden_call = %{
      "jsonrpc" => "2.0",
      "id" => 3,
      "method" => "tools/call",
      "params" => %{"name" => "hidden_tool", "arguments" => %{}}
    }

    rejected = post_rpc(handle, hidden_call, session_id: session_id)
    assert rejected.status == 200
    assert rejected.body["error"]["code"] == -32_602
    refute_received {:tool_executed, "hidden_tool", _arguments, _opts}

    assert post_rpc(handle, tools_list_request(4), session_id: nil).status == 400
    assert post_rpc(handle, tools_list_request(5), session_id: "another-session").status == 404

    wrong_token_get = Req.get!(handle.url, headers: authorization_headers("not-the-token"))
    assert wrong_token_get.status == 401

    wrong_token_post =
      Req.post!(handle.url,
        headers: [{"content-type", "application/json"} | authorization_headers("not-the-token")],
        body: "not-json"
      )

    assert wrong_token_post.status == 401

    for {header, value} <- [
          {"x-symphony-issue-id", "another-issue"},
          {"x-symphony-backend", "codex"},
          {"x-symphony-backend-session-id", "another-backend-session"}
        ] do
      response = health(handle, handle.token, [{header, value}])
      assert response.status == 403
    end

    mismatched_method =
      post_rpc(handle, tools_list_request(6),
        session_id: session_id,
        extra_headers: [{"mcp-method", "tools/call"}]
      )

    assert mismatched_method.status == 400
    assert mismatched_method.body == %{"error" => "invalid_mcp_headers"}
  end

  test "bounds request bodies and rejects non-loopback peers and foreign origins", %{binding: binding} do
    handle = start_session!(binding, max_body_bytes: 64)

    oversized =
      Req.post!(handle.url,
        headers: [{"content-type", "application/json"} | authorization_headers(handle.token)],
        body: String.duplicate("x", 65)
      )

    assert oversized.status == 413
    assert oversized.body == %{"error" => "payload_too_large"}

    invalid_content_type =
      Req.post!(handle.url,
        headers: [{"content-type", "application/jsonp"} | authorization_headers(handle.token)],
        body: "{}"
      )

    assert invalid_content_type.status == 415

    foreign_origin = health(handle, handle.token, [{"origin", "https://attacker.example"}])
    assert foreign_origin.status == 403

    conn =
      :get
      |> Plug.Test.conn("/health")
      |> put_req_header("authorization", "Bearer #{handle.token}")

    conn = %{conn | remote_ip: {10, 1, 2, 3}}
    rejected = Router.call(conn, Router.init(server: handle.pid, max_body_bytes: 64))
    assert rejected.status == 403

    assert :ok = TrackerMCP.stop_session(handle)

    stopped_conn =
      :get
      |> Plug.Test.conn("/health")
      |> put_req_header("authorization", "Bearer #{handle.token}")

    unavailable = Router.call(stopped_conn, Router.init(server: handle.pid, max_body_bytes: 64))
    assert unavailable.status == 503
    assert unavailable.resp_body == Jason.encode!(%{"error" => "server_stopped"})
  end

  test "validates required scope and tool allowlist before opening a listener", %{binding: binding} do
    assert {:error, {:invalid_option, :issue_id}} =
             TrackerMCP.start_session(binding, backend: "claude")

    assert {:error, {:invalid_option, :backend}} =
             TrackerMCP.start_session(binding, issue_id: "issue-1")

    assert {:error, {:unknown_tool, "missing_tool"}} =
             TrackerMCP.start_session(binding,
               issue_id: "issue-1",
               backend: "claude",
               allowed_tools: ["missing_tool"]
             )
  end

  test "redacts status and isolates adapter failures without losing the session", %{binding: binding} do
    handle = start_session!(binding, allowed_tools: ["raise_tool"])
    %{session_id: session_id} = initialize(handle)

    request = %{
      "jsonrpc" => "2.0",
      "id" => 7,
      "method" => "tools/call",
      "params" => %{"name" => "raise_tool", "arguments" => %{"value" => "sensitive-argument"}}
    }

    {response, log} =
      capture_result_and_log(fn -> post_rpc(handle, request, session_id: session_id) end)

    assert response.status == 200
    assert response.body["result"]["isError"] == true
    assert_receive {:raising_tool_executed, %{"value" => "sensitive-argument"}}
    assert Process.alive?(handle.pid)
    assert health(handle, handle.token).status == 200
    assert log =~ "Tracker MCP tool failed"
    refute log =~ handle.token
    refute log =~ "tracker-super-secret"
    refute log =~ "sensitive-argument"

    status = inspect(:sys.get_status(handle.pid))
    refute status =~ handle.token
    refute status =~ "tracker-super-secret"
    refute status =~ "sensitive-argument"
  end

  test "shutdown cancels a hung tracker tool and does not leave the listener live", %{binding: binding} do
    handle =
      start_session!(binding,
        allowed_tools: ["block_tool"],
        execute_timeout_ms: 5_000
      )

    %{session_id: session_id} = initialize(handle)
    parent = self()

    requester =
      spawn(fn ->
        result =
          try do
            post_rpc(
              handle,
              %{
                "jsonrpc" => "2.0",
                "id" => 8,
                "method" => "tools/call",
                "params" => %{"name" => "block_tool", "arguments" => %{"wait" => true}}
              },
              session_id: session_id
            )
          rescue
            error -> {:error, error}
          end

        send(parent, {:blocking_request_finished, result})
      end)

    assert_receive {:blocking_tool_started, %{"wait" => true}}, 1_000
    started_at = System.monotonic_time(:millisecond)
    {stop_result, log} = capture_result_and_log(fn -> TrackerMCP.stop_session(handle) end)
    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    assert stop_result == :ok
    assert elapsed_ms < 1_000
    assert log =~ "Tracker MCP tool cancelled"
    refute log =~ "GenServer terminating"
    refute Process.alive?(handle.pid)
    assert_receive {:blocking_request_finished, _result}, 1_000
    refute Process.alive?(requester)
  end

  test "tool execution timeout returns a transport failure and emits a sanitized audit", %{binding: binding} do
    handle =
      start_session!(binding,
        allowed_tools: ["block_tool"],
        execute_timeout_ms: 50
      )

    %{session_id: session_id} = initialize(handle)

    {response, log} =
      capture_result_and_log(fn ->
        post_rpc(
          handle,
          %{
            "jsonrpc" => "2.0",
            "id" => 9,
            "method" => "tools/call",
            "params" => %{"name" => "block_tool", "arguments" => %{"secret" => "sensitive-argument"}}
          },
          session_id: session_id
        )
      end)

    assert_receive {:blocking_tool_started, %{"secret" => "sensitive-argument"}}, 1_000
    assert response.status == 503
    assert response.body == %{"error" => "execution_timeout"}
    assert log =~ "Tracker MCP tool timed_out"
    refute log =~ "sensitive-argument"
    refute log =~ "tracker-super-secret"
    refute log =~ handle.token
    assert Process.alive?(handle.pid)
  end

  test "the server follows its explicit owner even when that owner exits normally", %{binding: binding} do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, handle} =
          TrackerMCP.start_session(binding,
            issue_id: "owner-issue",
            backend: "claude",
            allowed_tools: ["echo_tool"]
          )

        send(parent, {:owned_session, handle})

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:owned_session, handle}, 1_000
    monitor = Process.monitor(handle.pid)
    send(owner, :finish)

    assert_receive {:DOWN, ^monitor, :process, _pid, :normal}, 1_000
    refute Process.alive?(handle.pid)
  end

  defp start_session!(binding, overrides \\ []) do
    opts =
      Keyword.merge(
        [
          issue_id: "issue-1",
          backend: "claude",
          session_id: "backend-session-1",
          allowed_tools: ["echo_tool"]
        ],
        overrides
      )

    {:ok, handle} = TrackerMCP.start_session(binding, opts)
    on_exit(fn -> TrackerMCP.stop_session(handle) end)
    handle
  end

  defp initialize(handle) do
    response =
      post_rpc(
        handle,
        %{
          "jsonrpc" => "2.0",
          "id" => 0,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => "2025-11-25",
            "capabilities" => %{},
            "clientInfo" => %{"name" => "test-client", "version" => "1.0"}
          }
        },
        session_id: nil
      )

    [session_id] = Req.Response.get_header(response, "mcp-session-id")
    %{response: response, session_id: session_id}
  end

  defp tools_list_request(id) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => "tools/list", "params" => %{}}
  end

  defp post_rpc(handle, request, opts) do
    session_id = Keyword.get(opts, :session_id)
    extra_headers = Keyword.get(opts, :extra_headers, [])

    headers =
      handle.token
      |> authorization_headers()
      |> maybe_add_session_header(session_id)
      |> Kernel.++(extra_headers)

    Req.post!(handle.url, headers: headers, json: request)
  end

  defp health(handle, token, extra_headers \\ []) do
    headers = if token, do: authorization_headers(token), else: []
    Req.get!(health_url(handle), headers: headers ++ extra_headers)
  end

  defp health_url(handle), do: String.replace_suffix(handle.url, "/mcp", "/health")

  defp authorization_headers(token) do
    [{"authorization", "Bearer #{token}"}, {"accept", "application/json, text/event-stream"}]
  end

  defp maybe_add_session_header(headers, nil), do: headers
  defp maybe_add_session_header(headers, session_id), do: [{"mcp-session-id", session_id} | headers]

  defp put_req_header(conn, name, value), do: Plug.Conn.put_req_header(conn, name, value)

  defp capture_result_and_log(fun) do
    parent = self()

    log =
      capture_log(fn ->
        result = fun.()
        send(parent, {:captured_result, result})
      end)

    assert_receive {:captured_result, result}
    {result, log}
  end
end
