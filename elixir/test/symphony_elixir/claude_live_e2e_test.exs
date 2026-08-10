defmodule SymphonyElixir.ClaudeLiveE2ETest do
  use SymphonyElixir.TestSupport

  @moduletag :live_e2e

  alias SymphonyElixir.AgentBackend.Claude
  alias SymphonyElixir.AgentTurnResult
  alias SymphonyElixir.Config
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.Workflow

  defmodule LiveAdapter do
    @spec fetch_issues_by_ids([String.t()], keyword()) :: {:ok, [Issue.t()]}
    def fetch_issues_by_ids([issue_id], opts) do
      tracker_settings = Keyword.fetch!(opts, :tracker_settings)
      send(tracker_settings.test_pid, {:live_tracker_refresh, issue_id})

      {:ok,
       [
         %Issue{
           id: issue_id,
           identifier: "LIVE-CLAUDE",
           title: "Claude smoke",
           state: "In Progress",
           dispatchable: true
         }
       ]}
    end
  end

  @live_e2e_skip_reason if(System.get_env("SYMPHONY_RUN_CLAUDE_LIVE_E2E") != "1",
                          do: "set SYMPHONY_RUN_CLAUDE_LIVE_E2E=1 to enable the real Claude CLI smoke test"
                        )

  @tag skip: @live_e2e_skip_reason
  test "runs a real authenticated Claude stream turn" do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-claude-live-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(root, "workspaces")
    workspace = Path.join(workspace_root, "LIVE-CLAUDE")
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf(root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      agent_backend: "claude",
      claude_command: "claude",
      claude_permission_mode: "default",
      claude_turn_timeout_ms: 120_000,
      claude_read_timeout_ms: 30_000
    )

    settings = Config.settings!()
    issue = %Issue{id: "live-claude", identifier: "LIVE-CLAUDE", title: "Claude smoke"}

    tool_session = %{
      adapter: LiveAdapter,
      tracker_settings: %{
        test_pid: self(),
        active_states: ["In Progress"],
        terminal_states: ["Done"],
        working_state: "In Progress",
        blocked_state: "Blocked",
        completion_state: "Done"
      },
      tool_specs: [
        %{
          "name" => "tracker_get_issue",
          "description" => "Refresh the current test issue.",
          "inputSchema" => %{
            "type" => "object",
            "additionalProperties" => false,
            "properties" => %{}
          }
        }
      ],
      secret_environment_names: [],
      issue: issue
    }

    assert :ok = Claude.validate_host(settings, nil)

    assert {:ok, session} =
             Claude.start_session(workspace, issue, tool_session, settings: settings)

    try do
      assert {:ok, %AgentTurnResult{status: :completed} = result, final_session} =
               Claude.run_turn(
                 session,
                 "Call tracker_get_issue exactly once, then respond with exactly SYMPHONY_CLAUDE_SMOKE_OK and no other text.",
                 issue
               )

      assert_receive {:live_tracker_refresh, "live-claude"}, 30_000
      assert result.final_text =~ "SYMPHONY_CLAUDE_SMOKE_OK"
      assert is_binary(result.session_id)
      assert :ok = Claude.stop_session(final_session, :normal)
    after
      Claude.stop_session(session, :test_cleanup)
    end
  end
end
