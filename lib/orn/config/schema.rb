# frozen_string_literal: true

module Orn
  class Config
    # Raised when a config file has a value of the wrong shape or type. The
    # loader catches it and treats the file as malformed, falling back to the
    # next layer (a malformed file is treated as absent).
    class InvalidConfig < Orn::Error; end

    # Default directory depth for project scanning when scan_depth is unset.
    DEFAULT_SCAN_DEPTH = 3

    # The config layer a resolved value came from. Plain symbols; `to_s` gives
    # the label shown by `orn config` ("project"/"global"/"default").
    SOURCES = %i[project global default].freeze

    # A vertical stack of panes; each entry is a shell command ("" = a plain
    # shell).
    Column = Data.define(:panes)

    # One row of a rows-layout: a list of panes, or nested columns, never both.
    # A columns-row has a non-empty `columns`; a panes-row has `columns` empty.
    Row = Data.define(:panes, :columns) do
      def columns?
        !columns.empty?
      end
    end

    # Top-level pane arrangement for a window: side-by-side columns or stacked
    # rows. Exactly one of `columns` / `rows` is non-nil.
    Layout = Data.define(:columns, :rows) do
      def self.of_columns(columns)
        new(columns: columns, rows: nil)
      end

      def self.of_rows(rows)
        new(columns: nil, rows: rows)
      end

      def columns?
        !columns.nil?
      end

      def rows?
        !rows.nil?
      end
    end

    # One [[symlinks.root]] entry: a project-root path linked into each
    # worktree.
    RootSymlink = Data.define(:source, :dest) do
      # Link name in the worktree: `dest` when set, otherwise the basename of
      # `source`.
      def effective_dest
        return dest if dest && !dest.empty?

        basename = File.basename(source)
        basename.empty? ? source : basename
      end
    end

    SymlinksConfig = Data.define(:base, :root) do
      def self.empty
        new(base: [], root: [])
      end
    end

    SbxBuild = Data.define(:dockerfile, :build_args)

    # One sandbox port mapping. Entries missing either field are skipped when
    # ports are set up.
    SbxPorts = Data.define(:container, :host_range)

    SbxConfig = Data.define(
      :template, :kit, :kits, :cpus, :memory, :agent_type,
      :setup, :start, :build, :env, :ports, :columns
    ) do
      # All kits to install: `kits`, with the legacy singular `kit` prepended
      # when not already present.
      def all_kits
        return kits if kit.nil? || kits.include?(kit)

        [kit, *kits]
      end

      def require_agent_type!
        return agent_type if agent_type

        raise Orn::Error,
          "No agent_type configured in [sbx]\n  " \
          "Set agent_type to the agent to run (e.g. agent_type: claude)"
      end

      def require_build!
        raise Orn::Error, "No [sbx.build] section in .orn/config.yaml" if build.nil?
        raise Orn::Error, "No template configured in [sbx]" if template.nil?

        [build, template]
      end
    end

    # A resolved config value paired with the layer it came from (a SOURCES
    # symbol).
    Sourced = Data.define(:value, :source)

    # Resolved [tui] values (each a Sourced), read from the global config only.
    TuiInfo = Data.define(:session, :scan_roots, :scan_depth)

    # One config file's values as parsed and normalized, before merging.
    RawConfig = Data.define(:base, :session, :columns, :rows, :symlinks, :sbx, :tui)

    # Full resolved configuration with per-value sources, for `orn config`.
    ConfigInfo = Data.define(
      :project_path, :project_exists, :global_path, :global_exists,
      :base, :session, :symlinks, :layout, :tui
    )

    # Normalizes a parsed YAML mapping into a RawConfig, raising InvalidConfig
    # on any value of the wrong type.
    def self.raw_from_hash(hash)
      raise InvalidConfig, "config root must be a mapping" unless hash.is_a?(Hash)

      git = section(hash, "git")
      tmux = section(hash, "tmux")
      tui = section(hash, "tui")

      RawConfig.new(
        base: optional_string(git, "base", "git.base"),
        session: optional_string(tmux, "session", "tmux.session"),
        columns: tmux.key?("columns") ? column_list(tmux["columns"]) : nil,
        rows: tmux.key?("rows") ? row_list(tmux["rows"]) : nil,
        symlinks: hash.key?("symlinks") ? symlinks_from(hash["symlinks"]) : nil,
        sbx: hash.key?("sbx") ? sbx_from(hash["sbx"]) : nil,
        tui: tui.empty? ? nil : tui
      )
    end

    def self.section(hash, key)
      value = hash[key]
      return {} if value.nil?
      raise InvalidConfig, "[#{key}] must be a mapping" unless value.is_a?(Hash)

      value
    end

    def self.optional_string(section, key, label)
      value = section[key]
      return nil if value.nil?
      raise InvalidConfig, "#{label} must be a string" unless value.is_a?(String)

      value
    end

    def self.optional_integer(section, key, label)
      value = section[key]
      return nil if value.nil?
      raise InvalidConfig, "#{label} must be an integer" unless value.is_a?(Integer)

      value
    end

    def self.string_list?(value)
      value.is_a?(Array) && value.all?(String)
    end

    def self.string_list_field(section, key, label)
      value = section.fetch(key, [])
      raise InvalidConfig, "#{label} must be a list of strings" unless string_list?(value)

      value
    end

    # Accepts columns as verbose tables ([{ panes: [...] }]) or the inline
    # shorthand ([["cmd1"], ["cmd2"]]).
    def self.column_list(raw)
      raise InvalidConfig, "columns must be a list" unless raw.is_a?(Array)

      raw.map { |entry| column_from(entry) }
    end

    def self.column_from(entry)
      return Column.new(panes: entry) if string_list?(entry) # inline: entry is the panes list

      raise InvalidConfig, "invalid column entry" unless entry.is_a?(Hash)

      panes = entry.fetch("panes", [])
      raise InvalidConfig, "column panes must be a list of strings" unless string_list?(panes)

      Column.new(panes: panes)
    end

    def self.row_list(raw)
      raise InvalidConfig, "rows must be a list" unless raw.is_a?(Array)

      raw.map { |entry| row_from(entry) }
    end

    def self.row_from(entry)
      raise InvalidConfig, "row must be a table" unless entry.is_a?(Hash)

      panes = entry.fetch("panes", [])
      raise InvalidConfig, "row panes must be a list of strings" unless string_list?(panes)

      columns = entry.key?("columns") ? column_list(entry["columns"]) : []
      if !panes.empty? && !columns.empty?
        raise InvalidConfig, "row cannot have both `panes` and `columns`; use one or the other"
      end

      return Row.new(panes: [], columns: columns) unless columns.empty?

      Row.new(panes: panes, columns: [])
    end

    def self.symlinks_from(raw)
      raise InvalidConfig, "[symlinks] must be a mapping" unless raw.is_a?(Hash)

      root_raw = raw.fetch("root", [])
      raise InvalidConfig, "symlinks.root must be a list" unless root_raw.is_a?(Array)

      SymlinksConfig.new(
        base: string_list_field(raw, "base", "symlinks.base"),
        root: root_raw.map { |entry| root_symlink_from(entry) }
      )
    end

    def self.root_symlink_from(entry)
      raise InvalidConfig, "symlinks.root entry must be a table" unless entry.is_a?(Hash)

      source = entry["source"]
      raise InvalidConfig, "symlinks.root source must be a string" unless source.is_a?(String)

      dest = entry["dest"]
      raise InvalidConfig, "symlinks.root dest must be a string" unless dest.nil? || dest.is_a?(String)

      RootSymlink.new(source: source, dest: dest)
    end

    def self.sbx_from(raw)
      raise InvalidConfig, "[sbx] must be a mapping" unless raw.is_a?(Hash)

      SbxConfig.new(
        template: optional_string(raw, "template", "sbx.template"),
        kit: optional_string(raw, "kit", "sbx.kit"),
        kits: string_list_field(raw, "kits", "sbx.kits"),
        cpus: optional_integer(raw, "cpus", "sbx.cpus"),
        memory: optional_string(raw, "memory", "sbx.memory"),
        agent_type: optional_string(raw, "agent_type", "sbx.agent_type"),
        setup: string_or_array(raw["setup"], "sbx.setup"),
        start: optional_string(raw, "start", "sbx.start"),
        build: raw.key?("build") ? sbx_build_from(raw["build"]) : nil,
        env: env_from(raw["env"]),
        ports: ports_from(raw["ports"]),
        columns: raw.key?("columns") ? column_list(raw["columns"]) : []
      )
    end

    def self.sbx_build_from(raw)
      raise InvalidConfig, "[sbx.build] must be a mapping" unless raw.is_a?(Hash)

      SbxBuild.new(
        dockerfile: optional_string(raw, "dockerfile", "sbx.build.dockerfile"),
        build_args: string_list_field(raw, "build_args", "sbx.build.build_args")
      )
    end

    def self.string_or_array(value, label)
      return [] if value.nil?
      return [value] if value.is_a?(String)
      return value if string_list?(value)

      raise InvalidConfig, "#{label} must be a string or a list of strings"
    end

    def self.env_from(value)
      return {} if value.nil?
      unless value.is_a?(Hash) && value.all? { |key, val| key.is_a?(String) && val.is_a?(String) }
        raise InvalidConfig, "[sbx.env] must be a mapping of strings to strings"
      end

      value
    end

    # Accepts a single port table or an array of port tables.
    def self.ports_from(value)
      return [] if value.nil?
      return [port_from(value)] if value.is_a?(Hash)
      return value.map { |entry| port_from(entry) } if value.is_a?(Array)

      raise InvalidConfig, "sbx.ports must be a table or a list of tables"
    end

    def self.port_from(raw)
      raise InvalidConfig, "sbx port must be a table" unless raw.is_a?(Hash)

      container = raw["container"]
      raise InvalidConfig, "sbx port container must be an integer" unless container.nil? || container.is_a?(Integer)

      host_range = raw["host_range"]
      raise InvalidConfig, "sbx port host_range must be [start, end]" unless port_range_shape?(host_range)

      SbxPorts.new(container: container, host_range: host_range)
    end

    def self.port_range_shape?(value)
      value.nil? || (value.is_a?(Array) && value.size == 2 && value.all?(Integer))
    end

    private_class_method :raw_from_hash, :section, :optional_string, :optional_integer,
      :string_list?, :string_list_field, :column_list, :column_from,
      :row_list, :row_from, :symlinks_from, :root_symlink_from,
      :sbx_from, :sbx_build_from, :string_or_array, :env_from,
      :ports_from, :port_from, :port_range_shape?
  end
end
