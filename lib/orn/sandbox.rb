# frozen_string_literal: true

require "json"
require "socket"
require "fileutils"

module Orn
  # Sandbox (dev container) operations. This first slice ports the Docker-free
  # foundations: host-port reservation/verification, `.ports` persistence, and
  # `sbx ls --json` parsing. The Docker/sbx-shelling lifecycle (create, exec,
  # build, preflight, doctor) and the `sbx/*` commands land next.
  module Sandbox
    # Total time verify_port waits for a published port to accept connections.
    PORT_VERIFY_TIMEOUT = 30
    # Starting delay for verify_port's exponential backoff (seconds).
    PORT_VERIFY_INITIAL_BACKOFF = 0.25

    # A host-to-container port mapping, displayed as `host:container`.
    PortMapping = Data.define(:host, :container) do
      def to_s
        "#{host}:#{container}"
      end
    end

    # A sandbox name and status as reported by `sbx ls`.
    SandboxEntry = Data.define(:name, :status)

    # The first bindable host port in `[start, end]`. The port is probed, not
    # held, so another process can still race for it.
    def self.reserve_port(host_range)
      start, finish = host_range
      (start..finish).each do |port|
        server = probe_bind(port)
        next if server.nil?

        server.close
        return port
      end
      raise Orn::Error, "No free port in range #{start}-#{finish}"
    end

    # Polls the host port with exponential backoff until it accepts a TCP
    # connection or `timeout` seconds elapse.
    def self.verify_port(host_port, timeout, initial_backoff)
      start = monotonic
      backoff = initial_backoff
      loop do
        return if port_open?(host_port)

        elapsed = monotonic - start
        raise Orn::Error, "Port #{host_port} not reachable after #{timeout.to_i}s" if elapsed >= timeout

        remaining = timeout - elapsed
        sleep([backoff, remaining].min)
        backoff *= 2
      end
    end

    # Writes the mappings as JSON to `<orn_dir>/sandbox/<name>.ports` so they
    # can be republished after a container restart.
    def self.persist_ports(orn_dir, name, mappings)
      sandbox_dir = File.join(orn_dir, "sandbox")
      FileUtils.mkdir_p(sandbox_dir)
      File.write(File.join(sandbox_dir, "#{name}.ports"), JSON.generate(mappings.map(&:to_h)))
      nil
    rescue SystemCallError => e
      raise Orn::Error, "Failed to write sandbox ports for #{name}: #{e.message}"
    end

    # Deletes the persisted ports file plus the legacy single-port `.port` file;
    # missing files are ignored.
    def self.remove_ports_file(orn_dir, name)
      FileUtils.rm_f(File.join(orn_dir, "sandbox", "#{name}.ports"))
      FileUtils.rm_f(File.join(orn_dir, "sandbox", "#{name}.port"))
      nil
    end

    # Reads the mappings persisted by persist_ports.
    def self.read_ports(orn_dir, name)
      path = File.join(orn_dir, "sandbox", "#{name}.ports")
      parsed = JSON.parse(File.read(path))
      parsed.map { |entry| PortMapping.new(host: entry["host"], container: entry["container"]) }
    rescue Errno::ENOENT
      raise Orn::Error, "Failed to read #{path}"
    rescue JSON::ParserError
      raise Orn::Error, "Invalid port data in #{path}"
    end

    # Parses `sbx ls --json` output, accepting either a bare array or a
    # `{"sandboxes": [...]}` wrapper object.
    def self.parse_list_output(json)
      value = JSON.parse(json)
      case value
      when Array then extract_entries(value)
      when Hash then extract_entries(value["sandboxes"].is_a?(Array) ? value["sandboxes"] : [])
      else []
      end
    rescue JSON::ParserError
      raise Orn::Error, "Failed to parse sbx ls output"
    end

    # Skips entries without a name; a missing status defaults to "unknown".
    def self.extract_entries(items)
      items.filter_map do |item|
        next unless item.is_a?(Hash) && item["name"].is_a?(String)

        status = item["status"].is_a?(String) ? item["status"] : "unknown"
        SandboxEntry.new(name: item["name"], status: status)
      end
    end

    def self.probe_bind(port)
      TCPServer.new("127.0.0.1", port)
    rescue SystemCallError
      nil
    end

    def self.port_open?(port)
      TCPSocket.new("127.0.0.1", port).close
      true
    rescue SystemCallError
      false
    end

    def self.monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    private_class_method :probe_bind, :port_open?, :monotonic
  end
end
