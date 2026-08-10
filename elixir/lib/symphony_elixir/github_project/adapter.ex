defmodule SymphonyElixir.GitHubProject.Adapter do
  @moduledoc """
  GitHub Project-backed tracker adapter.

  Repository issues supply work-item content while the configured Project
  Status field supplies scheduler state.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.GitHub.AgentTool
  alias SymphonyElixir.GitHubProject.Client
  alias SymphonyElixir.Tracker.Issue

  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(tracker_settings), do: Client.validate_settings(tracker_settings)

  @spec prepare_config(map()) :: {:ok, map()} | {:error, term()}
  def prepare_config(tracker_settings) do
    with :ok <- Client.validate_settings(tracker_settings),
         {:ok, snapshot} <- client_module().load_snapshot(tracker_settings, []) do
      {:ok, Map.put(tracker_settings, :runtime_snapshot, Map.delete(snapshot, :token))}
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issues_by_states([String.t()], keyword()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states, opts) when is_list(states) and is_list(opts) do
    tracker_settings = Keyword.fetch!(opts, :tracker_settings)

    client_module().fetch_issues_by_states(
      states,
      tracker_settings,
      Keyword.delete(opts, :tracker_settings)
    )
  end

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids), do: client_module().fetch_issues_by_ids(issue_ids)

  @spec fetch_issues_by_ids([String.t()], keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids, opts) when is_list(opts) do
    tracker_settings = Keyword.fetch!(opts, :tracker_settings)

    client_module().fetch_issues_by_ids(
      issue_ids,
      tracker_settings,
      Keyword.delete(opts, :tracker_settings)
    )
  end

  @spec update_issue_state(Issue.t(), String.t(), keyword()) ::
          {:ok, Issue.t()} | {:error, term()}
  def update_issue_state(%Issue{} = issue, state, opts) when is_binary(state) and is_list(opts) do
    client_module().update_issue_state(issue, state, opts)
  end

  @spec add_issue_comment(Issue.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def add_issue_comment(%Issue{} = issue, body, opts)
      when is_binary(body) and is_list(opts) do
    tracker_settings = Keyword.fetch!(opts, :tracker_settings)
    github_client = Keyword.get(opts, :github_client, &Client.request/5)

    with {:ok, repository, issue_number} <- comment_target(issue, tracker_settings),
         {:ok, %{status: status, body: response_body}} when status in 200..299 <-
           github_client.(
             "POST",
             "/repos/#{repository}/issues/#{issue_number}/comments",
             %{},
             %{"body" => body},
             tracker_settings: tracker_settings
           ) do
      {:ok, response_body}
    else
      {:ok, %{status: status, body: response_body}} ->
        {:error, {:github_project_comment_failed, status, response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec agent_tool_specs() :: [map()]
  def agent_tool_specs, do: AgentTool.tool_specs()

  @spec execute_agent_tool(String.t(), term(), keyword()) :: map()
  def execute_agent_tool(tool, arguments, opts) do
    AgentTool.execute(tool, arguments, Keyword.put_new(opts, :github_client, &Client.request/5))
  end

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(tracker_settings),
    do: Client.secret_environment_names(tracker_settings)

  defp client_module do
    Application.get_env(:symphony_elixir, :github_project_client_module, Client)
  end

  defp comment_target(
         %Issue{native_ref: %{"issue_number" => issue_number, "repository" => issue_repository}},
         %{provider: %{"repository" => configured_repository}}
       )
       when is_integer(issue_number) and issue_number > 0 and is_binary(issue_repository) and
              is_binary(configured_repository) do
    if normalize_repository(issue_repository) == normalize_repository(configured_repository) do
      {:ok, encode_repository(configured_repository), issue_number}
    else
      {:error, :github_project_issue_snapshot_mismatch}
    end
  end

  defp comment_target(_issue, _tracker_settings),
    do: {:error, :invalid_github_project_issue_reference}

  defp encode_repository(repository) do
    repository
    |> String.split("/", parts: 2)
    |> Enum.map_join("/", &URI.encode(&1, fn character -> URI.char_unreserved?(character) end))
  end

  defp normalize_repository(repository), do: repository |> String.trim() |> String.downcase()
end
