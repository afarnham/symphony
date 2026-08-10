defmodule SymphonyElixir.TrackerMCP.Handle do
  @moduledoc """
  Opaque lifecycle handle for a session-scoped tracker MCP server.

  The bearer token is intentionally omitted from inspected output.
  """

  @enforce_keys [:pid, :url, :token, :issue_id, :backend, :session_id, :tool_names]
  defstruct [:pid, :url, :token, :issue_id, :backend, :session_id, :tool_names]

  @type t :: %__MODULE__{
          pid: pid(),
          url: String.t(),
          token: String.t(),
          issue_id: String.t(),
          backend: String.t(),
          session_id: String.t(),
          tool_names: [String.t()]
        }
end

defimpl Inspect, for: SymphonyElixir.TrackerMCP.Handle do
  import Inspect.Algebra

  @spec inspect(SymphonyElixir.TrackerMCP.Handle.t(), Inspect.Opts.t()) :: Inspect.Algebra.t()
  def inspect(handle, opts) do
    fields = [
      pid: handle.pid,
      url: handle.url,
      token: "[REDACTED]",
      issue_id: handle.issue_id,
      backend: handle.backend,
      session_id: handle.session_id,
      tool_names: handle.tool_names
    ]

    concat(["#TrackerMCP.Handle<", to_doc(fields, opts), ">"])
  end
end
