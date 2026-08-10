defmodule SymphonyElixir.GitHubProject.AdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHubProject.Adapter
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Tracker

  defmodule FakeClient do
    def load_snapshot(_tracker_settings, _opts) do
      {:ok, %{project_id: 901, status: %{field_id: 7}, token: "must-not-be-snapshotted"}}
    end

    def fetch_issues_by_states(states) do
      send(self(), {:github_project_states, states})
      {:ok, states}
    end

    def fetch_issues_by_states(states, tracker_settings, opts) do
      send(self(), {:github_project_bound_states, states, tracker_settings, opts})
      {:ok, states}
    end

    def fetch_issues_by_ids(ids) do
      send(self(), {:github_project_ids, ids})
      {:ok, ids}
    end

    def fetch_issues_by_ids(ids, tracker_settings, opts) do
      send(self(), {:github_project_bound_ids, ids, tracker_settings, opts})

      issues_by_id =
        tracker_settings
        |> Map.get(:provider, %{})
        |> Map.get("test_bound_issues")

      case issues_by_id do
        issues_by_id when is_map(issues_by_id) ->
          {:ok, Enum.flat_map(ids, &List.wrap(Map.get(issues_by_id, &1)))}

        _other ->
          {:ok, ids}
      end
    end

    def update_issue_state(issue, state, opts) do
      send(self(), {:github_project_update, issue, state, opts})
      {:ok, %{issue | state: state}}
    end
  end

  setup do
    previous_client = Application.get_env(:symphony_elixir, :github_project_client_module)

    on_exit(fn ->
      if is_nil(previous_client) do
        Application.delete_env(:symphony_elixir, :github_project_client_module)
      else
        Application.put_env(:symphony_elixir, :github_project_client_module, previous_client)
      end
    end)

    :ok
  end

  test "validates project provider and lifecycle state relationships" do
    settings = tracker_settings()

    assert :ok = Adapter.validate_config(settings)

    assert {:error, :missing_github_project_owner} =
             Adapter.validate_config(put_provider(settings, "owner", ""))

    assert {:error, :invalid_github_project_owner_type} =
             Adapter.validate_config(put_provider(settings, "owner_type", "team"))

    assert {:error, :invalid_github_project_number} =
             Adapter.validate_config(put_provider(settings, "project_number", 0))

    assert {:error, :invalid_github_project_repository} =
             Adapter.validate_config(put_provider(settings, "repository", "repo"))

    assert {:error, :missing_github_project_status_field} =
             Adapter.validate_config(put_provider(settings, "status_field", " "))

    assert {:error, :missing_github_project_active_states} =
             Adapter.validate_config(%{settings | active_states: nil})

    assert {:error, :missing_github_project_terminal_states} =
             Adapter.validate_config(%{settings | terminal_states: nil})

    assert {:error, :missing_github_project_working_state} =
             Adapter.validate_config(%{settings | working_state: nil})

    assert {:error, :missing_github_project_blocked_state} =
             Adapter.validate_config(%{settings | blocked_state: nil})

    assert {:error, :github_project_working_state_not_active} =
             Adapter.validate_config(%{settings | working_state: "Doing"})

    assert {:error, :github_project_active_terminal_state_overlap} =
             Adapter.validate_config(%{settings | terminal_states: ["Done", " ready "]})

    assert {:error, :github_project_blocked_state_active} =
             Adapter.validate_config(%{settings | blocked_state: "Ready"})

    assert {:error, :github_project_blocked_state_terminal} =
             Adapter.validate_config(%{settings | blocked_state: "Done"})

    assert {:error, :github_project_blocked_completion_state_overlap} =
             Adapter.validate_config(%{settings | blocked_state: "In Review"})

    assert {:error, :invalid_github_project_completion_state} =
             Adapter.validate_config(%{settings | completion_state: 42})
  end

  test "delegates project-item reads and status updates to the configured client" do
    Application.put_env(:symphony_elixir, :github_project_client_module, FakeClient)
    issue = %Issue{id: "41", identifier: "GH-141", state: "Ready"}

    assert {:ok, ["Ready"]} = Adapter.fetch_issues_by_states(["Ready"])
    assert_receive {:github_project_states, ["Ready"]}

    assert {:ok, ["41"]} = Adapter.fetch_issues_by_ids(["41"])
    assert_receive {:github_project_ids, ["41"]}

    tracker_settings = tracker_settings()
    snapshot = %{project_id: 901}

    assert {:ok, ["Ready"]} =
             Tracker.fetch_bound_issues_by_states(
               %{adapter: Adapter, tracker_settings: tracker_settings},
               ["Ready"]
             )

    assert_receive {:github_project_bound_states, ["Ready"], ^tracker_settings, []}

    assert {:ok, ["41"]} =
             Adapter.fetch_issues_by_ids(
               ["41"],
               tracker_settings: tracker_settings,
               snapshot: snapshot
             )

    assert_receive {:github_project_bound_ids, ["41"], ^tracker_settings, [snapshot: ^snapshot]}

    assert {:ok, %Issue{state: "In Progress"}} =
             Adapter.update_issue_state(
               issue,
               "In Progress",
               tracker_settings: tracker_settings,
               snapshot: snapshot
             )

    assert_receive {:github_project_update, ^issue, "In Progress", [tracker_settings: ^tracker_settings, snapshot: ^snapshot]}
  end

  test "prepares a discovered project snapshot for the loaded workflow" do
    Application.put_env(:symphony_elixir, :github_project_client_module, FakeClient)
    tracker_settings = tracker_settings()

    assert {:ok, prepared} = Tracker.prepare_config(tracker_settings)
    assert prepared.runtime_snapshot == %{project_id: 901, status: %{field_id: 7}}
    refute Map.has_key?(prepared.runtime_snapshot, :token)
  end

  test "running and blocked reconciliation retain their dispatch-time snapshot across reload" do
    Application.put_env(:symphony_elixir, :github_project_client_module, FakeClient)
    token_env = "SYMPHONY_PROJECT_TOKEN_#{System.unique_integer([:positive])}"
    previous_token = System.get_env(token_env)
    System.put_env(token_env, "test-token")
    on_exit(fn -> restore_env(token_env, previous_token) end)

    write_github_project_workflow!(Workflow.workflow_file_path(), "$#{token_env}")
    dispatch_settings = Config.settings!()

    running_issue = %Issue{
      id: "run-bound",
      identifier: "GH-201",
      state: "In Progress",
      labels: [],
      dispatchable: true
    }

    blocked_issue = %Issue{
      id: "blocked-bound",
      identifier: "GH-202",
      state: "In Progress",
      labels: [],
      dispatchable: true
    }

    settings_snapshot =
      put_in(dispatch_settings.tracker.provider["test_bound_issues"], %{
        running_issue.id => running_issue,
        blocked_issue.id => blocked_issue
      })

    tracker_settings = settings_snapshot.tracker
    {:ok, tracker_binding} = Tracker.bind_config(tracker_settings)

    agent_pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> if Process.alive?(agent_pid), do: Process.exit(agent_pid, :kill) end)

    running_entry = %{
      pid: agent_pid,
      ref: nil,
      identifier: running_issue.identifier,
      issue: running_issue,
      started_at: DateTime.utc_now(),
      settings_snapshot: settings_snapshot,
      tracker_binding: tracker_binding
    }

    blocked_entry = %{
      identifier: blocked_issue.identifier,
      issue: blocked_issue,
      error: "operator input required",
      settings_snapshot: settings_snapshot,
      tracker_binding: tracker_binding
    }

    state = %Orchestrator.State{
      running: %{running_issue.id => running_entry},
      blocked: %{blocked_issue.id => blocked_entry},
      claimed: MapSet.new([running_issue.id, blocked_issue.id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    write_workflow_file!(Workflow.workflow_file_path(), tracker_required_labels: ["new-policy"])
    assert Config.settings!().tracker.required_labels == ["new-policy"]

    state =
      Orchestrator.reconcile_bound_running_issue_for_test(
        state,
        running_issue.id,
        running_entry
      )

    state =
      Orchestrator.reconcile_bound_blocked_issue_for_test(
        state,
        blocked_issue.id,
        blocked_entry
      )

    assert Map.has_key?(state.running, running_issue.id)
    assert Map.has_key?(state.blocked, blocked_issue.id)
    assert Process.alive?(agent_pid)

    assert_receive {:github_project_bound_ids, ["run-bound"], ^tracker_settings, []}
    assert_receive {:github_project_bound_ids, ["blocked-bound"], ^tracker_settings, []}
  end

  test "adds comments only through the repository bound to the project item" do
    tracker_settings = tracker_settings()

    issue = %Issue{
      id: "41",
      identifier: "GH-141",
      native_ref: %{
        "issue_number" => 141,
        "repository" => "GHW-Consulting/app-tastemap"
      }
    }

    github_client = fn method, path, params, body, opts ->
      send(self(), {:comment_request, method, path, params, body, opts})
      {:ok, %{status: 201, body: %{"id" => 99}}}
    end

    assert {:ok, %{"id" => 99}} =
             Adapter.add_issue_comment(
               issue,
               "hello",
               tracker_settings: tracker_settings,
               github_client: github_client
             )

    assert_receive {:comment_request, "POST", "/repos/GHW-Consulting/app-tastemap/issues/141/comments", %{}, %{"body" => "hello"}, [tracker_settings: ^tracker_settings]}

    mismatched = put_in(issue.native_ref["repository"], "other/repo")

    assert {:error, :github_project_issue_snapshot_mismatch} =
             Adapter.add_issue_comment(
               mismatched,
               "hello",
               tracker_settings: tracker_settings,
               github_client: github_client
             )

    assert {:error, {:github_project_comment_failed, 403, %{"message" => "forbidden"}}} =
             Adapter.add_issue_comment(
               issue,
               "hello",
               tracker_settings: tracker_settings,
               github_client: fn _method, _path, _params, _body, _opts ->
                 {:ok, %{status: 403, body: %{"message" => "forbidden"}}}
               end
             )

    assert {:error, :invalid_github_project_issue_reference} =
             Adapter.add_issue_comment(
               %Issue{id: "41", identifier: "GH-141"},
               "hello",
               tracker_settings: tracker_settings,
               github_client: github_client
             )
  end

  test "advertises the existing github_api tool through project-scoped credentials" do
    assert [%{"name" => "github_api"}] = Adapter.agent_tool_specs()

    tracker_settings = tracker_settings()

    result =
      Adapter.execute_agent_tool(
        "github_api",
        %{
          "method" => "POST",
          "path" => "/repos/GHW-Consulting/app-tastemap/issues/141/comments",
          "body" => %{"body" => "hello"}
        },
        tracker_settings: tracker_settings,
        github_client: fn method, path, params, body, opts ->
          send(self(), {:github_api, method, path, params, body, opts})
          {:ok, %{status: 201, body: %{"id" => 99}}}
        end
      )

    assert result["success"]

    assert_receive {:github_api, "POST", "/repos/GHW-Consulting/app-tastemap/issues/141/comments", %{}, %{"body" => "hello"}, [tracker_settings: ^tracker_settings]}

    assert Adapter.secret_environment_names(put_provider(tracker_settings, "token", "$SYMPHONY_PROJECT_TOKEN")) == ["GITHUB_TOKEN", "SYMPHONY_PROJECT_TOKEN"]
  end

  test "registers github_project and preserves its workflow configuration" do
    Application.put_env(:symphony_elixir, :github_project_client_module, FakeClient)
    token_env = "SYMPHONY_PROJECT_TOKEN_#{System.unique_integer([:positive])}"
    previous_token = System.get_env(token_env)
    System.put_env(token_env, "test-token")

    on_exit(fn -> restore_env(token_env, previous_token) end)

    write_github_project_workflow!(Workflow.workflow_file_path(), "$#{token_env}")

    config = Config.settings!()
    assert config.tracker.kind == "github_project"
    assert config.tracker.provider["owner"] == "GHW-Consulting"
    assert config.tracker.provider["owner_type"] == "organization"
    assert config.tracker.provider["project_number"] == 12
    assert config.tracker.provider["repository"] == "GHW-Consulting/app-tastemap"
    assert config.tracker.provider["status_field"] == "Status"
    assert config.tracker.active_states == ["Ready", "In Progress"]
    assert config.tracker.terminal_states == ["Done", "Cancelled"]
    assert config.tracker.working_state == "In Progress"
    assert config.tracker.blocked_state == "Blocked"
    assert config.tracker.completion_state == "In Review"
    assert config.tracker.runtime_snapshot == %{project_id: 901, status: %{field_id: 7}}

    assert {:ok, Adapter} = Tracker.adapter_for_kind("github_project")
    assert Tracker.adapter() == Adapter
    assert :ok = Config.validate!()

    binding = Tracker.bind_agent_tools()
    assert binding.adapter == Adapter
    assert binding.secret_environment_names == ["GITHUB_TOKEN", token_env]
    assert [%{"name" => "github_api"}] = binding.tool_specs
  end

  defp tracker_settings do
    %{
      kind: "github_project",
      provider: %{
        "owner" => "GHW-Consulting",
        "owner_type" => "organization",
        "project_number" => 12,
        "repository" => "GHW-Consulting/app-tastemap",
        "status_field" => "Status",
        "api_url" => "https://api.github.test",
        "token" => "test-token"
      },
      active_states: ["Ready", "In Progress"],
      terminal_states: ["Done", "Cancelled"],
      working_state: "In Progress",
      blocked_state: "Blocked",
      completion_state: "In Review"
    }
  end

  defp put_provider(settings, key, value) do
    %{settings | provider: Map.put(settings.provider, key, value)}
  end

  defp write_github_project_workflow!(path, token) do
    File.write!(
      path,
      """
      ---
      tracker:
        kind: github_project
        provider:
          owner: GHW-Consulting
          owner_type: organization
          project_number: 12
          repository: GHW-Consulting/app-tastemap
          status_field: Status
          api_url: https://api.github.test
          token: #{Jason.encode!(token)}
        active_states: [Ready, In Progress]
        terminal_states: [Done, Cancelled]
        working_state: In Progress
        blocked_state: Blocked
        completion_state: In Review
      ---

      You are working on {{ issue.identifier }}.
      """
    )

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      assert :ok = SymphonyElixir.WorkflowStore.force_reload()
    end
  end
end
