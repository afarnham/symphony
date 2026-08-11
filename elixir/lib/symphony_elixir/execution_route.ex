defmodule SymphonyElixir.ExecutionRoute do
  @moduledoc """
  Immutable backend and worker ownership resolved for one issue dispatch.
  """

  alias SymphonyElixir.Tracker.Issue

  @enforce_keys [:backend, :worker_hosts]
  defstruct [:profile, :ready_actor, :backend, :worker_hosts]

  @type t :: %__MODULE__{
          profile: String.t() | nil,
          ready_actor: String.t() | nil,
          backend: String.t(),
          worker_hosts: [String.t()]
        }

  @spec enabled?(map()) :: boolean()
  def enabled?(%{agent: %{routing: routing}}), do: not is_nil(routing)
  def enabled?(_settings), do: false

  @spec resolve(Issue.t(), map()) :: {:ok, t()} | {:error, term()}
  def resolve(%Issue{}, %{agent: %{routing: nil}} = settings) do
    {:ok,
     %__MODULE__{
       profile: nil,
       ready_actor: nil,
       backend: settings.agent.backend,
       worker_hosts: settings.worker.ssh_hosts
     }}
  end

  def resolve(%Issue{} = issue, %{agent: %{routing: routing}})
      when is_map(routing.profiles) do
    actor = normalize_login(issue.ready_actor_id)
    assignees = MapSet.new(issue.assignee_ids, &normalize_login/1)

    with :ok <- validate_ready_actor(actor, issue.ready_actor_automated),
         true <- MapSet.member?(assignees, actor) or {:error, {:ready_actor_not_assigned, actor}},
         {:ok, profile} <- fetch_profile(routing.profiles, actor),
         {:ok, backend} <- selected_backend(issue.requested_backend, profile) do
      {:ok,
       %__MODULE__{
         profile: actor,
         ready_actor: actor,
         backend: backend,
         worker_hosts: Map.fetch!(profile, "worker_hosts")
       }}
    end
  end

  def resolve(%Issue{}, _settings), do: {:error, :invalid_agent_routing_settings}

  defp validate_ready_actor("", _automated), do: {:error, :ready_actor_missing}
  defp validate_ready_actor(_actor, true), do: {:error, :ready_transition_automated}
  defp validate_ready_actor(_actor, false), do: :ok
  defp validate_ready_actor(_actor, _automated), do: {:error, :ready_transition_automation_unknown}

  defp fetch_profile(profiles, actor) do
    case Map.fetch(profiles, actor) do
      {:ok, profile} -> {:ok, profile}
      :error -> {:error, {:ready_actor_profile_not_found, actor}}
    end
  end

  defp selected_backend(nil, profile), do: {:ok, Map.fetch!(profile, "default_backend")}
  defp selected_backend("", profile), do: {:ok, Map.fetch!(profile, "default_backend")}
  defp selected_backend(backend, _profile) when backend in ["codex", "claude"], do: {:ok, backend}
  defp selected_backend(backend, _profile), do: {:error, {:unsupported_requested_backend, backend}}

  defp normalize_login(login) when is_binary(login),
    do: login |> String.trim() |> String.downcase()

  defp normalize_login(_login), do: ""
end
