# frozen_string_literal: true

require "json"
require "fileutils"

module Orn
  module Mcp
    # One-time registration of the orn MCP server in Claude Code's user config
    # (`~/.claude.json`).
    module Setup
      # Adds (or overwrites) an `orn` entry under `mcpServers`, pointing at the
      # orn launcher with the `mcp` arg. The rest of the file is preserved.
      def self.register
        path = claude_json_path
        register_into(path, orn_command, ["mcp"], "orn")
        puts "Registered orn MCP server in #{path}"
        puts "Restart Claude Code to pick up the new server."
      end

      # Testable core: merge an `mcpServers.<name>` entry into `config_path`,
      # preserving every other key, and write pretty JSON with a trailing
      # newline. Returns the path written.
      def self.register_into(config_path, command, args, name)
        config = read_config(config_path)
        raise Orn::Error, "~/.claude.json is not a JSON object" unless config.is_a?(Hash)

        servers = (config["mcpServers"] ||= {})
        raise Orn::Error, "mcpServers in ~/.claude.json is not a JSON object" unless servers.is_a?(Hash)

        servers[name] = { "command" => command, "args" => args }
        FileUtils.mkdir_p(File.dirname(config_path))
        File.write(config_path, "#{JSON.pretty_generate(config)}\n")
        config_path
      end

      # The orn launcher path to register: the currently running executable, so
      # Claude Code invokes the same orn the user set up with.
      def self.orn_command
        File.expand_path($PROGRAM_NAME)
      end

      def self.claude_json_path
        home = Orn::Fs.home_dir
        raise Orn::Error, "HOME not set" if home.nil?

        File.join(home, ".claude.json")
      end

      def self.read_config(path)
        return {} unless File.exist?(path)

        JSON.parse(File.read(path))
      rescue JSON::ParserError
        raise Orn::Error, "~/.claude.json is not valid JSON"
      end

      private_class_method :read_config
    end
  end
end
