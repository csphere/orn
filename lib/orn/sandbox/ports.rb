# frozen_string_literal: true

require "json"
require "socket"
require "fileutils"

module Orn
  module Sandbox
    # Host-side port handling for sandboxes: reserving a free host port,
    # publishing it into the container via SbxCli, verifying it accepts TCP
    # connections, and persisting the mappings to
    # `<orn_dir>/sandbox/<name>.ports` so they can be republished after a
    # container restart.
    module Ports
      # Total time verify_port waits for a published port to accept
      # connections.
      VERIFY_TIMEOUT = 30
      # Starting delay for verify_port's exponential backoff (seconds).
      VERIFY_INITIAL_BACKOFF = 0.25

      # Reserves, publishes, and verifies each configured port, then persists
      # the mappings. Entries missing a container port or host range are
      # skipped.
      def self.setup_ports(output_mode, name, ports, orn_dir)
        mappings = []
        ports.each do |entry|
          next if entry.container.nil? || entry.host_range.nil?

          host = reserve_port(entry.host_range)
          output_mode.status("Publishing port #{host}:#{entry.container}...")
          SbxCli.publish_port(
            output_mode,
            name,
            host,
            entry.container
          )
          verify_port(
            host,
            VERIFY_TIMEOUT,
            VERIFY_INITIAL_BACKOFF
          )
          mappings.push(
            PortMapping.new(
              host: host,
              container: entry.container
            )
          )
        end
        unless mappings.empty?
          persist_ports(
            orn_dir,
            name,
            mappings
          )
        end
        mappings
      end

      # Re-publishes previously persisted port mappings, e.g. after a
      # container restart. A missing or unreadable ports file is a no-op.
      def self.republish_ports(output_mode, name, orn_dir)
        mappings = read_persisted_ports(orn_dir, name)
        return [] if mappings.nil?

        mappings.each do |mapping|
          output_mode.status("Publishing port #{mapping}...")
          SbxCli.publish_port(
            output_mode,
            name,
            mapping.host,
            mapping.container
          )
          verify_port(
            mapping.host,
            VERIFY_TIMEOUT,
            VERIFY_INITIAL_BACKOFF
          )
        end
        mappings
      end

      # The first bindable host port in `[start, end]`. The port is probed,
      # not held, so another process can still race for it.
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

      # Writes the mappings as JSON to `<orn_dir>/sandbox/<name>.ports` so
      # they can be republished after a container restart.
      def self.persist_ports(orn_dir, name, mappings)
        sandbox_dir = File.join(orn_dir, "sandbox")
        FileUtils.mkdir_p(sandbox_dir)
        File.write(File.join(sandbox_dir, "#{name}.ports"), JSON.generate(mappings.map(&:to_h)))
        nil
      rescue SystemCallError => e
        raise Orn::Error, "Failed to write sandbox ports for #{name}: #{e.message}"
      end

      # Deletes the persisted ports file plus the legacy single-port `.port`
      # file; missing files are ignored.
      def self.remove_ports_file(orn_dir, name)
        FileUtils.rm_f(
          File.join(
            orn_dir,
            "sandbox",
            "#{name}.ports"
          )
        )
        FileUtils.rm_f(
          File.join(
            orn_dir,
            "sandbox",
            "#{name}.port"
          )
        )
        nil
      end

      # Reads the mappings persisted by persist_ports.
      def self.read_ports(orn_dir, name)
        path = File.join(
          orn_dir,
          "sandbox",
          "#{name}.ports"
        )
        parsed = JSON.parse(File.read(path))
        parsed.map do |entry|
          PortMapping.new(
            host: entry["host"],
            container: entry["container"]
          )
        end
      rescue Errno::ENOENT
        raise Orn::Error, "Failed to read #{path}"
      rescue JSON::ParserError
        raise Orn::Error, "Invalid port data in #{path}"
      end

      # Reads persisted ports, returning nil (rather than raising) when the
      # file is missing or unreadable, so republish can no-op.
      def self.read_persisted_ports(orn_dir, name)
        read_ports(orn_dir, name)
      rescue Orn::Error
        nil
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

      private_class_method :read_persisted_ports,
        :probe_bind,
        :port_open?,
        :monotonic
    end
  end
end
