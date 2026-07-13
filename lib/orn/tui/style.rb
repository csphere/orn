# frozen_string_literal: true

module Orn
  module TUI
    # The colours orn draws with, as symbols. `:reset` is the terminal default (an unstyled cell).
    module Color
      RESET = :reset
      BLACK = :black
      WHITE = :white
      RED = :red
      GREEN = :green
      YELLOW = :yellow
      CYAN = :cyan
      DARK_GRAY = :dark_gray

      # ANSI SGR foreground codes for the real-terminal backend. Background is
      # this + 10. `:reset` maps to the default (39/49).
      CODES = {
        black: 30,
        red: 31,
        green: 32,
        yellow: 33,
        cyan: 36,
        white: 37,
        dark_gray: 90,
        reset: 39
      }.freeze
    end

    # Foreground colour, background colour, and a bold flag for a run of text.
    # Immutable: the builder methods (`fg`/`bg`/`bold`) return a new `Style`,
    # supporting `Style.default.fg(...).bg(...)` chaining, while the
    # readers (`foreground`/`background`/`bold?`) expose the resolved values.
    # `nil` colours mean "inherit the terminal default".
    class Style
      attr_reader :foreground, :background

      def initialize(foreground: nil, background: nil, bold: false)
        @foreground = foreground
        @background = background
        @bold = bold
      end

      def self.default
        new
      end

      def bold?
        @bold
      end

      def fg(color)
        self.class.new(foreground: color, background: @background, bold: @bold)
      end

      def bg(color)
        self.class.new(foreground: @foreground, background: color, bold: @bold)
      end

      def bold
        self.class.new(foreground: @foreground, background: @background, bold: true)
      end

      def ==(other)
        other.is_a?(Style) &&
          foreground == other.foreground &&
          background == other.background &&
          bold? == other.bold?
      end
      alias eql? ==

      def hash
        [foreground, background, @bold].hash
      end
    end

    # A run of text with one style. The atomic unit a `Line` is built from.
    Span = Data.define(:content, :style) do
      def self.raw(content)
        new(content: content, style: Style.default)
      end

      def self.styled(content, style)
        new(content: content, style: style)
      end
    end

    # A single row of styled text: an ordered list of spans. `Line.from` takes
    # pre-built spans; `Line.styled`/`Line.raw` are shorthands for a one-span
    # line.
    Line = Data.define(:spans) do
      def self.from(spans)
        new(spans: spans)
      end

      def self.raw(content)
        new(spans: [Span.raw(content)])
      end

      def self.styled(content, style)
        new(spans: [Span.styled(content, style)])
      end
    end
  end
end
