defmodule SymphonyElixir.AgentRoutingConfigTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{AgentBackend, Config}
  alias SymphonyElixir.Config.Schema

  test "normalizes GitHub profile logins, backends, and worker hosts" do
    assert {:ok, settings} = Schema.parse(routed_config())

    assert settings.agent.routing.ready_state == "Ready"
    assert settings.agent.routing.executor_field == "Executor"

    assert settings.agent.routing.profiles == %{
             "afarnham" => %{
               "default_backend" => "codex",
               "worker_hosts" => ["worker@aaron"]
             },
             "karbas" => %{
               "default_backend" => "claude",
               "worker_hosts" => ["worker@karbas"]
             }
           }

    assert Enum.sort(AgentBackend.configured_backend_names(settings)) == ["claude", "codex"]
    assert :ok = Config.validate_settings(settings)
  end

  test "rejects shared hosts, invalid defaults, and invalid Ready state semantics" do
    shared_hosts =
      routed_config()
      |> put_in([:agent, :routing, :profiles, :karbas, :worker_hosts], ["worker@aaron"])

    assert {:error, {:invalid_workflow_config, shared_message}} = Schema.parse(shared_hosts)
    assert shared_message =~ "worker hosts may belong to only one profile"

    invalid_backend =
      routed_config()
      |> put_in([:agent, :routing, :profiles, :karbas, :default_backend], "other")

    assert {:error, {:invalid_workflow_config, backend_message}} = Schema.parse(invalid_backend)
    assert backend_message =~ "default_backend must be codex or claude"

    assert {:ok, invalid_ready_settings} =
             routed_config()
             |> put_in([:agent, :routing, :ready_state], "In Progress")
             |> Schema.parse()

    assert {:error, :agent_routing_ready_state_is_working_state} =
             Config.validate_settings(invalid_ready_settings)
  end

  test "rejects profile logins that collide after normalization" do
    profiles = %{
      "AFarnham" => %{default_backend: "codex", worker_hosts: ["worker@one"]},
      "afarnham" => %{default_backend: "claude", worker_hosts: ["worker@two"]}
    }

    assert {:error, {:invalid_workflow_config, message}} =
             routed_config()
             |> put_in([:agent, :routing, :profiles], profiles)
             |> Schema.parse()

    assert message =~ "profile logins must be unique after normalization"
  end

  test "reports malformed profiles without crashing normalization" do
    malformed_profiles = [
      %{},
      %{"afarnham" => "not-a-map"},
      %{"afarnham" => %{default_backend: "codex", worker_hosts: nil}},
      %{"afarnham" => %{default_backend: "codex", worker_hosts: [123]}}
    ]

    Enum.each(malformed_profiles, fn profiles ->
      assert {:error, {:invalid_workflow_config, _message}} =
               routed_config()
               |> put_in([:agent, :routing, :profiles], profiles)
               |> Schema.parse()
    end)
  end

  test "validates every backend available through Executor overrides" do
    assert AgentBackend.configured_backend_names(%{agent: %{backend: "codex"}}) == ["codex"]

    assert {:ok, settings} = Schema.parse(routed_config())
    invalid_claude = put_in(settings.claude.command, "")

    assert {:error, :invalid_claude_command} = AgentBackend.validate_config(invalid_claude)
  end

  test "rejects routing for another tracker kind" do
    assert {:ok, settings} =
             routed_config()
             |> put_in([:tracker, :kind], "memory")
             |> Schema.parse()

    assert {:error, :agent_routing_requires_github_project} = Config.validate_settings(settings)
  end

  defp routed_config do
    %{
      tracker: %{
        kind: "github_project",
        provider: %{
          owner: "GHW-Consulting",
          owner_type: "organization",
          project_number: 2,
          repository: "GHW-Consulting/app-tastemap",
          status_field: "Status",
          token: "token"
        },
        active_states: ["Ready", "In Progress"],
        terminal_states: ["Done", "Cancelled"],
        working_state: "In Progress",
        blocked_state: "Blocked",
        completion_state: "In Review"
      },
      agent: %{
        backend: "codex",
        routing: %{
          ready_state: " Ready ",
          executor_field: " Executor ",
          profiles: %{
            "AFarnham" => %{
              default_backend: "codex",
              worker_hosts: [" worker@aaron "]
            },
            karbas: %{
              default_backend: "claude",
              worker_hosts: ["worker@karbas"]
            }
          }
        }
      }
    }
  end
end
