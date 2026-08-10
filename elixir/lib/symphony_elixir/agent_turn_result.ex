defmodule SymphonyElixir.AgentTurnResult do
  @moduledoc """
  Backend-neutral terminal result for one agent turn.

  Unknown usage values remain `nil`. Backends must not convert unavailable
  token counts to zero.
  """

  @type status :: :completed | :failed | :blocked

  defstruct [
    :backend,
    :session_id,
    :turn_id,
    :status,
    :final_text,
    :input_tokens,
    :cached_input_tokens,
    :output_tokens,
    :failure_text,
    :failure_reason,
    text_blocks: [],
    input_required: false,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          backend: atom() | nil,
          session_id: String.t() | nil,
          turn_id: String.t() | nil,
          status: status() | nil,
          final_text: String.t() | nil,
          text_blocks: [String.t()],
          input_tokens: non_neg_integer() | nil,
          cached_input_tokens: non_neg_integer() | nil,
          output_tokens: non_neg_integer() | nil,
          failure_text: String.t() | nil,
          failure_reason: term(),
          input_required: boolean(),
          metadata: map()
        }
end
