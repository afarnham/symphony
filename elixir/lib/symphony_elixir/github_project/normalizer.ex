defmodule SymphonyElixir.GitHubProject.Normalizer do
  @moduledoc """
  Resolves GitHub Project field metadata and converts project items into
  tracker issues.

  Project item IDs are the scheduler identity. The underlying repository
  issue remains available through `Issue.native_ref` for provider operations.
  """

  alias SymphonyElixir.Tracker.Issue

  @type status_snapshot :: %{
          required(:field_id) => pos_integer(),
          required(:field_name) => String.t(),
          required(:option_ids) => %{String.t() => String.t()},
          required(:option_names) => %{String.t() => String.t()}
        }

  @spec resolve_status_field([map()], String.t(), [String.t()]) ::
          {:ok, status_snapshot()} | {:error, term()}
  def resolve_status_field(fields, configured_name, required_states)
      when is_list(fields) and is_binary(configured_name) and is_list(required_states) do
    requested_name = String.trim(configured_name)
    normalized_name = normalize_name(requested_name)

    matches =
      Enum.filter(fields, fn field ->
        normalize_name(display_name(field["name"])) == normalized_name
      end)

    case matches do
      [] ->
        {:error, {:github_project_status_field_not_found, requested_name}}

      [_first, _second | _rest] ->
        {:error, {:github_project_status_field_ambiguous, requested_name}}

      [field] ->
        resolve_single_status_field(field, required_states)
    end
  end

  def resolve_status_field(_fields, configured_name, _required_states) do
    {:error, {:github_project_status_field_not_found, display_name(configured_name)}}
  end

  @spec normalize_item(map(), map()) ::
          {:ok, Issue.t()} | {:skip, term()} | {:error, term()}
  def normalize_item(%{"content_type" => "Issue"} = item, context) when is_map(context) do
    with {:ok, item_id} <- positive_integer(item["id"]),
         {:ok, status_option_id, state} <- item_status(item, context),
         %{} = content <- item["content"],
         :ok <- validate_repository(content, item, context.repository),
         {:ok, issue_number} <- positive_integer(content["number"]),
         true <- present_string?(content["title"]) or {:error, :github_project_item_malformed},
         true <- present_string?(content["state"]) or {:error, :github_project_item_malformed} do
      issue = %Issue{
        id: Integer.to_string(item_id),
        native_ref: native_ref(item_id, issue_number, status_option_id, content, context),
        identifier: "GH-#{issue_number}",
        title: content["title"],
        description: content["body"],
        priority: nil,
        state: state,
        branch_name: nil,
        url: content["html_url"],
        assignee_id: get_in(content, ["assignee", "login"]),
        labels: extract_labels(content["labels"]),
        blocked_by: [],
        dispatchable: dispatchable?(item, content, state),
        created_at: parse_datetime(content["created_at"]),
        updated_at: parse_datetime(content["updated_at"])
      }

      {:ok, issue}
    else
      {:skip, _reason} = skip -> skip
      {:error, _reason} = error -> error
      _ -> {:error, :github_project_item_malformed}
    end
  end

  def normalize_item(%{"content_type" => content_type}, _context)
      when content_type in ["DraftIssue", "PullRequest"] do
    {:skip, :unsupported_content_type}
  end

  def normalize_item(_item, _context), do: {:error, :github_project_item_malformed}

  defp resolve_single_status_field(field, required_states) do
    field_name = display_name(field["name"])

    cond do
      normalize_name(field["data_type"]) != "single_select" ->
        {:error, {:github_project_status_field_not_single_select, field_name}}

      not is_integer(field["id"]) or field["id"] <= 0 ->
        {:error, :github_project_status_field_malformed}

      not is_list(field["options"]) ->
        {:error, :github_project_status_field_malformed}

      true ->
        with {:ok, options} <- normalize_options(field["options"]),
             :ok <- validate_required_states(required_states, options.option_ids) do
          {:ok,
           %{
             field_id: field["id"],
             field_name: field_name,
             option_ids: options.option_ids,
             option_names: options.option_names
           }}
        end
    end
  end

  defp normalize_options(options) do
    Enum.reduce_while(options, {:ok, %{option_ids: %{}, option_names: %{}}}, fn option, {:ok, acc} ->
      id = option["id"]
      name = display_name(option["name"])
      normalized_name = normalize_name(name)

      cond do
        not present_string?(id) or not present_string?(name) ->
          {:halt, {:error, :github_project_status_option_malformed}}

        Map.has_key?(acc.option_ids, normalized_name) ->
          {:halt, {:error, {:github_project_state_ambiguous, normalized_name}}}

        Map.has_key?(acc.option_names, id) ->
          {:halt, {:error, :github_project_status_option_malformed}}

        true ->
          {:cont,
           {:ok,
            %{
              option_ids: Map.put(acc.option_ids, normalized_name, id),
              option_names: Map.put(acc.option_names, id, name)
            }}}
      end
    end)
  end

  defp validate_required_states(states, option_ids) do
    states
    |> Enum.uniq_by(&normalize_name/1)
    |> Enum.reduce_while(:ok, fn state, :ok ->
      if is_binary(state) and Map.has_key?(option_ids, normalize_name(state)) do
        {:cont, :ok}
      else
        {:halt, {:error, {:github_project_state_not_found, display_name(state)}}}
      end
    end)
  end

  defp item_status(item, context) do
    status_fields =
      item
      |> Map.get("fields", [])
      |> List.wrap()
      |> Enum.filter(&(&1["id"] == context.status.field_id))

    case status_fields do
      [] ->
        {:error, :github_project_item_missing_status_field}

      [_first, _second | _rest] ->
        {:error, :github_project_item_ambiguous_status_field}

      [%{"value" => nil}] ->
        {:ok, nil, nil}

      [%{"value" => %{"id" => option_id}}] when is_binary(option_id) ->
        case Map.fetch(context.status.option_names, option_id) do
          {:ok, state} -> {:ok, option_id, state}
          :error -> {:error, {:github_project_unknown_status_option, option_id}}
        end

      [_field] ->
        {:error, :github_project_item_malformed_status}
    end
  end

  defp validate_repository(content, item, configured_repository) do
    case repository_name(content, item) do
      nil ->
        {:error, :github_project_item_missing_repository}

      repository ->
        if normalize_name(repository) == normalize_name(configured_repository) do
          :ok
        else
          {:skip, :repository_mismatch}
        end
    end
  end

  defp repository_name(content, item) do
    repository_from_url(content["repository_url"]) ||
      repository_from_url(content["url"]) ||
      repository_from_field(item["fields"])
  end

  defp repository_from_url(url) when is_binary(url) do
    case URI.parse(url).path |> to_string() |> String.split("/", trim: true) do
      ["repos", owner, repository | _rest] ->
        URI.decode(owner) <> "/" <> URI.decode(repository)

      _ ->
        nil
    end
  end

  defp repository_from_url(_url), do: nil

  defp repository_from_field(fields) when is_list(fields) do
    Enum.find_value(fields, fn
      %{"data_type" => "repository", "value" => %{"full_name" => full_name}}
      when is_binary(full_name) ->
        full_name

      _ ->
        nil
    end)
  end

  defp repository_from_field(_fields), do: nil

  defp native_ref(item_id, issue_number, status_option_id, content, context) do
    %{
      "project_id" => context.project_id,
      "project_number" => context.project_number,
      "project_item_id" => item_id,
      "status_field_id" => context.status.field_id,
      "status_option_id" => status_option_id,
      "repository" => context.repository,
      "issue_id" => content["id"],
      "issue_node_id" => content["node_id"],
      "issue_number" => issue_number
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp extract_labels(labels) when is_list(labels) do
    labels
    |> Enum.flat_map(fn
      %{"name" => name} when is_binary(name) -> [name]
      name when is_binary(name) -> [name]
      _ -> []
    end)
    |> Enum.map(&normalize_name/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp extract_labels(_labels), do: []

  defp dispatchable?(item, content, state) do
    is_nil(item["archived_at"]) and not is_nil(state) and normalize_name(content["state"]) == "open"
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(_value), do: {:error, :github_project_item_malformed}

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp display_name(%{"raw" => raw}) when is_binary(raw), do: String.trim(raw)
  defp display_name(value) when is_binary(value), do: String.trim(value)
  defp display_name(_value), do: ""

  defp normalize_name(value) do
    value
    |> display_name()
    |> String.downcase()
  end

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false
end
