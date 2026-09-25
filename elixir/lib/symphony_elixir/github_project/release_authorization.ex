defmodule SymphonyElixir.GitHubProject.ReleaseAuthorization do
  @moduledoc """
  Recovers explicit release authorization when GitHub omits a Ready timeline event.

  The comment author comes from GitHub, never from the JSON body. A receipt binds
  one Project item and Ready revision to a profile and backend. Existing execution
  route validation remains authoritative for actor and credential ownership.
  """

  alias SymphonyElixir.Tracker.Issue

  @prefix "Symphony release authorization\n\n```json\n"
  @suffix "\n```"
  @query """
  query SymphonyReleaseAuthorization($issueId: ID!, $itemId: ID!, $statusField: String!, $before: String) {
    issue: node(id: $issueId) {
      ... on Issue {
        comments(last: 100, before: $before) {
          nodes { id body createdAt lastEditedAt isMinimized author { __typename login } }
          pageInfo { hasPreviousPage startCursor }
        }
      }
    }
    item: node(id: $itemId) {
      ... on ProjectV2Item {
        id
        project { id }
        content { ... on Issue { id } }
        fieldValueByName(name: $statusField) {
          ... on ProjectV2ItemFieldSingleSelectValue { name updatedAt }
        }
      }
    }
  }
  """

  @spec fetch(Issue.t(), map(), (map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, Issue.t()} | {:error, term()}
  def fetch(%Issue{native_ref: %{"project_item_node_id" => item_id}} = issue, snapshot, request)
      when is_binary(item_id) do
    fetch_page(issue, snapshot, request, nil, 0)
  end

  def fetch(_issue, _snapshot, _request),
    do: {:error, :github_project_ready_transition_not_found}

  defp fetch_page(_issue, _snapshot, _request, _before, 10),
    do: {:error, :github_project_release_authorization_history_limit}

  defp fetch_page(issue, snapshot, request, before, page) do
    body = %{
      "query" => @query,
      "variables" => %{
        "issueId" => issue.native_ref["issue_node_id"],
        "itemId" => issue.native_ref["project_item_node_id"],
        "statusField" => snapshot.status.field_name,
        "before" => before
      }
    }

    with {:ok, payload} <- request.(body),
         {:ok, nodes, page_info, status} <- response(payload, issue, snapshot) do
      case Enum.find_value(Enum.reverse(nodes), &authorization(&1, issue, snapshot, status)) do
        nil -> previous_page(page_info, issue, snapshot, request, page)
        authorized -> {:ok, authorized}
      end
    end
  end

  defp response(
         %{
           "data" => %{
             "issue" => %{"comments" => %{"nodes" => nodes, "pageInfo" => page_info}},
             "item" => %{
               "id" => item_id,
               "project" => %{"id" => project_id},
               "content" => %{"id" => issue_id},
               "fieldValueByName" => %{"name" => name, "updatedAt" => revision} = status
             }
           }
         } = payload,
         issue,
         snapshot
       )
       when is_list(nodes) and is_map(page_info) and is_binary(name) and is_binary(revision) do
    if not Map.has_key?(payload, "errors") and
         item_id == issue.native_ref["project_item_node_id"] and
         project_id == snapshot.project_node_id and issue_id == issue.native_ref["issue_node_id"] and
         normalize(name) == normalize(issue.state) do
      {:ok, nodes, page_info, status}
    else
      {:error, :github_project_release_authorization_snapshot_mismatch}
    end
  end

  defp response(_payload, _issue, _snapshot),
    do: {:error, :github_project_release_authorization_payload_malformed}

  defp authorization(
         %{
           "id" => comment_id,
           "body" => @prefix <> text,
           "createdAt" => created,
           "lastEditedAt" => nil,
           "isMinimized" => false,
           "author" => %{"login" => actor, "__typename" => actor_type}
         },
         issue,
         snapshot,
         status
       )
       when is_binary(comment_id) and is_binary(actor) and actor_type in ["User", "Bot"] and is_binary(created) do
    with true <- normalize(actor) in Map.get(snapshot, :routing_authorized_actors, []),
         true <- String.ends_with?(text, @suffix),
         {:ok, %{"version" => 1} = receipt} <- Jason.decode(String.replace_suffix(text, @suffix, "")),
         true <- receipt["project_item_id"] == issue.native_ref["project_item_node_id"],
         profile when is_binary(profile) and profile != "" <- receipt["profile"],
         true <- profile == normalize(profile),
         true <- profile in Enum.map(issue.assignee_ids, &normalize/1),
         backend when backend in ["codex", "claude"] <- receipt["backend"],
         true <- valid_revision?(receipt["ready_updated_at"], created, status, snapshot) do
      %{
        issue
        | ready_actor_id: actor,
          ready_actor_automated: actor_type == "Bot",
          release_authorization: %{"profile" => profile, "backend" => backend, "comment_id" => comment_id}
      }
    else
      _invalid -> nil
    end
  end

  defp authorization(_comment, _issue, _snapshot, _status), do: nil

  defp valid_revision?(ready_revision, created, status, snapshot) when is_binary(ready_revision) do
    with {:ok, ready_at, 0} <- DateTime.from_iso8601(ready_revision),
         {:ok, created_at, 0} <- DateTime.from_iso8601(created),
         {:ok, status_at, 0} <- DateTime.from_iso8601(status["updatedAt"]),
         true <- DateTime.compare(created_at, ready_at) != :lt do
      cond do
        normalize(status["name"]) == normalize(snapshot.routing_ready_state) ->
          DateTime.compare(status_at, ready_at) == :eq

        normalize(status["name"]) == normalize(snapshot.working_state) ->
          DateTime.compare(status_at, created_at) != :lt

        true ->
          false
      end
    else
      _invalid -> false
    end
  end

  defp valid_revision?(_revision, _created, _status, _snapshot), do: false

  defp previous_page(%{"hasPreviousPage" => true, "startCursor" => cursor}, issue, snapshot, request, page)
       when is_binary(cursor) and cursor != "" do
    fetch_page(issue, snapshot, request, cursor, page + 1)
  end

  defp previous_page(%{"hasPreviousPage" => false}, _issue, _snapshot, _request, _page),
    do: {:error, :github_project_ready_transition_not_found}

  defp previous_page(_page_info, _issue, _snapshot, _request, _page),
    do: {:error, :github_project_release_authorization_payload_malformed}

  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize(_value), do: ""
end
