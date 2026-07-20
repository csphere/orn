# frozen_string_literal: true

module Orn
  class Config
    # Default tmux session name for the global TUI.
    DEFAULT_TUI_SESSION = "orn"

    # Resolved tui settings, read from the global config only (there is no
    # per-project TUI config). Unlike ConfigInfo's TuiInfo, these are plain
    # resolved values without source provenance, for the TUI to consume.
    GlobalTuiConfig = Data.define(
      :session,
      :scan_roots,
      :scan_depth
    ) do
      def self.load
        load_from(Config.global_config_dir)
      end

      def self.load_from(global_dir)
        resolve(tui_section(global_dir))
      end

      # The one place tui defaults and validation live; `orn config show`
      # resolves through here too, so it cannot display a config the TUI
      # would refuse to start with.
      def self.resolve(tui)
        new(
          session: tui["session"] || DEFAULT_TUI_SESSION,
          scan_roots: scan_roots_from(tui["scan_roots"]),
          scan_depth: tui["scan_depth"] || DEFAULT_SCAN_DEPTH
        )
      end

      def self.tui_section(global_dir)
        return {} if global_dir.nil?

        Config.parse_file(File.join(global_dir, GLOBAL_CONFIG_FILENAME))&.tui || {}
      end

      def self.scan_roots_from(roots)
        return current_directory_roots if roots.nil?

        # YAML values get no shell expansion, so a ~-prefixed root would
        # silently never match anything.
        tilde_root = roots.find { |root| root.is_a?(String) && root.start_with?("~") }
        if tilde_root
          raise Orn::Error, "Invalid scan root #{tilde_root.inspect}: use an absolute path (e.g. /home/user/dev)"
        end

        roots
      end

      def self.current_directory_roots
        [Dir.pwd]
      rescue SystemCallError
        []
      end

      private_class_method :tui_section,
        :scan_roots_from,
        :current_directory_roots
    end
  end
end
