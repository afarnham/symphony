defmodule SymphonyElixir.Secret do
  @moduledoc """
  Resolves runtime secrets without requiring their values in workflow files or
  container environment variables.

  Secret settings may contain a literal value, an existing `$ENV_NAME`
  reference, or an absolute `file:///path` reference. Environment references
  also honor the common `ENV_NAME_FILE` convention when the value variable is
  unset.
  """

  @max_secret_bytes 65_536
  @environment_name ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  @spec resolve(term()) :: String.t() | nil
  def resolve(value), do: resolve(value, nil)

  @spec resolve(term(), String.t() | nil) :: String.t() | nil
  def resolve(nil, default_environment_name) do
    read_environment(default_environment_name)
  end

  def resolve("$" <> environment_name, default_environment_name) do
    if environment_configured?(environment_name) do
      read_environment(environment_name)
    else
      read_environment(default_environment_name)
    end
  end

  def resolve("file:" <> _rest = reference, _default_environment_name) do
    read_file_reference(reference)
  end

  def resolve(value, _default_environment_name), do: normalize(value)

  @spec environment_names([String.t()]) :: [String.t()]
  def environment_names(names) when is_list(names) do
    names
    |> Enum.filter(&valid_environment_name?/1)
    |> Enum.flat_map(&[&1, &1 <> "_FILE"])
    |> Enum.uniq()
  end

  @spec reference_environment_names([term()]) :: [String.t()]
  def reference_environment_names(values) when is_list(values) do
    values
    |> Enum.flat_map(fn
      "$" <> environment_name -> [environment_name]
      _value -> []
    end)
    |> environment_names()
  end

  defp read_environment(environment_name) do
    if valid_environment_name?(environment_name) do
      case System.get_env(environment_name) do
        nil -> read_environment_file(environment_name <> "_FILE")
        value -> normalize(value)
      end
    end
  end

  defp environment_configured?(environment_name) do
    valid_environment_name?(environment_name) and
      (not is_nil(System.get_env(environment_name)) or
         not is_nil(System.get_env(environment_name <> "_FILE")))
  end

  defp read_environment_file(file_environment_name) do
    case System.get_env(file_environment_name) do
      nil -> nil
      path -> read_absolute_file(path)
    end
  end

  defp read_file_reference(reference) do
    case URI.parse(reference) do
      %URI{scheme: "file", host: host, path: path, query: nil, fragment: nil}
      when host in [nil, ""] ->
        read_absolute_file(path)

      _reference ->
        nil
    end
  end

  defp read_absolute_file(path) when is_binary(path) do
    if Path.type(path) == :absolute do
      with {:ok, %{type: :regular, size: size}} when size <= @max_secret_bytes <- File.stat(path),
           {:ok, value} when byte_size(value) <= @max_secret_bytes <- File.read(path) do
        normalize(value)
      else
        _error -> nil
      end
    end
  end

  defp read_absolute_file(_path), do: nil

  defp valid_environment_name?(name) when is_binary(name),
    do: Regex.match?(@environment_name, name)

  defp valid_environment_name?(_name), do: false

  defp normalize(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> if String.contains?(normalized, <<0>>), do: nil, else: normalized
    end
  end

  defp normalize(_value), do: nil
end
