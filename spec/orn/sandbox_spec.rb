# frozen_string_literal: true

require "socket"
require "tmpdir"
require "fileutils"

RSpec.describe Orn::Sandbox do
  describe Orn::Sandbox::PortMapping do
    it "displays as host:container" do
      expect(described_class.new(host: 3042, container: 3000).to_s).to eq("3042:3000")
    end
  end

  describe ".parse_list_output" do
    it "parses a bare array of sandboxes" do
      json = '[{"name": "sbx-1", "status": "running"}, {"name": "sbx-2", "status": "stopped"}]'

      entries = described_class.parse_list_output(json)

      aggregate_failures do
        expect(entries.length).to eq(2)
        expect(entries[0]).to have_attributes(name: "sbx-1", status: "running")
        expect(entries[1]).to have_attributes(name: "sbx-2", status: "stopped")
      end
    end

    it "parses a {sandboxes: [...]} wrapper object" do
      entries = described_class.parse_list_output('{"sandboxes": [{"name": "sbx-1", "status": "running"}]}')

      expect(entries).to contain_exactly(have_attributes(name: "sbx-1", status: "running"))
    end

    it "returns nothing for an empty array and empty wrapper" do
      aggregate_failures do
        expect(described_class.parse_list_output("[]")).to be_empty
        expect(described_class.parse_list_output('{"sandboxes": []}')).to be_empty
      end
    end

    it "skips entries without a name" do
      json = '[{"status": "running"}, {"name": "sbx-1", "status": "running"}]'

      expect(described_class.parse_list_output(json).map(&:name)).to eq(["sbx-1"])
    end

    it "defaults a missing status to unknown" do
      expect(described_class.parse_list_output('[{"name": "sbx-1"}]').first.status).to eq("unknown")
    end

    it "returns nothing for a wrapper without a sandboxes key" do
      expect(described_class.parse_list_output('{"other": "data"}')).to be_empty
    end

    it "raises on invalid JSON" do
      expect { described_class.parse_list_output("not json") }.to raise_error(Orn::Error, /parse sbx ls/)
    end
  end

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

      expect { described_class.verify_port(port, 1, 0.01) }.not_to raise_error
    ensure
      listener&.close
    end

    it "times out when the port never opens" do
      expect { described_class.verify_port(1, 0.2, 0.05) }.to raise_error(Orn::Error, /not reachable/)
    end
  end

  describe "port persistence" do
    let(:orn_dir) { Dir.mktmpdir }

    after { FileUtils.remove_entry(orn_dir, true) }

    it "round-trips a single mapping" do
      mappings = [Orn::Sandbox::PortMapping.new(host: 3042, container: 3000)]
      described_class.persist_ports(orn_dir, "my-sbx", mappings)

      expect(described_class.read_ports(orn_dir, "my-sbx")).to eq(mappings)
    end

    it "round-trips multiple mappings" do
      mappings = [
        Orn::Sandbox::PortMapping.new(host: 3042, container: 3000),
        Orn::Sandbox::PortMapping.new(host: 6380, container: 6379)
      ]
      described_class.persist_ports(orn_dir, "my-sbx", mappings)

      expect(described_class.read_ports(orn_dir, "my-sbx")).to eq(mappings)
    end

    it "creates the sandbox directory" do
      described_class.persist_ports(orn_dir, "test", [Orn::Sandbox::PortMapping.new(host: 8080, container: 80)])

      expect(File).to exist(File.join(orn_dir, "sandbox", "test.ports"))
    end

    it "raises when reading a missing file" do
      expect { described_class.read_ports(orn_dir, "nonexistent") }.to raise_error(Orn::Error, /Failed to read/)
    end

    it "removes the ports file" do
      described_class.persist_ports(orn_dir, "my-sbx", [Orn::Sandbox::PortMapping.new(host: 3042, container: 3000)])

      described_class.remove_ports_file(orn_dir, "my-sbx")

      expect(File).not_to exist(File.join(orn_dir, "sandbox", "my-sbx.ports"))
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
end
