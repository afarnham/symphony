defmodule SymphonyElixir.AgentEvent do
  @moduledoc """
  Backend-neutral activity emitted while an agent session runs.

  Backends translate their native protocols into these events before handing
  activity to the orchestrator or observability layers.
  """

  @type kind ::
          :session_started
          | :turn_started
          | :assistant_text
          | :reasoning_update
          | :action_started
          | :action_completed
          | :tool_call_started
          | :tool_call_completed
          | :usage_updated
          | :input_required
          | :turn_completed
          | :turn_failed
          | :backend_message
          | :session_stopped

  defstruct [
    :kind,
    :backend,
    :issue_id,
    :session_id,
    :turn_id,
    :timestamp,
    payload: %{},
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          kind: kind() | nil,
          backend: atom() | nil,
          issue_id: String.t() | nil,
          session_id: String.t() | nil,
          turn_id: String.t() | nil,
          timestamp: DateTime.t() | nil,
          payload: map(),
          metadata: map()
        }
end
