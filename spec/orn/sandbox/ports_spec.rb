# frozen_string_literal: true

require "socket"
require "tmpdir"
require "fileutils"

RSpec.describe Orn::Sandbox::Ports do
  describe ".reserve_port" do
    it "finds a free port in the range" do
      expect(described_class.reserve_port([49_152, 49_252])).to be_between(49_152, 49_252)
    end

    it "skips an occupied port" do
      listener = TCPServer.new("127.0.0.1", 0)
      busy_port = listener.addr[1]

      found = described_class.reserve_port([busy_port, busy_port + 2])

      aggregate_failures do
        expect(found).not_to eq(busy_port)
        expect(found).to be_between(busy_port + 1, busy_port + 2)
      end
    ensure
      listener&.close
    end

    it "raises when the range is exhausted" do
      first = TCPServer.new("127.0.0.1", 0)
      start_port = first.addr[1]
      # The neighbouring port may already be held by another process; either
      # way the whole range stays occupied.
      second = begin
        TCPServer.new("127.0.0.1", start_port + 1)
      rescue Errno::EADDRINUSE
        nil
      end

      expect { described_class.reserve_port([start_port, start_port + 1]) }.to raise_error(Orn::Error, /No free port/)
    ensure
      first&.close
      second&.close
    end
  end

  describe ".verify_port" do
    it "succeeds when a listener is accepting connections" do
      listener = TCPServer.new("127.0.0.1", 0)
      port = listener.addr[1]

      expect do
        described_class.verify_port(
          port,
          1,
          0.01
        )
      end.not_to raise_error
    ensure
      listener&.close
    end

    it "times out when the port never opens" do
      expect do
        described_class.verify_port(
          1,
          0.2,
          0.05
        )
      end.to raise_error(Orn::Error, /not reachable/)
    end
  end

  describe "port persistence" do
    let(:orn_dir) { Dir.mktmpdir }

    after { FileUtils.remove_entry(orn_dir, true) }

    it "round-trips a single mapping" do
      mappings = [
        Orn::Sandbox::PortMapping.new(
          host: 3042,
          container: 3000
        )
      ]
      described_class.persist_ports(
        orn_dir,
        "my-sbx",
        mappings
      )

      expect(described_class.read_ports(orn_dir, "my-sbx")).to eq(mappings)
    end

    it "round-trips multiple mappings" do
      mappings = [
        Orn::Sandbox::PortMapping.new(
          host: 3042,
          container: 3000
        ),
        Orn::Sandbox::PortMapping.new(
          host: 6380,
          container: 6379
        )
      ]
      described_class.persist_ports(
        orn_dir,
        "my-sbx",
        mappings
      )

      expect(described_class.read_ports(orn_dir, "my-sbx")).to eq(mappings)
    end

    it "creates the sandbox directory" do
      described_class.persist_ports(
        orn_dir,
        "test",
        [
          Orn::Sandbox::PortMapping.new(
            host: 8080,
            container: 80
          )
        ]
      )

      expect(File).to exist(
        File.join(
          orn_dir,
          "sandbox",
          "test.ports"
        )
      )
    end

    it "raises when reading a missing file" do
      expect { described_class.read_ports(orn_dir, "nonexistent") }.to raise_error(Orn::Error, /Failed to read/)
    end

    it "raises when the ports file holds invalid JSON" do
      sandbox_dir = File.join(orn_dir, "sandbox")
      FileUtils.mkdir_p(sandbox_dir)
      File.write(File.join(sandbox_dir, "my-sbx.ports"), "not json")

      expect { described_class.read_ports(orn_dir, "my-sbx") }.to raise_error(Orn::Error, /Invalid port data/)
    end

    it "raises a labelled error when the ports file cannot be written" do
      # A regular file where the sandbox directory should go makes mkdir_p fail.
      blocked_dir = File.join(orn_dir, "blocked")
      File.write(blocked_dir, "")

      expect do
        described_class.persist_ports(
          blocked_dir,
          "my-sbx",
          []
        )
      end.to raise_error(Orn::Error, /Failed to write sandbox ports for my-sbx/)
    end

    it "removes the ports file" do
      described_class.persist_ports(
        orn_dir,
        "my-sbx",
        [
          Orn::Sandbox::PortMapping.new(
            host: 3042,
            container: 3000
          )
        ]
      )

      described_class.remove_ports_file(orn_dir, "my-sbx")

      expect(File).not_to exist(
        File.join(
          orn_dir,
          "sandbox",
          "my-sbx.ports"
        )
      )
    end

    it "cleans up the legacy single-port file" do
      sandbox_dir = File.join(orn_dir, "sandbox")
      FileUtils.mkdir_p(sandbox_dir)
      File.write(File.join(sandbox_dir, "my-sbx.port"), "3042")

      described_class.remove_ports_file(orn_dir, "my-sbx")

      expect(File).not_to exist(File.join(sandbox_dir, "my-sbx.port"))
    end

    it "ignores a missing file on removal" do
      expect { described_class.remove_ports_file(orn_dir, "nonexistent") }.not_to raise_error
    end
  end

  describe ".setup_ports" do
    let(:orn_dir) { Dir.mktmpdir }
    let(:mode) { Orn::OutputMode.default }
    let(:quiet_mode) { Orn::OutputMode.quiet }
    let(:entry) do
      Orn::Config::SbxPorts.new(
        container: 3000,
        host_range: [59_500, 59_502]
      )
    end

    after { FileUtils.remove_entry(orn_dir, true) }

    def port_entry(container:, host_range:)
      Orn::Config::SbxPorts.new(
        container: container,
        host_range: host_range
      )
    end

    def pick_free_port
      probe_server = TCPServer.new("127.0.0.1", 0)
      port = probe_server.addr[1]
      probe_server.close
      port
    end

    # verify_port really connects to the published host port, so a listener
    # must appear once `sbx ports --publish` has run (reserve_port needs the
    # port free until then). Otherwise delegates to the scripted fake.
    def listen_after_publish(fake_backend, host_port, listeners)
      wrapper = Object.new
      wrapper.define_singleton_method(:capture) do |command, **options|
        result = fake_backend.capture(command, **options)
        listeners << TCPServer.new("127.0.0.1", host_port) if command.first(2) == %w[sbx ports]
        result
      end
      Orn::Cmd.backend = wrapper
    end

    it "reserves, publishes, verifies, and persists each configured port" do
      host_port = pick_free_port
      listeners = []
      with_fake_cmd do |fake|
        fake.script(["sbx", "ports", "my-sbx", "--publish", "#{host_port}:3000"])
        listen_after_publish(
          fake,
          host_port,
          listeners
        )

        mappings = described_class.setup_ports(
          quiet_mode,
          "my-sbx",
          [
            port_entry(
              container: 3000,
              host_range: [host_port, host_port]
            )
          ],
          orn_dir
        )

        aggregate_failures do
          expect(mappings).to eq(
            [
              Orn::Sandbox::PortMapping.new(
                host: host_port,
                container: 3000
              )
            ]
          )
          expect(described_class.read_ports(orn_dir, "my-sbx")).to eq(mappings)
        end
      end
    ensure
      listeners.each(&:close)
    end

    it "skips entries missing a container port or host range without persisting anything" do
      with_fake_cmd do |fake|
        mappings = described_class.setup_ports(
          quiet_mode,
          "my-sbx",
          [
            port_entry(
              container: nil,
              host_range: [3000, 3010]
            ),
            port_entry(
              container: 6379,
              host_range: nil
            )
          ],
          orn_dir
        )

        aggregate_failures do
          expect(mappings).to be_empty
          expect(fake.invocations).to be_empty
          expect(File).not_to exist(
            File.join(
              orn_dir,
              "sandbox",
              "my-sbx.ports"
            )
          )
        end
      end
    end

    # The reserved port depends on what is free, so every port in the range is
    # scripted to fail.
    def script_publish_failures(fake)
      (59_500..59_502).each do |port|
        fake.script(
          ["sbx", "ports", "my-sbx", "--publish", "#{port}:3000"],
          stderr: "no such sandbox",
          status: 1
        )
      end
    end

    it "raises when publishing fails after a port was reserved" do
      with_fake_cmd do |fake|
        script_publish_failures(fake)

        expect do
          described_class.setup_ports(
            mode,
            "my-sbx",
            [entry],
            orn_dir
          )
        end.to raise_error(Orn::Error, /sbx failed: no such sandbox/)
      end
    end

    it "persists no mappings when publishing fails" do
      with_fake_cmd do |fake|
        script_publish_failures(fake)

        expect do
          described_class.setup_ports(
            mode,
            "my-sbx",
            [entry],
            orn_dir
          )
        end.to raise_error(Orn::Error)
      end

      expect(File).not_to exist(
        File.join(
          orn_dir,
          "sandbox",
          "my-sbx.ports"
        )
      )
    end
  end

  describe ".republish_ports" do
    let(:mode) { Orn::OutputMode.quiet }
    let(:orn_dir) { Dir.mktmpdir }

    after { FileUtils.remove_entry(orn_dir, true) }

    it "republishes and verifies the persisted mappings" do
      # A live listener stands in for the sandbox service, so the real
      # verify_port probe connects instead of timing out.
      listener = TCPServer.new("127.0.0.1", 0)
      host_port = listener.addr[1]
      described_class.persist_ports(
        orn_dir,
        "my-sbx",
        [
          Orn::Sandbox::PortMapping.new(
            host: host_port,
            container: 3000
          )
        ]
      )
      with_fake_cmd do |fake|
        fake.script(["sbx", "ports", "my-sbx", "--publish", "#{host_port}:3000"])

        mappings = described_class.republish_ports(mode, "my-sbx", orn_dir)

        aggregate_failures do
          expect(mappings.map(&:host)).to eq([host_port])
          expect(fake.invocations).to eq([["sbx", "ports", "my-sbx", "--publish", "#{host_port}:3000"]])
        end
      end
    ensure
      listener&.close
    end

    it "is a no-op when no ports file was persisted" do
      with_fake_cmd do |fake|
        expect(described_class.republish_ports(mode, "my-sbx", orn_dir)).to eq([])
        expect(fake.invocations).to be_empty
      end
    end
  end
end
