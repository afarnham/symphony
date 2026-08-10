defmodule SymphonyElixir.SecretTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Secret

  @environment_names [
    "SYMPHONY_TEST_SECRET",
    "SYMPHONY_TEST_SECRET_FILE",
    "SYMPHONY_UNCONFIGURED_SECRET",
    "SYMPHONY_UNCONFIGURED_SECRET_FILE"
  ]

  setup do
    previous = Map.new(@environment_names, &{&1, System.get_env(&1)})
    Enum.each(@environment_names, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  test "resolves literal, environment, and file references" do
    path = temporary_secret!("file-secret\n")

    assert Secret.resolve("literal-secret") == "literal-secret"

    System.put_env("SYMPHONY_TEST_SECRET", "environment-secret")
    assert Secret.resolve("$SYMPHONY_TEST_SECRET") == "environment-secret"

    assert Secret.resolve("file://#{path}") == "file-secret"
  end

  test "uses the _FILE convention only when the value environment variable is unset" do
    path = temporary_secret!("file-secret")
    System.put_env("SYMPHONY_TEST_SECRET_FILE", path)

    assert Secret.resolve(nil, "SYMPHONY_TEST_SECRET") == "file-secret"
    assert Secret.resolve("$SYMPHONY_TEST_SECRET") == "file-secret"

    System.put_env("SYMPHONY_TEST_SECRET", "direct-secret")
    assert Secret.resolve("$SYMPHONY_TEST_SECRET") == "direct-secret"

    System.put_env("SYMPHONY_TEST_SECRET", "")
    assert Secret.resolve("$SYMPHONY_TEST_SECRET") == nil
  end

  test "falls back only when an explicit environment reference is entirely unconfigured" do
    System.put_env("SYMPHONY_TEST_SECRET", "fallback-secret")

    assert Secret.resolve("$SYMPHONY_UNCONFIGURED_SECRET", "SYMPHONY_TEST_SECRET") ==
             "fallback-secret"

    System.put_env("SYMPHONY_UNCONFIGURED_SECRET_FILE", "/does/not/exist")

    assert Secret.resolve("$SYMPHONY_UNCONFIGURED_SECRET", "SYMPHONY_TEST_SECRET") == nil
  end

  test "fails closed for unsafe, unreadable, invalid, or oversized files" do
    relative_path = "relative-secret"
    directory = Path.dirname(temporary_secret!("unused"))
    oversized = temporary_secret!(String.duplicate("x", 65_537))
    nul_value = temporary_secret!("before\0after")

    assert Secret.resolve("file:#{relative_path}") == nil
    assert Secret.resolve("file:") == nil
    assert Secret.resolve("file://remote-host/secret") == nil
    assert Secret.resolve("file://#{directory}") == nil
    assert Secret.resolve("file:///does/not/exist") == nil
    assert Secret.resolve("file://#{oversized}") == nil
    assert Secret.resolve("file://#{nul_value}") == nil
    assert Secret.resolve("$INVALID-NAME") == nil
  end

  test "returns nil when neither a default environment value nor its file fallback is configured" do
    assert Secret.resolve(nil, "SYMPHONY_UNCONFIGURED_SECRET") == nil
  end

  test "expands secret environment names to include their file counterparts" do
    assert Secret.environment_names(["GITHUB_TOKEN", "GITHUB_TOKEN", "INVALID-NAME"]) == [
             "GITHUB_TOKEN",
             "GITHUB_TOKEN_FILE"
           ]

    assert Secret.reference_environment_names(["$CUSTOM_TOKEN", "literal", nil]) == [
             "CUSTOM_TOKEN",
             "CUSTOM_TOKEN_FILE"
           ]
  end

  defp temporary_secret!(contents) do
    path = Path.join(System.tmp_dir!(), "symphony-secret-#{System.unique_integer([:positive])}")
    File.write!(path, contents, [:binary])
    on_exit(fn -> File.rm(path) end)
    path
  end
end
