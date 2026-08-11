defmodule SymphonyElixir.AgentBackendTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentBackend
  alias SymphonyElixir.AgentBackend.Codex
  alias SymphonyElixir.{AgentEvent, AgentRunner, AgentTurnResult, ExecutionRoute, Workflow}
  alias SymphonyElixir.Tracker.Issue

  defmodule FakeAppServer do
    def start_session(workspace, opts) do
      send(self(), {:fake_start_session, workspace, opts})
      {:ok, %{thread_id: "thread-1", workspace: workspace}}
    end

    def run_turn(session, prompt, issue, opts) do
      on_message = Keyword.fetch!(opts, :on_message)

      on_message.(%{
        event: :session_started,
        timestamp: DateTime.utc_now(),
        session_id: "thread-1-turn-1",
        thread_id: "thread-1",
        turn_id: "turn-1",
        codex_app_server_pid: "123"
      })

      on_message.(%{
        event: :turn_completed,
        timestamp: DateTime.utc_now(),
        payload: %{"method" => "turn/completed"}
      })

      send(self(), {:fake_run_turn, session, prompt, issue})

      {:ok,
       %{
         result: :turn_completed,
         session_id: "thread-1-turn-1",
         thread_id: "thread-1",
         turn_id: "turn-1"
       }}
    end

    def stop_session(session) do
      send(self(), {:fake_stop_session, session})
      :ok
    end
  end

  defmodule FakeBlockedAppServer do
    def start_session(workspace, _opts), do: {:ok, %{thread_id: "thread-blocked", workspace: workspace}}

    def run_turn(_session, _prompt, _issue, opts) do
      Keyword.fetch!(opts, :on_message).(%{
        event: :turn_input_required,
        timestamp: DateTime.utc_now(),
        payload: %{"reason" => "question"}
      })

      {:error, {:turn_input_required, %{"reason" => "question"}}}
    end

    def stop_session(_session), do: :ok
  end

  defmodule FakeRichAppServer do
    def start_session(workspace, _opts), do: {:ok, %{thread_id: "thread-rich", workspace: workspace}}

    def run_turn(_session, prompt, _issue, opts) do
      on_message = Keyword.fetch!(opts, :on_message)
      second_turn? = prompt == "second"
      turn_id = if second_turn?, do: "turn-2", else: "turn-1"

      usage =
        if second_turn? do
          %{"inputTokens" => 20, "cachedInputTokens" => 5, "outputTokens" => 9}
        else
          %{"inputTokens" => 14, "cachedInputTokens" => 3, "outputTokens" => 5}
        end

      emit(on_message, :session_started, %{
        session_id: "thread-rich-#{turn_id}",
        thread_id: "thread-rich",
        turn_id: turn_id,
        codex_app_server_pid: "456"
      })

      emit(on_message, :notification, %{
        payload: %{"method" => "item/agentMessage/delta", "params" => %{"delta" => "Working "}}
      })

      emit(on_message, :notification, %{
        payload: %{
          "method" => "codex/event/agent_message_content_delta",
          "params" => %{"msg" => %{"content" => "done."}}
        }
      })

      emit(on_message, :notification, %{
        payload: %{
          "method" => "item/completed",
          "params" => %{"item" => %{"id" => "message-1", "type" => "agentMessage", "text" => "Working done."}}
        }
      })

      emit(on_message, :notification, %{
        payload: %{
          "method" => "item/reasoning/textDelta",
          "params" => %{"textDelta" => "Checking the result"}
        }
      })

      emit(on_message, :notification, %{
        payload: %{
          "method" => "item/started",
          "params" => %{"item" => %{"id" => "command-1", "type" => "commandExecution", "command" => "mix test"}}
        }
      })

      emit(on_message, :tool_call_failed, %{
        payload: %{"method" => "item/tool/call", "params" => %{"itemId" => "tool-1", "tool" => "tracker_get_issue"}}
      })

      emit(on_message, :notification, %{
        payload: %{
          "method" => "thread/tokenUsage/updated",
          "params" => %{"tokenUsage" => %{"total" => usage}}
        }
      })

      emit(on_message, :turn_completed, %{payload: %{"method" => "turn/completed"}})

      {:ok,
       %{
         result: :turn_completed,
         session_id: "thread-rich-#{turn_id}",
         thread_id: "thread-rich",
         turn_id: turn_id
       }}
    end

    def stop_session(_session), do: :ok

    defp emit(on_message, event, details) do
      on_message.(details |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now()))
    end
  end

  defmodule FakeBackend do
    @behaviour SymphonyElixir.AgentBackend

    @impl true
    def name, do: :fake

    @impl true
    def validate_config(_settings), do: :ok

    @impl true
    def validate_host(_settings, _worker_host), do: :ok

    @impl true
    def start_session(_workspace, issue, _tool_session, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:fake_backend_started, issue.id})
      {:ok, %{turn: 0, test_pid: Keyword.fetch!(opts, :test_pid)}}
    end

    @impl true
    def run_turn(session, _prompt, _issue, _opts) do
      updated_session = %{session | turn: session.turn + 1}
      send(session.test_pid, {:fake_backend_turn, session.turn, updated_session.turn})

      {:ok,
       %AgentTurnResult{
         backend: :fake,
         session_id: "fake-session",
         turn_id: "turn-#{updated_session.turn}",
         status: :completed
       }, updated_session}
    end

    @impl true
    def stop_session(session, reason) do
      send(session.test_pid, {:fake_backend_stopped, session.turn, reason})
      :ok
    end
  end

  defmodule FakeBlockingBackend do
    @behaviour SymphonyElixir.AgentBackend

    @impl true
    def name, do: :fake_blocking

    @impl true
    def validate_config(_settings), do: :ok

    @impl true
    def validate_host(_settings, _worker_host), do: :ok

    @impl true
    def start_session(_workspace, _issue, _tool_session, opts) do
      session_pid =
        spawn_link(fn ->
          receive do
            :stop -> :ok
          end
        end)

      {:ok, %{pid: session_pid, test_pid: Keyword.fetch!(opts, :test_pid)}}
    end

    @impl true
    def run_turn(session, _prompt, _issue, _opts) do
      send(session.test_pid, :fake_blocking_turn_started)

      receive do
        :never -> {:error, :unexpected, session}
      end
    end

    @impl true
    def stop_session(session, reason) do
      send(
        session.test_pid,
        {:fake_blocking_backend_stopped, reason, Process.alive?(session.pid)}
      )

      send(session.pid, :stop)
      :ok
    end
  end

  test "backend registry resolves configured names without dynamic atoms" do
    assert {:ok, Codex} = AgentBackend.resolve(%{agent: %{backend: "codex"}})

    assert {:error, {:unsupported_agent_backend, "unknown"}} =
             AgentBackend.resolve(%{agent: %{backend: "unknown"}})

    assert {:error, {:unsupported_agent_backend, nil}} = AgentBackend.resolve(nil)
  end

  test "Codex wrapper preserves the app-server session and normalizes events and results" do
    issue = %Issue{id: "issue-1", identifier: "GH-1"}
    on_event = fn event -> send(self(), {:agent_event, event}) end

    assert {:ok, session} =
             Codex.start_session("/tmp/workspace", issue, nil,
               app_server_module: FakeAppServer,
               on_event: on_event,
               worker_host: nil
             )

    assert_receive {:fake_start_session, "/tmp/workspace", start_opts}
    assert start_opts[:worker_host] == nil

    assert_receive {:agent_event,
                    %AgentEvent{
                      kind: :session_started,
                      backend: :codex,
                      issue_id: "issue-1",
                      session_id: "thread-1"
                    }}

    assert {:ok,
            %AgentTurnResult{
              backend: :codex,
              status: :completed,
              session_id: "thread-1",
              turn_id: "turn-1"
            }, updated_session} =
             Codex.run_turn(session, "prompt", issue, on_event: on_event)

    assert updated_session.session_id == "thread-1"
    assert updated_session.turn_id == "turn-1"
    assert_receive {:fake_run_turn, %{thread_id: "thread-1"}, "prompt", ^issue}

    assert_receive {:agent_event,
                    %AgentEvent{
                      kind: :turn_started,
                      session_id: "thread-1",
                      turn_id: "turn-1",
                      metadata: %{os_pid: "123"}
                    }}

    assert_receive {:agent_event, %AgentEvent{kind: :turn_completed, session_id: "thread-1", turn_id: "turn-1"}}

    assert :ok = Codex.stop_session(updated_session, :normal)
    assert_receive {:fake_stop_session, %{thread_id: "thread-1"}}
  end

  test "Codex wrapper maps interactive turns to the shared blocked result" do
    issue = %Issue{id: "issue-blocked", identifier: "GH-2"}
    on_event = fn event -> send(self(), {:agent_event, event}) end

    assert {:ok, session} =
             Codex.start_session("/tmp/workspace", issue, nil,
               app_server_module: FakeBlockedAppServer,
               on_event: on_event
             )

    assert {:blocked,
            %AgentTurnResult{
              status: :blocked,
              input_required: true,
              failure_reason: {:turn_input_required, %{"reason" => "question"}}
            }, _session} =
             Codex.run_turn(session, "prompt", issue, on_event: on_event)

    assert_receive {:agent_event, %AgentEvent{kind: :input_required, issue_id: "issue-blocked"}}
  end

  test "Codex wrapper emits lossless normalized text, tool, reasoning, usage, and terminal data" do
    issue = %Issue{id: "issue-rich", identifier: "GH-RICH"}
    on_event = fn event -> send(self(), {:agent_event, event}) end

    assert {:ok, session} =
             Codex.start_session("/tmp/workspace", issue, nil,
               app_server_module: FakeRichAppServer,
               on_event: on_event
             )

    assert {:ok,
            %AgentTurnResult{
              status: :completed,
              final_text: "Working done.",
              text_blocks: ["Working done."],
              input_tokens: 14,
              cached_input_tokens: 3,
              output_tokens: 5,
              metadata: %{usage_source: :thread_total, native_terminal: %{event: :turn_completed}}
            }, updated_session} = Codex.run_turn(session, "first", issue, on_event: on_event)

    assert updated_session.thread_usage == %{input_tokens: 14, cached_input_tokens: 3, output_tokens: 5}

    assert_received {:agent_event,
                     %AgentEvent{
                       kind: :assistant_text,
                       payload: %{delta: true, text: "Working ", native: %{event: :notification}}
                     }}

    assert_received {:agent_event, %AgentEvent{kind: :reasoning_update, payload: %{text: "Checking the result"}}}

    assert_received {:agent_event, %AgentEvent{kind: :action_started, payload: %{native_type: "commandExecution"}}}

    assert_received {:agent_event,
                     %AgentEvent{
                       kind: :tool_call_completed,
                       payload: %{is_error: true, name: "tracker_get_issue", native: %{event: :tool_call_failed}}
                     }}

    assert_received {:agent_event,
                     %AgentEvent{
                       kind: :usage_updated,
                       payload: %{
                         accounting: :absolute,
                         source: :thread_total,
                         usage: %{input_tokens: 14, cached_input_tokens: 3, output_tokens: 5},
                         native: %{event: :notification}
                       }
                     }}

    assert_received {:agent_event,
                     %AgentEvent{
                       kind: :turn_completed,
                       payload: %{final_text: "Working done.", native: %{event: :turn_completed}}
                     }}

    assert_received {:agent_event,
                     %AgentEvent{
                       kind: :assistant_text,
                       payload: %{delta: false, replaces_stream: true, text: "Working done."}
                     }}
  end

  test "Codex wrapper converts cumulative thread usage into authoritative per-turn usage" do
    issue = %Issue{id: "issue-rich-continuation", identifier: "GH-RICH-2"}
    on_event = fn event -> send(self(), {:agent_event, event}) end

    assert {:ok, session} =
             Codex.start_session("/tmp/workspace", issue, nil,
               app_server_module: FakeRichAppServer,
               on_event: on_event
             )

    assert {:ok, %AgentTurnResult{}, session} = Codex.run_turn(session, "first", issue, on_event: on_event)

    assert {:ok,
            %AgentTurnResult{
              turn_id: "turn-2",
              input_tokens: 6,
              cached_input_tokens: 2,
              output_tokens: 4
            }, session} = Codex.run_turn(session, "second", issue, on_event: on_event)

    assert session.thread_usage == %{input_tokens: 20, cached_input_tokens: 5, output_tokens: 9}
  end

  test "AgentRunner snapshots a backend and threads its updated session across continuation turns" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", max_turns: 3)

    issue = %Issue{
      id: "issue-fake-backend",
      identifier: "FAKE-1",
      title: "Exercise backend",
      state: "In Progress",
      dispatchable: true
    }

    Process.put(:fake_backend_refresh_count, 0)

    route = %ExecutionRoute{
      profile: "afarnham",
      ready_actor: "afarnham",
      backend: "codex",
      worker_hosts: []
    }

    issue_state_fetcher = fn ["issue-fake-backend"] ->
      count = Process.get(:fake_backend_refresh_count, 0) + 1
      Process.put(:fake_backend_refresh_count, count)

      state = if count == 1, do: "In Progress", else: "Done"
      {:ok, [%{issue | state: state}]}
    end

    assert :ok =
             AgentRunner.run(issue, self(),
               backend_module: FakeBackend,
               execution_route: route,
               issue_state_fetcher: issue_state_fetcher,
               backend_options: [test_pid: self()]
             )

    assert_receive {:fake_backend_started, "issue-fake-backend"}
    assert_receive {:worker_runtime_info, "issue-fake-backend", %{profile: "afarnham", ready_actor: "afarnham", backend: :fake}}
    assert_receive {:fake_backend_turn, 0, 1}
    assert_receive {:fake_backend_turn, 1, 2}
    assert_receive {:agent_worker_completed, "issue-fake-backend", %AgentTurnResult{turn_id: "turn-2"}}
    assert_receive {:fake_backend_stopped, 2, :normal}
  end

  test "AgentRunner rejects a preferred host outside the captured profile" do
    issue = %Issue{
      id: "issue-cross-profile-host",
      identifier: "ROUTE-1",
      title: "Keep credentials isolated",
      state: "In Progress",
      dispatchable: true
    }

    route = %ExecutionRoute{
      profile: "afarnham",
      ready_actor: "afarnham",
      backend: "codex",
      worker_hosts: ["worker@agent-worker-afarnham"]
    }

    assert_raise RuntimeError, ~r/worker_host_outside_execution_profile/, fn ->
      AgentRunner.run(issue, self(),
        backend_module: FakeBackend,
        execution_route: route,
        worker_host: "worker@agent-worker-karbas"
      )
    end
  end

  test "AgentRunner publishes a guardian that stops a blocked backend before task termination" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", max_turns: 1)

    issue = %Issue{
      id: "issue-cancel-backend",
      identifier: "FAKE-CANCEL",
      title: "Cancel backend",
      state: "In Progress",
      dispatchable: true
    }

    test_pid = self()

    runner_pid =
      spawn(fn ->
        AgentRunner.run(issue, test_pid,
          backend_module: FakeBlockingBackend,
          backend_options: [test_pid: test_pid]
        )
      end)

    on_exit(fn ->
      if Process.alive?(runner_pid), do: Process.exit(runner_pid, :kill)
    end)

    assert_receive {:agent_cancellation_ready, "issue-cancel-backend", cancellation_pid}
    assert_receive :fake_blocking_turn_started
    assert :ok = AgentRunner.cancel(cancellation_pid, :reconciled)
    assert_receive {:fake_blocking_backend_stopped, :reconciled, true}
  end

  test "AgentRunner guardian cleans a detached backend session when its runner crashes" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", max_turns: 1)

    issue = %Issue{
      id: "issue-crashed-runner",
      identifier: "FAKE-CRASH",
      title: "Crash runner",
      state: "In Progress",
      dispatchable: true
    }

    test_pid = self()

    runner_pid =
      spawn(fn ->
        AgentRunner.run(issue, test_pid,
          backend_module: FakeBlockingBackend,
          backend_options: [test_pid: test_pid]
        )
      end)

    assert_receive {:agent_cancellation_ready, "issue-crashed-runner", _cancellation_pid}
    assert_receive :fake_blocking_turn_started
    Process.exit(runner_pid, :kill)

    assert_receive {:fake_blocking_backend_stopped, {:runner_down, :killed}, true}
  end
end
