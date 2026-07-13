# frozen_string_literal: true

module Orn
  module TUI
    # A rectangular region of the terminal, in cells.
    Rect = Data.define(:x, :y, :width, :height) do
      def self.zero
        new(x: 0, y: 0, width: 0, height: 0)
      end

      def right
        x + width
      end

      def bottom
        y + height
      end
    end

    # A single layout constraint. Only the kinds orn actually uses are
    # modelled: a fixed `length`, a flexible `min` (a floor that absorbs
    # leftover space), a `percentage` of the parent, and a `fill` weight.
    Constraint = Data.define(:kind, :value) do
      def self.length(cells)
        new(kind: :length, value: cells)
      end

      def self.min(cells)
        new(kind: :min, value: cells)
      end

      def self.percentage(percent)
        new(kind: :percentage, value: percent)
      end

      def self.fill(weight)
        new(kind: :fill, value: weight)
      end
    end

    # Splits a `Rect` into sub-regions along one axis under a list of
    # constraints, via `Layout.vertical`/`Layout.horizontal`. orn only
    # ever stacks fixed `length` rows around a single flexible `min` row, so the
    # solver is a two-pass allocator rather than a full cassowary solve: fixed
    # sizes first, then the remainder handed to the flexible constraint.
    class Layout
      def self.vertical(constraints)
        new(:vertical, constraints)
      end

      def self.horizontal(constraints)
        new(:horizontal, constraints)
      end

      def initialize(direction, constraints)
        @direction = direction
        @constraints = constraints
      end

      # Return one `Rect` per constraint, laid out in order along the axis.
      def split(area)
        total = @direction == :vertical ? area.height : area.width
        sizes = solve(total)
        offset = @direction == :vertical ? area.y : area.x
        sizes.map do |size|
          rect = slice(area, offset, size)
          offset += size
          rect
        end
      end

      private

      # Resolve each constraint to a cell count that sums to `total`.
      def solve(total)
        sizes = @constraints.map { |constraint| base_size(constraint, total) }
        remainder = total - sizes.sum
        distribute(sizes, remainder)
        sizes
      end

      def base_size(constraint, total)
        case constraint.kind
        when :length, :min then constraint.value
        when :percentage then total * constraint.value / 100
        when :fill then 0
        end
      end

      # Hand leftover space to the first flexible constraint (fill, else min),
      # or trim an overflow from the trailing constraints.
      def distribute(sizes, remainder)
        return if remainder.zero?

        if remainder.positive?
          index = flexible_index
          sizes[index] += remainder if index
        else
          shrink(sizes, -remainder)
        end
      end

      def flexible_index
        fill = @constraints.index { |c| c.kind == :fill }
        return fill if fill

        @constraints.index { |c| c.kind == :min }
      end

      # Remove `overflow` cells from the back so the sizes still fit.
      def shrink(sizes, overflow)
        index = sizes.length - 1
        while overflow.positive? && index >= 0
          take = [sizes[index], overflow].min
          sizes[index] -= take
          overflow -= take
          index -= 1
        end
      end

      def slice(area, offset, size)
        if @direction == :vertical
          Rect.new(x: area.x, y: offset, width: area.width, height: size)
        else
          Rect.new(x: offset, y: area.y, width: size, height: area.height)
        end
      end
    end
  end
end
