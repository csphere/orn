# frozen_string_literal: true

module Orn
  module TUI
    # One terminal cell: the grapheme drawn there plus its colours and weight.
    # A blank cell is a space with the terminal-default style.
    class Cell
      attr_accessor :symbol,
        :fg,
        :bg,
        :bold

      def initialize(symbol: " ", fg: Color::RESET, bg: Color::RESET, bold: false)
        @symbol = symbol
        @fg = fg
        @bg = bg
        @bold = bold
      end

      def set(symbol, style)
        @symbol = symbol
        @fg = style.foreground || Color::RESET
        @bg = style.background || Color::RESET
        @bold = style.bold?
      end
    end

    # A width x height grid of `Cell`s covering a `Rect`, the surface widgets
    # draw into. orn's glyphs are all single-column, so one character maps to
    # one cell (no wide-char skip handling), which keeps cell positions exact.
    class Buffer
      attr_reader :area

      def initialize(area)
        @area = area
        @cells = Array.new(area.width * area.height) { Cell.new }
      end

      def self.empty(area)
        new(area)
      end

      # The cell at absolute (x, y), or nil when outside the buffer.
      def cell(x, y)
        return nil unless x >= @area.x && x < @area.right && y >= @area.y && y < @area.bottom

        @cells[index(x, y)]
      end

      # `buf[[x, y]]` accessor for reading a cell by coordinate.
      def [](coord)
        cell(coord[0], coord[1])
      end

      # Every cell in row-major order, for tests that reconstruct the screen.
      def content
        @cells
      end

      # Concatenated symbols of every cell, so tests can assert on the
      # rendered screen contents.
      def to_s
        @cells.map(&:symbol).join
      end

      # Draw one styled line at (x, y), clipping to `max_width` and the buffer
      # edge. Characters past the limit are dropped, not wrapped.
      def set_line(x, y, line, max_width)
        cursor = x
        limit = x + max_width
        line.spans.each do |span|
          span.content.each_char do |char|
            break if cursor >= limit

            target = cell(cursor, y)
            target&.set(char, span.style)
            cursor += 1
          end
        end
        cursor
      end

      private

      def index(x, y)
        ((y - @area.y) * @area.width) + (x - @area.x)
      end
    end
  end
end
