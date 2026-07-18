# frozen_string_literal: true

module Orn
  module TUI
    # Rendering for the per-project TUI: the worktree list with git and agent
    # status, modal prompts, and the help line. Immediate-mode: the whole view
    # is rebuilt from `app` state each tick.
    module Ui
      module_function

      # Render the project TUI: title, worktree rows, optional error line, the
      # active modal prompt, and mode-specific help.
      def draw(frame, app)
        chunks = split_chunks(frame.area, !app.error.nil?, !app.mode.normal?)
        render_header(frame, app, chunks)
        render_body(frame, app, chunks)
      end

      def render_header(frame, app, chunks)
        frame.render_widget(Paragraph.line(title_line(app)), chunks[0])
        frame.render_widget(Paragraph.new(entry_lines(app)), chunks[1])
      end

      def render_body(frame, app, chunks)
        render_error(frame, app, chunks[2]) unless app.error.nil?
        render_modal(frame, app, chunks[3]) unless app.mode.normal?
        frame.render_widget(Paragraph.line(help_line(app.mode)), chunks[4])
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
        app.entries.each_with_index.map { |entry, index| entry_line(app, entry, index) }
      end

      # One worktree row: branch, dirty/window indicators, ahead/behind counts,
      # and, when present, the agent status indicator.
      def entry_line(app, entry, index)
        style = index == app.selected ? Style.default.fg(Color::BLACK).bg(Color::WHITE) : Style.default
        dirty_indicator = entry.dirty ? "\u{270e}" : "\u{2714}"
        window_indicator = entry.has_window ? "\u{25cf}" : "\u{25cb}"

        text = " #{entry.branch.ljust(24)} #{dirty_indicator}  " \
               "#{window_indicator} #{entry.ahead}\u{2191} #{entry.behind}\u{2193}"
        spans = [Span.styled(text, style)]
        append_agent_span(spans, app, entry, style, index)
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

      def render_error(frame, app, chunk)
        frame.render_widget(Paragraph.line(Line.styled(" #{app.error}", Style.default.fg(Color::RED))), chunk)
      end

      def render_modal(frame, app, chunk)
        frame.render_widget(Paragraph.line(modal_line(app.mode)), chunk)
      end

      def modal_line(mode)
        if mode.new_branch?
          Line.from(
            [
              Span.styled(" Branch: ", Style.default.fg(Color::CYAN)),
              Span.raw(mode.input),
              Span.styled("_", Style.default.fg(Color::DARK_GRAY))
            ]
          )
        else
          Line.styled(" Remove #{mode.branch}? y/n", Style.default.fg(Color::YELLOW))
        end
      end

      def help_line(mode)
        text =
          if mode.new_branch?
            " enter:confirm  esc:cancel"
          elsif mode.confirm_remove?
            " y:confirm  any:cancel"
          else
            " enter:open  c:close  n:new  d:remove  r:refresh  q:quit"
          end
        Line.styled(text, Style.default.fg(Color::DARK_GRAY))
      end
    end
  end
end
