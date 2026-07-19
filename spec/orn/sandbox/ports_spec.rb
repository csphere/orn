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
      listener = TCPServer.new("127.0.0.1", 59_300)

      found = described_class.reserve_port([59_300, 59_302])

      aggregate_failures do
        expect(found).not_to eq(59_300)
        expect(found).to be_between(59_301, 59_302)
      end
    ensure
      listener&.close
    end

    it "raises when the range is exhausted" do
      first = TCPServer.new("127.0.0.1", 59_400)
      second = TCPServer.new("127.0.0.1", 59_401)

      expect { described_class.reserve_port([59_400, 59_401]) }.to raise_error(Orn::Error, /No free port/)
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
    let(:entry) do
      Orn::Config::SbxPorts.new(
        container: 3000,
        host_range: [59_500, 59_502]
      )
    end

    after { FileUtils.remove_entry(orn_dir, true) }

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
end
