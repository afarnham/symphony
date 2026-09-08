defmodule SymphonyElixir.RateLimitsTest do
  use SymphonyElixir.TestSupport
  import Phoenix.ConnTest

  @endpoint SymphonyElixirWeb.Endpoint

  setup do
    start_supervised!({SymphonyElixirWeb.Endpoint, [server: false]})
    root = Path.dirname(Workflow.workflow_file_path())
    log = Path.join(root, "requests.jsonl")
    command = Path.join(root, "codex-quota")
    {:ok, root: root, log: log, command: command}
  end

  test "reads fresh quota after restart without creating a thread or turn", ctx do
    limits = %{"limitId" => "codex", "secondary" => %{"usedPercent" => 34, "windowDurationMins" => 10_080}}

    fake_server(ctx, %{
      "rateLimits" => %{"limitId" => "other", "primary" => %{"usedPercent" => 99}},
      "rateLimitsByLimitId" => %{"codex" => limits}
    })

    # An idle snapshot has no stream events, including after a coordinator restart.
    assert {:ok, ^limits} = AppServer.read_rate_limits()
    assert {:ok, ^limits} = AppServer.read_rate_limits()

    methods = ctx.log |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1) |> Enum.map(& &1["method"])
    assert methods == List.duplicate(["initialize", "initialized", "account/rateLimits/read"], 2) |> List.flatten()

    conn = get(build_conn(), "/api/v1/rate_limits")
    assert %{"rate_limits" => ^limits, "profile" => nil} = json_response(conn, 200)
    assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "never falls back to a different account bucket", ctx do
    fake_server(ctx, %{"rateLimits" => %{"primary" => %{"usedPercent" => 0}}, "rateLimitsByLimitId" => %{"other" => %{}}})
    assert {:error, :rate_limits_unavailable} = AppServer.read_rate_limits()
    assert %{"error" => %{"code" => "rate_limits_unavailable"}} = json_response(get(build_conn(), "/api/v1/rate_limits"), 503)
  end

  test "supports the legacy response and rejects null quota", ctx do
    fake_server(ctx, %{"rateLimits" => %{"secondary" => %{"usedPercent" => 45}}})
    assert {:ok, %{"secondary" => %{"usedPercent" => 45}}} = AppServer.read_rate_limits()
    fake_server(ctx, %{"rateLimits" => nil})
    assert {:error, :rate_limits_unavailable} = AppServer.read_rate_limits()
  end

  test "rejects unknown profiles before starting an account process", ctx do
    assert %{"error" => %{"code" => "unknown_profile"}} =
             json_response(get(build_conn(), "/api/v1/rate_limits?profile=unknown"), 400)

    refute File.exists?(ctx.log)
    assert json_response(post(build_conn(), "/api/v1/rate_limits", %{}), 405)
  end

  test "bounds an unresponsive app server and returns unavailable", ctx do
    File.write!(ctx.command, "#!/bin/sh\nwhile IFS= read -r line; do :; done\n")
    File.chmod!(ctx.command, 0o755)
    write_workflow_file!(Workflow.workflow_file_path(), codex_command: ctx.command, codex_read_timeout_ms: 50)
    started = System.monotonic_time(:millisecond)
    assert {:error, _} = AppServer.read_rate_limits()
    assert System.monotonic_time(:millisecond) - started < 1_000
  end

  test "routes quota to the requested profile's worker", ctx do
    fake_server(ctx, %{"rateLimits" => %{"secondary" => %{"usedPercent" => 34}}})
    ssh = Path.join(ctx.root, "ssh")
    argv = Path.join(ctx.root, "ssh-args")
    File.write!(ssh, "#!/bin/sh\nprintf '%s\\n' \"$@\" > '#{argv}'\nexec '#{ctx.command}'\n")
    File.chmod!(ssh, 0o755)
    original_path = System.get_env("PATH")
    System.put_env("PATH", ctx.root <> ":" <> original_path)
    on_exit(fn -> System.put_env("PATH", original_path) end)

    # Keep the memory tracker transport; routing schema discovery has its own tests.
    settings = Config.settings!()

    routing = %SymphonyElixir.Config.Schema.AgentRouting{
      profiles: %{
        "afarnham" => %{"worker_hosts" => ["worker@afarnham"]},
        "karbas" => %{"worker_hosts" => ["worker@karbas"]}
      }
    }

    :sys.replace_state(WorkflowStore, fn state ->
      %{state | settings: put_in(settings.agent.routing, routing)}
    end)

    assert %{"profile" => "afarnham"} = json_response(get(build_conn(), "/api/v1/rate_limits?profile=afarnham"), 200)
    assert File.read!(argv) =~ "worker@afarnham"
    refute File.read!(argv) =~ "worker@karbas"
    assert json_response(get(build_conn(), "/api/v1/rate_limits"), 400)
  end

  defp fake_server(ctx, result) do
    response = Jason.encode!(%{"id" => 4, "result" => result})

    File.write!(ctx.command, """
    #!/bin/sh
    while IFS= read -r line; do
      printf '%s\\n' "$line" >> '#{ctx.log}'
      case "$line" in
        *'"method":"initialize"'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
        *'account/rateLimits/read'*) printf '%s\\n' '#{response}' ;;
        *'thread/'*|*'turn/'*) exit 9 ;;
      esac
    done
    """)

    File.chmod!(ctx.command, 0o755)
    write_workflow_file!(Workflow.workflow_file_path(), codex_command: ctx.command)
  end
end
