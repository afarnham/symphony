defmodule SymphonyElixir.TrackerTicketFile do
  @moduledoc "Writes an authoritative tracker payload on the bound worker without agent transcription."

  alias SymphonyElixir.SSH

  # The payload travels on stdin, never through shell source or command arguments.
  # A private, unique directory avoids shared paths between concurrent sessions.
  @remote_script """
  set -eu
  umask 077
  ticket_dir=$(mktemp -d /tmp/symphony-ticket.XXXXXXXXXX)
  trap 'rm -f "$ticket_dir/issue.json"; rmdir "$ticket_dir"' EXIT
  cat > "$ticket_dir/issue.json"
  printf '%s\\n' "$ticket_dir/issue.json"
  trap - EXIT
  """

  @spec write(map(), String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def write(payload, nil) when is_map(payload) do
    directory = Path.join(System.tmp_dir!(), "symphony-ticket-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower))
    path = Path.join(directory, "issue.json")

    case File.mkdir(directory) do
      :ok ->
        with :ok <- File.chmod(directory, 0o700),
             :ok <- File.write(path, Jason.encode!(payload), [:binary, :exclusive]),
             :ok <- File.chmod(path, 0o600) do
          {:ok, path}
        else
          {:error, reason} ->
            File.rm_rf(directory)
            {:error, {:tracker_ticket_file_write_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:tracker_ticket_file_write_failed, reason}}
    end
  end

  def write(payload, host) when is_map(payload) and is_binary(host) do
    case SSH.run_with_input(host, @remote_script, Jason.encode!(payload), timeout: 10_000, noninteractive: true, stderr_to_stdout: true) do
      {:ok, {output, 0}} ->
        path = String.trim(output)

        if Regex.match?(~r|\A/tmp/symphony-ticket\.[A-Za-z0-9]{10}/issue\.json\z|, path) do
          {:ok, path}
        else
          {:error, :invalid_tracker_ticket_file_path}
        end

      {:ok, {_output, status}} ->
        {:error, {:tracker_ticket_file_write_failed, status}}

      {:error, reason} ->
        {:error, {:tracker_ticket_file_write_failed, reason}}
    end
  end
end
