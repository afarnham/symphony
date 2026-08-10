defmodule SymphonyElixir.TrackerToolBrokerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool, as: CodexDynamicTool
  alias SymphonyElixir.Linear.Adapter
  alias SymphonyElixir.Linear.AgentTool, as: LinearAgentTool
  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.Tracker.Memory
  alias SymphonyElixir.TrackerToolBroker
  alias SymphonyElixir.Workflow

  defmodule GenericAdapter do
    @spec fetch_issues_by_ids([String.t()], keyword()) :: {:ok, [Issue.t()]}
    def fetch_issues_by_ids([issue_id], opts) do
      settings = Keyword.fetch!(opts, :tracker_settings)
      send(settings.test_pid, {:refreshed, issue_id, settings.marker})
      {:ok, [%Issue{id: issue_id, identifier: "GH-1", state: "In Progress"}]}
    end

    @spec update_issue_state(Issue.t(), String.t(), keyword()) :: {:ok, Issue.t()}
    def update_issue_state(%Issue{} = issue, state, opts) do
      settings = Keyword.fetch!(opts, :tracker_settings)
      send(settings.test_pid, {:updated, issue.id, state, settings.marker})
      {:ok, %{issue | state: state}}
    end

    @spec add_issue_comment(Issue.t(), String.t(), keyword()) :: {:ok, map()}
    def add_issue_comment(%Issue{} = issue, body, opts) do
      settings = Keyword.fetch!(opts, :tracker_settings)
      send(settings.test_pid, {:commented, issue.id, body, settings.marker})
      {:ok, %{"id" => 17}}
    end
  end

  test "bind snapshots the selected adapter, settings, tool specs, and secret names" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_api_token: "session-token",
      tracker_project_slug: "session-project"
    )

    binding = TrackerToolBroker.bind()

    assert binding.adapter == Adapter
    assert binding.tracker_settings.api_key == "session-token"
    assert binding.tracker_settings.project_slug == "session-project"

    assert Enum.map(binding.tool_specs, & &1["name"]) == [
             "tracker_get_issue",
             "tracker_add_comment",
             "tracker_update_state",
             "linear_graphql"
           ]

    assert binding.secret_environment_names == ["LINEAR_API_KEY"]

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    assert Enum.map(TrackerToolBroker.bind().tool_specs, & &1["name"]) == [
             "tracker_get_issue",
             "tracker_add_comment",
             "tracker_update_state"
           ]

    assert binding.adapter == Adapter
    assert binding.tracker_settings.api_key == "session-token"
    assert List.last(binding.tool_specs)["name"] == "linear_graphql"
  end

  test "shared tools refresh, comment, and transition with the session-bound issue and settings" do
    issue = %Issue{id: "41", identifier: "GH-141", state: "Ready", dispatchable: true}

    binding = %{
      adapter: GenericAdapter,
      tracker_settings: %{
        active_states: ["Ready", "In Progress"],
        terminal_states: ["Done"],
        working_state: "In Progress",
        blocked_state: "Blocked",
        completion_state: "In Review",
        marker: :bound_snapshot,
        test_pid: self()
      },
      tool_specs: [],
      secret_environment_names: [],
      issue: issue
    }

    assert %{"success" => true, "output" => refresh_output} =
             TrackerToolBroker.execute(binding, "tracker_get_issue", %{})

    assert Jason.decode!(refresh_output)["issue"]["state"] == "In Progress"
    assert_receive {:refreshed, "41", :bound_snapshot}

    assert %{"success" => true, "output" => comment_output} =
             TrackerToolBroker.execute(binding, "tracker_add_comment", %{"body" => "  hello  "})

    assert Jason.decode!(comment_output)["comment"] == %{"id" => 17}
    assert_receive {:commented, "41", "hello", :bound_snapshot}

    assert %{"success" => true, "output" => state_output} =
             TrackerToolBroker.execute(binding, "tracker_update_state", %{"state" => "in review"})

    assert Jason.decode!(state_output)["issue"]["state"] == "in review"
    assert_receive {:updated, "41", "in review", :bound_snapshot}

    assert %{"success" => true} =
             TrackerToolBroker.execute(binding, "tracker_update_state", %{"state" => "Blocked"})

    assert_receive {:updated, "41", "Blocked", :bound_snapshot}

    assert %{"success" => false} =
             TrackerToolBroker.execute(binding, "tracker_update_state", %{"state" => "Backlog"})

    refute_receive {:updated, "41", "Backlog", :bound_snapshot}
  end

  test "tracker routes bound reads, state changes, and provider tools through captured settings" do
    issue = %Issue{id: "41", identifier: "GH-141", state: "Ready", dispatchable: true}

    tracker_settings = %{
      active_states: ["Ready", "In Progress"],
      terminal_states: ["Done"],
      working_state: "In Progress",
      blocked_state: "Blocked",
      completion_state: "In Review",
      marker: :bound_snapshot,
      test_pid: self()
    }

    binding = %{adapter: GenericAdapter, tracker_settings: tracker_settings}

    assert {:ok, [%Issue{id: "41"}]} = Tracker.fetch_bound_issues_by_ids(binding, ["41"])
    assert_receive {:refreshed, "41", :bound_snapshot}

    assert {:ok, %Issue{state: "In Progress"}} =
             Tracker.update_issue_state(issue, "In Progress",
               adapter: GenericAdapter,
               tracker_settings: tracker_settings
             )

    assert_receive {:updated, "41", "In Progress", :bound_snapshot}

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    assert {:ok, [^issue]} =
             Tracker.fetch_bound_issues_by_ids(
               %{adapter: Memory, tracker_settings: %{kind: "memory"}},
               ["41"]
             )

    linear_binding = %{
      adapter: Adapter,
      tracker_settings: %{api_key: "token", endpoint: "https://linear.test/graphql"}
    }

    result =
      Tracker.execute_bound_agent_tool(
        linear_binding,
        "linear_graphql",
        %{"query" => "query { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:ok, %{"data" => %{}}} end
      )

    assert result["success"]
  end

  test "execute uses the bound settings and preserves the provider response" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_api_token: "session-token",
      tracker_project_slug: "session-project"
    )

    binding = TrackerToolBroker.bind()
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    test_pid = self()

    response =
      TrackerToolBroker.execute(
        binding,
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_bound"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, [tracker_settings: tracker_settings]}
    assert tracker_settings.api_key == "session-token"
    assert tracker_settings.project_slug == "session-project"

    assert response["success"] == true
    assert Jason.decode!(response["output"]) == %{"data" => %{"viewer" => %{"id" => "usr_bound"}}}

    assert response["contentItems"] == [
             %{"type" => "inputText", "text" => response["output"]}
           ]
  end

  test "execute preserves the provider rejection for unsupported tools" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    binding = TrackerToolBroker.bind()

    response = TrackerToolBroker.execute(binding, "not_a_real_tool", %{})

    assert response ==
             LinearAgentTool.execute(
               "not_a_real_tool",
               %{},
               tracker_settings: binding.tracker_settings
             )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "not_a_real_tool".),
               "supportedTools" => ["linear_graphql"]
             }
           }

    assert response["contentItems"] == [
             %{"type" => "inputText", "text" => response["output"]}
           ]
  end

  test "execute returns the existing failure envelope when the adapter has no tools" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    binding = TrackerToolBroker.bind()

    response = TrackerToolBroker.execute(binding, "not_a_memory_tool", %{})

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "not_a_memory_tool".),
               "supportedTools" => []
             }
           }

    assert response["contentItems"] == [
             %{"type" => "inputText", "text" => response["output"]}
           ]
  end

  test "Codex dynamic tools expose and execute the broker binding unchanged" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    broker_binding = TrackerToolBroker.bind()

    assert CodexDynamicTool.bind() == broker_binding

    expected = TrackerToolBroker.execute(broker_binding, "not_a_real_tool", %{})

    assert CodexDynamicTool.execute(
             "not_a_real_tool",
             %{},
             broker_binding
           ) == expected
  end
end
