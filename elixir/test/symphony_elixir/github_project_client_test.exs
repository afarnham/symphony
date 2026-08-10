defmodule SymphonyElixir.GitHubProject.ClientTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.GitHubProject.{Client, Normalizer}
  alias SymphonyElixir.Tracker.Issue

  describe "status field discovery" do
    test "resolves the named single-select field and configured states case-insensitively" do
      fields = [
        %{"id" => 4, "name" => "Priority", "data_type" => "single_select", "options" => []},
        status_field()
      ]

      assert {:ok, status} =
               Normalizer.resolve_status_field(fields, " status ", [
                 "ready",
                 "IN PROGRESS",
                 "Done"
               ])

      assert status.field_id == 7
      assert status.field_name == "Status"

      assert status.option_ids == %{
               "backlog" => "option-backlog",
               "blocked" => "option-blocked",
               "cancelled" => "option-cancelled",
               "done" => "option-done",
               "in progress" => "option-progress",
               "ready" => "option-ready"
             }

      assert status.option_names == %{
               "option-backlog" => "Backlog",
               "option-blocked" => "Blocked",
               "option-cancelled" => "Cancelled",
               "option-done" => "Done",
               "option-progress" => "In Progress",
               "option-ready" => "Ready"
             }
    end

    test "rejects missing, ambiguous, non-single-select, and ambiguous option definitions" do
      assert {:error, {:github_project_status_field_not_found, "Missing"}} =
               Normalizer.resolve_status_field([status_field()], "Missing", ["Ready"])

      assert {:error, {:github_project_status_field_ambiguous, "Status"}} =
               Normalizer.resolve_status_field([status_field(), status_field(8)], "Status", ["Ready"])

      assert {:error, {:github_project_status_field_not_single_select, "Status"}} =
               Normalizer.resolve_status_field(
                 [%{"id" => 7, "name" => "Status", "data_type" => "text"}],
                 "Status",
                 ["Ready"]
               )

      field =
        update_in(status_field()["options"], fn options ->
          [%{"id" => "another-ready", "name" => %{"raw" => " READY "}} | options]
        end)

      assert {:error, {:github_project_state_ambiguous, "ready"}} =
               Normalizer.resolve_status_field([field], "Status", ["Ready"])

      assert {:error, {:github_project_state_not_found, "Review"}} =
               Normalizer.resolve_status_field([status_field()], "Status", ["Review"])
    end
  end

  describe "project item normalization" do
    test "uses project-item identity and project Status while retaining issue metadata" do
      assert {:ok, %Issue{} = issue} =
               Normalizer.normalize_item(raw_item(41, "Ready"), normalization_context())

      assert issue.id == "41"
      assert issue.identifier == "GH-141"
      assert issue.title == "Issue 141"
      assert issue.description == "Body 141"
      assert issue.state == "Ready"
      assert issue.url == "https://github.test/GHW-Consulting/app-tastemap/issues/141"
      assert issue.assignee_id == "octocat"
      assert issue.labels == ["bug", "platform"]
      assert issue.dispatchable
      assert %DateTime{} = issue.created_at
      assert %DateTime{} = issue.updated_at

      assert issue.native_ref == %{
               "issue_id" => 10_141,
               "issue_node_id" => "I_141",
               "issue_number" => 141,
               "project_id" => 901,
               "project_item_id" => 41,
               "project_number" => 12,
               "repository" => "GHW-Consulting/app-tastemap",
               "status_field_id" => 7,
               "status_option_id" => "option-ready"
             }
    end

    test "keeps unset and archived items visible but non-dispatchable" do
      unset =
        raw_item(42, nil)
        |> Map.update!("fields", fn fields ->
          Enum.map(fields, fn
            %{"id" => 7} = field -> Map.put(field, "value", nil)
            field -> field
          end)
        end)

      assert {:ok, %Issue{state: nil, dispatchable: false}} =
               Normalizer.normalize_item(unset, normalization_context())

      archived = Map.put(raw_item(43, "Done"), "archived_at", "2026-08-01T00:00:00Z")

      assert {:ok, %Issue{state: "Done", dispatchable: false}} =
               Normalizer.normalize_item(archived, normalization_context())
    end

    test "skips draft items, pull requests, and issues from another repository" do
      assert {:skip, :unsupported_content_type} =
               Normalizer.normalize_item(
                 %{raw_item(44, "Ready") | "content_type" => "DraftIssue"},
                 normalization_context()
               )

      assert {:skip, :unsupported_content_type} =
               Normalizer.normalize_item(
                 %{raw_item(45, "Ready") | "content_type" => "PullRequest"},
                 normalization_context()
               )

      other_repo =
        raw_item(46, "Ready")
        |> put_in(["content", "repository_url"], "https://api.github.test/repos/other/repo")
        |> put_in(["content", "url"], "https://api.github.test/repos/other/repo/issues/146")

      assert {:skip, :repository_mismatch} =
               Normalizer.normalize_item(other_repo, normalization_context())
    end

    test "rejects malformed issue items instead of manufacturing stale state" do
      assert {:error, :github_project_item_missing_status_field} =
               Normalizer.normalize_item(
                 %{raw_item(47, "Ready") | "fields" => []},
                 normalization_context()
               )

      assert {:error, :github_project_item_malformed} =
               Normalizer.normalize_item(
                 put_in(raw_item(48, "Ready"), ["content", "title"], ""),
                 normalization_context()
               )
    end
  end

  describe "client discovery and polling" do
    test "validates provider settings and secret environment references" do
      assert :ok = Client.validate_settings(tracker_settings())

      assert {:error, :missing_github_project_owner} =
               Client.validate_settings(tracker_settings(%{"owner" => ""}))

      assert {:error, :invalid_github_project_owner_type} =
               Client.validate_settings(tracker_settings(%{"owner_type" => "team"}))

      assert {:error, :invalid_github_project_number} =
               Client.validate_settings(tracker_settings(%{"project_number" => 0}))

      assert {:error, :invalid_github_project_repository} =
               Client.validate_settings(tracker_settings(%{"repository" => "repo"}))

      assert {:error, :missing_github_project_token} =
               Client.validate_settings(tracker_settings(%{"token" => 123}))

      assert Client.secret_environment_names(tracker_settings(%{"token" => "$SYMPHONY_PROJECT_TOKEN"})) == ["GITHUB_TOKEN", "SYMPHONY_PROJECT_TOKEN"]
    end

    test "loads an owner-specific snapshot and follows field pagination" do
      test_pid = self()

      request_fun = fn method, path, params, body, settings ->
        send(test_pid, {:request, method, path, params, body, settings})

        case {method, path, params} do
          {"GET", "/orgs/GHW-Consulting/projectsV2/12", %{}} ->
            ok_response(%{"id" => 901, "number" => 12})

          {"GET", "/repos/GHW-Consulting/app-tastemap", %{}} ->
            ok_response(%{"id" => 88, "full_name" => "GHW-Consulting/app-tastemap"})

          {"GET", "/orgs/GHW-Consulting/projectsV2/12/fields", %{"per_page" => 100}} ->
            ok_response(
              [%{"id" => 4, "name" => "Priority", "data_type" => "single_select"}],
              %{
                "link" => [
                  ~s(<https://api.github.test/orgs/GHW-Consulting/projectsV2/12/fields?after=cursor-2&per_page=100>; rel="next")
                ]
              }
            )

          {"GET", "/orgs/GHW-Consulting/projectsV2/12/fields", %{"after" => "cursor-2", "per_page" => "100"}} ->
            ok_response([status_field()])

          {"GET", "/orgs/GHW-Consulting/projectsV2/12/items", %{"fields" => "7", "per_page" => 1}} ->
            ok_response([raw_item(49, "Ready")])

          {"GET", "/orgs/GHW-Consulting/projectsV2/12/items/49", %{"fields" => "7"}} ->
            ok_response(%{"value" => raw_item(49, "Ready")})
        end
      end

      assert {:ok, snapshot} =
               Client.load_snapshot(tracker_settings(), request_fun: request_fun)

      assert snapshot.project_id == 901
      assert snapshot.project_number == 12
      assert snapshot.status.field_id == 7
      assert snapshot.status.option_ids["ready"] == "option-ready"
      assert snapshot.active_states == MapSet.new(["ready", "in progress"])
      assert snapshot.terminal_states == MapSet.new(["done", "cancelled"])
      assert snapshot.working_state == "In Progress"

      assert_received {:request, "GET", "/orgs/GHW-Consulting/projectsV2/12", %{}, nil, %{owner_type: :organization}}
    end

    test "uses the user route family for user-owned projects" do
      settings =
        tracker_settings(%{
          "owner" => "octocat",
          "owner_type" => "user",
          "repository" => "octocat/repo"
        })

      request_fun = fn "GET", path, _params, nil, _settings ->
        case path do
          "/users/octocat/projectsV2/12" ->
            ok_response(%{"id" => 902, "number" => 12})

          "/repos/octocat/repo" ->
            ok_response(%{"id" => 89, "full_name" => "octocat/repo"})

          "/users/octocat/projectsV2/12/fields" ->
            ok_response([status_field()])

          "/users/octocat/projectsV2/12/items" ->
            ok_response([])
        end
      end

      assert {:ok, %{owner_type: :user, project_id: 902}} =
               Client.load_snapshot(settings, request_fun: request_fun)
    end

    test "reuses the discovered snapshot stored with the loaded workflow" do
      tracker_settings = Map.put(tracker_settings(), :runtime_snapshot, snapshot())

      request_fun = fn "GET", "/orgs/GHW-Consulting/projectsV2/12/items", _params, nil, _settings ->
        ok_response([raw_item(50, "Ready")])
      end

      assert {:ok, [%Issue{id: "50", state: "Ready"}]} =
               Client.fetch_issues_by_states(
                 ["Ready"],
                 tracker_settings,
                 request_fun: request_fun
               )
    end

    test "polls all item pages and returns only configured repository issues in requested states" do
      snapshot = snapshot()
      test_pid = self()

      request_fun = fn "GET", "/orgs/GHW-Consulting/projectsV2/12/items", params, nil, _settings ->
        send(test_pid, {:item_page, params})

        case params do
          %{"fields" => "7", "per_page" => 100} ->
            ok_response(
              [
                raw_item(51, "Ready"),
                raw_item(52, "Backlog"),
                %{raw_item(53, "Ready") | "content_type" => "PullRequest"}
              ],
              %{
                "link" => [
                  ~s(<https://api.github.test/orgs/GHW-Consulting/projectsV2/12/items?after=cursor-2&fields=7&per_page=100>; rel="next")
                ]
              }
            )

          %{"after" => "cursor-2", "fields" => "7", "per_page" => "100"} ->
            ok_response([
              raw_item(54, "In Progress"),
              Map.put(raw_item(55, "Ready"), "archived_at", "2026-08-01T00:00:00Z")
            ])
        end
      end

      assert {:ok, issues} =
               Client.fetch_issues_by_states(
                 [" ready ", "IN PROGRESS"],
                 tracker_settings(),
                 snapshot: snapshot,
                 request_fun: request_fun
               )

      assert Enum.map(issues, & &1.id) == ["51", "54"]
      assert_received {:item_page, %{"fields" => "7", "per_page" => 100}}

      assert_received {:item_page,
                       %{
                         "after" => "cursor-2",
                         "fields" => "7",
                         "per_page" => "100"
                       }}
    end

    test "refreshes project item IDs in order, omits 404s, and preserves archived terminal items" do
      request_fun = fn "GET", path, %{"fields" => "7"}, nil, _settings ->
        case path do
          "/orgs/GHW-Consulting/projectsV2/12/items/62" ->
            ok_response(%{
              "value" => Map.put(raw_item(62, "Done"), "archived_at", "2026-08-01T00:00:00Z")
            })

          "/orgs/GHW-Consulting/projectsV2/12/items/61" ->
            ok_response(raw_item(61, "In Progress"))

          "/orgs/GHW-Consulting/projectsV2/12/items/404" ->
            {:ok, %{status: 404, body: %{"message" => "Not Found"}, headers: %{}}}
        end
      end

      assert {:ok, issues} =
               Client.fetch_issues_by_ids(
                 ["62", "61", "404", "62"],
                 tracker_settings(),
                 snapshot: snapshot(),
                 request_fun: request_fun
               )

      assert Enum.map(issues, & &1.id) == ["62", "61"]
      refute hd(issues).dispatchable

      assert {:error, :invalid_github_project_item_id} =
               Client.fetch_issues_by_ids(
                 ["not-an-id"],
                 tracker_settings(),
                 snapshot: snapshot(),
                 request_fun: request_fun
               )
    end

    test "enriches incomplete item content from the repository issue endpoint" do
      incomplete =
        raw_item(71, "Ready")
        |> put_in(["content", "title"], nil)
        |> put_in(["content", "labels"], nil)

      request_fun = fn
        "GET", "/orgs/GHW-Consulting/projectsV2/12/items", _params, nil, _settings ->
          ok_response([incomplete])

        "GET", "/repos/GHW-Consulting/app-tastemap/issues/171", %{}, nil, _settings ->
          ok_response(raw_issue(171))
      end

      assert {:ok, [%Issue{} = issue]} =
               Client.fetch_issues_by_states(
                 ["Ready"],
                 tracker_settings(),
                 snapshot: snapshot(),
                 request_fun: request_fun
               )

      assert issue.title == "Issue 171"
      assert issue.labels == ["bug", "platform"]
    end
  end

  describe "confirmed state transitions and API errors" do
    test "re-fetches, patches the configured status option, and confirms the result" do
      issue = elem(Normalizer.normalize_item(raw_item(81, "Ready"), normalization_context()), 1)
      test_pid = self()
      current_calls = :counters.new(1, [])

      request_fun = fn method, path, params, body, _settings ->
        send(test_pid, {:transition_request, method, path, params, body})

        case {method, path} do
          {"GET", "/orgs/GHW-Consulting/projectsV2/12/items/81"} ->
            call = :counters.get(current_calls, 1)
            :counters.add(current_calls, 1, 1)
            ok_response(raw_item(81, if(call == 0, do: "Ready", else: "In Progress")))

          {"PATCH", "/orgs/GHW-Consulting/projectsV2/12/items/81"} ->
            ok_response(raw_item(81, "In Progress"))
        end
      end

      assert {:ok, %Issue{state: "In Progress"}} =
               Client.update_issue_state(
                 issue,
                 " in progress ",
                 tracker_settings(),
                 snapshot: snapshot(),
                 request_fun: request_fun
               )

      assert_received {:transition_request, "PATCH", "/orgs/GHW-Consulting/projectsV2/12/items/81", %{}, %{"fields" => [%{"id" => 7, "value" => "option-progress"}]}}
    end

    test "does not patch an already-confirmed target state" do
      issue = elem(Normalizer.normalize_item(raw_item(82, "Ready"), normalization_context()), 1)

      request_fun = fn
        "GET", "/orgs/GHW-Consulting/projectsV2/12/items/82", %{"fields" => "7"}, nil, _settings ->
          ok_response(raw_item(82, "Done"))

        "PATCH", _path, _params, _body, _settings ->
          flunk("an idempotent transition must not PATCH")
      end

      assert {:ok, %Issue{state: "Done"}} =
               Client.update_issue_state(
                 issue,
                 "Done",
                 tracker_settings: tracker_settings(),
                 snapshot: snapshot(),
                 request_fun: request_fun
               )
    end

    test "returns a confirmation error when the refetched status did not change" do
      issue = elem(Normalizer.normalize_item(raw_item(83, "Ready"), normalization_context()), 1)

      request_fun = fn
        "GET", "/orgs/GHW-Consulting/projectsV2/12/items/83", %{"fields" => "7"}, nil, _settings ->
          ok_response(raw_item(83, "Ready"))

        "PATCH", "/orgs/GHW-Consulting/projectsV2/12/items/83", %{}, _body, _settings ->
          ok_response(raw_item(83, "In Progress"))
      end

      assert {:error, {:github_project_state_not_confirmed, "In Progress", "Ready"}} =
               Client.update_issue_state(
                 issue,
                 "In Progress",
                 tracker_settings(),
                 snapshot: snapshot(),
                 request_fun: request_fun
               )
    end

    test "does not claim an item that became inactive or non-dispatchable before the patch" do
      issue = elem(Normalizer.normalize_item(raw_item(84, "Ready"), normalization_context()), 1)

      for current <- [raw_item(84, "Backlog"), Map.put(raw_item(84, "Ready"), "archived_at", "2026-08-01T00:00:00Z")] do
        request_fun = fn
          "GET", "/orgs/GHW-Consulting/projectsV2/12/items/84", %{"fields" => "7"}, nil, _settings ->
            ok_response(current)

          "PATCH", _path, _params, _body, _settings ->
            flunk("an inactive or non-dispatchable claim source must not be patched")
        end

        assert {:error, reason} =
                 Client.update_issue_state(
                   issue,
                   "In Progress",
                   tracker_settings(),
                   snapshot: snapshot(),
                   request_fun: request_fun,
                   expected_active_states: ["Ready", "In Progress"],
                   require_dispatchable: true
                 )

        assert reason in [
                 {:github_project_claim_source_not_active, "Backlog"},
                 :github_project_claim_source_not_dispatchable
               ]
      end
    end

    test "classifies authentication, authorization, rate-limit, validation, and transport failures" do
      cases = [
        {401, %{}, :authentication},
        {403, %{}, :authorization},
        {403, %{"x-ratelimit-remaining" => ["0"], "x-ratelimit-reset" => ["123"]}, :rate_limit},
        {429, %{"retry-after" => ["60"]}, :rate_limit},
        {404, %{}, :not_found},
        {422, %{}, :validation}
      ]

      for {status, headers, kind} <- cases do
        assert {:error, {:github_project_api_error, %{kind: ^kind, status: ^status, rate_limit: rate_limit}}} =
                 Client.request(
                   "GET",
                   "/example",
                   %{},
                   nil,
                   tracker_settings: tracker_settings(),
                   request_fun: fn _method, _path, _params, _body, _settings ->
                     {:ok, %{status: status, body: %{"message" => "failed"}, headers: headers}}
                   end
                 )

        if status == 403 and kind == :rate_limit do
          assert rate_limit == %{remaining: 0, reset: 123, retry_after: nil}
        end
      end

      assert {:error, {:github_project_api_error, %{kind: :transport, reason: :timeout, status: nil}}} =
               Client.request(
                 "GET",
                 "/example",
                 %{},
                 nil,
                 tracker_settings: tracker_settings(),
                 request_fun: fn _method, _path, _params, _body, _settings ->
                   {:error, :timeout}
                 end
               )
    end

    test "bounds and redacts HTTP error bodies" do
      secret = "github-secret-value"

      assert {:error, {:github_project_api_error, %{body: body}}} =
               Client.request(
                 "GET",
                 "/example",
                 %{},
                 nil,
                 tracker_settings: tracker_settings(%{"token" => secret}),
                 request_fun: fn _method, _path, _params, _body, _settings ->
                   {:ok,
                    %{
                      status: 403,
                      body: %{
                        "token" => secret,
                        "message" => "Bearer #{secret} " <> String.duplicate("x", 8_000)
                      },
                      headers: %{}
                    }}
                 end
               )

      assert is_binary(body)
      assert String.length(body) <= 4_096
      refute body =~ secret
      assert body =~ "[REDACTED]"
    end
  end

  test "does not fall back to GITHUB_TOKEN when an explicit token environment variable is absent" do
    env_name = "SYMPHONY_MISSING_PROJECT_TOKEN_#{System.unique_integer([:positive])}"
    previous_github_token = System.get_env("GITHUB_TOKEN")
    System.delete_env(env_name)
    System.put_env("GITHUB_TOKEN", "fallback-must-not-be-used")

    on_exit(fn ->
      if is_nil(previous_github_token),
        do: System.delete_env("GITHUB_TOKEN"),
        else: System.put_env("GITHUB_TOKEN", previous_github_token)
    end)

    assert {:error, :missing_github_project_token} =
             Client.validate_settings(tracker_settings(%{"token" => "$#{env_name}"}))
  end

  test "accepts pagination links beneath an API path prefix" do
    settings = tracker_settings(%{"api_url" => "https://ghe.test/api/v3"})
    test_pid = self()

    request_fun = fn "GET", "/orgs/GHW-Consulting/projectsV2/12/items", params, nil, _settings ->
      send(test_pid, {:enterprise_page, params})

      case params do
        %{"fields" => "7", "per_page" => 100} ->
          ok_response(
            [raw_item(91, "Ready")],
            %{
              "link" => [
                ~s(<https://ghe.test/api/v3/orgs/GHW-Consulting/projectsV2/12/items?after=next&fields=7&per_page=100>; rel="next")
              ]
            }
          )

        %{"after" => "next", "fields" => "7", "per_page" => "100"} ->
          ok_response([raw_item(92, "Ready")])
      end
    end

    assert {:ok, issues} =
             Client.fetch_issues_by_states(
               ["Ready"],
               settings,
               snapshot: %{snapshot() | api_url: "https://ghe.test/api/v3"},
               request_fun: request_fun
             )

    assert Enum.map(issues, & &1.id) == ["91", "92"]
    assert_received {:enterprise_page, %{"after" => "next"}}
  end

  test "accepts GitHub canonical numeric owner paths in pagination links" do
    settings = tracker_settings(%{"api_url" => "https://api.github.com"})
    test_pid = self()

    request_fun = fn "GET", "/orgs/GHW-Consulting/projectsV2/12/items", params, nil, _settings ->
      send(test_pid, {:canonical_owner_page, params})

      case params do
        %{"fields" => "7", "per_page" => 100} ->
          ok_response(
            [raw_item(93, "Ready")],
            %{
              "link" => [
                ~s(<https://api.github.com/organizations/311632961/projectsV2/12/items?after=next&fields=7&per_page=100>; rel="next")
              ]
            }
          )

        %{"after" => "next", "fields" => "7", "per_page" => "100"} ->
          ok_response([raw_item(94, "Ready")])
      end
    end

    assert {:ok, issues} =
             Client.fetch_issues_by_states(
               ["Ready"],
               settings,
               snapshot: %{snapshot() | api_url: "https://api.github.com"},
               request_fun: request_fun
             )

    assert Enum.map(issues, & &1.id) == ["93", "94"]
    assert_received {:canonical_owner_page, %{"after" => "next"}}
  end

  test "rejects canonical owner pagination links for another project" do
    settings = tracker_settings(%{"api_url" => "https://api.github.com"})

    request_fun = fn "GET", "/orgs/GHW-Consulting/projectsV2/12/items", params, nil, _settings ->
      case params do
        %{"fields" => "7", "per_page" => 100} ->
          ok_response(
            [raw_item(95, "Ready")],
            %{
              "link" => [
                ~s(<https://api.github.com/organizations/311632961/projectsV2/99/items?after=next&fields=7&per_page=100>; rel="next")
              ]
            }
          )

        %{"after" => "next"} ->
          flunk("followed a pagination link for another project")
      end
    end

    assert {:error, :github_project_invalid_pagination_link} =
             Client.fetch_issues_by_states(
               ["Ready"],
               settings,
               snapshot: %{snapshot() | api_url: "https://api.github.com"},
               request_fun: request_fun
             )
  end

  defp tracker_settings(provider_overrides \\ %{}) do
    %{
      provider:
        Map.merge(
          %{
            "owner" => "GHW-Consulting",
            "owner_type" => "organization",
            "project_number" => 12,
            "repository" => "GHW-Consulting/app-tastemap",
            "status_field" => "Status",
            "api_url" => "https://api.github.test",
            "token" => "secret-token"
          },
          provider_overrides
        ),
      active_states: ["Ready", "In Progress"],
      terminal_states: ["Done", "Cancelled"],
      working_state: "In Progress",
      blocked_state: "Blocked",
      completion_state: "Done"
    }
  end

  defp snapshot do
    %{
      api_url: "https://api.github.test",
      token: "secret-token",
      owner: "GHW-Consulting",
      owner_type: :organization,
      project_id: 901,
      project_number: 12,
      repository: "GHW-Consulting/app-tastemap",
      status: elem(Normalizer.resolve_status_field([status_field()], "Status", required_states()), 1),
      active_states: MapSet.new(["ready", "in progress"]),
      terminal_states: MapSet.new(["done", "cancelled"]),
      working_state: "In Progress",
      blocked_state: "Blocked",
      completion_state: "Done"
    }
  end

  defp normalization_context do
    snapshot()
  end

  defp required_states, do: ["Ready", "In Progress", "Blocked", "Done", "Cancelled"]

  defp status_field(id \\ 7) do
    %{
      "id" => id,
      "name" => "Status",
      "data_type" => "single_select",
      "options" => [
        %{"id" => "option-backlog", "name" => %{"raw" => "Backlog", "html" => "Backlog"}},
        %{"id" => "option-ready", "name" => %{"raw" => "Ready", "html" => "Ready"}},
        %{
          "id" => "option-progress",
          "name" => %{"raw" => "In Progress", "html" => "In Progress"}
        },
        %{"id" => "option-blocked", "name" => %{"raw" => "Blocked", "html" => "Blocked"}},
        %{"id" => "option-done", "name" => %{"raw" => "Done", "html" => "Done"}},
        %{
          "id" => "option-cancelled",
          "name" => %{"raw" => "Cancelled", "html" => "Cancelled"}
        }
      ]
    }
  end

  defp raw_item(item_id, status) do
    issue_number = item_id + 100

    %{
      "id" => item_id,
      "node_id" => "PVTI_#{item_id}",
      "project_url" => "https://api.github.test/orgs/GHW-Consulting/projectsV2/12",
      "item_url" => "https://api.github.test/orgs/GHW-Consulting/projectsV2/12/items/#{item_id}",
      "content_type" => "Issue",
      "content" => raw_issue(issue_number),
      "created_at" => "2026-07-31T12:00:00Z",
      "updated_at" => "2026-08-01T12:00:00Z",
      "archived_at" => nil,
      "fields" => [
        %{
          "id" => 7,
          "name" => "Status",
          "data_type" => "single_select",
          "value" => status_value(status)
        }
      ]
    }
  end

  defp raw_issue(issue_number) do
    %{
      "id" => 10_000 + issue_number,
      "node_id" => "I_#{issue_number}",
      "number" => issue_number,
      "repository_url" => "https://api.github.test/repos/GHW-Consulting/app-tastemap",
      "url" => "https://api.github.test/repos/GHW-Consulting/app-tastemap/issues/#{issue_number}",
      "html_url" => "https://github.test/GHW-Consulting/app-tastemap/issues/#{issue_number}",
      "title" => "Issue #{issue_number}",
      "body" => "Body #{issue_number}",
      "state" => "open",
      "assignee" => %{"login" => "octocat"},
      "labels" => [%{"name" => "Bug"}, %{"name" => " platform "}],
      "created_at" => "2026-07-01T12:00:00Z",
      "updated_at" => "2026-08-01T12:00:00Z"
    }
  end

  defp status_value(nil), do: nil

  defp status_value(status) do
    option_id =
      case status do
        "Backlog" -> "option-backlog"
        "Ready" -> "option-ready"
        "In Progress" -> "option-progress"
        "Done" -> "option-done"
        "Cancelled" -> "option-cancelled"
      end

    %{
      "id" => option_id,
      "name" => %{"raw" => status, "html" => status},
      "color" => "GRAY"
    }
  end

  defp ok_response(body, headers \\ %{}) do
    {:ok, %{status: 200, body: body, headers: headers}}
  end
end
