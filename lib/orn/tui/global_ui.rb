# frozen_string_literal: true

module Orn
  module TUI
    # Rendering for the global TUI sidebar: the repo/worktree tree with
    # session, git, and agent indicators. Immediate-mode over the substrate.
    module GlobalUi
      module_function

      HELP_LINES = [
        " enter:open  space:expand  x:hide tab",
        " M-o:sidebar  M-i:agent  M-n/p:cycle  q:quit"
      ].freeze

      # Fixed name-column widths per row type. The two are independent (repo
      # rows carry an expand marker, worktree rows a two-space indent); they
      # are not tuned to align with each other or with the project TUI's
      # Ui::BRANCH_COLUMN_WIDTH.
      REPO_NAME_WIDTH = 28
      WORKTREE_BRANCH_WIDTH = 26

      # Render the global TUI: title, repo/worktree tree, optional error line,
      # and the help footer.
      def draw(frame, app)
        chunks = split_chunks(frame.area, !app.error.nil?)
        frame.render_widget(Paragraph.line(Line.styled(" orn", Style.default.bold)), chunks[0])
        render_tree(
          frame,
          app,
          chunks[1]
        )
        unless app.error.nil?
          render_error(
            frame,
            app,
            chunks[2]
          )
        end
        frame.render_widget(Paragraph.new(help_lines), chunks[3])
      end

      def split_chunks(area, has_error)
        Layout.vertical(
          [
            Constraint.length(2),
            Constraint.min(1),
            Constraint.length(has_error ? 1 : 0),
            Constraint.length(2)
          ]
        ).split(area)
      end

      def render_tree(frame, app, chunk)
        rows = app.visible_rows
        if rows.empty?
          empty = Line.styled(" No orn repos found", Style.default.fg(Color::DARK_GRAY))
          return frame.render_widget(Paragraph.line(empty), chunk)
        end

        selected = app.list_state.selected
        items = rows.each_with_index.map do |row, i|
          ListItem.new(
            row_line(
              app,
              row,
              selected == i
            )
          )
        end
        frame.render_stateful_widget(
          List.new(items),
          chunk,
          app.list_state
        )
      end

      def row_line(app, row, is_selected)
        if row.repo?
          repo_line(
            app,
            app.entries[row.repo_index],
            is_selected
          )
        else
          worktree_line(
            app,
            row.repo_index,
            row.wt_index,
            is_selected
          )
        end
      end

      def render_error(frame, app, chunk)
        frame.render_widget(Paragraph.line(Line.styled(" #{app.error}", Style.default.fg(Color::RED))), chunk)
      end

      def help_lines
        HELP_LINES.map { |text| Line.styled(text, Style.default.fg(Color::DARK_GRAY)) }
      end

      # A repo row: expand marker, name, aggregate agent indicator, and
      # session/worktree counts. Unhealthy repos are grayed out.
      def repo_line(app, entry, is_selected)
        style = row_style(is_selected)
        style = style.fg(Color::DARK_GRAY) unless entry.healthy
        expand_marker = entry.expanded ? "\u{25be}" : "\u{25b8}"
        session_indicator = entry.session_alive ? "\u{25cf}" : "\u{25cb}"

        spans = [Span.styled(" #{expand_marker} #{entry.display_name.ljust(REPO_NAME_WIDTH)} ", style)]
        append_repo_agent(
          spans,
          app,
          entry,
          style,
          is_selected
        )
        counts = "#{session_indicator} #{entry.window_count.to_s.rjust(2)} active  #{entry.worktree_count} wt"
        spans.push(Span.styled(counts, style))
        Line.from(spans)
      end

      def append_repo_agent(spans, app, entry, style, is_selected)
        state = entry.aggregate_agent_state
        return unless state

        symbol, color, label = Orn::TUI.agent_indicator(state, app.spinner_tick)
        spans.push(Span.styled("#{symbol} #{label}", agent_style(color, is_selected)))
        spans.push(Span.styled("  ", style))
      end

      # A worktree row: tab gutter, branch, dirty and window indicators,
      # ahead/behind counts, sandbox badge, and agent indicator.
      def worktree_line(app, repo_idx, wt_idx, is_selected)
        entry = app.entries[repo_idx]
        worktree = entry.worktrees[wt_idx]
        style = row_style(is_selected)

        gutter, gutter_style = tab_gutter(
          app,
          entry,
          worktree,
          style
        )
        spans = [
          Span.styled(" #{gutter} ", gutter_style),
          Span.styled(worktree_columns(worktree), style)
        ]
        append_sandbox_badge(
          spans,
          worktree,
          is_selected
        )
        append_worktree_agent(
          spans,
          app,
          worktree,
          is_selected
        )
        Line.from(spans)
      end

      def worktree_columns(worktree)
        window_indicator = worktree.has_window ? "\u{25cf}" : "\u{25cb}"
        "  #{worktree.branch.ljust(WORKTREE_BRANCH_WIDTH)} #{dirty_indicator(worktree)}  " \
          "#{window_indicator} #{ahead_behind(worktree).ljust(7)} "
      end

      # A heavy bar marks the visible tab (yellow while its agent pane has
      # focus), a light bar an open-but-hidden tab, a space for no tab.
      def tab_gutter(app, entry, worktree, style)
        tabs = app.tabs
        tab_idx = tabs.tab_index_for(entry.root, worktree.branch)
        if tab_idx && tabs.visible_index == tab_idx
          color = tabs.agent_focused ? Color::YELLOW : Color::WHITE
          ["\u{2503}", Style.default.fg(color).bold]
        elsif tab_idx
          ["\u{2502}", Style.default.fg(Color::DARK_GRAY)]
        else
          [" ", style]
        end
      end

      def dirty_indicator(worktree)
        case worktree.dirty
        when true then "\u{270e}"
        when false then "\u{2714}"
        else " "
        end
      end

      def ahead_behind(worktree)
        return "" unless worktree.ahead_behind

        ahead, behind = worktree.ahead_behind
        "#{ahead}\u{2191} #{behind}\u{2193}"
      end

      def append_sandbox_badge(spans, worktree, is_selected)
        return unless worktree.sandboxed

        badge_style = is_selected ? Style.default.fg(Color::CYAN).bg(Color::WHITE) : Style.default.fg(Color::CYAN)
        spans.push(Span.styled("\u{2b1a} ", badge_style))
      end

      def append_worktree_agent(spans, app, worktree, is_selected)
        agent = worktree.agent
        return unless agent&.agent

        symbol, color, label = Orn::TUI.agent_indicator(agent.state, app.spinner_tick)
        spans.push(Span.styled("#{symbol} #{label}", agent_style(color, is_selected)))
      end

      def row_style(is_selected)
        is_selected ? Style.default.fg(Color::BLACK).bg(Color::WHITE) : Style.default
      end

      def agent_style(color, is_selected)
        is_selected ? Style.default.fg(color).bg(Color::WHITE) : Style.default.fg(color)
      end
    end
  end
end
