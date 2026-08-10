defmodule SymphonyElixir.SSHTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SSH

  test "run/3 keeps bracketed IPv6 host:port targets intact" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-ipv6-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file)

    assert {:ok, {"", 0}} =
             SSH.run("root@[::1]:2200", "printf ok", stderr_to_stdout: true)

    trace = File.read!(trace_file)
    assert trace =~ "-T -p 2200 root@[::1] bash -lc"
    assert trace =~ "printf ok"
  end

  test "run/3 leaves unbracketed IPv6-style targets unchanged" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-ipv6-raw-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file)

    assert {:ok, {"", 0}} =
             SSH.run("::1:2200", "printf ok", stderr_to_stdout: true)

    trace = File.read!(trace_file)
    assert trace =~ "-T ::1:2200 bash -lc"
    refute trace =~ "-p 2200"
  end

  test "run/3 passes host:port targets through ssh -p" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")
    previous_ssh_config = System.get_env("SYMPHONY_SSH_CONFIG")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMPHONY_SSH_CONFIG", previous_ssh_config)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file)
    System.put_env("SYMPHONY_SSH_CONFIG", "/tmp/symphony-test-ssh-config")

    assert {:ok, {"", 0}} =
             SSH.run("localhost:2222", "echo ready", stderr_to_stdout: true)

    trace = File.read!(trace_file)
    assert trace =~ "-F /tmp/symphony-test-ssh-config"
    assert trace =~ "-T -p 2222 localhost bash -lc"
    assert trace =~ "echo ready"
  end

  test "run/3 keeps the user prefix when parsing user@host:port targets" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-user-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file)

    assert {:ok, {"", 0}} =
             SSH.run("root@127.0.0.1:2200", "printf ok", stderr_to_stdout: true)

    trace = File.read!(trace_file)
    assert trace =~ "-T -p 2200 root@127.0.0.1 bash -lc"
    assert trace =~ "printf ok"
  end

  test "run/3 returns an error when ssh is unavailable" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-missing-test-#{System.unique_integer([:positive])}")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    File.mkdir_p!(test_root)
    System.put_env("PATH", test_root)

    assert {:error, :ssh_not_found} = SSH.run("localhost", "printf ok")
  end

  test "start_port/3 supports binary output without line mode" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-port-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")
    previous_ssh_config = System.get_env("SYMPHONY_SSH_CONFIG")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMPHONY_SSH_CONFIG", previous_ssh_config)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file, """
    #!/bin/sh
    printf 'ARGV:%s\\n' "$*" >> "#{trace_file}"
    printf 'ready\\n'
    exit 0
    """)

    System.delete_env("SYMPHONY_SSH_CONFIG")

    assert {:ok, port} = SSH.start_port("localhost", "printf ok")
    assert is_port(port)
    wait_for_trace!(trace_file)

    trace = File.read!(trace_file)
    assert trace =~ "-T localhost bash -lc"
    refute trace =~ " -F "
  end

  test "start_port/3 supports line mode" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-line-port-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file, """
    #!/bin/sh
    printf 'ARGV:%s\\n' "$*" >> "#{trace_file}"
    printf 'ready\\n'
    exit 0
    """)

    assert {:ok, port} = SSH.start_port("localhost:2222", "printf ok", line: 256)
    assert is_port(port)
    wait_for_trace!(trace_file)

    trace = File.read!(trace_file)
    assert trace =~ "-T -p 2222 localhost bash -lc"
  end

  test "remote_shell_command/1 escapes embedded single quotes" do
    assert SSH.remote_shell_command("printf 'hello'") ==
             "bash -lc 'printf '\"'\"'hello'\"'\"''"
  end

  test "start_reverse_tunnel/4 starts and verifies a noninteractive reverse forward" do
    test_root = tunnel_test_root("ready")
    trace_file = Path.join(test_root, "ssh.trace")
    state_file = Path.join(test_root, "tunnel.state")
    stop_file = Path.join(test_root, "tunnel.stop")
    previous_path = System.get_env("PATH")
    previous_ssh_config = System.get_env("SYMPHONY_SSH_CONFIG")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMPHONY_SSH_CONFIG", previous_ssh_config)
      File.rm_rf(test_root)
    end)

    install_tunnel_ssh!(test_root, trace_file, state_file, stop_file)
    System.put_env("SYMPHONY_SSH_CONFIG", "/tmp/symphony-test-ssh-config")

    assert {:ok, %SSH.Tunnel{} = tunnel} =
             SSH.start_reverse_tunnel("worker@example.test:2222", 43_210, 12_345,
               startup_timeout: 1_000,
               poll_interval: 10
             )

    assert is_pid(tunnel.owner)
    assert is_port(tunnel.port)
    assert tunnel.host == "worker@example.test:2222"
    assert tunnel.remote_port == 43_210
    assert tunnel.local_port == 12_345

    assert {:ok,
            %{
              status: :ready,
              host: "worker@example.test:2222",
              remote_port: 43_210,
              local_port: 12_345
            }} = SSH.reverse_tunnel_health(tunnel)

    trace = File.read!(trace_file)

    assert trace =~
             "START:-F /tmp/symphony-test-ssh-config -T -p 2222 -o BatchMode=yes " <>
               "-o ExitOnForwardFailure=yes -o ControlMaster=yes -o ControlPersist=no"

    assert trace =~ "-N -R 127.0.0.1:43210:127.0.0.1:12345 worker@example.test"
    assert trace =~ "CHECK:"
    refute trace =~ "bash -lc"

    assert :ok = SSH.stop_reverse_tunnel(tunnel)
    assert :ok = SSH.stop_reverse_tunnel(tunnel)
    assert {:error, :tunnel_closed} = SSH.reverse_tunnel_health(tunnel)
  end

  test "start_reverse_tunnel/4 reports an ssh startup exit and does not fall back" do
    test_root = tunnel_test_root("startup-failure")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file, """
    #!/bin/sh
    printf 'ARGV:%s\\n' "$*" >> "#{trace_file}"

    case " $* " in
      *" -O check "*) exit 255 ;;
      *" -O exit "*) exit 0 ;;
      *) printf 'remote port forwarding failed\\n'; exit 23 ;;
    esac
    """)

    assert {:error, {:ssh_tunnel_exited, 23, output}} =
             SSH.start_reverse_tunnel("worker.example.test", 43_210, 12_345,
               startup_timeout: 1_000,
               poll_interval: 10
             )

    assert output =~ "remote port forwarding failed"

    trace = File.read!(trace_file)
    assert trace =~ "ExitOnForwardFailure=yes"
    refute trace =~ "localhost bash -lc"
  end

  test "reverse_tunnel_health/1 detects tunnel loss through the ssh exit status" do
    test_root = tunnel_test_root("loss")
    trace_file = Path.join(test_root, "ssh.trace")
    state_file = Path.join(test_root, "tunnel.state")
    stop_file = Path.join(test_root, "tunnel.stop")
    loss_file = Path.join(test_root, "tunnel.loss")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    install_tunnel_ssh!(test_root, trace_file, state_file, stop_file, loss_file)

    assert {:ok, tunnel} =
             SSH.start_reverse_tunnel("worker.example.test", 43_210, 12_345,
               startup_timeout: 1_000,
               poll_interval: 10
             )

    File.touch!(loss_file)

    assert {:error, {:ssh_tunnel_exited, 42, _output}} =
             wait_for_tunnel_loss(tunnel)

    assert_receive {:ssh_reverse_tunnel_exit, owner, 42}
    assert owner == tunnel.owner

    assert :ok = SSH.stop_reverse_tunnel(tunnel)
    assert :ok = SSH.stop_reverse_tunnel(tunnel)
  end

  test "start_reverse_tunnel/4 stops an unready tunnel at the startup deadline" do
    test_root = tunnel_test_root("timeout")
    trace_file = Path.join(test_root, "ssh.trace")
    stop_file = Path.join(test_root, "tunnel.stop")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file, """
    #!/bin/sh

    case " $* " in
      *" -O check "*) exit 255 ;;
      *" -O exit "*) touch "#{stop_file}"; exit 0 ;;
      *)
        while [ ! -f "#{stop_file}" ]; do sleep 0.02; done
        exit 0
        ;;
    esac
    """)

    assert {:error, {:ssh_tunnel_start_timeout, "worker.example.test", 50}} =
             SSH.start_reverse_tunnel("worker.example.test", 43_210, 12_345,
               startup_timeout: 50,
               poll_interval: 10
             )

    assert File.exists?(stop_file)
  end

  test "start_reverse_tunnel/4 rejects invalid forwarding ports before launching ssh" do
    assert {:error, {:invalid_tunnel_port, :remote, 0}} =
             SSH.start_reverse_tunnel("worker.example.test", 0, 12_345)

    assert {:error, {:invalid_tunnel_port, :local, 65_536}} =
             SSH.start_reverse_tunnel("worker.example.test", 43_210, 65_536)
  end

  defp install_fake_ssh!(test_root, trace_file, script \\ nil) do
    fake_bin_dir = Path.join(test_root, "bin")
    fake_ssh = Path.join(fake_bin_dir, "ssh")

    File.mkdir_p!(fake_bin_dir)

    File.write!(
      fake_ssh,
      script ||
        """
        #!/bin/sh
        printf 'ARGV:%s\\n' "$*" >> "#{trace_file}"
        exit 0
        """
    )

    File.chmod!(fake_ssh, 0o755)
    System.put_env("PATH", fake_bin_dir <> ":" <> (System.get_env("PATH") || ""))
  end

  defp install_tunnel_ssh!(test_root, trace_file, state_file, stop_file, loss_file \\ nil) do
    loss_check =
      if is_binary(loss_file) do
        "if [ -f \"#{loss_file}\" ]; then exit 42; fi"
      else
        "true"
      end

    install_fake_ssh!(test_root, trace_file, """
    #!/bin/sh

    case " $* " in
      *" -O check "*)
        printf 'CHECK:%s\\n' "$*" >> "#{trace_file}"
        test -f "#{state_file}"
        exit $?
        ;;
      *" -O exit "*)
        printf 'STOP:%s\\n' "$*" >> "#{trace_file}"
        touch "#{stop_file}"
        exit 0
        ;;
      *)
        printf 'START:%s\\n' "$*" >> "#{trace_file}"
        touch "#{state_file}"
        trap 'rm -f "#{state_file}"' EXIT

        while [ ! -f "#{stop_file}" ]; do
          #{loss_check}
          sleep 0.02
        done
        exit 0
        ;;
    esac
    """)
  end

  defp tunnel_test_root(suffix) do
    Path.join(
      System.tmp_dir!(),
      "symphony-ssh-tunnel-#{suffix}-#{System.unique_integer([:positive])}"
    )
  end

  defp wait_for_tunnel_loss(tunnel, attempts \\ 50)

  defp wait_for_tunnel_loss(_tunnel, 0), do: flunk("timed out waiting for fake ssh tunnel loss")

  defp wait_for_tunnel_loss(tunnel, attempts) do
    case SSH.reverse_tunnel_health(tunnel) do
      {:ok, _health} ->
        Process.sleep(20)
        wait_for_tunnel_loss(tunnel, attempts - 1)

      {:error, _reason} = error ->
        error
    end
  end

  defp wait_for_trace!(trace_file, attempts \\ 20)
  defp wait_for_trace!(trace_file, 0), do: flunk("timed out waiting for fake ssh trace at #{trace_file}")

  defp wait_for_trace!(trace_file, attempts) do
    if File.exists?(trace_file) and File.read!(trace_file) != "" do
      :ok
    else
      Process.sleep(25)
      wait_for_trace!(trace_file, attempts - 1)
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
