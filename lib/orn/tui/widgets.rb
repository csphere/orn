# frozen_string_literal: true

module Orn
  module TUI
    # A stack of styled lines drawn top-to-bottom in an area, one line per row.
    # Lines past the area height are clipped; no line wrapping.
    class Paragraph
      def initialize(lines)
        @lines = lines
      end

      # A single-line paragraph, the common case.
      def self.line(line)
        new([line])
      end

      def render(area, buffer)
        @lines.each_with_index do |line, row|
          break if row >= area.height

          buffer.set_line(
            area.x,
            area.y + row,
            line,
            area.width
          )
        end
      end
    end

    # One row of a `List`, wrapping a `Line`. Selection styling lives in the
    # line's spans (orn pre-styles the selected row), so the list widget itself
    # applies no highlight.
    ListItem = Data.define(:line)

    # Mutable scroll/selection state for a `List`, held by the app across
    # frames. `offset` is the index of the
    # first visible row; the list widget keeps it in sync so the selected row
    # stays on screen.
    class ListState
      attr_accessor :offset, :selected

      def initialize
        @offset = 0
        @selected = nil
      end

      def select(index)
        @selected = index
      end
    end

    # A vertical list of pre-styled items with scroll-follow. Each item is one
    # row tall; the widget adjusts the state's offset to keep the selection
    # visible, then draws the visible slice.
    class List
      def initialize(items)
        @items = items
      end

      def render(area, buffer, state)
        return if area.height <= 0

        state.offset = self.class.follow_offset(
          state.offset,
          state.selected,
          area.height
        )
        last = [state.offset + area.height, @items.length].min
        (state.offset...last).each_with_index do |item_index, row|
          buffer.set_line(
            area.x,
            area.y + row,
            @items[item_index].line,
            area.width
          )
        end
      end

      # List scroll-follow for single-height rows: pull the offset up
      # to a selection above the viewport, or push it down to keep a selection
      # below the viewport in view.
      def self.follow_offset(offset, selected, height)
        return offset if selected.nil?

        if selected < offset
          selected
        elsif selected >= offset + height
          selected - height + 1
        else
          offset
        end
      end
    end
  end
end
