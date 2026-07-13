# frozen_string_literal: true

require "yaml"

module Orn
  # Merged project configuration: project values win over global values, which
  # win over built-in defaults. Loading never fails; an unreadable or malformed
  # file degrades to the next layer with a warning.
  #
  # The value types and validation live under this class (Column, Layout,
  # SbxConfig, Validate, ...); see config/schema.rb and config/validate.rb.
  class Config
    PROJECT_CONFIG_RELATIVE_PATH = ".orn/config.yaml"
    GLOBAL_CONFIG_FILENAME = "default.yaml"

    attr_reader :base, :session, :symlinks, :layout, :layout_source, :sbx

    def initialize(base:, session:, symlinks:, layout:, layout_source:, sbx:)
      @base = base
      @session = session
      @symlinks = symlinks
      @layout = layout
      @layout_source = layout_source
      @sbx = sbx
    end

    # Like `sbx`, but raises when the config has no sbx section.
    def require_sbx!
      return sbx if sbx

      raise Orn::Error, "No sbx section in .orn/config.yaml"
    end

    # The sbx.columns layout, or nil when sbx is absent or defines no
    # columns.
    def sbx_layout
      return nil if sbx.nil? || sbx.columns.empty?

      Layout.of_columns(sbx.columns)
    end

    # Layout for sandbox windows: the sbx.columns layout when defined
    # (always project-sourced), otherwise the regular layout and its source.
    # Returns [layout, source].
    def effective_sbx_layout
      columns = sbx_layout
      return [columns, :project] if columns

      [layout, layout_source]
    end

    # Loads and merges the project and global config files.
    def self.load(project_root)
      load_from(project_root, global_config_dir)
    end

    def self.load_from(project_root, global_dir)
      project = parse_file(File.join(project_root, PROJECT_CONFIG_RELATIVE_PATH))
      global = global_dir ? parse_file(File.join(global_dir, GLOBAL_CONFIG_FILENAME)) : nil

      layout, layout_source = resolve_layout(project, global)

      new(
        base: project&.base || "main",
        session: resolve_session(project),
        symlinks: project&.symlinks || SymlinksConfig.empty,
        layout: layout,
        layout_source: layout_source,
        sbx: filter_sbx_ports(project&.sbx)
      )
    end

    # Resolves every config value with its source, for `orn config` output.
    def self.info(project_root)
      info_from(project_root, global_config_dir)
    end

    def self.info_from(project_root, global_dir)
      project_path = File.join(project_root, PROJECT_CONFIG_RELATIVE_PATH)
      global_path = global_dir ? File.join(global_dir, GLOBAL_CONFIG_FILENAME) : nil

      project = parse_file(project_path)
      global = global_path ? parse_file(global_path) : nil

      layout_value, layout_source = resolve_layout(project, global)

      ConfigInfo.new(
        project_path: project_path,
        project_exists: File.exist?(project_path),
        global_path: global_path,
        global_exists: global_path ? File.exist?(global_path) : false,
        base: sourced_or_default(project&.base, "main"),
        session: project&.session && Sourced.new(value: project.session, source: :project),
        symlinks: sourced_symlinks(project),
        layout: Sourced.new(value: layout_value, source: layout_source),
        tui: tui_info(global)
      )
    end

    # Persists `tmux.session = name` into the project config, keeping other
    # keys. Round-trips through YAML, so comments are lost.
    def self.write_session(project_root, name)
      Validate.session_name!(name)
      config_path = File.join(project_root, PROJECT_CONFIG_RELATIVE_PATH)
      data = read_yaml_mapping(config_path)
      tmux = data["tmux"]
      tmux = data["tmux"] = {} unless tmux.is_a?(Hash)
      tmux["session"] = name
      File.write(config_path, YAML.dump(data))
      nil
    end

    # Global config directory: $XDG_CONFIG_HOME/orn, falling back to
    # ~/.config/orn.
    def self.global_config_dir
      base = Orn::Fs.xdg_dir("XDG_CONFIG_HOME", ".config")
      return nil if base.nil?

      File.join(base, "orn")
    end

    # Parses one config file into a RawConfig. Returns nil when the file is
    # missing (silently), unreadable, or malformed (both with a warning).
    def self.parse_file(path)
      return nil unless File.exist?(path)

      contents = File.read(path)
      raw_from_hash(YAML.safe_load(contents) || {})
    rescue SystemCallError, Psych::Exception, InvalidConfig => e
      warn "warning: failed to read #{path}: #{e.message}"
      nil
    end

    # Layout precedence: project, then global, then default. A config with both
    # rows and columns is rejected with a warning and the default layout is
    # used. Returns [layout, source].
    def self.resolve_layout(project, global)
      [[project, :project, "config"], [global, :global, "global config"]].each do |raw, source, label|
        next if raw.nil?

        if raw.rows && raw.columns
          warn "warning: #{label} has both rows and columns; using default layout"
          return [default_layout, :default]
        end
        return [Layout.of_rows(raw.rows), source] if raw.rows
        return [Layout.of_columns(raw.columns), source] if raw.columns
      end

      [default_layout, :default]
    end

    # Two columns with one empty pane each (plain shells, no commands).
    def self.default_layout
      Layout.of_columns([Column.new(panes: [""]), Column.new(panes: [""])])
    end

    # The configured session when set and valid; nil (with a warning) when the
    # configured name is invalid.
    def self.resolve_session(project)
      session = project&.session
      return nil if session.nil?

      Validate.session_name!(session)
      session
    rescue Orn::Error => e
      warn "warning: ignoring configured session: #{e.message}"
      nil
    end

    # Drops port entries whose host_range is present but invalid (warning on
    # each). Entries without a host_range are kept.
    def self.filter_sbx_ports(sbx)
      return nil if sbx.nil?

      sbx.with(ports: sbx.ports.select { |port| valid_host_range?(port) })
    end

    def self.valid_host_range?(port)
      return true if port.host_range.nil?

      Validate.host_range!(port.host_range)
      true
    rescue Orn::Error => e
      warn "warning: ignoring port entry: #{e.message}"
      false
    end

    def self.sourced_or_default(value, default)
      return Sourced.new(value: value, source: :project) if value

      Sourced.new(value: default, source: :default)
    end

    def self.sourced_symlinks(project)
      symlinks = project&.symlinks
      return Sourced.new(value: symlinks, source: :project) if symlinks

      Sourced.new(value: SymlinksConfig.empty, source: :default)
    end

    def self.tui_info(global)
      tui = global&.tui || {}
      TuiInfo.new(
        session: sourced_global(tui["session"], "orn"),
        scan_roots: sourced_global(tui["scan_roots"], []),
        scan_depth: sourced_global(tui["scan_depth"], DEFAULT_SCAN_DEPTH)
      )
    end

    def self.sourced_global(value, default)
      return Sourced.new(value: value, source: :global) unless value.nil?

      Sourced.new(value: default, source: :default)
    end

    def self.read_yaml_mapping(path)
      return {} unless File.exist?(path)

      data = YAML.safe_load_file(path)
      data.is_a?(Hash) ? data : {}
    rescue Psych::Exception
      {}
    end

    private_class_method :resolve_layout, :default_layout, :resolve_session,
      :filter_sbx_ports, :valid_host_range?, :sourced_or_default,
      :sourced_symlinks, :tui_info, :sourced_global, :read_yaml_mapping
  end
end
