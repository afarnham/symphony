defmodule SymphonyElixir.GitHubProject.Client do
  @moduledoc """
  REST client for a GitHub Project whose single-select Status field controls
  issue dispatch.

  The client discovers project and field identifiers at runtime, pages through
  cursor-based Projects responses, and confirms every status transition with a
  fresh item read.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.GitHubProject.Normalizer
  alias SymphonyElixir.Secret
  alias SymphonyElixir.Tracker.Issue

  @default_api_url "https://api.github.com"
  @api_version "2026-03-10"
  @page_size 100
  @user_agent "symphony"
  @max_error_body_chars 4_096

  @type snapshot :: %{
          required(:api_url) => String.t(),
          required(:token) => String.t(),
          required(:owner) => String.t(),
          required(:owner_type) => :organization | :user,
          required(:project_id) => pos_integer(),
          required(:project_number) => pos_integer(),
          required(:repository) => String.t(),
          required(:status) => Normalizer.status_snapshot(),
          required(:active_states) => MapSet.t(String.t()),
          required(:terminal_states) => MapSet.t(String.t()),
          required(:working_state) => String.t(),
          required(:blocked_state) => String.t(),
          required(:completion_state) => String.t() | nil
        }

  @spec validate_settings(map()) :: :ok | {:error, term()}
  def validate_settings(tracker_settings) do
    with {:ok, _settings} <- settings(tracker_settings), do: :ok
  end

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(tracker_settings) do
    provider = provider_settings(tracker_settings)

    (Secret.environment_names(["GITHUB_TOKEN"]) ++
       Secret.reference_environment_names([provider["token"]]))
    |> Enum.uniq()
  end

  @spec load_snapshot(map(), keyword()) :: {:ok, snapshot()} | {:error, term()}
  def load_snapshot(tracker_settings, opts \\ [])
      when is_map(tracker_settings) and is_list(opts) do
    request_fun = Keyword.get(opts, :request_fun, &perform_request/5)

    with {:ok, settings} <- settings(tracker_settings),
         {:ok, project} <-
           request_body("GET", project_path(settings), %{}, nil, settings, request_fun),
         {:ok, project_id} <- project_id(project, settings.project_number),
         {:ok, repository} <-
           request_body("GET", repository_path(settings), %{}, nil, settings, request_fun),
         :ok <- validate_repository_payload(repository, settings.repository),
         {:ok, fields} <- fetch_pages(fields_path(settings), settings, request_fun),
         {:ok, status} <-
           Normalizer.resolve_status_field(
             fields,
             settings.status_field,
             settings.required_states
           ) do
      snapshot =
        settings
        |> Map.drop([:required_states, :status_field])
        |> Map.merge(%{project_id: project_id, status: status})

      with :ok <- preflight_project_items(snapshot, request_fun) do
        {:ok, snapshot}
      end
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states) when is_list(states) do
    fetch_issues_by_states(states, Config.settings!().tracker, [])
  end

  @spec fetch_issues_by_states([String.t()], map(), keyword()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states, tracker_settings, opts)
      when is_list(states) and is_map(tracker_settings) and is_list(opts) do
    request_fun = Keyword.get(opts, :request_fun, &perform_request/5)

    with {:ok, snapshot} <- resolve_snapshot(tracker_settings, opts),
         {:ok, items} <- fetch_item_pages(snapshot, request_fun),
         {:ok, normalized} <- normalize_items(items, snapshot, request_fun, :poll) do
      requested_states = states |> Enum.map(&normalize_state/1) |> MapSet.new()

      issues =
        Enum.filter(normalized, fn issue ->
          MapSet.member?(requested_states, normalize_state(issue.state)) and
            (issue.dispatchable or
               MapSet.member?(snapshot.terminal_states, normalize_state(issue.state)))
        end)

      {:ok, issues}
    end
  end

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(ids) when is_list(ids) do
    fetch_issues_by_ids(ids, Config.settings!().tracker, [])
  end

  @spec fetch_issues_by_ids([String.t()], map(), keyword()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(ids, tracker_settings, opts)
      when is_list(ids) and is_map(tracker_settings) and is_list(opts) do
    request_fun = Keyword.get(opts, :request_fun, &perform_request/5)

    with {:ok, item_ids} <- parse_item_ids(ids),
         {:ok, snapshot} <- resolve_snapshot(tracker_settings, opts) do
      fetch_item_ids(item_ids, snapshot, request_fun, [])
    end
  end

  @spec update_issue_state(Issue.t(), String.t(), keyword()) ::
          {:ok, Issue.t()} | {:error, term()}
  def update_issue_state(%Issue{} = issue, state, opts)
      when is_binary(state) and is_list(opts) do
    tracker_settings = Keyword.get_lazy(opts, :tracker_settings, fn -> Config.settings!().tracker end)
    update_issue_state(issue, state, tracker_settings, opts)
  end

  @spec update_issue_state(Issue.t(), String.t(), map(), keyword()) ::
          {:ok, Issue.t()} | {:error, term()}
  def update_issue_state(%Issue{} = issue, state, tracker_settings, opts)
      when is_binary(state) and is_map(tracker_settings) and is_list(opts) do
    request_fun = Keyword.get(opts, :request_fun, &perform_request/5)

    with {:ok, snapshot} <- resolve_snapshot(tracker_settings, opts),
         {:ok, item_id} <- transition_item_id(issue, snapshot),
         {:ok, target_option_id, target_state} <- target_state(snapshot, state),
         {:ok, current_issue} <- fetch_one_issue(item_id, snapshot, request_fun),
         :ok <- validate_transition_source(current_issue, opts) do
      if normalize_state(current_issue.state) == normalize_state(target_state) do
        {:ok, current_issue}
      else
        confirm_state_transition(
          item_id,
          target_option_id,
          target_state,
          snapshot,
          request_fun
        )
      end
    end
  end

  @spec request(String.t(), String.t(), map(), term(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def request(method, path, params, body, opts \\ [])
      when is_binary(method) and is_binary(path) and is_map(params) and is_list(opts) do
    tracker_settings = Keyword.get_lazy(opts, :tracker_settings, fn -> Config.settings!().tracker end)
    request_fun = Keyword.get(opts, :request_fun, &perform_request/5)

    with {:ok, _request_method} <- request_method(method),
         {:ok, settings} <- settings(tracker_settings) do
      request_with_settings(method, path, params, body, settings, request_fun)
    end
  end

  defp resolve_snapshot(tracker_settings, opts) do
    case Keyword.fetch(opts, :snapshot) do
      {:ok, snapshot} when is_map(snapshot) -> {:ok, snapshot}
      {:ok, _snapshot} -> {:error, :invalid_github_project_snapshot}
      :error -> resolve_runtime_snapshot(tracker_settings, opts)
    end
  end

  defp resolve_runtime_snapshot(tracker_settings, opts) do
    case Map.get(tracker_settings, :runtime_snapshot) do
      snapshot when is_map(snapshot) -> hydrate_runtime_snapshot(snapshot, tracker_settings)
      nil -> load_snapshot(tracker_settings, opts)
      _snapshot -> {:error, :invalid_github_project_snapshot}
    end
  end

  defp hydrate_runtime_snapshot(snapshot, tracker_settings) do
    with {:ok, request_settings} <- settings(tracker_settings) do
      {:ok, Map.merge(request_settings, snapshot)}
    end
  end

  defp settings(tracker_settings) do
    provider = provider_settings(tracker_settings)
    api_url = normalize_string(provider["api_url"] || @default_api_url)
    owner = normalize_string(provider["owner"])
    owner_type = normalize_owner_type(provider["owner_type"])
    project_number = provider["project_number"]
    repository = normalize_string(provider["repository"])
    status_field = normalize_string(provider["status_field"] || "Status")
    token = resolve_token(provider["token"])

    with :ok <- validate_api_url(api_url),
         :ok <- validate_owner(owner),
         {:ok, owner_type} <- owner_type,
         :ok <- validate_project_number(project_number),
         :ok <- validate_repository(repository),
         :ok <- validate_status_field(status_field),
         :ok <- validate_token(token),
         {:ok, active_states} <- state_list(Map.get(tracker_settings, :active_states), :active),
         {:ok, terminal_states} <- state_list(Map.get(tracker_settings, :terminal_states), :terminal),
         {:ok, working_state} <- required_state(Map.get(tracker_settings, :working_state), :working),
         {:ok, blocked_state} <- required_blocked_state(Map.get(tracker_settings, :blocked_state)),
         {:ok, completion_state} <- optional_state(Map.get(tracker_settings, :completion_state)),
         :ok <-
           validate_state_sets(
             active_states,
             terminal_states,
             working_state,
             blocked_state,
             completion_state
           ) do
      required_states =
        (active_states ++ terminal_states ++ [working_state, blocked_state, completion_state])
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq_by(&normalize_state/1)

      {:ok,
       %{
         api_url: String.trim_trailing(api_url, "/"),
         token: token,
         owner: owner,
         owner_type: owner_type,
         project_number: project_number,
         repository: repository,
         status_field: status_field,
         active_states: MapSet.new(active_states, &normalize_state/1),
         terminal_states: MapSet.new(terminal_states, &normalize_state/1),
         working_state: working_state,
         blocked_state: blocked_state,
         completion_state: completion_state,
         required_states: required_states
       }}
    end
  end

  defp provider_settings(%{provider: provider}) when is_map(provider), do: provider
  defp provider_settings(_tracker_settings), do: %{}

  defp validate_api_url(api_url) do
    case URI.parse(api_url) do
      %URI{scheme: "https", host: host} when is_binary(host) -> :ok
      _ -> {:error, :invalid_github_project_api_url}
    end
  end

  defp validate_owner(owner) do
    if present_string?(owner) and String.match?(owner, ~r/^[^\s\/]+$/) do
      :ok
    else
      {:error, :missing_github_project_owner}
    end
  end

  defp normalize_owner_type(value) when is_binary(value) do
    case normalize_state(value) do
      "organization" -> {:ok, :organization}
      "user" -> {:ok, :user}
      _ -> {:error, :invalid_github_project_owner_type}
    end
  end

  defp normalize_owner_type(_value), do: {:error, :invalid_github_project_owner_type}

  defp validate_project_number(value) when is_integer(value) and value > 0, do: :ok
  defp validate_project_number(_value), do: {:error, :invalid_github_project_number}

  defp validate_repository(repository) do
    if present_string?(repository) and
         String.match?(repository, ~r/^[^\s\/]+\/[^\s\/]+$/) do
      :ok
    else
      {:error, :invalid_github_project_repository}
    end
  end

  defp validate_status_field(value) do
    if present_string?(value),
      do: :ok,
      else: {:error, :missing_github_project_status_field}
  end

  defp validate_token(value) do
    if present_string?(value), do: :ok, else: {:error, :missing_github_project_token}
  end

  defp state_list(states, kind) when is_list(states) do
    if Enum.all?(states, &present_string?/1) do
      {:ok, Enum.map(states, &String.trim/1)}
    else
      {:error, state_list_error(kind)}
    end
  end

  defp state_list(_states, kind), do: {:error, state_list_error(kind)}
  defp state_list_error(:active), do: :missing_github_project_active_states
  defp state_list_error(:terminal), do: :missing_github_project_terminal_states

  defp required_state(state, _kind) when is_binary(state) do
    case String.trim(state) do
      "" -> {:error, :missing_github_project_working_state}
      trimmed -> {:ok, trimmed}
    end
  end

  defp required_state(_state, _kind), do: {:error, :missing_github_project_working_state}

  defp required_blocked_state(state) when is_binary(state) do
    case String.trim(state) do
      "" -> {:error, :missing_github_project_blocked_state}
      trimmed -> {:ok, trimmed}
    end
  end

  defp required_blocked_state(_state), do: {:error, :missing_github_project_blocked_state}

  defp optional_state(nil), do: {:ok, nil}

  defp optional_state(state) when is_binary(state) do
    case String.trim(state) do
      "" -> {:ok, nil}
      trimmed -> {:ok, trimmed}
    end
  end

  defp optional_state(_state), do: {:error, :invalid_github_project_completion_state}

  defp validate_state_sets(
         active_states,
         terminal_states,
         working_state,
         blocked_state,
         completion_state
       ) do
    active = MapSet.new(active_states, &normalize_state/1)
    terminal = MapSet.new(terminal_states, &normalize_state/1)
    normalized_blocked_state = normalize_state(blocked_state)

    cond do
      not MapSet.member?(active, normalize_state(working_state)) ->
        {:error, :github_project_working_state_not_active}

      not MapSet.disjoint?(active, terminal) ->
        {:error, :github_project_active_terminal_state_overlap}

      MapSet.member?(active, normalized_blocked_state) ->
        {:error, :github_project_blocked_state_active}

      MapSet.member?(terminal, normalized_blocked_state) ->
        {:error, :github_project_blocked_state_terminal}

      is_binary(completion_state) and
          normalize_state(completion_state) == normalized_blocked_state ->
        {:error, :github_project_blocked_completion_state_overlap}

      true ->
        :ok
    end
  end

  defp project_id(%{"id" => project_id, "number" => project_number}, project_number)
       when is_integer(project_id) and project_id > 0,
       do: {:ok, project_id}

  defp project_id(%{"id" => project_id}, _project_number)
       when is_integer(project_id) and project_id > 0,
       do: {:error, :github_project_project_number_mismatch}

  defp project_id(_project, _project_number),
    do: {:error, :github_project_project_payload_malformed}

  defp validate_repository_payload(%{"full_name" => full_name}, configured_repository)
       when is_binary(full_name) do
    if normalize_state(full_name) == normalize_state(configured_repository),
      do: :ok,
      else: {:error, :github_project_repository_mismatch}
  end

  defp validate_repository_payload(_payload, _repository),
    do: {:error, :github_project_repository_payload_malformed}

  defp fetch_pages(path, settings, request_fun) do
    fetch_pages(path, %{"per_page" => @page_size}, settings, request_fun, [])
  end

  defp fetch_pages(path, params, settings, request_fun, pages) do
    with {:ok, response} <- request_with_settings("GET", path, params, nil, settings, request_fun),
         true <- is_list(response.body) or {:error, :github_project_payload_malformed} do
      updated_pages = [response.body | pages]

      case next_page_params(response.headers, path, settings) do
        {:ok, nil} -> {:ok, updated_pages |> Enum.reverse() |> List.flatten()}
        {:ok, next_params} -> fetch_pages(path, next_params, settings, request_fun, updated_pages)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp fetch_item_pages(snapshot, request_fun) do
    path = items_path(snapshot)

    fetch_pages(
      path,
      %{"fields" => Integer.to_string(snapshot.status.field_id), "per_page" => @page_size},
      snapshot,
      request_fun,
      []
    )
  end

  defp preflight_project_items(snapshot, request_fun) do
    params = %{
      "fields" => Integer.to_string(snapshot.status.field_id),
      "per_page" => 1
    }

    with {:ok, items} <-
           request_body(
             "GET",
             items_path(snapshot),
             params,
             nil,
             snapshot,
             request_fun
           ),
         true <- is_list(items) or {:error, :github_project_payload_malformed} do
      preflight_first_project_item(items, snapshot, request_fun)
    end
  end

  defp preflight_first_project_item([], _snapshot, _request_fun), do: :ok

  defp preflight_first_project_item([%{"id" => item_id} | _rest], snapshot, request_fun) do
    with {:ok, item_id} <- parse_positive_integer(item_id),
         {:ok, payload} <-
           request_body(
             "GET",
             item_path(snapshot, item_id),
             %{"fields" => Integer.to_string(snapshot.status.field_id)},
             nil,
             snapshot,
             request_fun
           ),
         {:ok, _item} <- unwrap_item_payload(payload) do
      :ok
    else
      {:error, :invalid_positive_integer} -> {:error, :github_project_item_payload_malformed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp preflight_first_project_item([_item | _rest], _snapshot, _request_fun),
    do: {:error, :github_project_item_payload_malformed}

  defp normalize_items(items, snapshot, request_fun, mode) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, issues} ->
      normalize_next_item(item, issues, snapshot, request_fun, mode)
    end)
    |> case do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      error -> error
    end
  end

  defp normalize_next_item(
         %{"archived_at" => archived_at},
         issues,
         _snapshot,
         _request_fun,
         :poll
       )
       when not is_nil(archived_at) do
    {:cont, {:ok, issues}}
  end

  defp normalize_next_item(item, issues, snapshot, request_fun, _mode) do
    case enrich_and_normalize(item, snapshot, request_fun) do
      {:ok, issue} -> {:cont, {:ok, [issue | issues]}}
      {:skip, _reason} -> {:cont, {:ok, issues}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp enrich_and_normalize(item, snapshot, request_fun) do
    with {:ok, enriched_item} <- enrich_item_if_needed(item, snapshot, request_fun) do
      Normalizer.normalize_item(enriched_item, snapshot)
    end
  end

  defp enrich_item_if_needed(%{"content_type" => "Issue", "content" => content} = item, snapshot, request_fun)
       when is_map(content) do
    if incomplete_issue_content?(content) and issue_from_repository?(content, snapshot.repository) do
      with {:ok, issue_number} <- parse_positive_integer(content["number"]),
           {:ok, issue_payload} <-
             request_body(
               "GET",
               repository_issue_path(snapshot, issue_number),
               %{},
               nil,
               snapshot,
               request_fun
             ),
           true <- is_map(issue_payload) or {:error, :github_project_issue_payload_malformed} do
        {:ok, Map.put(item, "content", Map.merge(content, issue_payload))}
      end
    else
      {:ok, item}
    end
  end

  defp enrich_item_if_needed(item, _snapshot, _request_fun), do: {:ok, item}

  defp incomplete_issue_content?(content) do
    not present_string?(content["title"]) or
      not present_string?(content["state"]) or
      not is_list(content["labels"])
  end

  defp issue_from_repository?(content, repository) do
    expected_path = "/repos/#{encoded_repository(repository)}"

    Enum.any?([content["repository_url"], content["url"]], fn
      url when is_binary(url) ->
        case URI.parse(url).path do
          ^expected_path -> true
          path when is_binary(path) -> String.starts_with?(path, expected_path <> "/")
          _ -> false
        end

      _ ->
        false
    end)
  end

  defp parse_item_ids(ids) do
    ids
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, parsed} ->
      case parse_positive_integer(id) do
        {:ok, item_id} -> {:cont, {:ok, [item_id | parsed]}}
        {:error, _reason} -> {:halt, {:error, :invalid_github_project_item_id}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  defp fetch_item_ids([], _snapshot, _request_fun, issues), do: {:ok, Enum.reverse(issues)}

  defp fetch_item_ids([item_id | rest], snapshot, request_fun, issues) do
    case fetch_item(item_id, snapshot, request_fun, true) do
      {:ok, :not_found} ->
        fetch_item_ids(rest, snapshot, request_fun, issues)

      {:ok, item} ->
        case normalize_items([item], snapshot, request_fun, :refresh) do
          {:ok, [issue]} -> fetch_item_ids(rest, snapshot, request_fun, [issue | issues])
          {:ok, []} -> fetch_item_ids(rest, snapshot, request_fun, issues)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_one_issue(item_id, snapshot, request_fun) do
    with {:ok, item} <- fetch_item(item_id, snapshot, request_fun, false),
         {:ok, issues} <- normalize_items([item], snapshot, request_fun, :refresh) do
      case issues do
        [issue] -> {:ok, issue}
        [] -> {:error, :github_project_item_not_dispatchable}
      end
    end
  end

  defp fetch_item(item_id, snapshot, request_fun, allow_not_found) do
    with {:ok, payload} <-
           request_body(
             "GET",
             item_path(snapshot, item_id),
             %{"fields" => Integer.to_string(snapshot.status.field_id)},
             nil,
             snapshot,
             request_fun,
             allow_not_found
           ) do
      unwrap_item_payload(payload)
    end
  end

  defp unwrap_item_payload(:not_found), do: {:ok, :not_found}
  defp unwrap_item_payload(%{"value" => item}) when is_map(item), do: {:ok, item}
  defp unwrap_item_payload(item) when is_map(item), do: {:ok, item}
  defp unwrap_item_payload(_payload), do: {:error, :github_project_item_payload_malformed}

  defp transition_item_id(%Issue{native_ref: native_ref}, snapshot) when is_map(native_ref) do
    item_id = native_ref["project_item_id"]

    cond do
      native_ref["project_number"] not in [nil, snapshot.project_number] ->
        {:error, :github_project_issue_snapshot_mismatch}

      native_ref["project_id"] not in [nil, snapshot.project_id] ->
        {:error, :github_project_issue_snapshot_mismatch}

      native_ref["status_field_id"] not in [nil, snapshot.status.field_id] ->
        {:error, :github_project_issue_snapshot_mismatch}

      normalize_optional(native_ref["repository"]) not in [nil, normalize_state(snapshot.repository)] ->
        {:error, :github_project_issue_snapshot_mismatch}

      is_integer(item_id) and item_id > 0 ->
        {:ok, item_id}

      true ->
        {:error, :invalid_github_project_item_id}
    end
  end

  defp transition_item_id(_issue, _snapshot), do: {:error, :invalid_github_project_item_id}

  defp target_state(snapshot, requested_state) do
    normalized_state = normalize_state(requested_state)

    with {:ok, option_id} <- Map.fetch(snapshot.status.option_ids, normalized_state),
         {:ok, canonical_state} <- Map.fetch(snapshot.status.option_names, option_id) do
      {:ok, option_id, canonical_state}
    else
      :error -> {:error, {:github_project_state_not_found, String.trim(requested_state)}}
    end
  end

  defp validate_transition_source(current_issue, opts) do
    case Keyword.get(opts, :expected_active_states) do
      states when is_list(states) ->
        expected_states = MapSet.new(states, &normalize_state/1)

        cond do
          Keyword.get(opts, :require_dispatchable, false) and not current_issue.dispatchable ->
            {:error, :github_project_claim_source_not_dispatchable}

          not MapSet.member?(expected_states, normalize_state(current_issue.state)) ->
            {:error, {:github_project_claim_source_not_active, current_issue.state}}

          true ->
            :ok
        end

      nil ->
        :ok

      _states ->
        {:error, :invalid_github_project_expected_active_states}
    end
  end

  defp confirm_state_transition(item_id, option_id, target_state, snapshot, request_fun) do
    body = %{
      "fields" => [%{"id" => snapshot.status.field_id, "value" => option_id}]
    }

    with {:ok, _payload} <-
           request_body(
             "PATCH",
             item_path(snapshot, item_id),
             %{},
             body,
             snapshot,
             request_fun
           ),
         {:ok, refreshed_issue} <- fetch_one_issue(item_id, snapshot, request_fun) do
      if normalize_state(refreshed_issue.state) == normalize_state(target_state) do
        {:ok, refreshed_issue}
      else
        {:error, {:github_project_state_not_confirmed, target_state, refreshed_issue.state}}
      end
    end
  end

  defp request_body(method, path, params, body, settings, request_fun, allow_not_found \\ false) do
    case request_with_settings(method, path, params, body, settings, request_fun) do
      {:ok, response} -> {:ok, response.body}
      {:error, {:github_project_api_error, %{kind: :not_found}}} when allow_not_found -> {:ok, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request_with_settings(method, path, params, body, settings, request_fun) do
    case request_fun.(method, path, params, body, settings) do
      {:ok, %{status: status, body: payload} = response} when status in 200..299 ->
        headers = normalize_headers(Map.get(response, :headers, %{}))

        {:ok,
         %{
           status: status,
           body: payload,
           headers: headers,
           rate_limit: rate_limit_metadata(headers)
         }}

      {:ok, %{status: status} = response} when is_integer(status) ->
        headers = normalize_headers(Map.get(response, :headers, %{}))

        {:error,
         {:github_project_api_error,
          %{
            kind: api_error_kind(status, headers),
            status: status,
            body: bounded_error_body(Map.get(response, :body), settings.token),
            rate_limit: rate_limit_metadata(headers)
          }}}

      {:error, reason} ->
        {:error, {:github_project_api_error, %{kind: :transport, status: nil, reason: reason, rate_limit: nil}}}

      other ->
        {:error, {:github_project_api_error, %{kind: :payload, status: nil, reason: other, rate_limit: nil}}}
    end
  end

  defp perform_request(method, path, params, body, settings) do
    with {:ok, request_method} <- request_method(method) do
      request_opts = [
        method: request_method,
        url: settings.api_url <> path,
        headers: github_headers(settings.token),
        params: params,
        connect_options: [timeout: 30_000]
      ]

      request_opts = if is_nil(body), do: request_opts, else: Keyword.put(request_opts, :json, body)

      case Req.request(request_opts) do
        {:ok, response} ->
          {:ok, %{status: response.status, body: response.body, headers: response.headers}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp normalize_headers(headers) when is_map(headers) do
    Map.new(headers, fn {name, value} -> {String.downcase(to_string(name)), List.wrap(value)} end)
  end

  defp normalize_headers(headers) when is_list(headers) do
    Enum.reduce(headers, %{}, fn {name, value}, acc ->
      Map.update(acc, String.downcase(to_string(name)), List.wrap(value), &(List.wrap(&1) ++ List.wrap(value)))
    end)
  end

  defp normalize_headers(_headers), do: %{}

  defp next_page_params(headers, expected_path, settings) do
    case next_link(headers) do
      nil ->
        {:ok, nil}

      url ->
        uri = URI.parse(url)
        api_uri = URI.parse(settings.api_url)

        expected_uri = URI.parse(settings.api_url <> expected_path)

        if uri.scheme == api_uri.scheme and uri.host == api_uri.host and
             uri.port == expected_uri.port and
             valid_pagination_path?(uri.path, expected_uri.path, expected_path, settings) do
          {:ok, URI.decode_query(uri.query || "")}
        else
          {:error, :github_project_invalid_pagination_link}
        end
    end
  end

  defp valid_pagination_path?(path, expected_path, _route_path, _settings)
       when path == expected_path,
       do: true

  defp valid_pagination_path?(path, _expected_path, route_path, settings)
       when is_binary(path) and is_binary(route_path) do
    project_path = owner_project_path(settings)

    if String.starts_with?(route_path, project_path) do
      resource_path = String.replace_prefix(route_path, project_path, "")
      api_path_prefix = api_path_prefix(settings.api_url)
      owner_collection = canonical_owner_collection(settings.owner_type)
      prefix = "#{api_path_prefix}/#{owner_collection}/"
      suffix = "/projectsV2/#{settings.project_number}#{resource_path}"

      positive_integer_between?(path, prefix, suffix)
    else
      false
    end
  end

  defp valid_pagination_path?(_path, _expected_path, _route_path, _settings), do: false

  defp api_path_prefix(api_url) do
    case URI.parse(api_url).path do
      nil -> ""
      "/" -> ""
      path -> String.trim_trailing(path, "/")
    end
  end

  defp canonical_owner_collection(:organization), do: "organizations"
  defp canonical_owner_collection(:user), do: "users"

  defp positive_integer_between?(value, prefix, suffix) do
    middle_size = byte_size(value) - byte_size(prefix) - byte_size(suffix)

    if middle_size > 0 and String.starts_with?(value, prefix) and
         String.ends_with?(value, suffix) do
      case Integer.parse(binary_part(value, byte_size(prefix), middle_size)) do
        {integer, ""} when integer > 0 -> true
        _other -> false
      end
    else
      false
    end
  end

  defp next_link(headers) do
    headers
    |> Map.get("link", [])
    |> Enum.join(",")
    |> String.split(",")
    |> Enum.find_value(fn segment ->
      case Regex.run(~r/^\s*<([^>]+)>;\s*rel="?next"?\s*$/, segment) do
        [_, url] -> url
        _ -> nil
      end
    end)
  end

  defp api_error_kind(401, _headers), do: :authentication

  defp api_error_kind(403, headers) do
    if header_integer(headers, "x-ratelimit-remaining") == 0 or
         present_header?(headers, "retry-after"),
       do: :rate_limit,
       else: :authorization
  end

  defp api_error_kind(404, _headers), do: :not_found
  defp api_error_kind(422, _headers), do: :validation
  defp api_error_kind(429, _headers), do: :rate_limit
  defp api_error_kind(_status, _headers), do: :api_status

  defp rate_limit_metadata(headers) do
    remaining = header_integer(headers, "x-ratelimit-remaining")
    reset = header_integer(headers, "x-ratelimit-reset")
    retry_after = header_integer(headers, "retry-after")

    if Enum.all?([remaining, reset, retry_after], &is_nil/1) do
      nil
    else
      %{remaining: remaining, reset: reset, retry_after: retry_after}
    end
  end

  defp header_integer(headers, name) do
    with [value | _rest] <- Map.get(headers, name, []),
         {integer, ""} <- Integer.parse(to_string(value)) do
      integer
    else
      _ -> nil
    end
  end

  defp present_header?(headers, name), do: Map.get(headers, name, []) != []

  defp project_path(settings), do: owner_project_path(settings)
  defp fields_path(settings), do: owner_project_path(settings) <> "/fields"
  defp items_path(settings), do: owner_project_path(settings) <> "/items"
  defp item_path(settings, item_id), do: items_path(settings) <> "/#{item_id}"

  defp owner_project_path(%{owner_type: :organization} = settings) do
    "/orgs/#{encoded_segment(settings.owner)}/projectsV2/#{settings.project_number}"
  end

  defp owner_project_path(%{owner_type: :user} = settings) do
    "/users/#{encoded_segment(settings.owner)}/projectsV2/#{settings.project_number}"
  end

  defp repository_path(settings), do: "/repos/#{encoded_repository(settings.repository)}"

  defp repository_issue_path(settings, issue_number) do
    repository_path(settings) <> "/issues/#{issue_number}"
  end

  defp encoded_repository(repository) do
    repository
    |> String.split("/", parts: 2)
    |> Enum.map_join("/", &encoded_segment/1)
  end

  defp encoded_segment(segment), do: URI.encode(segment, &URI.char_unreserved?/1)

  defp github_headers(token) do
    [
      {"Accept", "application/vnd.github+json"},
      {"Authorization", "Bearer #{token}"},
      {"X-GitHub-Api-Version", @api_version},
      {"User-Agent", @user_agent}
    ]
  end

  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _ -> {:error, :invalid_positive_integer}
    end
  end

  defp parse_positive_integer(_value), do: {:error, :invalid_positive_integer}

  defp request_method("GET"), do: {:ok, :get}
  defp request_method("POST"), do: {:ok, :post}
  defp request_method("PATCH"), do: {:ok, :patch}
  defp request_method("PUT"), do: {:ok, :put}
  defp request_method("DELETE"), do: {:ok, :delete}
  defp request_method(_method), do: {:error, :invalid_github_project_method}

  defp resolve_token(nil), do: Secret.resolve(nil, "GITHUB_TOKEN")
  defp resolve_token(value), do: Secret.resolve(value)

  defp bounded_error_body(body, token) do
    body
    |> inspect(limit: 50, printable_limit: @max_error_body_chars, width: 120)
    |> redact_error_secrets(token)
    |> String.slice(0, @max_error_body_chars)
  end

  defp redact_error_secrets(text, token) do
    text
    |> redact_exact_secret(token)
    |> then(&Regex.replace(~r/(?i)bearer\s+[A-Za-z0-9._~+\/=\-]+/, &1, "Bearer [REDACTED]"))
    |> then(
      &Regex.replace(
        ~r/(?i)(["']?(?:authorization|token|secret|password)["']?\s*(?:=>|:)\s*)(["'][^"']*["']|[^,}\s]+)/,
        &1,
        "\\1[REDACTED]"
      )
    )
  end

  defp redact_exact_secret(text, token) when is_binary(token) and token != "",
    do: String.replace(text, token, "[REDACTED]")

  defp redact_exact_secret(text, _token), do: text

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil

  defp normalize_optional(value) when is_binary(value), do: normalize_state(value)
  defp normalize_optional(_value), do: nil

  defp normalize_state(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_state(_value), do: ""

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false
end
