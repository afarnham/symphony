defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Adapts backend-neutral tracker tool bindings to the Codex app-server protocol.
  """

  alias SymphonyElixir.TrackerToolBroker

  @spec execute(String.t() | nil, term(), TrackerToolBroker.binding(), keyword()) :: map()
  def execute(tool, arguments, binding, opts \\ []) do
    TrackerToolBroker.execute(binding, tool, arguments, opts)
  end

  @spec bind() :: TrackerToolBroker.binding()
  def bind do
    TrackerToolBroker.bind()
  end
end
