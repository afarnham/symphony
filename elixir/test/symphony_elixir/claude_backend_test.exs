defmodule SymphonyElixir.ClaudeBackendTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentBackend.Claude
  alias SymphonyElixir.{AgentEvent, AgentTurnResult, Claude.Session, Workflow}
  alias SymphonyElixir.Tracker.Issue

  @fake_claude Path.expand("../fixtures/claude/fake_claude.sh", __DIR__)
  @fake_ssh Path.expand("../fixtures/claude/fake_ssh.sh", __DIR__)
  @test_read_timeout_ms 2_000
  @eventually_attempts 1_000
  @process_stop_attempts 3_000

  setup do
    original_auth_status = System.get_env("FAKE_CLAUDE_AUTH_STATUS")
    System.delete_env("FAKE_CLAUDE_AUTH_STATUS")

    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-claude-backend-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(root, "workspaces")
    workspace = Path.join(workspace_root, "GH-42")
    File.mkdir_p!(workspace)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      agent_backend: "claude",
      claude_command: @fake_claude,
      claude_model: "sonnet",
      claude_permission_mode: "acceptEdits",
      claude_turn_timeout_ms: 2_000,
      claude_read_timeout_ms: @test_read_timeout_ms
    )

    on_exit(fn ->
      restore_env("FAKE_CLAUDE_AUTH_STATUS", original_auth_status)
      File.rm_rf(root)
    end)

    issue = %Issue{
      id: "issue-42",
      identifier: "GH-42",
      title: "Exercise Claude",
      state: "In Progress"
    }

    %{workspace: workspace, issue: issue}
  end

  test "invokes Claude with reserved argv, writes prompts to stdin, and resumes the captured session",
       %{workspace: workspace, issue: issue} do
    test_pid = self()
    on_event = fn event -> send(test_pid, {:agent_event, event}) end

    assert :ok = Claude.validate_config(Config.settings!())
    assert :ok = Claude.validate_host(Config.settings!(), nil)

    tool_session = %{
      binding: :accepted,
      secret_environment_names: ["LINEAR_API_KEY"]
    }

    mcp_options_resolver = fn binding ->
      send(test_pid, {:mcp_options_resolved, binding})

      {:ok,
       %{
         config: "/tmp/symphony-mcp.json",
         allowed_tools: [
           "mcp__symphony_tracker__tracker_get_issue",
           "mcp__symphony_tracker__tracker_update_state"
         ],
         env: %{
           "SYMPHONY_TRACKER_MCP_URL" => "http://127.0.0.1:43123/mcp",
           "SYMPHONY_TRACKER_MCP_TOKEN" => "session-token"
         }
       }}
    end

    assert {:ok, session} =
             Claude.start_session(workspace, issue, tool_session,
               on_event: on_event,
               mcp_options_resolver: mcp_options_resolver
             )

    assert_receive {:mcp_options_resolved, ^tool_session}

    assert {:ok,
            %AgentTurnResult{
              backend: :claude,
              status: :completed,
              session_id: "session-123",
              turn_id: "turn-1",
              final_text: "completed turn 1"
            }, resumed_session} = Claude.run_turn(session, "first prompt", issue)

    assert resumed_session.session_id == "session-123"
    assert resumed_session.turn_number == 1

    assert File.read!(Path.join(workspace, "claude-prompt-1.txt")) == "first prompt"
    assert File.read!(Path.join(workspace, "claude-mcp-url-1.txt")) == "http://127.0.0.1:43123/mcp"
    assert File.read!(Path.join(workspace, "claude-mcp-token-1.txt")) == "session-token"
    assert File.read!(Path.join(workspace, "claude-tracker-secret-1.txt")) == "unset"

    assert File.read!(Path.join(workspace, "claude-args-1.txt")) |> String.split("\n", trim: true) == [
             "-p",
             "--input-format",
             "text",
             "--output-format",
             "stream-json",
             "--verbose",
             "--permission-mode",
             "acceptEdits",
             "--mcp-config",
             "/tmp/symphony-mcp.json",
             "--allowedTools",
             "mcp__symphony_tracker__tracker_get_issue,mcp__symphony_tracker__tracker_update_state",
             "--model",
             "sonnet"
           ]

    assert {:ok,
            %AgentTurnResult{
              status: :completed,
              session_id: "session-123",
              turn_id: "turn-2",
              final_text: "completed turn 2"
            }, final_session} = Claude.run_turn(resumed_session, "second prompt", issue)

    assert final_session.turn_number == 2
    assert File.read!(Path.join(workspace, "claude-prompt-2.txt")) == "second prompt"

    assert File.read!(Path.join(workspace, "claude-args-2.txt")) |> String.split("\n", trim: true) == [
             "-p",
             "--input-format",
             "text",
             "--output-format",
             "stream-json",
             "--verbose",
             "--resume",
             "session-123",
             "--permission-mode",
             "acceptEdits",
             "--mcp-config",
             "/tmp/symphony-mcp.json",
             "--allowedTools",
             "mcp__symphony_tracker__tracker_get_issue,mcp__symphony_tracker__tracker_update_state",
             "--model",
             "sonnet"
           ]

    assert_receive {:agent_event,
                    %AgentEvent{
                      kind: :turn_started,
                      turn_id: "turn-1",
                      metadata: turn_started_metadata
                    }}

    assert turn_started_metadata.mcp == %{
             enabled: true,
             health: :initializing,
             transport: :local_http
           }

    assert turn_started_metadata.ssh_tunnel == %{health: :disabled, remote_port: nil}

    assert_receive {:agent_event,
                    %AgentEvent{
                      kind: :session_started,
                      session_id: "session-123",
                      turn_id: "turn-1",
                      metadata: session_started_metadata
                    }}

    assert session_started_metadata.mcp == %{
             enabled: true,
             health: :healthy,
             transport: :local_http
           }

    safe_metadata = inspect([turn_started_metadata, session_started_metadata])
    refute safe_metadata =~ "session-token"
    refute safe_metadata =~ "SYMPHONY_TRACKER_MCP_URL"
    refute safe_metadata =~ "/tmp/symphony-mcp.json"

    assert_receive {:agent_event, %AgentEvent{kind: :assistant_text, turn_id: "turn-1"}}
    assert_receive {:agent_event, %AgentEvent{kind: :usage_updated, turn_id: "turn-1"}}
    assert_receive {:agent_event, %AgentEvent{kind: :turn_completed, turn_id: "turn-1"}}
    refute_receive {:agent_event, %AgentEvent{kind: :session_started, turn_id: "turn-2"}}, 20

    assert :ok = Claude.stop_session(final_session, :normal)

    assert_receive {:agent_event,
                    %AgentEvent{
                      kind: :session_stopped,
                      session_id: "session-123",
                      turn_id: "turn-2",
                      metadata: stopped_metadata
                    }}

    assert stopped_metadata.mcp == %{enabled: true, health: :stopped, transport: :local_http}
    assert stopped_metadata.ssh_tunnel == %{health: :disabled, remote_port: nil}

    assert :ok = Claude.stop_session(final_session, :normal)
    refute_receive {:agent_event, %AgentEvent{kind: :session_stopped}}, 20
  end

  test "maps the shared input sentinel to a blocked backend turn", %{
    workspace: workspace,
    issue: issue
  } do
    assert {:ok, session} = Claude.start_session(workspace, issue, nil, [])

    assert {:blocked,
            %AgentTurnResult{
              backend: :claude,
              status: :blocked,
              session_id: "session-123",
              input_required: true
            }, blocked_session} = Claude.run_turn(session, "blocked", issue)

    assert :ok = Claude.stop_session(blocked_session, :normal)
  end

  test "reports disabled MCP and SSH transport metadata when no broker is configured", %{
    workspace: workspace,
    issue: issue
  } do
    test_pid = self()
    on_event = fn event -> send(test_pid, {:transport_event, event}) end

    assert {:ok, session} = Claude.start_session(workspace, issue, nil, on_event: on_event)

    assert {:ok, %AgentTurnResult{status: :completed}, final_session} =
             Claude.run_turn(session, "transport metadata", issue)

    assert_receive {:transport_event, %AgentEvent{kind: :turn_started, metadata: metadata}}

    assert metadata.mcp == %{enabled: false, health: :disabled, transport: :none}
    assert metadata.ssh_tunnel == %{health: :disabled, remote_port: nil}
    assert :ok = Claude.stop_session(final_session, :normal)
  end

  test "refreshes transport health on every event when init and result arrive in one write", %{
    workspace: workspace,
    issue: issue
  } do
    executable = Path.join(Path.dirname(workspace), "single-write-claude.sh")

    stream =
      [
        %{
          "type" => "system",
          "subtype" => "init",
          "session_id" => "session-single-write",
          "tools" => [],
          "mcp_servers" => [%{"name" => "symphony_tracker", "status" => "connected"}]
        },
        %{
          "type" => "assistant",
          "session_id" => "session-single-write",
          "message" => %{
            "id" => "message-single-write",
            "content" => [%{"type" => "text", "text" => "done"}]
          }
        },
        %{
          "type" => "result",
          "subtype" => "success",
          "session_id" => "session-single-write",
          "is_error" => false,
          "result" => "done"
        }
      ]
      |> Enum.map_join("\n", &Jason.encode!/1)
      |> Kernel.<>("\n")

    File.write!(
      executable,
      "#!/bin/sh\nset -eu\ncat >/dev/null\nprintf '%s' '#{stream}'\n"
    )

    File.chmod!(executable, 0o755)

    settings = put_in(Config.settings!().claude.command, executable)
    test_pid = self()
    on_event = fn event -> send(test_pid, {:single_write_event, event}) end

    assert {:ok, session} =
             Claude.start_session(workspace, issue, nil,
               settings: settings,
               on_event: on_event,
               mcp_options: %{config: "/tmp/not-read.json", allowed_tools: [], env: %{}}
             )

    assert {:ok, %AgentTurnResult{status: :completed}, final_session} =
             Claude.run_turn(session, "single write", issue)

    for kind <- [:session_started, :assistant_text, :turn_completed] do
      assert_receive {:single_write_event, %AgentEvent{kind: ^kind, metadata: metadata}}

      assert metadata.mcp.health == :healthy
      assert metadata.mcp.transport == :local_http
    end

    assert :ok = Claude.stop_session(final_session, :normal)
  end

  test "owns an authenticated tracker MCP session and grants only its advertised tools", %{
    workspace: workspace,
    issue: issue
  } do
    tool_session = %{
      adapter: SymphonyElixir.Tracker.Memory,
      tracker_settings: %{kind: "memory"},
      tool_specs: [
        %{
          "name" => "tracker_get_issue",
          "description" => "Refresh the issue.",
          "inputSchema" => %{"type" => "object"}
        },
        %{
          "name" => "tracker_update_state",
          "description" => "Update issue state.",
          "inputSchema" => %{"type" => "object"}
        }
      ],
      secret_environment_names: ["LINEAR_API_KEY"],
      issue: issue
    }

    assert {:ok, session} = Claude.start_session(workspace, issue, tool_session, [])
    assert Process.alive?(session.mcp_handle.pid)
    assert session.mcp_config_dir |> Path.expand() |> String.starts_with?(System.tmp_dir!())
    refute String.starts_with?(session.mcp_config_dir, workspace)

    config_path = Path.join(session.mcp_config_dir, "mcp.json")
    config = File.read!(config_path)
    assert config =~ "${SYMPHONY_TRACKER_MCP_URL}"
    assert config =~ "${SYMPHONY_TRACKER_MCP_TOKEN}"
    refute config =~ session.mcp_handle.token

    assert {:ok, %AgentTurnResult{status: :completed}, final_session} =
             Claude.run_turn(session, "mcp turn", issue)

    assert File.read!(Path.join(workspace, "claude-mcp-url-1.txt")) ==
             session.mcp_handle.url

    assert File.read!(Path.join(workspace, "claude-mcp-token-1.txt")) ==
             session.mcp_handle.token

    assert File.read!(Path.join(workspace, "claude-tracker-secret-1.txt")) == "unset"

    mcp_pid = session.mcp_handle.pid
    assert :ok = Claude.stop_session(final_session, :normal)
    refute Process.alive?(mcp_pid)
    refute File.exists?(config_path)
  end

  test "revokes MCP and removes config when the Claude session is already dead", %{
    workspace: workspace,
    issue: issue
  } do
    assert {:ok, session} =
             Claude.start_session(workspace, issue, tracker_tool_session(issue), [])

    mcp_pid = session.mcp_handle.pid
    config_path = Path.join(session.mcp_config_dir, "mcp.json")
    assert :ok = Session.stop(session.pid, :external_shutdown)
    refute Process.alive?(session.pid)
    assert Process.alive?(mcp_pid)
    assert File.exists?(config_path)

    assert :ok = Claude.stop_session(session, :normal)
    refute Process.alive?(mcp_pid)
    refute File.exists?(config_path)
  end

  test "returns a structured failed turn instead of treating it as completion", %{
    workspace: workspace,
    issue: issue
  } do
    assert {:ok, session} = Claude.start_session(workspace, issue, nil, [])

    assert {:error,
            {:claude_turn_failed,
             %AgentTurnResult{
               backend: :claude,
               status: :failed,
               session_id: "session-123",
               failure_text: "The turn failed."
             }}, failed_session} = Claude.run_turn(session, "fail", issue)

    assert failed_session.session_id == "session-123"
    assert :ok = Claude.stop_session(failed_session, :normal)
  end

  test "refuses a resumed turn that changes the native session identity", %{
    workspace: workspace,
    issue: issue
  } do
    assert {:ok, session} = Claude.start_session(workspace, issue, nil, [])
    assert {:ok, _result, resumed_session} = Claude.run_turn(session, "first prompt", issue)

    assert {:error, {:claude_session_id_mismatch, "session-123", "session-other"}, failed_session} =
             Claude.run_turn(resumed_session, "session-mismatch", issue)

    assert failed_session.session_id == "session-123"
    assert :ok = Claude.stop_session(failed_session, :normal)
  end

  test "enforces the hard turn timeout even while stream records arrive", %{
    workspace: workspace,
    issue: issue
  } do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.dirname(workspace),
      agent_backend: "claude",
      claude_command: @fake_claude,
      claude_turn_timeout_ms: 800,
      claude_read_timeout_ms: 600
    )

    assert {:ok, session} = Claude.start_session(workspace, issue, nil, [])
    assert {:error, :claude_turn_timeout, failed_session} = Claude.run_turn(session, "hard-timeout", issue)
    assert_process_tree_stopped(workspace)
    assert :ok = Claude.stop_session(failed_session, :normal)
  end

  test "enforces the stream read timeout and cleans up the child process group", %{
    workspace: workspace,
    issue: issue
  } do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.dirname(workspace),
      agent_backend: "claude",
      claude_command: @fake_claude,
      claude_turn_timeout_ms: 2_000,
      claude_read_timeout_ms: 80
    )

    assert {:ok, session} = Claude.start_session(workspace, issue, nil, [])
    assert {:error, :claude_read_timeout, failed_session} = Claude.run_turn(session, "read-timeout", issue)
    assert_process_tree_stopped(workspace)
    assert :ok = Claude.stop_session(failed_session, :normal)
  end

  test "stop_session cancels an active turn and cleans up its process group", %{
    workspace: workspace,
    issue: issue
  } do
    assert {:ok, session} = Claude.start_session(workspace, issue, nil, [])

    task = Task.async(fn -> Claude.run_turn(session, "read-timeout", issue) end)
    assert_eventually(fn -> File.exists?(Path.join(workspace, "claude-child.pid")) end)

    assert :ok = Claude.stop_session(session, :cancelled)
    assert {:error, {:claude_cancelled, :cancelled}, _session} = Task.await(task)
    assert_process_tree_stopped(workspace, 1)
  end

  test "cancellation force-kills a Claude process group that ignores TERM", %{
    workspace: workspace,
    issue: issue
  } do
    assert {:ok, session} = Claude.start_session(workspace, issue, nil, [])

    task = Task.async(fn -> Claude.run_turn(session, "ignore-term", issue) end)
    assert_eventually(fn -> File.exists?(Path.join(workspace, "claude-child.pid")) end)

    assert :ok = Claude.stop_session(session, :cancelled)
    assert {:error, {:claude_cancelled, :cancelled}, _session} = Task.await(task)
    assert_process_tree_stopped(workspace, 1)
  end

  test "the process probe treats zombie processes as stopped" do
    assert process_running_status?("R")
    assert process_running_status?("S+")
    refute process_running_status?("")
    refute process_running_status?("Z")
    refute process_running_status?("Z+")
  end

  test "supports a safely tokenized configured command prefix", %{
    workspace: workspace,
    issue: issue
  } do
    settings = put_in(Config.settings!().claude.command, "env #{@fake_claude}")

    assert :ok = Claude.validate_config(settings)
    assert :ok = Claude.validate_host(settings, nil)
    assert {:ok, session} = Claude.start_session(workspace, issue, nil, settings: settings)

    assert {:ok, %AgentTurnResult{status: :completed}, final_session} =
             Claude.run_turn(session, "prefix turn", issue)

    assert :ok = Claude.stop_session(final_session, :normal)
  end

  test "fails closed on missing MCP initialization for blocked and failed results", %{
    workspace: workspace,
    issue: issue
  } do
    for prompt <- ["blocked-mcp-disconnected", "fail-mcp-disconnected"] do
      assert {:ok, session} =
               Claude.start_session(workspace, issue, tracker_tool_session(issue), [])

      assert {:error,
              {:claude_mcp_initialization_failed,
               %{
                 connected: false,
                 missing_tools: ["mcp__symphony_tracker__tracker_get_issue"]
               }}, failed_session} = Claude.run_turn(session, prompt, issue)

      assert :ok = Claude.stop_session(failed_session, :normal)
    end
  end

  test "preflights and runs resumable Claude turns over noninteractive SSH", %{
    workspace: workspace,
    issue: issue
  } do
    ssh = install_fake_ssh!()
    on_exit(ssh.cleanup)

    assert :ok = Claude.validate_host(Config.settings!(), "worker.example")

    System.put_env("FAKE_SSH_REMOTE_MODE", "missing-bash")

    assert {:error, {:remote_bash_not_found, "worker.example"}} =
             Claude.validate_host(Config.settings!(), "worker.example")

    System.put_env("FAKE_SSH_REMOTE_MODE", "missing-claude")

    assert {:error, {:remote_claude_executable_not_found, "worker.example", @fake_claude}} =
             Claude.validate_host(Config.settings!(), "worker.example")

    System.put_env("FAKE_SSH_REMOTE_MODE", "missing-curl")

    assert {:error, {:remote_curl_not_found, "worker.example"}} =
             Claude.validate_host(Config.settings!(), "worker.example")

    System.delete_env("FAKE_SSH_REMOTE_MODE")

    System.put_env("FAKE_CLAUDE_AUTH_STATUS", "logged-out")

    assert {:error, {:claude_authentication_failed, %{logged_in: false}}} =
             Claude.validate_host(Config.settings!(), "worker.example")

    System.delete_env("FAKE_CLAUDE_AUTH_STATUS")

    tool_session = %{
      adapter: SymphonyElixir.Tracker.Memory,
      tracker_settings: %{kind: "memory"},
      tool_specs: [
        %{
          "name" => "tracker_get_issue",
          "description" => "Refresh the issue.",
          "inputSchema" => %{"type" => "object"}
        }
      ],
      secret_environment_names: ["LINEAR_API_KEY"],
      issue: issue
    }

    test_pid = self()
    on_event = fn event -> send(test_pid, {:remote_event, event}) end

    assert {:ok, session} =
             Claude.start_session(workspace, issue, tool_session,
               worker_host: "worker.example",
               on_event: on_event,
               remote_port_candidates: [43_209, 43_210]
             )

    canonical_workspace = session.workspace
    local_mcp_port = URI.parse(session.mcp_handle.url).port
    mcp_token = session.mcp_handle.token
    mcp_pid = session.mcp_handle.pid

    assert %{remote_port: 43_210, remote_staging_dir: staging_dir} =
             Session.transport_info(session.pid)

    refute String.starts_with?(staging_dir, workspace)
    assert file_mode(Path.join(staging_dir, "mcp.json")) == 0o600
    assert file_mode(Path.join(staging_dir, "session.env")) == 0o600
    refute File.read!(Path.join(staging_dir, "mcp.json")) =~ mcp_token
    assert File.read!(Path.join(staging_dir, "session.env")) =~ mcp_token

    prompt = "remote prompt ' $(touch should-not-run)"

    assert {:ok, %AgentTurnResult{status: :completed}, resumed_session} =
             Claude.run_turn(session, prompt, issue)

    assert {:ok, %AgentTurnResult{status: :completed}, final_session} =
             Claude.run_turn(resumed_session, "second remote prompt", issue)

    assert File.read!(Path.join(workspace, "claude-prompt-1.txt")) == prompt
    assert File.read!(Path.join(workspace, "claude-mcp-url-1.txt")) == "http://127.0.0.1:43210/mcp"
    assert File.read!(Path.join(workspace, "claude-mcp-token-1.txt")) == mcp_token
    assert File.read!(Path.join(workspace, "claude-tracker-secret-1.txt")) == "unset"
    refute File.exists?(Path.join(workspace, "should-not-run"))

    remote_args =
      workspace
      |> Path.join("claude-args-1.txt")
      |> File.read!()
      |> String.split("\n", trim: true)

    assert Enum.take(remote_args, 6) == [
             "-p",
             "--input-format",
             "text",
             "--output-format",
             "stream-json",
             "--verbose"
           ]

    assert Enum.at(remote_args, Enum.find_index(remote_args, &(&1 == "--mcp-config")) + 1) ==
             Path.join(staging_dir, "mcp.json")

    assert File.read!(Path.join(workspace, "claude-args-2.txt")) =~
             "--resume\nsession-123\n"

    trace = File.read!(ssh.trace)
    assert trace =~ "BatchMode=yes"
    assert trace =~ "auth"
    assert trace =~ "status"
    assert trace =~ "SYMPHONY_MCP_HEALTH"
    assert trace =~ "127.0.0.1:43209:127.0.0.1:#{local_mcp_port}"
    assert trace =~ "127.0.0.1:43210:127.0.0.1:#{local_mcp_port}"
    refute trace =~ prompt
    refute trace =~ mcp_token

    assert trace_position(trace, "127.0.0.1:43210:127.0.0.1:#{local_mcp_port}") <
             trace_position(trace, "symphony-claude-launcher")

    assert trace_position(trace, "SYMPHONY_MCP_HEALTH") <
             trace_position(trace, "symphony-claude-launcher")

    assert_receive {:remote_event,
                    %AgentEvent{
                      kind: :turn_started,
                      metadata: remote_started_metadata
                    }}

    assert remote_started_metadata.worker_host == "worker.example"
    assert remote_started_metadata.workspace_path == canonical_workspace

    assert remote_started_metadata.mcp == %{
             enabled: true,
             health: :initializing,
             transport: :ssh_reverse_tunnel
           }

    assert remote_started_metadata.ssh_tunnel == %{health: :healthy, remote_port: 43_210}

    assert_receive {:remote_event, %AgentEvent{kind: :session_started, metadata: remote_healthy_metadata}}

    assert remote_healthy_metadata.mcp.health == :healthy
    assert remote_healthy_metadata.ssh_tunnel == %{health: :healthy, remote_port: 43_210}

    safe_metadata = inspect([remote_started_metadata, remote_healthy_metadata])
    refute safe_metadata =~ mcp_token
    refute safe_metadata =~ session.mcp_handle.url
    refute safe_metadata =~ staging_dir
    refute safe_metadata =~ "session.env"

    assert :ok = Claude.stop_session(final_session, :normal)
    refute File.exists?(staging_dir)
    assert File.exists?(Path.join(ssh.state_dir, "stop"))
    refute Process.alive?(mcp_pid)
  end

  test "remote host preflight proves reverse forwarding and cleans up its probe tunnel", %{
    workspace: _workspace,
    issue: _issue
  } do
    ssh = install_fake_ssh!(fail_remote_port: nil)
    on_exit(ssh.cleanup)

    assert :ok = Claude.validate_host(Config.settings!(), "worker.example")

    trace = File.read!(ssh.trace)
    assert trace =~ "SYMPHONY_SSH_FORWARD_PROBE"
    assert trace =~ "ExitOnForwardFailure=yes"
    assert trace =~ "127.0.0.1:"
    assert File.exists?(Path.join(ssh.state_dir, "stop"))
    assert_eventually(fn -> Path.wildcard(Path.join(ssh.state_dir, "tunnel-*.ready")) == [] end)
  end

  test "remote host preflight rejects disabled forwarding and times out without leaking a tunnel", %{
    workspace: _workspace,
    issue: _issue
  } do
    ssh = install_fake_ssh!(fail_remote_port: nil)
    on_exit(ssh.cleanup)
    settings = Config.settings!()

    System.put_env("FAKE_SSH_REMOTE_MODE", "reject-forwarding")

    assert {:error, {:claude_remote_port_forwarding_failed, "worker.example", {:ssh_reverse_forward_probe_failed, rejected}}} =
             Claude.validate_host(settings, "worker.example")

    assert length(rejected) == 3

    assert Enum.all?(rejected, fn
             {_port, {:ssh_tunnel_exited, 23, output}} ->
               output =~ "remote port forwarding rejected"

             _other ->
               false
           end)

    System.put_env("FAKE_SSH_REMOTE_MODE", "forward-probe-timeout")
    fast_timeout_settings = put_in(settings.claude.read_timeout_ms, 1_000)

    assert {:error, {:claude_remote_port_forwarding_failed, "worker.example", {:ssh_reverse_forward_probe_failed, timeout_errors}}} =
             Claude.validate_host(fast_timeout_settings, "worker.example")

    assert Enum.any?(timeout_errors, fn
             {_port, :probe_timeout} -> true
             :timeout -> true
             _other -> false
           end)

    assert File.exists?(Path.join(ssh.state_dir, "stop"))
    assert_eventually(fn -> Path.wildcard(Path.join(ssh.state_dir, "tunnel-*.ready")) == [] end)
  end

  test "fails before Claude when the tunneled MCP health check fails", %{
    workspace: workspace,
    issue: issue
  } do
    ssh = install_fake_ssh!(fail_remote_port: nil)
    on_exit(ssh.cleanup)
    config_path = Path.join(ssh.root, "mcp.json")
    File.write!(config_path, ~s({"mcpServers":{}}))
    System.put_env("FAKE_SSH_REMOTE_MODE", "mcp-health-failure")

    assert {:error, {:claude_remote_mcp_staging_failed, 44, ""}} =
             Claude.start_session(workspace, issue, nil,
               worker_host: "worker.example",
               mcp_options: remote_mcp_options(config_path),
               remote_port_candidates: [43_210]
             )

    trace = File.read!(ssh.trace)
    assert trace =~ "SYMPHONY_MCP_HEALTH"
    refute trace =~ "symphony-claude-launcher"
    assert trace =~ "rm -rf --"
  end

  test "reports remote cleanup failure while revoking the MCP session", %{
    workspace: workspace,
    issue: issue
  } do
    ssh = install_fake_ssh!(fail_remote_port: nil)
    on_exit(ssh.cleanup)

    assert {:ok, session} =
             Claude.start_session(workspace, issue, tracker_tool_session(issue),
               worker_host: "worker.example",
               remote_port_candidates: [43_210]
             )

    %{remote_staging_dir: staging_dir} = Session.transport_info(session.pid)
    mcp_pid = session.mcp_handle.pid
    System.put_env("FAKE_SSH_REMOTE_MODE", "cleanup-failure")

    assert {:error, {:claude_remote_cleanup_failed, 41, ""}} =
             Claude.stop_session(session, :normal)

    refute Process.alive?(mcp_pid)
    assert File.exists?(staging_dir)
    System.delete_env("FAKE_SSH_REMOTE_MODE")
    File.rm_rf!(staging_dir)
  end

  test "tunnel loss fails the active turn and kills remote Claude", %{
    workspace: workspace,
    issue: issue
  } do
    ssh = install_fake_ssh!(fail_remote_port: nil)
    on_exit(ssh.cleanup)

    config_path = Path.join(ssh.root, "mcp.json")
    File.write!(config_path, ~s({"mcpServers":{}}))

    mcp_options = %{
      config: config_path,
      allowed_tools: [],
      env: %{
        "SYMPHONY_TRACKER_MCP_URL" => "http://127.0.0.1:43123/mcp",
        "SYMPHONY_TRACKER_MCP_TOKEN" => "remote-session-token"
      }
    }

    test_pid = self()
    on_event = fn event -> send(test_pid, {:tunnel_loss_event, event}) end

    assert {:ok, session} =
             Claude.start_session(workspace, issue, nil,
               worker_host: "worker.example",
               on_event: on_event,
               mcp_options: mcp_options,
               remote_port_candidates: [43_210]
             )

    %{remote_staging_dir: staging_dir} = Session.transport_info(session.pid)

    task = Task.async(fn -> Claude.run_turn(session, "read-timeout", issue) end)
    assert_eventually(fn -> File.exists?(Path.join(workspace, "claude-child.pid")) end)
    File.touch!(Path.join(ssh.state_dir, "loss"))

    assert {:error, {:ssh_tunnel_lost, 42}, failed_session} = Task.await(task, 2_000)

    assert_receive {:tunnel_loss_event,
                    %AgentEvent{
                      kind: :turn_failed,
                      payload: %{reason: {:ssh_tunnel_lost, 42}},
                      metadata: failed_metadata
                    }}

    assert failed_metadata.mcp == %{
             enabled: true,
             health: :unhealthy,
             transport: :ssh_reverse_tunnel
           }

    assert failed_metadata.ssh_tunnel == %{health: :unhealthy, remote_port: 43_210}
    safe_metadata = inspect(failed_metadata)
    refute safe_metadata =~ "remote-session-token"
    refute safe_metadata =~ "http://127.0.0.1:43123/mcp"
    refute safe_metadata =~ config_path
    refute safe_metadata =~ staging_dir
    assert_process_tree_stopped(workspace)
    assert :ok = Claude.stop_session(failed_session, :normal)
  end

  test "auth preflight fails closed for logged-out, malformed, and stalled CLI responses", %{
    workspace: _workspace,
    issue: _issue
  } do
    settings = Config.settings!()

    System.put_env("FAKE_CLAUDE_AUTH_STATUS", "logged-out")

    assert {:error,
            {:claude_authentication_failed,
             %{
               api_provider: "firstParty",
               auth_method: "none",
               exit_status: 1,
               logged_in: false
             }}} = Claude.validate_host(settings, nil)

    System.put_env("FAKE_CLAUDE_AUTH_STATUS", "malformed")

    assert {:error, {:claude_auth_status_failed, %{exit_status: 1, reason: :invalid_response}}} =
             Claude.validate_host(settings, nil)

    System.put_env("FAKE_CLAUDE_AUTH_STATUS", "timeout")
    fast_timeout_settings = put_in(settings.claude.read_timeout_ms, 50)
    assert {:error, {:claude_auth_status_failed, :timeout}} = Claude.validate_host(fast_timeout_settings, nil)
  end

  test "rejects reserved protocol flags embedded in the configured command", %{
    workspace: _workspace,
    issue: _issue
  } do
    settings = Config.settings!()

    for {command, expected_flag} <- [
          {"claude --output-format text", "--output-format"},
          {"claude --output-format=text", "--output-format"},
          {"claude --resume previous", "--resume"},
          {~s(claude "--resume" previous), "--resume"},
          {~s(claude '--allowedTools=tracker_get_issue'), "--allowedTools"},
          {"claude -p", "-p"},
          {"claude --dangerously-skip-permissions", "--dangerously-skip-permissions"}
        ] do
      configured = put_in(settings.claude.command, command)

      assert {:error, {:reserved_claude_command_flag, ^expected_flag}} =
               Claude.validate_config(configured)
    end
  end

  test "tokenizes command prefixes without executing shell syntax", %{
    workspace: workspace,
    issue: _issue
  } do
    marker = Path.join(workspace, "command-validation-must-not-execute")

    configured =
      put_in(
        Config.settings!().claude.command,
        "claude '$(touch #{marker})' \"--mcp-config=/tmp/untrusted.json\""
      )

    assert {:error, {:reserved_claude_command_flag, "--mcp-config"}} =
             Claude.validate_config(configured)

    refute File.exists?(marker)
  end

  defp assert_process_tree_stopped(workspace, attempts \\ @process_stop_attempts) do
    for filename <- ["claude-process.pid", "claude-child.pid"],
        {:ok, contents} <- [File.read(Path.join(workspace, filename))] do
      pid = String.trim(contents)
      assert_eventually(fn -> not process_alive?(pid) end, attempts)
    end
  end

  defp process_alive?(pid) do
    case System.cmd("ps", ["-o", "stat=", "-p", pid], stderr_to_stdout: true) do
      {status, 0} -> process_running_status?(status)
      {_output, _status} -> false
    end
  end

  defp process_running_status?(status) do
    status = String.trim(status)
    status != "" and not String.starts_with?(status, "Z")
  end

  defp assert_eventually(fun, attempts \\ @eventually_attempts)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")

  defp install_fake_ssh!(opts \\ []) do
    root = Path.join(System.tmp_dir!(), "symphony-claude-ssh-#{System.unique_integer([:positive])}")
    bin_dir = Path.join(root, "bin")
    state_dir = Path.join(root, "state")
    trace = Path.join(root, "ssh.trace")
    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("FAKE_SSH_TRACE")
    previous_state_dir = System.get_env("FAKE_SSH_STATE_DIR")
    previous_fail_port = System.get_env("FAKE_SSH_FAIL_REMOTE_PORT")
    previous_remote_mode = System.get_env("FAKE_SSH_REMOTE_MODE")

    File.mkdir_p!(bin_dir)
    File.mkdir_p!(state_dir)
    File.cp!(@fake_ssh, Path.join(bin_dir, "ssh"))
    File.chmod!(Path.join(bin_dir, "ssh"), 0o755)
    System.put_env("PATH", bin_dir <> ":" <> (previous_path || ""))
    System.put_env("FAKE_SSH_TRACE", trace)
    System.put_env("FAKE_SSH_STATE_DIR", state_dir)
    System.delete_env("FAKE_SSH_REMOTE_MODE")

    case Keyword.get(opts, :fail_remote_port, 43_209) do
      nil -> System.delete_env("FAKE_SSH_FAIL_REMOTE_PORT")
      port -> System.put_env("FAKE_SSH_FAIL_REMOTE_PORT", to_string(port))
    end

    cleanup = fn ->
      restore_env("PATH", previous_path)
      restore_env("FAKE_SSH_TRACE", previous_trace)
      restore_env("FAKE_SSH_STATE_DIR", previous_state_dir)
      restore_env("FAKE_SSH_FAIL_REMOTE_PORT", previous_fail_port)
      restore_env("FAKE_SSH_REMOTE_MODE", previous_remote_mode)
      File.rm_rf(root)
    end

    %{root: root, state_dir: state_dir, trace: trace, cleanup: cleanup}
  end

  defp file_mode(path) do
    {:ok, stat} = File.stat(path)
    Bitwise.band(stat.mode, 0o777)
  end

  defp trace_position(trace, needle) do
    {position, _length} = :binary.match(trace, needle)
    position
  end

  defp tracker_tool_session(issue) do
    %{
      adapter: SymphonyElixir.Tracker.Memory,
      tracker_settings: %{kind: "memory"},
      tool_specs: [
        %{
          "name" => "tracker_get_issue",
          "description" => "Refresh the issue.",
          "inputSchema" => %{"type" => "object"}
        }
      ],
      secret_environment_names: ["LINEAR_API_KEY"],
      issue: issue
    }
  end

  defp remote_mcp_options(config_path) do
    %{
      config: config_path,
      allowed_tools: [],
      env: %{
        "SYMPHONY_TRACKER_MCP_URL" => "http://127.0.0.1:43123/mcp",
        "SYMPHONY_TRACKER_MCP_TOKEN" => "remote-session-token"
      }
    }
  end
end
