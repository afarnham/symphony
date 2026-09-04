defmodule SymphonyElixir.AppTastemapWorkflowTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Workflow

  @workflow_path Path.expand(
                   "../../../deploy/workflows/app-tastemap.WORKFLOW.md",
                   __DIR__
                 )

  test "app-tastemap workflow installs the router and fails closed into explicit routes" do
    assert {:ok, %{config: config, prompt: prompt}} = Workflow.load(@workflow_path)

    assert get_in(config, ["hooks", "after_create"]) =~
             "pnpm install --frozen-lockfile"

    assert get_in(config, ["codex", "approval_policy"]) == "never"
    assert get_in(config, ["agent", "routing", "trusted_release_actors"]) == ["thor-claw"]

    assert prompt =~ "pnpm dive-graph -- route-ticket"
    assert prompt =~ "--ticket-file"
    refute prompt =~ "--issue <native_ref.issue_number>"
    assert prompt =~ "tracker_get_issue payload"
    assert prompt =~ "top-level `issue` object"
    assert prompt =~ "Do not unwrap"
    assert prompt =~ "native_ref.project_item_id"
    assert prompt =~ "SYMPHONY_ROUTE=generic"
    assert prompt =~ "SYMPHONY_ROUTE=wine-dive-graph"
    assert prompt =~ "SYMPHONY_ROUTE=dining-dive-graph"
    assert prompt =~ "must not fall through to generic implementation"
  end

  test "generic tickets use review while wine graph tickets keep one continuous claim" do
    assert {:ok, %{prompt: prompt}} = Workflow.load(@workflow_path)

    assert prompt =~ "For `SYMPHONY_ROUTE=generic`"
    assert prompt =~ "move the item to `In Review`"
    assert prompt =~ "For `SYMPHONY_ROUTE=wine-dive-graph`"
    assert prompt =~ "For `SYMPHONY_ROUTE=dining-dive-graph`"
    assert prompt =~ "Keep the Project item `In Progress` between band PRs"
    assert prompt =~ "pnpm dining-dive -- preflight"
    assert prompt =~ "pnpm dining-dive-dispatch -- ready --run-dir"
    assert prompt =~ "pnpm dining-dive-dispatch -- complete --run-dir"
    assert prompt =~ "run-codex"
    assert prompt =~ "run-claude"
    assert prompt =~ "pnpm dining-dive-publish -- record-receipt"
    assert prompt =~ "--tracker-managed"
    assert prompt =~ "<!-- dining-dive-closeout:<run-id> -->"
    assert prompt =~ ~s({"state":"closed"})
    assert prompt =~ "Issues permission on the worker credential"
    assert prompt =~ "requests squash auto-merge"
    assert prompt =~ "Never invent or estimate token counts"
    assert prompt =~ "pnpm dining-dive -- reopen-discovery"
    assert prompt =~ "git fetch --unshallow origin main"
    assert prompt =~ "git merge --ff-only origin/main"
    assert prompt =~ "archives the failed discovery artifact and receipt"
    assert prompt =~ "fail closed if another block reason is present"
    assert prompt =~ "Do not move it to `In Review`"
    assert prompt =~ "move the item to `Done`"
    assert prompt =~ "emit the input-required sentinel"
    assert prompt =~ "<!-- symphony:needs-input -->"
  end
end
