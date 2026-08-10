defmodule SymphonyElixir.TrackerMCP.Router do
  @moduledoc false

  @behaviour Plug

  import Plug.Conn

  alias SymphonyElixir.TrackerMCP.Server

  @json_content_type "application/json"

  @impl true
  def init(opts) do
    %{
      server: Keyword.fetch!(opts, :server),
      max_body_bytes: Keyword.fetch!(opts, :max_body_bytes)
    }
  end

  @impl true
  def call(conn, opts) do
    conn = put_common_headers(conn)

    cond do
      not loopback?(conn.remote_ip) ->
        json_error(conn, 403, "forbidden")

      not allowed_origin?(get_req_header(conn, "origin")) ->
        json_error(conn, 403, "forbidden")

      conn.method == "GET" and conn.request_path == "/health" ->
        serve_health(conn, opts)

      conn.request_path == "/mcp" ->
        serve_mcp(conn, opts)

      true ->
        json_error(conn, 404, "not_found")
    end
  end

  defp serve_health(conn, opts) do
    with {:ok, token} <- bearer_token(conn),
         :ok <- safe_server_call(fn -> Server.health(opts.server, credential_digest(token), scope_identity(conn)) end) do
      json_response(conn, 200, %{"status" => "ok"})
    else
      {:error, reason} -> authorization_error(conn, reason)
    end
  end

  defp serve_mcp(%Plug.Conn{method: "POST"} = conn, opts) do
    with {:ok, token} <- bearer_token(conn),
         credential_digest = credential_digest(token),
         :ok <- safe_server_call(fn -> Server.health(opts.server, credential_digest, scope_identity(conn)) end),
         :ok <- require_json_content_type(conn),
         {:ok, body, conn} <- read_bounded_body(conn, opts.max_body_bytes),
         {:ok, request} <- decode_request(body),
         :ok <- validate_mcp_headers(conn, request),
         result <- safe_server_call(fn -> Server.rpc(opts.server, credential_digest, scope_identity(conn), request) end) do
      rpc_response(conn, result, opts.server)
    else
      {:error, :payload_too_large, conn} -> json_error(close_connection(conn), 413, "payload_too_large")
      {:error, :invalid_content_type} -> json_error(conn, 415, "unsupported_media_type")
      {:error, :invalid_json} -> json_rpc_error(conn, 400, nil, -32_700, "Parse error.")
      {:error, :invalid_request} -> json_rpc_error(conn, 400, nil, -32_600, "Invalid Request.")
      {:error, :invalid_mcp_headers} -> json_error(conn, 400, "invalid_mcp_headers")
      {:error, reason} -> authorization_error(conn, reason)
    end
  end

  defp serve_mcp(conn, opts) when conn.method in ["GET", "DELETE"] do
    with {:ok, token} <- bearer_token(conn),
         :ok <-
           safe_server_call(fn ->
             Server.authorize_transport(opts.server, credential_digest(token), scope_identity(conn))
           end) do
      conn
      |> put_resp_header("allow", "POST")
      |> json_error(405, "method_not_allowed")
    else
      {:error, reason} -> authorization_error(conn, reason)
    end
  end

  defp serve_mcp(conn, opts) do
    with {:ok, token} <- bearer_token(conn),
         :ok <-
           safe_server_call(fn ->
             Server.authorize_transport(opts.server, credential_digest(token), scope_identity(conn))
           end) do
      conn
      |> put_resp_header("allow", "POST")
      |> json_error(405, "method_not_allowed")
    else
      {:error, reason} -> authorization_error(conn, reason)
    end
  end

  defp rpc_response(conn, {:response, response, headers}, _server) do
    conn = Enum.reduce(headers, conn, fn {name, value}, acc -> put_resp_header(acc, name, value) end)
    json_response(conn, 200, response)
  end

  defp rpc_response(conn, {:execute, execution_ref, timeout_ms}, server) do
    case Server.await_execution(server, execution_ref, timeout_ms) do
      {:ok, response} -> json_response(conn, 200, response)
      {:error, reason} -> json_error(conn, 503, Atom.to_string(reason))
    end
  end

  defp rpc_response(conn, :accepted, _server), do: send_resp(conn, 202, "")
  defp rpc_response(conn, {:error, reason}, _server), do: authorization_error(conn, reason)

  defp authorization_error(conn, reason) when reason in [:unauthorized, :expired] do
    conn
    |> put_resp_header("www-authenticate", ~s(Bearer realm="symphony_tracker"))
    |> json_error(401, "unauthorized")
  end

  defp authorization_error(conn, :scope_mismatch), do: json_error(conn, 403, "forbidden")
  defp authorization_error(conn, :missing_session), do: json_error(conn, 400, "missing_mcp_session")
  defp authorization_error(conn, :unknown_session), do: json_error(conn, 404, "unknown_mcp_session")
  defp authorization_error(conn, :server_stopped), do: json_error(conn, 503, "server_stopped")
  defp authorization_error(conn, _reason), do: json_error(conn, 401, "unauthorized")

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      [authorization] -> parse_bearer_token(authorization)
      _headers -> {:error, :unauthorized}
    end
  end

  defp parse_bearer_token(authorization) do
    case String.split(authorization, " ", parts: 2) do
      [scheme, token] when byte_size(token) > 0 ->
        if String.downcase(scheme) == "bearer", do: {:ok, token}, else: {:error, :unauthorized}

      _parts ->
        {:error, :unauthorized}
    end
  end

  defp require_json_content_type(conn) do
    case get_req_header(conn, "content-type") do
      [content_type] ->
        media_type =
          content_type
          |> String.split(";", parts: 2)
          |> hd()
          |> String.trim()
          |> String.downcase()

        if media_type == "application/json" do
          :ok
        else
          {:error, :invalid_content_type}
        end

      _headers ->
        {:error, :invalid_content_type}
    end
  end

  defp read_bounded_body(conn, maximum) do
    case content_length(conn) do
      length when is_integer(length) and length > maximum ->
        {:error, :payload_too_large, conn}

      _length ->
        case read_body(conn, length: maximum, read_length: maximum) do
          {:ok, body, conn} -> {:ok, body, conn}
          {:more, _partial, conn} -> {:error, :payload_too_large, conn}
          {:error, _reason} -> {:error, :invalid_json}
        end
    end
  end

  defp content_length(conn) do
    case get_req_header(conn, "content-length") do
      [value] ->
        case Integer.parse(value) do
          {length, ""} when length >= 0 -> length
          _invalid -> nil
        end

      _headers ->
        nil
    end
  end

  defp decode_request(body) do
    case Jason.decode(body) do
      {:ok, request} when is_map(request) -> {:ok, request}
      {:ok, _request} -> {:error, :invalid_request}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp validate_mcp_headers(conn, request) do
    method = Map.get(request, "method")
    name = get_in(request, ["params", "name"])

    if header_matches_if_present?(conn, "mcp-method", method) and
         header_matches_if_present?(conn, "mcp-name", name) do
      :ok
    else
      {:error, :invalid_mcp_headers}
    end
  end

  defp header_matches_if_present?(conn, header, expected) do
    case get_req_header(conn, header) do
      [] -> true
      [actual] when is_binary(expected) -> actual == expected
      _headers -> false
    end
  end

  defp scope_identity(conn) do
    %{
      issue_id: single_header(conn, "x-symphony-issue-id"),
      backend: single_header(conn, "x-symphony-backend"),
      backend_session_id: single_header(conn, "x-symphony-backend-session-id"),
      session_id: single_header(conn, "mcp-session-id")
    }
  end

  defp single_header(conn, name) do
    case get_req_header(conn, name) do
      [value] -> value
      [] -> nil
      _headers -> :invalid
    end
  end

  defp allowed_origin?([]), do: true

  defp allowed_origin?([origin]) do
    case URI.parse(origin) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] ->
        String.downcase(host || "") in ["localhost", "127.0.0.1", "::1"]

      _uri ->
        false
    end
  end

  defp allowed_origin?(_origins), do: false

  defp loopback?({127, _second, _third, _fourth}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_remote_ip), do: false

  defp put_common_headers(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
  end

  defp close_connection(conn), do: put_resp_header(conn, "connection", "close")

  defp credential_digest(token), do: :crypto.hash(:sha256, token)

  defp safe_server_call(fun) do
    fun.()
  catch
    :exit, _reason -> {:error, :server_stopped}
  end

  defp json_error(conn, status, code) do
    json_response(conn, status, %{"error" => code})
  end

  defp json_rpc_error(conn, status, id, code, message) do
    json_response(conn, status, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message}
    })
  end

  defp json_response(conn, status, payload) do
    body = Jason.encode!(payload)

    conn
    |> put_resp_content_type(@json_content_type)
    |> send_resp(status, body)
  end
end
