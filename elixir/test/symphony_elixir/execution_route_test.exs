defmodule SymphonyElixir.ExecutionRouteTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ExecutionRoute
  alias SymphonyElixir.Tracker.Issue

  test "legacy workflows retain the global backend and worker hosts" do
    settings = %{agent: %{backend: "codex", routing: nil}, worker: %{ssh_hosts: ["worker-a"]}}

    assert {:ok,
            %ExecutionRoute{
              profile: nil,
              backend: "codex",
              worker_hosts: ["worker-a"]
            }} = ExecutionRoute.resolve(%Issue{}, settings)

    assert ExecutionRoute.enabled?(settings) == false
    assert ExecutionRoute.enabled?(%{}) == false
  end

  test "the assigned Ready actor selects a profile and its default backend" do
    issue = %Issue{
      assignee_ids: ["reviewer", "AFarnham"],
      ready_actor_id: "afarnham",
      ready_actor_automated: false
    }

    assert {:ok,
            %ExecutionRoute{
              profile: "afarnham",
              ready_actor: "afarnham",
              backend: "codex",
              worker_hosts: ["worker@aaron"]
            }} = ExecutionRoute.resolve(issue, routed_settings())
  end

  test "an explicit executor overrides the profile default" do
    issue = %Issue{
      assignee_ids: ["afarnham"],
      ready_actor_id: "AFARNHAM",
      ready_actor_automated: false,
      requested_backend: "claude"
    }

    assert {:ok, %ExecutionRoute{backend: "claude"}} =
             ExecutionRoute.resolve(issue, routed_settings())

    assert ExecutionRoute.enabled?(routed_settings())

    assert {:ok, %ExecutionRoute{backend: "codex"}} =
             ExecutionRoute.resolve(%{issue | requested_backend: ""}, routed_settings())
  end

  test "routing fails closed for missing, automated, unknown, and unassigned actors" do
    base = %Issue{assignee_ids: ["afarnham"], ready_actor_automated: false}

    assert {:error, :ready_actor_missing} = ExecutionRoute.resolve(base, routed_settings())

    assert {:error, :ready_transition_automated} =
             ExecutionRoute.resolve(
               %{base | ready_actor_id: "afarnham", ready_actor_automated: true},
               routed_settings()
             )

    assert {:error, :ready_transition_automation_unknown} =
             ExecutionRoute.resolve(
               %{base | ready_actor_id: "afarnham", ready_actor_automated: nil},
               routed_settings()
             )

    assert {:error, {:ready_actor_profile_not_found, "unknown"}} =
             ExecutionRoute.resolve(
               %{base | ready_actor_id: "unknown", assignee_ids: ["unknown"]},
               routed_settings()
             )

    assert {:error, {:ready_actor_not_assigned, "karbas"}} =
             ExecutionRoute.resolve(%{base | ready_actor_id: "karbas"}, routed_settings())

    assert {:error, {:unsupported_requested_backend, "other"}} =
             ExecutionRoute.resolve(
               %{base | ready_actor_id: "afarnham", requested_backend: "other"},
               routed_settings()
             )

    assert {:error, :invalid_agent_routing_settings} =
             ExecutionRoute.resolve(base, %{agent: %{routing: %{profiles: nil}}})
  end

  defp routed_settings do
    %{
      agent: %{
        routing: %{
          profiles: %{
            "afarnham" => %{
              "default_backend" => "codex",
              "worker_hosts" => ["worker@aaron"]
            },
            "karbas" => %{
              "default_backend" => "claude",
              "worker_hosts" => ["worker@karbas"]
            }
          }
        }
      }
    }
  end
end
