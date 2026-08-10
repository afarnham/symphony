defmodule SymphonyElixir.TrackerToolBroker do
  @moduledoc """
  Binds and executes tracker tools independently of an agent backend.

  A binding snapshots the configured tracker adapter, its effective settings,
  advertised tool specifications, and secret environment names. Reusing that
  binding keeps one agent session stable across workflow reloads.
  """

  alias SymphonyElixir.{Config, Tracker}
  alias SymphonyElixir.Tracker.Issue

  @get_issue_tool "tracker_get_issue"
  @add_comment_tool "tracker_add_comment"
  @update_state_tool "tracker_update_state"

  @shared_tool_specs [
    %{
      "name" => @get_issue_tool,
      "description" => "Refresh the current tracker work item and its scheduler state.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{}
      }
    },
    %{
      "name" => @add_comment_tool,
      "description" => "Add a comment to the current tracker work item.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["body"],
        "properties" => %{
          "body" => %{"type" => "string", "minLength" => 1}
        }
      }
    },
    %{
      "name" => @update_state_tool,
      "description" => "Move the current tracker work item to an allowed workflow state.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["state"],
        "properties" => %{
          "state" => %{"type" => "string", "minLength" => 1}
        }
      }
    }
  ]

  @type binding :: %{
          required(:adapter) => module(),
          required(:tracker_settings) => map(),
          required(:tool_specs) => [map()],
          required(:secret_environment_names) => [String.t()],
          optional(:issue) => Issue.t()
        }

  @doc """
  Captures the effective tracker-tool configuration for one agent session.
  """
  @spec bind() :: binding()
  def bind, do: bind(Config.settings!().tracker)

  @doc false
  @spec bind(map()) :: binding()
  def bind(tracker_settings) when is_map(tracker_settings) do
    {:ok, adapter} = Tracker.adapter_for_kind(tracker_settings.kind)

    %{
      adapter: adapter,
      tracker_settings: tracker_settings,
      tool_specs: @shared_tool_specs ++ adapter_tool_specs(adapter),
      secret_environment_names: adapter.secret_environment_names(tracker_settings)
    }
  end

  @doc """
  Executes an advertised provider-native tool against a session binding.

  The bound tracker settings always replace caller-supplied settings so a
  workflow reload cannot change an active session's authority.
  """
  @spec execute(binding(), String.t() | nil, term(), keyword()) :: map()
  def execute(
        %{
          adapter: adapter,
          tracker_settings: tracker_settings
        } = binding,
        tool,
        arguments,
        opts \\ []
      ) do
    opts = Keyword.put_new(opts, :issue, binding[:issue])

    case tool do
      @get_issue_tool -> execute_get_issue(adapter, tracker_settings, arguments, opts)
      @add_comment_tool -> execute_add_comment(adapter, tracker_settings, arguments, opts)
      @update_state_tool -> execute_update_state(adapter, tracker_settings, arguments, opts)
      provider_tool -> execute_provider_tool(adapter, tracker_settings, provider_tool, arguments, opts)
    end
  end

  defp execute_get_issue(adapter, tracker_settings, arguments, opts) do
    with :ok <- require_object(arguments),
         {:ok, issue} <- bound_issue(opts),
         {:ok, [refreshed | _rest]} <- fetch_bound_issue(adapter, tracker_settings, issue) do
      success_response(%{"issue" => issue_payload(refreshed)})
    else
      {:ok, []} -> failure_response(:tracker_issue_not_found)
      {:error, reason} -> failure_response(reason)
    end
  end

  defp execute_add_comment(adapter, tracker_settings, %{"body" => body}, opts)
       when is_binary(body) do
    with body when body != "" <- String.trim(body),
         {:ok, issue} <- bound_issue(opts),
         true <- function_exported?(adapter, :add_issue_comment, 3),
         {:ok, response} <-
           adapter.add_issue_comment(
             issue,
             body,
             tracker_settings: tracker_settings
           ) do
      success_response(%{"issue" => issue_payload(issue), "comment" => response})
    else
      "" -> failure_response(:invalid_tracker_comment)
      false -> failure_response(:tracker_comment_not_supported)
      {:error, reason} -> failure_response(reason)
    end
  end

  defp execute_add_comment(_adapter, _tracker_settings, _arguments, _opts),
    do: failure_response(:invalid_tracker_comment)

  defp execute_update_state(adapter, tracker_settings, %{"state" => state}, opts)
       when is_binary(state) do
    with state when state != "" <- String.trim(state),
         {:ok, issue} <- bound_issue(opts),
         :ok <- allowed_state(tracker_settings, state),
         true <- function_exported?(adapter, :update_issue_state, 3),
         {:ok, refreshed} <-
           adapter.update_issue_state(
             issue,
             state,
             tracker_settings: tracker_settings
           ) do
      success_response(%{"issue" => issue_payload(refreshed)})
    else
      "" -> failure_response(:invalid_tracker_state)
      false -> failure_response(:tracker_state_update_not_supported)
      {:error, reason} -> failure_response(reason)
    end
  end

  defp execute_update_state(_adapter, _tracker_settings, _arguments, _opts),
    do: failure_response(:invalid_tracker_state)

  defp execute_provider_tool(adapter, tracker_settings, tool, arguments, opts) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :execute_agent_tool, 3) do
      adapter.execute_agent_tool(
        tool,
        arguments,
        Keyword.put(opts, :tracker_settings, tracker_settings)
      )
    else
      unsupported_tool_response(tool)
    end
  end

  defp fetch_bound_issue(adapter, tracker_settings, issue) do
    cond do
      function_exported?(adapter, :fetch_issues_by_ids, 2) ->
        adapter.fetch_issues_by_ids([issue.id], tracker_settings: tracker_settings)

      function_exported?(adapter, :fetch_issues_by_ids, 1) ->
        adapter.fetch_issues_by_ids([issue.id])

      true ->
        {:error, :tracker_issue_refresh_not_supported}
    end
  end

  defp bound_issue(opts) do
    case Keyword.get(opts, :issue) do
      %Issue{} = issue -> {:ok, issue}
      _ -> {:error, :missing_bound_tracker_issue}
    end
  end

  defp require_object(arguments) when is_map(arguments), do: :ok
  defp require_object(_arguments), do: {:error, :invalid_tracker_tool_arguments}

  defp allowed_state(tracker_settings, requested_state) do
    allowed_states =
      [
        Map.get(tracker_settings, :active_states, []),
        Map.get(tracker_settings, :terminal_states, []),
        [
          Map.get(tracker_settings, :working_state),
          Map.get(tracker_settings, :blocked_state),
          Map.get(tracker_settings, :completion_state)
        ]
      ]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)
      |> MapSet.new(&normalize_state/1)

    if MapSet.member?(allowed_states, normalize_state(requested_state)) do
      :ok
    else
      {:error, {:tracker_state_not_allowed, requested_state}}
    end
  end

  defp issue_payload(%Issue{} = issue) do
    %{
      "id" => issue.id,
      "identifier" => issue.identifier,
      "title" => issue.title,
      "description" => issue.description,
      "state" => issue.state,
      "url" => issue.url,
      "labels" => issue.labels,
      "dispatchable" => issue.dispatchable,
      "native_ref" => issue.native_ref
    }
  end

  defp success_response(payload), do: dynamic_tool_response(true, payload)
  defp failure_response(reason), do: dynamic_tool_response(false, %{"error" => format_error(reason)})

  defp dynamic_tool_response(success, payload) do
    output = Jason.encode!(payload)

    %{
      "success" => success,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end

  defp format_error(reason) do
    %{"message" => "Tracker tool execution failed.", "reason" => inspect(reason)}
  end

  defp normalize_state(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_state(_value), do: ""

  defp adapter_tool_specs(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :agent_tool_specs, 0) do
      adapter.agent_tool_specs()
    else
      []
    end
  end

  defp unsupported_tool_response(tool) do
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
