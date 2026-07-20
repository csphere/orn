# frozen_string_literal: true

module Orn
  module TUI
    # Rendering for the per-project TUI: the worktree list with git and agent
    # status, modal prompts, and the help line. Immediate-mode: the whole view
    # is rebuilt from `app` state each tick.
    module Ui
      # The branch-name column stretches to the widest branch, within these
      # bounds; longer names are truncated with an ellipsis.
      BRANCH_COLUMN_MIN = 10
      BRANCH_COLUMN_MAX = 25

      module_function

      # Render the project TUI: title, worktree rows, optional error line, the
      # active modal prompt, and mode-specific help.
      def draw(frame, app)
        title_area, list_area, error_area, modal_area, help_area = split_chunks(
          frame.area,
          !app.error.nil?,
          !app.mode.normal?
        )
        frame.render_widget(Paragraph.line(title_line(app)), title_area)
        frame.render_widget(Paragraph.new(entry_lines(app)), list_area)
        render_optional_rows(
          frame,
          app,
          error_area,
          modal_area
        )
        frame.render_widget(Paragraph.line(help_line(app.mode)), help_area)
      end

      # The error and modal rows only exist while active; split_chunks gave
      # them zero height otherwise.
      def render_optional_rows(frame, app, error_area, modal_area)
        TUI.render_error(frame, app, error_area) unless app.error.nil?
        render_modal(frame, app, modal_area) unless app.mode.normal?
      end

      # Title (2), worktree list (fills), optional error row, optional modal
      # row, help footer (2). Absent rows collapse to zero height.
      def split_chunks(area, has_error, has_modal)
        Layout.vertical(
          [
            Constraint.length(2),
            Constraint.min(1),
            Constraint.length(has_error ? 1 : 0),
            Constraint.length(has_modal ? 1 : 0),
            Constraint.length(2)
          ]
        ).split(area)
      end

      def title_line(app)
        Line.from(
          [
            Span.styled(" orn", Style.default.bold),
            Span.raw(" - "),
            Span.raw(app.repo_name)
          ]
        )
      end

      def entry_lines(app)
        branch_width = branch_column_width(app.entries)
        app.entries.each_with_index.map do |entry, index|
          entry_line(
            app,
            entry,
            index,
            branch_width
          )
        end
      end

      def branch_column_width(entries)
        widest = entries.map { |entry| entry.branch.length }.max || 0
        widest.clamp(BRANCH_COLUMN_MIN, BRANCH_COLUMN_MAX)
      end

      # One worktree row: branch, dirty/window indicators, ahead/behind counts,
      # and, when present, the agent status indicator.
      def entry_line(app, entry, index, branch_width)
        style = index == app.selected ? Style.default.fg(Color::BLACK).bg(Color::WHITE) : Style.default
        dirty_indicator = entry.dirty ? "\u{270e}" : "\u{2714}"
        window_indicator = entry.has_window ? "\u{25cf}" : "\u{25cb}"

        text = " #{TUI.fit(entry.branch, branch_width)} #{dirty_indicator}  " \
          "#{window_indicator} #{entry.ahead}\u{2191} #{entry.behind}\u{2193}"
        spans = [Span.styled(text, style)]
        append_agent_span(
          spans,
          app,
          entry,
          style,
          index
        )
        Line.from(spans)
      end

      def append_agent_span(spans, app, entry, style, index)
        agent_state = app.agent_states[entry.branch]
        return unless agent_state&.agent

        symbol, color, label = Orn::TUI.agent_indicator(agent_state.state, app.spinner_tick)
        agent_style = index == app.selected ? Style.default.fg(color).bg(Color::WHITE) : Style.default.fg(color)
        spans.push(Span.styled("  ", style))
        spans.push(Span.styled("#{symbol} #{label}", agent_style))
      end

      def render_modal(frame, app, chunk)
        frame.render_widget(Paragraph.line(modal_line(app.mode)), chunk)
      end

      def modal_line(mode)
        if mode.new_branch?
          Line.from(
            [
              Span.styled(" Branch: ", Style.default.fg(Color::CYAN)),
              Span.raw(mode.text),
              Span.styled("_", Style.default.fg(Color::DARK_GRAY))
            ]
          )
        else
          Line.styled(" Remove #{mode.text}? y/n", Style.default.fg(Color::YELLOW))
        end
      end

      def help_line(mode)
        text =
          if mode.new_branch?
            " enter:confirm  esc:cancel"
          elsif mode.confirm_remove?
            " y:confirm  any:cancel"
          else
            " enter:open  c:close  n:new  d:remove  q:quit"
          end
        Line.styled(text, Style.default.fg(Color::DARK_GRAY))
      end
    end
  end
end
