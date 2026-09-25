defmodule SymphonyElixir.GitHubProject.ReleaseAuthorizationTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHubProject.ReleaseAuthorization
  alias SymphonyElixir.Tracker.Issue

  @ready "2026-09-25T15:30:46Z"
  @created "2026-09-25T15:31:00Z"
  @claimed "2026-09-25T15:31:01Z"

  test "uses the GitHub author and binds the receipt to the current Ready revision" do
    assert {:ok, issue} = fetch([comment()])
    assert issue.ready_actor_id == "thor-claw"
    refute issue.ready_actor_automated

    assert issue.release_authorization == %{
             "profile" => "afarnham",
             "backend" => "codex",
             "comment_id" => "IC_receipt"
           }

    bot = put_in(comment(), ["author", "__typename"], "Bot")
    assert {:ok, %{ready_actor_automated: true}} = fetch([bot])
  end

  test "a claimed run can recover its receipt after a coordinator restart" do
    issue = %{issue() | state: "In progress"}
    assert {:ok, recovered} = fetch([comment()], issue, @claimed)
    assert recovered.release_authorization["profile"] == "afarnham"
    assert {:error, :github_project_ready_transition_not_found} = fetch([comment()], issue, @ready)
  end

  test "rejects stale, malformed, edited, minimized, untrusted, and incorrectly scoped records" do
    invalid_comments = [
      comment(%{"project_item_id" => "PVTI_other"}),
      comment(%{"version" => 2}),
      comment(%{"ready_updated_at" => "2026-09-25T15:30:45Z"}),
      comment(%{"ready_updated_at" => "not-a-time"}),
      comment(%{"ready_updated_at" => nil}),
      comment(%{"profile" => "karbas"}),
      comment(%{"profile" => "AFarnham"}),
      comment(%{"backend" => "unknown"}),
      Map.put(comment(), "lastEditedAt", @created),
      Map.put(comment(), "isMinimized", true),
      Map.put(comment(), "createdAt", "not-a-time"),
      Map.put(comment(), "createdAt", "2026-09-25T15:30:45Z"),
      put_in(comment(), ["author", "login"], "unknown"),
      put_in(comment(), ["author", "__typename"], "Organization"),
      Map.put(comment(), "body", "Symphony release authorization\n\n```json\n{}"),
      Map.put(comment(), "body", "Symphony release authorization\n\n```json\nbad-json\n```"),
      %{},
      nil
    ]

    for invalid <- invalid_comments do
      assert {:error, :github_project_ready_transition_not_found} = fetch([invalid])
    end

    assert {:error, :github_project_ready_transition_not_found} = fetch([comment()], %{issue() | state: "Blocked"})
    assert {:error, :github_project_ready_transition_not_found} = fetch([comment()], %{issue() | state: nil})
    assert {:error, :github_project_ready_transition_not_found} = fetch([comment()], issue(), "bad-time")
  end

  test "skips untrusted comments and selects the latest valid receipt" do
    old = comment(%{"backend" => "claude"})
    forged = put_in(comment(), ["author", "login"], "unknown")
    assert {:ok, recovered} = fetch([old, comment(), forged])
    assert recovered.release_authorization["backend"] == "codex"
  end

  test "pages backwards and bounds missing-history work" do
    request = fn %{"variables" => variables} ->
      assert variables["issueId"] == "I_issue"
      assert variables["itemId"] == "PVTI_item"
      assert variables["statusField"] == "Status"

      case variables["before"] do
        nil -> {:ok, payload([], issue(), @ready, %{"hasPreviousPage" => true, "startCursor" => "older"})}
        "older" -> {:ok, payload([comment()])}
      end
    end

    assert {:ok, _issue} = ReleaseAuthorization.fetch(issue(), snapshot(), request)

    endless = fn _body ->
      {:ok, payload([], issue(), @ready, %{"hasPreviousPage" => true, "startCursor" => "older"})}
    end

    assert {:error, :github_project_release_authorization_history_limit} =
             ReleaseAuthorization.fetch(issue(), snapshot(), endless)

    malformed = fn _body -> {:ok, payload([], issue(), @ready, %{})} end

    assert {:error, :github_project_release_authorization_payload_malformed} =
             ReleaseAuthorization.fetch(issue(), snapshot(), malformed)
  end

  test "fails closed on transport failures, partial GraphQL results, and mismatched snapshots" do
    assert {:error, :unavailable} = ReleaseAuthorization.fetch(issue(), snapshot(), fn _body -> {:error, :unavailable} end)

    assert {:error, :github_project_release_authorization_payload_malformed} =
             ReleaseAuthorization.fetch(issue(), snapshot(), fn _body -> {:ok, %{}} end)

    mismatches = [
      put_in(payload([comment()]), ["data", "item", "id"], "PVTI_wrong"),
      put_in(payload([comment()]), ["data", "item", "project", "id"], "PVT_wrong"),
      put_in(payload([comment()]), ["data", "item", "content", "id"], "I_wrong"),
      put_in(payload([comment()]), ["data", "item", "fieldValueByName", "name"], "Blocked"),
      Map.put(payload([comment()]), "errors", [%{"message" => "partial failure"}])
    ]

    for response <- mismatches do
      assert {:error, :github_project_release_authorization_snapshot_mismatch} =
               ReleaseAuthorization.fetch(issue(), snapshot(), fn _body -> {:ok, response} end)
    end

    assert {:error, :github_project_ready_transition_not_found} =
             ReleaseAuthorization.fetch(%{issue() | native_ref: %{}}, snapshot(), fn _body -> flunk("unexpected read") end)
  end

  defp fetch(comments, issue \\ issue(), revision \\ @ready) do
    ReleaseAuthorization.fetch(issue, snapshot(), fn _body -> {:ok, payload(comments, issue, revision)} end)
  end

  defp issue do
    %Issue{
      state: "Ready",
      assignee_ids: ["afarnham"],
      native_ref: %{"issue_node_id" => "I_issue", "project_item_node_id" => "PVTI_item"}
    }
  end

  defp snapshot do
    %{
      project_node_id: "PVT_project",
      status: %{field_name: "Status"},
      routing_ready_state: "Ready",
      working_state: "In Progress",
      routing_authorized_actors: ["afarnham", "thor-claw"]
    }
  end

  defp comment(overrides \\ %{}) do
    receipt =
      Map.merge(
        %{
          "version" => 1,
          "project_item_id" => "PVTI_item",
          "ready_updated_at" => @ready,
          "profile" => "afarnham",
          "backend" => "codex"
        },
        overrides
      )

    %{
      "id" => "IC_receipt",
      "body" => "Symphony release authorization\n\n```json\n" <> Jason.encode!(receipt) <> "\n```",
      "author" => %{"login" => "thor-claw", "__typename" => "User"},
      "createdAt" => @created,
      "lastEditedAt" => nil,
      "isMinimized" => false
    }
  end

  defp payload(comments, issue \\ issue(), revision \\ @ready, page_info \\ %{"hasPreviousPage" => false}) do
    %{
      "data" => %{
        "issue" => %{"comments" => %{"nodes" => comments, "pageInfo" => page_info}},
        "item" => %{
          "id" => "PVTI_item",
          "project" => %{"id" => "PVT_project"},
          "content" => %{"id" => "I_issue"},
          "fieldValueByName" => %{"name" => issue.state || "", "updatedAt" => revision}
        }
      }
    }
  end
end
