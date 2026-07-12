# frozen_string_literal: true

require "json"

module Orn
  module Commands
    module Config
      # `orn config show`: prints the effective configuration with per-value
      # source annotations (or the resolved ConfigInfo as JSON).
      class Show
        # Column the "(source)" annotation is padded to.
        SOURCE_COLUMN = 42

        def initialize(output_mode:)
          @output_mode = output_mode
        end

        def run
          info = run_inner
          puts(@output_mode.json ? json(info) : render(info))
        end

        # The resolved ConfigInfo (the serializable result).
        def run_inner
          Orn::Config.info(Orn::Git::Project.discover_root)
        end

        # Human-readable rendering with a "(project/global/default)" annotation
        # on each resolved value.
        def render(info)
          lines = [project_config_line(info), global_config_line(info), ""]
          append_scalars(lines, info)
          append_symlinks(lines, info.symlinks)
          append_layout(lines, info.layout)
          append_tui(lines, info.tui)
          lines.join("\n")
        end

        def json(info)
          JSON.generate(info_hash(info))
        end

        private

        def append_scalars(lines, info)
          lines << annotate("[git] base = #{info.base.value.inspect}", info.base.source)
          return unless info.session

          lines << annotate("[tmux] session = #{info.session.value.inspect}", info.session.source)
        end

        def project_config_line(info)
          status = info.project_exists ? "" : " (not found)"
          "Project config: #{info.project_path}#{status}"
        end

        def global_config_line(info)
          return "Global config:  (unavailable)" if info.global_path.nil?

          status = info.global_exists ? "" : " (not found)"
          "Global config:  #{info.global_path}#{status}"
        end

        # Pads `left` to a fixed column and appends the value's source in
        # parentheses (at least two spaces of padding).
        def annotate(left, source)
          padding = [SOURCE_COLUMN - left.length, 2].max
          "#{left}#{" " * padding}(#{source})"
        end

        def append_symlinks(lines, symlinks)
          value = symlinks.value
          return if value.base.empty? && value.root.empty?

          lines << ""
          lines << annotate("[symlinks]", symlinks.source)
          lines << "base = [#{join_inspected(value.base)}]" unless value.base.empty?
          value.root.each { |entry| append_root_symlink(lines, entry) }
        end

        def append_root_symlink(lines, entry)
          lines << ""
          lines << "[[symlinks.root]]"
          lines << "source = #{entry.source.inspect}"
          lines << "dest = #{entry.dest.inspect}" if entry.dest
        end

        def append_layout(lines, layout)
          if layout.value.columns?
            layout.value.columns.each { |column| append_columns_entry(lines, column, layout.source) }
          else
            layout.value.rows.each { |row| append_rows_entry(lines, row, layout.source) }
          end
        end

        def append_columns_entry(lines, column, source)
          lines << ""
          lines << annotate("[[tmux.columns]]", source)
          lines << panes_line(column.panes)
        end

        def append_rows_entry(lines, row, source)
          lines << ""
          lines << annotate("[[tmux.rows]]", source)
          if row.columns?
            row.columns.each { |column| append_nested_columns(lines, column) }
          else
            lines << panes_line(row.panes)
          end
        end

        def append_nested_columns(lines, column)
          lines << ""
          lines << "[[tmux.rows.columns]]"
          lines << panes_line(column.panes)
        end

        def append_tui(lines, tui)
          lines << ""
          lines << annotate("[tui] session = #{tui.session.value.inspect}", tui.session.source)
          lines << annotate("[tui] scan_roots = [#{join_inspected(tui.scan_roots.value)}]", tui.scan_roots.source)
          lines << annotate("[tui] scan_depth = #{tui.scan_depth.value}", tui.scan_depth.source)
        end

        def panes_line(panes)
          "panes = [#{join_inspected(panes)}]"
        end

        def join_inspected(values)
          values.map(&:inspect).join(", ")
        end

        def info_hash(info)
          {
            "project_path" => info.project_path,
            "project_exists" => info.project_exists,
            "global_path" => info.global_path,
            "global_exists" => info.global_exists,
            "base" => sourced_hash(info.base) { |value| value },
            "session" => info.session && sourced_hash(info.session) { |value| value },
            "symlinks" => sourced_hash(info.symlinks) { |value| symlinks_hash(value) },
            "layout" => sourced_hash(info.layout) { |value| layout_hash(value) },
            "tui" => tui_hash(info.tui)
          }
        end

        def sourced_hash(sourced)
          { "value" => yield(sourced.value), "source" => sourced.source.to_s }
        end

        def symlinks_hash(symlinks)
          {
            "base" => symlinks.base,
            "root" => symlinks.root.map { |entry| { "source" => entry.source, "dest" => entry.dest } }
          }
        end

        def layout_hash(layout)
          return { "columns" => layout.columns.map { |column| { "panes" => column.panes } } } if layout.columns?

          { "rows" => layout.rows.map { |row| row_hash(row) } }
        end

        def row_hash(row)
          return { "columns" => row.columns.map { |column| { "panes" => column.panes } } } if row.columns?

          { "panes" => row.panes }
        end

        def tui_hash(tui)
          {
            "session" => sourced_hash(tui.session) { |value| value },
            "scan_roots" => sourced_hash(tui.scan_roots) { |value| value },
            "scan_depth" => sourced_hash(tui.scan_depth) { |value| value }
          }
        end
      end
    end
  end
end
