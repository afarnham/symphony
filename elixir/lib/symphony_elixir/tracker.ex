defmodule SymphonyElixir.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads and provider-native agent tools.

  The orchestrator only depends on the read callbacks. Agent-side mutations stay
  behind optional provider-native tools so tracker-specific capabilities do not
  leak into scheduler policy.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Tracker.Issue

  @adapters %{
    "asana" => SymphonyElixir.Asana.Adapter,
    "github" => SymphonyElixir.GitHub.Adapter,
    "github_project" => SymphonyElixir.GitHubProject.Adapter,
    "gitlab" => SymphonyElixir.GitLab.Adapter,
    "jira" => SymphonyElixir.Jira.Adapter,
    "linear" => SymphonyElixir.Linear.Adapter,
    "memory" => SymphonyElixir.Tracker.Memory
  }

  @callback fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  @callback fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  @callback update_issue_state(Issue.t(), String.t(), keyword()) ::
              {:ok, Issue.t()} | {:error, term()}
  @callback agent_tool_specs() :: [map()]
  @callback execute_agent_tool(String.t(), term(), keyword()) :: map()
  @callback secret_environment_names(map()) :: [String.t()]
  @callback validate_config(map()) :: :ok | {:error, term()}
  @callback prepare_config(map()) :: {:ok, map()} | {:error, term()}

  @optional_callbacks agent_tool_specs: 0,
                      execute_agent_tool: 3,
                      update_issue_state: 3,
                      prepare_config: 1,
                      validate_config: 1

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    adapter().fetch_issues_by_states(states)
  end

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids) do
    adapter().fetch_issues_by_ids(issue_ids)
  end

  @spec fetch_bound_issues_by_ids(map(), [String.t()]) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_bound_issues_by_ids(
        %{adapter: selected_adapter, tracker_settings: tracker_settings},
        issue_ids
      )
      when is_list(issue_ids) do
    if Code.ensure_loaded?(selected_adapter) and
         function_exported?(selected_adapter, :fetch_issues_by_ids, 2) do
      selected_adapter.fetch_issues_by_ids(
        issue_ids,
        tracker_settings: tracker_settings
      )
    else
      selected_adapter.fetch_issues_by_ids(issue_ids)
    end
  end

  @spec fetch_bound_issues_by_states(map(), [String.t()]) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_bound_issues_by_states(
        %{adapter: selected_adapter, tracker_settings: tracker_settings},
        states
      )
      when is_list(states) do
    if Code.ensure_loaded?(selected_adapter) and
         function_exported?(selected_adapter, :fetch_issues_by_states, 2) do
      selected_adapter.fetch_issues_by_states(
        states,
        tracker_settings: tracker_settings
      )
    else
      selected_adapter.fetch_issues_by_states(states)
    end
  end

  @spec bind_config(map()) :: {:ok, map()} | {:error, term()}
  def bind_config(%{kind: kind} = tracker_settings) do
    with {:ok, selected_adapter} <- adapter_for_kind(kind) do
      {:ok, %{adapter: selected_adapter, tracker_settings: tracker_settings}}
    end
  end

  @spec update_issue_state(Issue.t(), String.t(), keyword()) ::
          {:ok, Issue.t()} | {:error, term()}
  def update_issue_state(%Issue{} = issue, state, opts \\ []) when is_binary(state) do
    selected_adapter = Keyword.get(opts, :adapter, adapter())
    tracker_settings = Keyword.get(opts, :tracker_settings, Config.settings!().tracker)

    if Code.ensure_loaded?(selected_adapter) and
         function_exported?(selected_adapter, :update_issue_state, 3) do
      selected_adapter.update_issue_state(
        issue,
        state,
        Keyword.put_new(opts, :tracker_settings, tracker_settings)
      )
    else
      {:error, :state_transition_not_supported}
    end
  end

  @doc """
  Captures the selected adapter and effective tracker settings for one
  app-server session so tool advertisement and execution cannot drift across a
  workflow reload.
  """
  @spec bind_agent_tools() :: map()
  def bind_agent_tools do
    tracker_settings = Config.settings!().tracker
    adapter = adapter_for_settings!(tracker_settings)

    %{
      adapter: adapter,
      tracker_settings: tracker_settings,
      tool_specs: adapter_agent_tool_specs(adapter),
      secret_environment_names: adapter_secret_environment_names(adapter, tracker_settings)
    }
  end

  @spec execute_bound_agent_tool(map(), String.t(), term(), keyword()) :: map()
  def execute_bound_agent_tool(
        %{adapter: adapter, tracker_settings: tracker_settings},
        tool,
        arguments,
        opts \\ []
      ) do
    execute_agent_tool_with_adapter(
      adapter,
      tool,
      arguments,
      Keyword.put(opts, :tracker_settings, tracker_settings)
    )
  end

  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(%{kind: kind} = tracker_settings) do
    with {:ok, adapter} <- adapter_for_kind(kind) do
      if Code.ensure_loaded?(adapter) and function_exported?(adapter, :validate_config, 1) do
        adapter.validate_config(tracker_settings)
      else
        :ok
      end
    end
  end

  @spec prepare_config(map()) :: {:ok, map()} | {:error, term()}
  def prepare_config(%{kind: kind} = tracker_settings) do
    with {:ok, adapter} <- adapter_for_kind(kind) do
      if Code.ensure_loaded?(adapter) and function_exported?(adapter, :prepare_config, 1) do
        adapter.prepare_config(tracker_settings)
      else
        {:ok, tracker_settings}
      end
    end
  end

  @spec adapter() :: module()
  def adapter do
    Config.settings!().tracker
    |> adapter_for_settings!()
  end

  @spec adapter_for_kind(String.t()) :: {:ok, module()} | {:error, term()}
  def adapter_for_kind(kind) do
    case Map.fetch(@adapters, kind) do
      {:ok, adapter} -> {:ok, adapter}
      :error -> {:error, {:unsupported_tracker_kind, kind}}
    end
  end

  defp adapter_for_settings!(%{kind: kind}) do
    {:ok, adapter} = adapter_for_kind(kind)
    adapter
  end

  defp adapter_agent_tool_specs(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :agent_tool_specs, 0) do
      adapter.agent_tool_specs()
    else
      []
    end
  end

  defp execute_agent_tool_with_adapter(adapter, tool, arguments, opts) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :execute_agent_tool, 3) do
      adapter.execute_agent_tool(tool, arguments, opts)
    else
      unsupported_agent_tool_response(tool)
    end
  end

  defp adapter_secret_environment_names(adapter, tracker_settings) do
    adapter.secret_environment_names(tracker_settings)
  end

  defp unsupported_agent_tool_response(tool) do
    output =
      Jason.encode!(%{
        "error" => %{
          "message" => "Unsupported dynamic tool: #{inspect(tool)}.",
          "supportedTools" => []
        }
      })

    %{
      "success" => false,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end
end
