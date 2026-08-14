defmodule SymphonyElixir.AppTastemapWorkflowTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Workflow

  @workflow_path Path.expand(
                   "../../../deploy/examples/app-tastemap.WORKFLOW.md",
                   __DIR__
                 )

  test "app-tastemap workflow installs the router and fails closed into explicit routes" do
    assert {:ok, %{config: config, prompt: prompt}} = Workflow.load(@workflow_path)

    assert get_in(config, ["hooks", "after_create"]) =~
             "pnpm install --frozen-lockfile"

    assert prompt =~ "pnpm wine-dive -- route-ticket"
    assert prompt =~ "native_ref.issue_number"
    assert prompt =~ "native_ref.project_item_id"
    assert prompt =~ "SYMPHONY_ROUTE=generic"
    assert prompt =~ "SYMPHONY_ROUTE=wine-dive-graph"
    assert prompt =~ "must not fall through to generic implementation"
  end

  test "generic tickets use review while wine graph tickets keep one continuous claim" do
    assert {:ok, %{prompt: prompt}} = Workflow.load(@workflow_path)

    assert prompt =~ "For `SYMPHONY_ROUTE=generic`"
    assert prompt =~ "move the item to `In Review`"
    assert prompt =~ "For `SYMPHONY_ROUTE=wine-dive-graph`"
    assert prompt =~ "Keep the Project item `In Progress` between band PRs"
    assert prompt =~ "move the item to `Done`"
    assert prompt =~ "emit the input-required sentinel"
  end
end
