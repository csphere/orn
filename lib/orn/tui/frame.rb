# frozen_string_literal: true

module Orn
  module TUI
    # The per-tick draw surface handed to a render pass, wrapping the back
    # buffer. Widgets are rendered into rects, and
    # `area` is the whole terminal.
    class Frame
      def initialize(buffer)
        @buffer = buffer
      end

      def area
        @buffer.area
      end

      # Draw a stateless widget (`Paragraph`) into `rect`.
      def render_widget(widget, rect)
        widget.render(rect, @buffer)
      end

      # Draw a stateful widget (`List`) into `rect`, letting it update `state`
      # (scroll offset).
      def render_stateful_widget(widget, rect, state)
        widget.render(
          rect,
          @buffer,
          state
        )
      end
    end
  end
end
