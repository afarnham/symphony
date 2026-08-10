defmodule SymphonyElixir.AgentBackend do
  @moduledoc """
  Backend-neutral boundary for agent session lifecycle and turns.

  The registry is static so workflow values never create atoms dynamically.
  """

  alias SymphonyElixir.{AgentTurnResult, TrackerToolBroker}
  alias SymphonyElixir.Tracker.Issue

  @type session :: term()
  @type tool_session :: map() | nil

  @callback name() :: atom()
  @callback validate_config(map()) :: :ok | {:error, term()}
  @callback validate_host(map(), String.t() | nil) :: :ok | {:error, term()}
  @callback start_session(Path.t(), Issue.t(), tool_session(), keyword()) ::
              {:ok, session()} | {:error, term()}
  @callback run_turn(session(), String.t(), Issue.t(), keyword()) ::
              {:ok, AgentTurnResult.t(), session()}
              | {:blocked, AgentTurnResult.t(), session()}
              | {:error, term(), session()}
  @callback stop_session(session(), term()) :: :ok | {:error, term()}

  @registry %{
    "codex" => SymphonyElixir.AgentBackend.Codex,
    "claude" => SymphonyElixir.AgentBackend.Claude
  }

  @spec resolve(map() | String.t()) :: {:ok, module()} | {:error, term()}
  def resolve(%{agent: %{backend: backend}}), do: resolve(backend)

  def resolve(backend) when is_binary(backend) do
    case Map.fetch(@registry, backend) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, {:unsupported_agent_backend, backend}}
    end
  end

  def resolve(backend), do: {:error, {:unsupported_agent_backend, backend}}

  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(settings) when is_map(settings) do
    with {:ok, backend} <- resolve(settings) do
      backend.validate_config(settings)
    end
  end

  @spec bind_tracker_tools(Issue.t(), map()) :: map()
  def bind_tracker_tools(%Issue{} = issue, tracker_settings) when is_map(tracker_settings) do
    TrackerToolBroker.bind(tracker_settings)
    |> Map.put(:issue, issue)
  end
end
