defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.{Codex.AppServer, Config}
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec rate_limits(Conn.t(), map()) :: Conn.t()
  def rate_limits(conn, params) do
    with {:ok, settings} <- Config.settings(),
         {:ok, worker_host} <- quota_worker_host(settings, params["profile"]),
         {:ok, limits} <- AppServer.read_rate_limits(settings: settings, worker_host: worker_host) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> json(%{
        profile: params["profile"],
        generated_at: DateTime.utc_now(),
        rate_limits: limits
      })
    else
      {:error, :unknown_profile} ->
        error_response(conn, 400, "unknown_profile", "Select a configured worker profile")

      _ ->
        error_response(conn, 503, "rate_limits_unavailable", "Fresh Codex quota is unavailable")
    end
  end

  defp quota_worker_host(%{agent: %{routing: %{profiles: profiles}}}, profile) do
    case Map.fetch(profiles, profile) do
      {:ok, %{"worker_hosts" => [host | _]}} -> {:ok, host}
      _ -> {:error, :unknown_profile}
    end
  end

  defp quota_worker_host(%{agent: %{routing: nil}, worker: %{ssh_hosts: hosts}}, nil) do
    {:ok, List.first(hosts)}
  end

  defp quota_worker_host(_, _), do: {:error, :unknown_profile}

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end
