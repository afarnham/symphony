defmodule SymphonyElixir.Claude.StreamParserTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.{AgentEvent, AgentTurnResult}
  alias SymphonyElixir.Claude.StreamParser

  @fixture Path.expand("../fixtures/claude/stream_success.jsonl", __DIR__)

  test "normalizes session, text, reasoning, tools, actions, usage, and a successful result" do
    assert {:ok, %AgentTurnResult{} = result, events} =
             @fixture
             |> File.read!()
             |> StreamParser.parse(
               issue_id: "issue-123",
               turn_id: "turn-1",
               metadata: %{worker_host: nil, workspace_path: "/tmp/workspace"}
             )

    assert result.backend == :claude
    assert result.session_id == "session-123"
    assert result.turn_id == "turn-1"
    assert result.status == :completed
    assert result.final_text == "The implementation is complete."
    assert result.text_blocks == ["I am checking the issue.", "The implementation is complete."]
    assert result.input_tokens == 12
    assert result.cached_input_tokens == 6
    assert result.output_tokens == 7
    assert result.failure_text == nil
    assert result.failure_reason == nil
    refute result.input_required
    assert result.metadata.usage_source == :result
    assert result.metadata.native_usage["cache_creation_input_tokens"] == 7
    assert result.metadata.malformed_records == []

    assert %AgentEvent{
             kind: :session_started,
             backend: :claude,
             issue_id: "issue-123",
             session_id: "session-123",
             turn_id: "turn-1",
             timestamp: %DateTime{},
             payload: %{
               model: "claude-opus-4-6",
               permission_mode: "bypassPermissions",
               tools: ["Read", "mcp__symphony_tracker__tracker_get_issue"]
             },
             metadata: %{workspace_path: "/tmp/workspace"}
           } = List.first(events)

    assert Enum.any?(events, &match?(%AgentEvent{kind: :assistant_text}, &1))
    assert Enum.count(events, &match?(%AgentEvent{kind: :reasoning_update}, &1)) == 4

    assert Enum.any?(events, fn
             %AgentEvent{
               kind: :tool_call_started,
               payload: %{tool_use_id: "tool-1", input: %{"refresh" => true}}
             } ->
               true

             _ ->
               false
           end)

    assert Enum.any?(events, fn
             %AgentEvent{
               kind: :tool_call_completed,
               payload: %{tool_use_id: "tool-1", is_error: false}
             } ->
               true

             _ ->
               false
           end)

    assert Enum.count(events, &match?(%AgentEvent{kind: :action_started}, &1)) == 3
    assert Enum.count(events, &match?(%AgentEvent{kind: :action_completed}, &1)) == 2

    assert Enum.any?(events, fn
             %AgentEvent{
               kind: :reasoning_update,
               payload: %{
                 activity: "subagent_progress",
                 usage: %{"total_tokens" => 20, "tool_uses" => 2}
               }
             } ->
               true

             _ ->
               false
           end)

    assert Enum.any?(events, fn
             %AgentEvent{
               kind: :action_completed,
               payload: %{activity: "hook_response", outcome: "success", exit_code: 0}
             } ->
               true

             _ ->
               false
           end)

    assert List.last(events).kind == :turn_completed

    usage_events = Enum.filter(events, &match?(%AgentEvent{kind: :usage_updated}, &1))

    assert Enum.map(usage_events, & &1.payload.source) == [:messages, :messages, :result]

    assert Enum.map(usage_events, & &1.payload.usage) == [
             %{input_tokens: 10, cached_input_tokens: 5, output_tokens: 3},
             %{input_tokens: 12, cached_input_tokens: 6, output_tokens: 7},
             %{input_tokens: 12, cached_input_tokens: 6, output_tokens: 7}
           ]

    assert Enum.all?(usage_events, &(&1.payload.accounting == :absolute))
    assert List.last(usage_events).payload.native["cache_creation_input_tokens"] == 7
  end

  test "buffers partial and CRLF-delimited records and accepts a final line without newline" do
    init =
      Jason.encode!(%{
        "type" => "system",
        "subtype" => "init",
        "session_id" => "partial-session"
      })

    assistant =
      Jason.encode!(%{
        "type" => "assistant",
        "session_id" => "partial-session",
        "message" => %{
          "content" => [%{"type" => "text", "text" => "partial text"}],
          "usage" => %{"input_tokens" => 3}
        }
      })

    result =
      Jason.encode!(%{
        "type" => "result",
        "subtype" => "success",
        "is_error" => false,
        "result" => "done",
        "session_id" => "partial-session"
      })

    state = StreamParser.new(turn_id: "partial-turn")
    split_at = div(byte_size(init), 2)
    <<first::binary-size(split_at), second::binary>> = init

    assert {:ok, state, []} = StreamParser.push(state, first)
    assert state.buffer == first
    assert {:ok, state, [%AgentEvent{kind: :session_started}]} = StreamParser.push(state, second <> "\r\n")

    assert {:ok, state, events} = StreamParser.push(state, assistant <> "\r\n" <> result)
    assert Enum.map(events, & &1.kind) == [:assistant_text, :usage_updated]

    assert {:ok, turn_result, [%AgentEvent{kind: :turn_completed}]} = StreamParser.finish(state)
    assert turn_result.session_id == "partial-session"
    assert turn_result.final_text == "done"
    assert turn_result.input_tokens == 3
    assert turn_result.cached_input_tokens == nil
    assert turn_result.output_tokens == nil
    assert turn_result.metadata.usage_source == :messages
  end

  test "deduplicates repeated message usage before a terminal result without usage" do
    stream =
      json_lines([
        %{"type" => "system", "subtype" => "init", "session_id" => "dedupe"},
        assistant_record("dedupe", "same-message", %{"input_tokens" => 4, "output_tokens" => 2}),
        assistant_record("dedupe", "same-message", %{"input_tokens" => 5, "output_tokens" => 3}),
        assistant_record("dedupe", nil, %{"cache_read_input_tokens" => 7}),
        %{
          "type" => "result",
          "subtype" => "success",
          "is_error" => false,
          "session_id" => "dedupe",
          "result" => "ok"
        }
      ])

    assert {:ok, result, events} = StreamParser.parse(stream)
    assert result.input_tokens == 5
    assert result.cached_input_tokens == 7
    assert result.output_tokens == 3
    assert result.metadata.usage_source == :messages

    usage_events = Enum.filter(events, &match?(%AgentEvent{kind: :usage_updated}, &1))
    assert List.last(usage_events).payload.usage == %{input_tokens: 5, cached_input_tokens: 7, output_tokens: 3}
  end

  test "classifies explicit approval errors and the standalone sentinel as input required" do
    explicit_error =
      json_lines([
        %{"type" => "system", "subtype" => "init", "session_id" => "blocked-1"},
        %{
          "type" => "result",
          "subtype" => "error_during_execution",
          "is_error" => true,
          "session_id" => "blocked-1",
          "error" => %{"message" => "Interactive confirmation requires user input"}
        }
      ])

    assert {:ok, explicit_result, explicit_events} = StreamParser.parse(explicit_error)
    assert explicit_result.status == :blocked
    assert explicit_result.input_required
    assert explicit_result.failure_text == "Interactive confirmation requires user input"
    assert explicit_result.failure_reason.type == :input_required
    assert List.last(explicit_events).kind == :input_required

    current_cli_error =
      json_lines([
        %{
          "type" => "result",
          "subtype" => "error_during_execution",
          "is_error" => true,
          "session_id" => "blocked-errors-array",
          "errors" => ["Approval required", "Waiting for user"]
        }
      ])

    assert {:ok, array_result, _events} = StreamParser.parse(current_cli_error)
    assert array_result.status == :blocked
    assert array_result.failure_text == "Approval required\nWaiting for user"
    assert array_result.failure_reason.errors == ["Approval required", "Waiting for user"]

    sentinel =
      json_lines([
        %{"type" => "system", "subtype" => "init", "session_id" => "blocked-2"},
        %{
          "type" => "assistant",
          "session_id" => "blocked-2",
          "message" => %{
            "content" => [
              %{
                "type" => "text",
                "text" => "```html\n<!-- symphony:needs-input -->\n```\n<!-- symphony:needs-input -->\nWhich project?"
              }
            ]
          }
        },
        %{
          "type" => "result",
          "subtype" => "success",
          "is_error" => false,
          "session_id" => "blocked-2",
          "result" => "Which project?"
        }
      ])

    assert {:ok, sentinel_result, sentinel_events} = StreamParser.parse(sentinel)
    assert sentinel_result.status == :blocked
    assert sentinel_result.failure_text == "Which project?"
    assert List.last(sentinel_events).kind == :input_required
  end

  test "does not treat a sentinel example inside tilde fences as input required" do
    stream =
      json_lines([
        %{"type" => "system", "subtype" => "init", "session_id" => "not-blocked"},
        %{
          "type" => "assistant",
          "session_id" => "not-blocked",
          "message" => %{
            "content" => [
              %{"type" => "text", "text" => "~~~html\n<!-- symphony:needs-input -->\n~~~"}
            ]
          }
        },
        %{
          "type" => "result",
          "subtype" => "success",
          "is_error" => false,
          "session_id" => "not-blocked",
          "result" => "done"
        }
      ])

    assert {:ok, result, _events} = StreamParser.parse(stream)
    assert result.status == :completed
  end

  test "normalizes failed results and error payload variants" do
    for {error, expected_text} <- [
          {"plain failure", "plain failure"},
          {%{"code" => "bad_request"}, ~s(%{"code" => "bad_request"})},
          {nil, "fallback failure"}
        ] do
      record = %{
        "type" => "result",
        "subtype" => "error_during_execution",
        "is_error" => true,
        "session_id" => "failed",
        "result" => "fallback failure",
        "error" => error
      }

      assert {:ok, result, events} = StreamParser.parse(json_lines([record]))
      assert result.status == :failed
      assert result.failure_text == expected_text
      assert result.failure_reason.type == :claude_result_error
      assert List.last(events).kind == :turn_failed
    end

    errors_array =
      json_lines([
        %{
          "type" => "result",
          "subtype" => "error_max_turns",
          "is_error" => true,
          "session_id" => "failed-errors-array",
          "errors" => ["Maximum turns reached", "", 42]
        }
      ])

    assert {:ok, result, _events} = StreamParser.parse(errors_array)
    assert result.failure_text == "Maximum turns reached"

    blank_errors =
      json_lines([
        %{
          "type" => "result",
          "subtype" => "error_max_turns",
          "is_error" => true,
          "session_id" => "failed-blank-errors",
          "result" => "fallback",
          "errors" => ["", 42]
        }
      ])

    assert {:ok, result, _events} = StreamParser.parse(blank_errors)
    assert result.failure_text == "fallback"
  end

  test "tolerates bounded non-critical malformed records with redacted context" do
    stream =
      [
        ~s({"noise":"Bearer top-secret","token":"also-secret"),
        ~s({"type":"system","subtype":"status","padding":"#{String.duplicate("x", 100)}"),
        Jason.encode!(%{"type" => "result", "subtype" => "error_during_execution", "is_error" => true})
      ]
      |> Enum.join("\n")
      |> Kernel.<>("\n")

    log =
      capture_log(fn ->
        assert {:ok, result, _events} =
                 StreamParser.parse(stream,
                   max_malformed_records: 2,
                   max_malformed_context_bytes: 48
                 )

        assert length(result.metadata.malformed_records) == 2

        assert Enum.all?(result.metadata.malformed_records, fn diagnostic ->
                 byte_size(diagnostic.context) <= 48
               end)

        assert hd(result.metadata.malformed_records).context =~ "[REDACTED]"
        refute hd(result.metadata.malformed_records).context =~ "top-secret"

        assert {:ok, tiny_context_result, _events} =
                 StreamParser.parse("not-json\n" <> terminal_error("tiny-context"),
                   max_malformed_context_bytes: 5
                 )

        assert hd(tiny_context_result.metadata.malformed_records).context == "...<t"
      end)

    assert log =~ "Skipping malformed Claude stream record"
    refute log =~ "top-secret"
  end

  test "rejects too many malformed records and malformed required records" do
    assert {:error, {:too_many_malformed_records, 1}, []} =
             StreamParser.parse("not-json\n", max_malformed_records: 0)

    assert {:error, {:malformed_required_record, 1, :result, _context}, []} =
             StreamParser.parse(~s({"type":"result","is_error":false\n))

    assert {:error, {:malformed_required_record, 1, :session, _context}, []} =
             StreamParser.parse(~s({"type":"system","subtype":"init","session_id":\n))
  end

  test "treats non-object JSON as malformed and ignores a whitespace-only final buffer" do
    assert {:error, :missing_terminal_result, []} =
             StreamParser.parse("[]\n   ", max_malformed_records: 1)
  end

  test "rejects oversize complete and partial records" do
    assert {:error, {:line_too_long, 1, 6}, []} =
             StreamParser.parse("123456\n", max_line_bytes: 5)

    state = StreamParser.new(max_line_bytes: 5)

    assert {:error, {:line_too_long, 1, 6}, _state, []} =
             StreamParser.push(state, "123456")

    state = StreamParser.new(max_line_bytes: 5)
    assert {:ok, state, []} = StreamParser.push(state, "12345")
    assert {:error, {:line_too_long, 1, 6}, []} = StreamParser.finish(%{state | buffer: "123456"})
  end

  test "rejects invalid parser bounds" do
    assert_raise ArgumentError, ~r/max_line_bytes must be a positive integer/, fn ->
      StreamParser.new(max_line_bytes: 0)
    end

    assert_raise ArgumentError, ~r/max_malformed_records must be a non-negative integer/, fn ->
      StreamParser.new(max_malformed_records: -1)
    end

    assert_raise ArgumentError, ~r/max_malformed_context_bytes must be a positive integer/, fn ->
      StreamParser.new(max_malformed_context_bytes: :unbounded)
    end
  end

  test "rejects session identity changes and records after a terminal result" do
    stream =
      json_lines([
        %{"type" => "system", "subtype" => "init", "session_id" => "first"},
        %{"type" => "assistant", "session_id" => "second", "message" => %{}}
      ])

    assert {:error, {:session_id_mismatch, "first", "second"}, [%AgentEvent{kind: :session_started}]} =
             StreamParser.parse(stream)

    state = StreamParser.new()
    terminal = Jason.encode!(%{"type" => "result", "subtype" => "error_during_execution", "is_error" => true})
    assert {:ok, state, [%AgentEvent{kind: :turn_failed}]} = StreamParser.push(state, terminal <> "\n")
    assert {:error, :stream_already_terminated, ^state, []} = StreamParser.push(state, "ignored")

    two_records = terminal <> "\n" <> Jason.encode!(%{"type" => "unknown"}) <> "\n"

    assert {:error, :record_after_terminal_result, [%AgentEvent{kind: :turn_failed}]} =
             StreamParser.parse(two_records)
  end

  test "requires init session identity for successful turns and a terminal result at EOF" do
    success =
      Jason.encode!(%{"type" => "result", "subtype" => "success", "is_error" => false, "result" => "done"})

    assert {:error, :missing_session_id, [%AgentEvent{kind: :turn_completed}]} =
             StreamParser.parse(success <> "\n")

    assert {:error, :missing_session_id, []} =
             StreamParser.parse(~s({"type":"system","subtype":"init"}\n))

    assert {:error, :missing_session_id, []} =
             StreamParser.parse(~s({"type":"system","subtype":"init","session_id":"  "}\n))

    init = Jason.encode!(%{"type" => "system", "subtype" => "init", "session_id" => "no-result"})

    assert {:error, :missing_terminal_result, [%AgentEvent{kind: :session_started}]} =
             StreamParser.parse(init <> "\n")

    assert {:error, {:incomplete_record, 1, _context}, []} = StreamParser.parse(~s({"type":"assistant"))
  end

  test "ignores unknown records, blank lines, unsupported blocks, and invalid usage values" do
    stream =
      "\n" <>
        json_lines([
          %{"type" => "system", "subtype" => "init", "session_id" => "unknowns"},
          %{"type" => "system", "subtype" => "status", "session_id" => "unknowns"},
          %{"type" => "unknown", "session_id" => "unknowns"},
          %{"type" => "user", "session_id" => "unknowns", "message" => "invalid"},
          %{
            "type" => "assistant",
            "session_id" => "unknowns",
            "message" => %{
              "content" => [%{"type" => "image"}, "not-a-map"],
              "usage" => %{"input_tokens" => -1, "output_tokens" => "3"}
            }
          },
          %{
            "type" => "user",
            "session_id" => "unknowns",
            "message" => %{
              "content" => [
                %{"type" => "tool_result", "tool_use_id" => "bad", "is_error" => true},
                %{"type" => "text", "text" => "ignored"}
              ]
            }
          },
          %{
            "type" => "result",
            "subtype" => "success",
            "is_error" => false,
            "session_id" => "unknowns",
            "usage" => %{},
            "result" => "done"
          }
        ])

    assert {:ok, result, events} = StreamParser.parse(stream)
    assert result.input_tokens == nil
    assert result.cached_input_tokens == nil
    assert result.output_tokens == nil
    assert Enum.map(events, & &1.kind) == [:session_started, :tool_call_completed, :turn_completed]
    assert Enum.at(events, 1).payload.is_error
  end

  test "maps atom-key cached token usage and nil collections safely" do
    state = StreamParser.new(backend: :custom)

    init = %{
      "type" => "system",
      "subtype" => "init",
      "session_id" => "atoms",
      "tools" => nil,
      "mcp_servers" => nil
    }

    assistant = %{
      "type" => "assistant",
      "session_id" => "atoms",
      "message" => %{
        "id" => "atoms-message",
        "content" => nil,
        "usage" => %{input_tokens: 1, cached_input_tokens: 2, output_tokens: 3}
      }
    }

    result = %{
      "type" => "result",
      "subtype" => "success",
      "is_error" => false,
      "session_id" => "atoms",
      "result" => "ok"
    }

    assert {:ok, state, events} = StreamParser.push(state, json_lines([init, assistant, result]))
    assert List.first(events).backend == :custom
    assert {:ok, result, []} = StreamParser.finish(state)
    assert {result.input_tokens, result.cached_input_tokens, result.output_tokens} == {1, 2, 3}
  end

  defp assistant_record(session_id, message_id, usage) do
    %{
      "type" => "assistant",
      "session_id" => session_id,
      "message" => %{"id" => message_id, "content" => [], "usage" => usage}
    }
  end

  defp json_lines(records) do
    Enum.map_join(records, "", &(Jason.encode!(&1) <> "\n"))
  end

  defp terminal_error(session_id) do
    Jason.encode!(%{
      "type" => "result",
      "subtype" => "error_during_execution",
      "is_error" => true,
      "session_id" => session_id
    }) <> "\n"
  end
end
