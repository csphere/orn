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

        # A string that renders as a plain (unquoted) YAML scalar; anything else
        # is double-quoted so the output stays valid, copy-pasteable YAML.
        PLAIN_SCALAR = %r{\A[A-Za-z0-9_][\w./-]*\z}

        # Human-readable YAML rendering with a "(project/global/default)"
        # annotation on each resolved value. The shape mirrors the YAML config
        # file so a user can copy sections straight into `.orn/config.yaml`.
        def render(info)
          lines = [project_config_line(info), global_config_line(info)]
          append_git(lines, info)
          append_tmux(lines, info)
          append_symlinks(lines, info.symlinks)
          append_tui(lines, info.tui)
          lines.join("\n")
        end

        def json(info)
          JSON.generate(info_hash(info))
        end

        private

        def append_git(lines, info)
          lines << ""
          lines << "git:"
          lines << annotate("  base: #{yaml_scalar(info.base.value)}", info.base.source)
        end

        def append_tmux(lines, info)
          lines << ""
          lines << "tmux:"
          lines << annotate("  session: #{yaml_scalar(info.session.value)}", info.session.source) if info.session
          append_layout(lines, info.layout)
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
          lines << annotate("symlinks:", symlinks.source)
          lines << "  base: #{seq(value.base)}" unless value.base.empty?
          return if value.root.empty?

          lines << "  root:"
          value.root.each { |entry| append_root_symlink(lines, entry) }
        end

        def append_root_symlink(lines, entry)
          lines << "    - source: #{yaml_scalar(entry.source)}"
          lines << "      dest: #{yaml_scalar(entry.dest)}" if entry.dest
        end

        def append_layout(lines, layout)
          if layout.value.columns?
            lines << "  columns:"
            layout.value.columns.each { |column| lines << annotate("    - panes: #{seq(column.panes)}", layout.source) }
          else
            lines << "  rows:"
            layout.value.rows.each { |row| append_row(lines, row, layout.source) }
          end
        end

        def append_row(lines, row, source)
          if row.columns?
            lines << annotate("    - columns:", source)
            row.columns.each { |column| lines << "        - panes: #{seq(column.panes)}" }
          else
            lines << annotate("    - panes: #{seq(row.panes)}", source)
          end
        end

        def append_tui(lines, tui)
          lines << ""
          lines << "tui:"
          lines << annotate("  session: #{yaml_scalar(tui.session.value)}", tui.session.source)
          lines << annotate("  scan_roots: #{seq(tui.scan_roots.value)}", tui.scan_roots.source)
          lines << annotate("  scan_depth: #{yaml_scalar(tui.scan_depth.value)}", tui.scan_depth.source)
        end

        # A YAML flow sequence, e.g. ["a", "b"]. Sequence string elements
        # (pane commands, symlink/scan-root paths) are always quoted, matching
        # the config template, since they are commonly commands or paths.
        def seq(values)
          "[#{values.map { |value| value.is_a?(String) ? value.inspect : value.to_s }.join(", ")}]"
        end

        # A scalar value: simple strings plain, anything unsafe double-quoted,
        # non-strings as-is.
        def yaml_scalar(value)
          return value.to_s unless value.is_a?(String)

          value.match?(PLAIN_SCALAR) ? value : value.inspect
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
