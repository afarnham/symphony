defmodule SymphonyElixir.Config.Schema do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.Secret

  @primary_key false
  @linear_endpoint "https://api.linear.app/graphql"
  @linear_active_states ["Todo", "In Progress"]
  @linear_terminal_states ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]

  @type t :: %__MODULE__{}

  defmodule StringOrMap do
    @moduledoc false
    @behaviour Ecto.Type

    @spec type() :: :map
    def type, do: :map

    @spec embed_as(term()) :: :self
    def embed_as(_format), do: :self

    @spec equal?(term(), term()) :: boolean()
    def equal?(left, right), do: left == right

    @spec cast(term()) :: {:ok, String.t() | map()} | :error
    def cast(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def cast(_value), do: :error

    @spec load(term()) :: {:ok, String.t() | map()} | :error
    def load(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def load(_value), do: :error

    @spec dump(term()) :: {:ok, String.t() | map()} | :error
    def dump(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def dump(_value), do: :error
  end

  defmodule Tracker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false

    embedded_schema do
      field(:kind, :string)
      field(:endpoint, :string)
      field(:api_key, :string)
      field(:project_slug, :string)
      field(:assignee, :string)
      field(:provider, :map, default: %{})
      field(:secret_environment_names, {:array, :string}, default: [])
      field(:required_labels, {:array, :string}, default: [])
      field(:active_states, {:array, :string})
      field(:terminal_states, {:array, :string})
      field(:working_state, :string)
      field(:blocked_state, :string)
      field(:completion_state, :string)
      field(:runtime_snapshot, :map, virtual: true)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :kind,
          :endpoint,
          :api_key,
          :project_slug,
          :assignee,
          :provider,
          :required_labels,
          :active_states,
          :terminal_states,
          :working_state,
          :blocked_state,
          :completion_state
        ],
        empty_values: []
      )
      |> update_change(:required_labels, fn labels ->
        labels
        |> Enum.map(&(String.trim(&1) |> String.downcase()))
        |> Enum.uniq()
      end)
    end
  end

  defmodule Polling do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:interval_ms, :integer, default: 30_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:interval_ms], empty_values: [])
      |> validate_number(:interval_ms, greater_than: 0)
    end
  end

  defmodule Workspace do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:root, :string, default: Path.join(System.tmp_dir!(), "symphony_workspaces"))
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:root], empty_values: [])
    end
  end

  defmodule Worker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:ssh_hosts, {:array, :string}, default: [])
      field(:max_concurrent_agents_per_host, :integer)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:ssh_hosts, :max_concurrent_agents_per_host], empty_values: [])
      |> validate_number(:max_concurrent_agents_per_host, greater_than: 0)
    end
  end

  defmodule AgentRouting do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    @backends ["codex", "claude"]
    @github_login_pattern ~r/^[a-z0-9](?:[a-z0-9-]{0,37}[a-z0-9])?$/

    embedded_schema do
      field(:ready_state, :string)
      field(:executor_field, :string)
      field(:trusted_release_actors, {:array, :string}, default: [])
      field(:profiles, :map)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [:ready_state, :executor_field, :trusted_release_actors, :profiles],
        empty_values: []
      )
      |> validate_required([:ready_state, :executor_field, :profiles])
      |> validate_change(:ready_state, &validate_present_string/2)
      |> validate_change(:executor_field, &validate_present_string/2)
      |> validate_change(:trusted_release_actors, &validate_trusted_release_actors/2)
      |> validate_change(:profiles, &validate_profiles/2)
      |> update_change(:ready_state, &String.trim/1)
      |> update_change(:executor_field, &String.trim/1)
      |> update_change(:trusted_release_actors, &Enum.map(&1, fn actor -> normalize_login(actor) end))
      |> update_change(:profiles, &normalize_profiles/1)
    end

    defp validate_present_string(field, value) do
      if is_binary(value) and String.trim(value) != "",
        do: [],
        else: [{field, "can't be blank"}]
    end

    defp validate_profiles(:profiles, profiles) when is_map(profiles) and map_size(profiles) > 0 do
      profile_errors =
        Enum.flat_map(profiles, fn {login, profile} ->
          validate_profile(login, profile)
        end)

      login_errors = validate_unique_profile_logins(profiles)
      host_errors = validate_unique_profile_hosts(profiles)

      if profile_errors == [] and login_errors == [] and host_errors == [],
        do: [],
        else: [profiles: Enum.join(profile_errors ++ login_errors ++ host_errors, "; ")]
    end

    defp validate_profiles(:profiles, _profiles), do: [profiles: "must contain at least one profile"]

    defp validate_trusted_release_actors(:trusted_release_actors, actors) when is_list(actors) do
      normalized = Enum.map(actors, &normalize_login/1)

      invalid? =
        Enum.any?(normalized, fn actor ->
          actor == "" or not String.match?(actor, @github_login_pattern)
        end)

      duplicates =
        normalized
        |> Enum.frequencies()
        |> Enum.filter(fn {_actor, count} -> count > 1 end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()

      []
      |> maybe_add_field_error(
        invalid?,
        {:trusted_release_actors, "must contain GitHub logins"}
      )
      |> maybe_add_field_error(
        duplicates != [],
        {:trusted_release_actors, "must be unique after normalization: #{Enum.join(duplicates, ", ")}"}
      )
    end

    defp validate_profile(login, profile) when is_map(profile) do
      normalized_login = login |> to_string() |> String.trim() |> String.downcase()
      backend = Map.get(profile, "default_backend") || Map.get(profile, :default_backend)
      hosts = Map.get(profile, "worker_hosts") || Map.get(profile, :worker_hosts)

      []
      |> maybe_add_error(
        normalized_login == "" or not String.match?(normalized_login, @github_login_pattern),
        "profile #{inspect(login)} must be a GitHub login"
      )
      |> maybe_add_error(
        backend not in @backends,
        "profile #{inspect(login)} default_backend must be codex or claude"
      )
      |> maybe_add_error(
        not valid_worker_hosts?(hosts),
        "profile #{inspect(login)} worker_hosts must contain non-empty unique strings"
      )
    end

    defp validate_profile(login, _profile),
      do: ["profile #{inspect(login)} must be a map"]

    defp valid_worker_hosts?(hosts) when is_list(hosts) and hosts != [] do
      normalized = Enum.map(hosts, &normalize_host/1)
      Enum.all?(normalized, &(&1 != "")) and Enum.uniq(normalized) == normalized
    end

    defp valid_worker_hosts?(_hosts), do: false

    defp validate_unique_profile_logins(profiles) do
      duplicates =
        profiles
        |> Map.keys()
        |> Enum.map(&(to_string(&1) |> String.trim() |> String.downcase()))
        |> Enum.frequencies()
        |> Enum.filter(fn {_login, count} -> count > 1 end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()

      case duplicates do
        [] -> []
        logins -> ["profile logins must be unique after normalization: #{Enum.join(logins, ", ")}"]
      end
    end

    defp validate_unique_profile_hosts(profiles) do
      duplicates =
        profiles
        |> Enum.flat_map(fn {_login, profile} ->
          profile_worker_hosts(profile)
        end)
        |> Enum.reject(&(&1 == ""))
        |> Enum.frequencies()
        |> Enum.filter(fn {_host, count} -> count > 1 end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()

      case duplicates do
        [] -> []
        hosts -> ["worker hosts may belong to only one profile: #{Enum.join(hosts, ", ")}"]
      end
    end

    defp profile_worker_hosts(profile) when is_map(profile) do
      case Map.get(profile, "worker_hosts") || Map.get(profile, :worker_hosts) do
        hosts when is_list(hosts) -> Enum.map(hosts, &normalize_host/1)
        _hosts -> []
      end
    end

    defp profile_worker_hosts(_profile), do: []

    defp normalize_profiles(profiles) do
      Map.new(profiles, fn {login, profile} ->
        normalized_login = login |> to_string() |> String.trim() |> String.downcase()
        {normalized_login, normalize_profile(profile)}
      end)
    end

    defp normalize_profile(profile) when is_map(profile) do
      backend = Map.get(profile, "default_backend") || Map.get(profile, :default_backend)
      hosts = Map.get(profile, "worker_hosts") || Map.get(profile, :worker_hosts)

      %{
        "default_backend" => backend,
        "worker_hosts" => if(is_list(hosts), do: Enum.map(hosts, &normalize_host/1), else: [])
      }
    end

    defp normalize_profile(_profile), do: %{}

    defp normalize_login(login) when is_binary(login),
      do: login |> String.trim() |> String.downcase()

    defp normalize_host(host) when is_binary(host), do: String.trim(host)
    defp normalize_host(_host), do: ""

    defp maybe_add_error(errors, true, error), do: errors ++ [error]
    defp maybe_add_error(errors, false, _error), do: errors

    defp maybe_add_field_error(errors, true, error), do: errors ++ [error]
    defp maybe_add_field_error(errors, false, _error), do: errors
  end

  defmodule Agent do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema

    @primary_key false
    @backends ["codex", "claude"]
    embedded_schema do
      field(:backend, :string, default: "codex")
      field(:max_concurrent_agents, :integer, default: 10)
      field(:max_turns, :integer, default: 20)
      field(:max_retry_backoff_ms, :integer, default: 300_000)
      field(:max_concurrent_agents_by_state, :map, default: %{})
      embeds_one(:routing, AgentRouting, on_replace: :update)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :backend,
          :max_concurrent_agents,
          :max_turns,
          :max_retry_backoff_ms,
          :max_concurrent_agents_by_state
        ],
        empty_values: []
      )
      |> validate_required([:backend])
      |> validate_inclusion(:backend, @backends)
      |> validate_number(:max_concurrent_agents, greater_than: 0)
      |> validate_number(:max_turns, greater_than: 0)
      |> validate_number(:max_retry_backoff_ms, greater_than: 0)
      |> update_change(:max_concurrent_agents_by_state, &Schema.normalize_state_limits/1)
      |> Schema.validate_state_limits(:max_concurrent_agents_by_state)
      |> cast_embed(:routing, with: &AgentRouting.changeset/2)
    end
  end

  defmodule Codex do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:command, :string, default: "codex app-server")

      field(:approval_policy, StringOrMap,
        default: %{
          "granular" => %{
            "sandbox_approval" => true,
            "rules" => true,
            "mcp_elicitations" => true
          }
        }
      )

      field(:thread_sandbox, :string, default: "workspace-write")
      field(:turn_sandbox_policy, :map)
      field(:turn_timeout_ms, :integer, default: 3_600_000)
      field(:read_timeout_ms, :integer, default: 5_000)
      field(:stall_timeout_ms, :integer, default: 300_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :command,
          :approval_policy,
          :thread_sandbox,
          :turn_sandbox_policy,
          :turn_timeout_ms,
          :read_timeout_ms,
          :stall_timeout_ms
        ],
        empty_values: []
      )
      |> validate_required([:command])
      |> validate_change(:command, fn :command, command ->
        if String.trim(command) == "" do
          [command: "can't be blank"]
        else
          []
        end
      end)
      |> validate_number(:turn_timeout_ms, greater_than: 0)
      |> validate_number(:read_timeout_ms, greater_than: 0)
      |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
    end
  end

  defmodule Claude do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    @permission_modes ["default", "acceptEdits", "plan", "bypassPermissions"]

    embedded_schema do
      field(:command, :string, default: "claude")
      field(:model, :string)
      field(:permission_mode, :string, default: "default")
      field(:turn_timeout_ms, :integer, default: 3_600_000)
      field(:read_timeout_ms, :integer, default: 5_000)
      field(:stall_timeout_ms, :integer, default: 300_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :command,
          :model,
          :permission_mode,
          :turn_timeout_ms,
          :read_timeout_ms,
          :stall_timeout_ms
        ],
        empty_values: []
      )
      |> validate_required([:command, :permission_mode])
      |> validate_non_blank(:command)
      |> validate_optional_non_blank(:model)
      |> validate_inclusion(:permission_mode, @permission_modes)
      |> validate_number(:turn_timeout_ms, greater_than: 0)
      |> validate_number(:read_timeout_ms, greater_than: 0)
      |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
    end

    defp validate_non_blank(changeset, field) do
      validate_change(changeset, field, fn ^field, value ->
        if is_binary(value) and String.trim(value) != "", do: [], else: [{field, "can't be blank"}]
      end)
    end

    defp validate_optional_non_blank(changeset, field) do
      validate_change(changeset, field, fn ^field, value ->
        if is_nil(value) or (is_binary(value) and String.trim(value) != "") do
          []
        else
          [{field, "can't be blank"}]
        end
      end)
    end
  end

  defmodule Hooks do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:after_create, :string)
      field(:before_run, :string)
      field(:after_run, :string)
      field(:before_remove, :string)
      field(:timeout_ms, :integer, default: 60_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:after_create, :before_run, :after_run, :before_remove, :timeout_ms], empty_values: [])
      |> validate_number(:timeout_ms, greater_than: 0)
    end
  end

  defmodule Observability do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:dashboard_enabled, :boolean, default: true)
      field(:refresh_ms, :integer, default: 1_000)
      field(:render_interval_ms, :integer, default: 16)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:dashboard_enabled, :refresh_ms, :render_interval_ms], empty_values: [])
      |> validate_number(:refresh_ms, greater_than: 0)
      |> validate_number(:render_interval_ms, greater_than: 0)
    end
  end

  defmodule Server do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:port, :integer)
      field(:host, :string, default: "127.0.0.1")
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:port, :host], empty_values: [])
      |> validate_number(:port, greater_than_or_equal_to: 0)
    end
  end

  embedded_schema do
    embeds_one(:tracker, Tracker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:polling, Polling, on_replace: :update, defaults_to_struct: true)
    embeds_one(:workspace, Workspace, on_replace: :update, defaults_to_struct: true)
    embeds_one(:worker, Worker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:agent, Agent, on_replace: :update, defaults_to_struct: true)
    embeds_one(:codex, Codex, on_replace: :update, defaults_to_struct: true)
    embeds_one(:claude, Claude, on_replace: :update, defaults_to_struct: true)
    embeds_one(:hooks, Hooks, on_replace: :update, defaults_to_struct: true)
    embeds_one(:observability, Observability, on_replace: :update, defaults_to_struct: true)
    embeds_one(:server, Server, on_replace: :update, defaults_to_struct: true)
  end

  @spec parse(map()) :: {:ok, %__MODULE__{}} | {:error, {:invalid_workflow_config, String.t()}}
  def parse(config) when is_map(config) do
    config
    |> normalize_keys()
    |> drop_nil_values()
    |> changeset()
    |> apply_action(:validate)
    |> case do
      {:ok, settings} ->
        {:ok, finalize_settings(settings)}

      {:error, changeset} ->
        {:error, {:invalid_workflow_config, format_errors(changeset)}}
    end
  end

  @spec resolve_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil) :: map()
  def resolve_turn_sandbox_policy(settings, workspace \\ nil) do
    case settings.codex.turn_sandbox_policy do
      %{} = policy ->
        policy

      _ ->
        workspace
        |> default_workspace_root(settings.workspace.root)
        |> expand_local_workspace_root()
        |> default_turn_sandbox_policy()
    end
  end

  @spec resolve_runtime_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def resolve_runtime_turn_sandbox_policy(settings, workspace \\ nil, opts \\ []) do
    case settings.codex.turn_sandbox_policy do
      %{} = policy ->
        {:ok, policy}

      _ ->
        workspace
        |> default_workspace_root(settings.workspace.root)
        |> default_runtime_turn_sandbox_policy(opts)
    end
  end

  @spec normalize_issue_state(String.t()) :: String.t()
  def normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  @doc false
  @spec normalize_state_limits(nil | map()) :: map()
  def normalize_state_limits(nil), do: %{}

  def normalize_state_limits(limits) when is_map(limits) do
    Enum.reduce(limits, %{}, fn {state_name, limit}, acc ->
      Map.put(acc, normalize_issue_state(to_string(state_name)), limit)
    end)
  end

  @doc false
  @spec validate_state_limits(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_state_limits(changeset, field) do
    validate_change(changeset, field, fn ^field, limits ->
      Enum.flat_map(limits, fn {state_name, limit} ->
        cond do
          state_name |> to_string() |> String.trim() == "" ->
            [{field, "state names must not be blank"}]

          not is_integer(limit) or limit <= 0 ->
            [{field, "limits must be positive integers"}]

          true ->
            []
        end
      end)
    end)
  end

  defp changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [])
    |> cast_embed(:tracker, with: &Tracker.changeset/2)
    |> cast_embed(:polling, with: &Polling.changeset/2)
    |> cast_embed(:workspace, with: &Workspace.changeset/2)
    |> cast_embed(:worker, with: &Worker.changeset/2)
    |> cast_embed(:agent, with: &Agent.changeset/2)
    |> cast_embed(:codex, with: &Codex.changeset/2)
    |> cast_embed(:claude, with: &Claude.changeset/2)
    |> cast_embed(:hooks, with: &Hooks.changeset/2)
    |> cast_embed(:observability, with: &Observability.changeset/2)
    |> cast_embed(:server, with: &Server.changeset/2)
  end

  defp finalize_settings(settings) do
    provider = normalize_optional_map(settings.tracker.provider) || %{}

    {api_key, assignee, provider, secret_environment_names} =
      case settings.tracker.kind do
        "linear" ->
          linear_provider =
            provider
            |> Map.put_new("endpoint", settings.tracker.endpoint || @linear_endpoint)
            |> Map.put_new("api_key", settings.tracker.api_key)
            |> Map.put_new("project_slug", settings.tracker.project_slug)
            |> Map.put_new("assignee", settings.tracker.assignee)

          resolved_api_key = Secret.resolve(linear_provider["api_key"], "LINEAR_API_KEY")

          resolved_assignee =
            resolve_secret_setting(linear_provider["assignee"], System.get_env("LINEAR_ASSIGNEE"))

          {
            resolved_api_key,
            resolved_assignee,
            linear_provider,
            Secret.environment_names(["LINEAR_API_KEY"]) ++
              Secret.reference_environment_names([linear_provider["api_key"]])
          }

        _ ->
          {settings.tracker.api_key, settings.tracker.assignee, provider, []}
      end

    {active_states, terminal_states} =
      case settings.tracker.kind do
        kind when kind in ["linear", "memory"] ->
          {
            settings.tracker.active_states || @linear_active_states,
            settings.tracker.terminal_states || @linear_terminal_states
          }

        _ ->
          {settings.tracker.active_states, settings.tracker.terminal_states}
      end

    tracker = %{
      settings.tracker
      | endpoint: Map.get(provider, "endpoint", settings.tracker.endpoint),
        api_key: api_key,
        project_slug: Map.get(provider, "project_slug", settings.tracker.project_slug),
        assignee: assignee,
        provider: provider,
        secret_environment_names: Enum.uniq(secret_environment_names),
        active_states: active_states,
        terminal_states: terminal_states
    }

    workspace = %{
      settings.workspace
      | root: resolve_path_value(settings.workspace.root, Path.join(System.tmp_dir!(), "symphony_workspaces"))
    }

    codex = %{
      settings.codex
      | approval_policy: normalize_keys(settings.codex.approval_policy),
        turn_sandbox_policy: normalize_optional_map(settings.codex.turn_sandbox_policy)
    }

    %{settings | tracker: tracker, workspace: workspace, codex: codex}
  end

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_optional_map(nil), do: nil
  defp normalize_optional_map(value) when is_map(value), do: normalize_keys(value)

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp drop_nil_values(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      case drop_nil_values(nested) do
        nil -> acc
        normalized -> Map.put(acc, key, normalized)
      end
    end)
  end

  defp drop_nil_values(value) when is_list(value), do: Enum.map(value, &drop_nil_values/1)
  defp drop_nil_values(value), do: value

  defp resolve_secret_setting(nil, fallback), do: normalize_secret_value(fallback)

  defp resolve_secret_setting(value, fallback) when is_binary(value) do
    case resolve_env_value(value, fallback) do
      resolved when is_binary(resolved) -> normalize_secret_value(resolved)
      resolved -> resolved
    end
  end

  defp resolve_secret_setting(value, _fallback), do: value

  defp resolve_path_value(value, default) when is_binary(value) do
    case normalize_path_token(value) do
      :missing ->
        default

      "" ->
        default

      path ->
        path
    end
  end

  defp resolve_env_value(value, fallback) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} ->
        case System.get_env(env_name) do
          nil -> fallback
          "" -> nil
          env_value -> env_value
        end

      :error ->
        value
    end
  end

  defp normalize_path_token(value) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} -> resolve_env_token(env_name)
      :error -> value
    end
  end

  defp env_reference_name("$" <> env_name) do
    if String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/) do
      {:ok, env_name}
    else
      :error
    end
  end

  defp env_reference_name(_value), do: :error

  defp resolve_env_token(env_name) do
    case System.get_env(env_name) do
      nil -> :missing
      env_value -> env_value
    end
  end

  defp normalize_secret_value(value) when is_binary(value) do
    if value == "", do: nil, else: value
  end

  defp normalize_secret_value(_value), do: nil

  defp default_turn_sandbox_policy(workspace) do
    %{
      "type" => "workspaceWrite",
      "writableRoots" => [workspace],
      "readOnlyAccess" => %{"type" => "fullAccess"},
      "networkAccess" => false,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }
  end

  defp default_runtime_turn_sandbox_policy(workspace_root, opts) when is_binary(workspace_root) do
    if Keyword.get(opts, :remote, false) do
      {:ok, default_turn_sandbox_policy(workspace_root)}
    else
      with expanded_workspace_root <- expand_local_workspace_root(workspace_root),
           {:ok, canonical_workspace_root} <- PathSafety.canonicalize(expanded_workspace_root) do
        {:ok, default_turn_sandbox_policy(canonical_workspace_root)}
      end
    end
  end

  defp default_runtime_turn_sandbox_policy(workspace_root, _opts) do
    {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, workspace_root}}}
  end

  defp default_workspace_root(workspace, _fallback) when is_binary(workspace) and workspace != "",
    do: workspace

  defp default_workspace_root(nil, fallback), do: fallback
  defp default_workspace_root("", fallback), do: fallback
  defp default_workspace_root(workspace, _fallback), do: workspace

  defp expand_local_workspace_root(workspace_root)
       when is_binary(workspace_root) and workspace_root != "" do
    Path.expand(workspace_root)
  end

  defp expand_local_workspace_root(_workspace_root) do
    Path.expand(Path.join(System.tmp_dir!(), "symphony_workspaces"))
  end

  defp format_errors(changeset) do
    changeset
    |> traverse_errors(&translate_error/1)
    |> flatten_errors()
    |> Enum.join(", ")
  end

  defp flatten_errors(errors, prefix \\ nil)

  defp flatten_errors(errors, prefix) when is_map(errors) do
    Enum.flat_map(errors, fn {key, value} ->
      next_prefix =
        case prefix do
          nil -> to_string(key)
          current -> current <> "." <> to_string(key)
        end

      flatten_errors(value, next_prefix)
    end)
  end

  defp flatten_errors(errors, prefix) when is_list(errors) do
    Enum.map(errors, &(prefix <> " " <> &1))
  end

  defp translate_error({message, options}) do
    Enum.reduce(options, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", error_value_to_string(value))
    end)
  end

  defp error_value_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp error_value_to_string(value), do: inspect(value)
end
