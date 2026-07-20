# frozen_string_literal: true

module Orn
  module Detect
    # Region extraction: slicing a DetectionInput into the named text
    # regions manifest rules match against, split out of manifest.rb. Entry
    # points: region, split_lines, horizontal_rule?.
    module Manifest
      # For tests: extract a region from an input using a fresh line split.
      def self.region(input, spec)
        region_with_lines(
          input,
          split_lines(input.screen),
          spec
        )
      end

      # Extract the text a rule's `region` spec refers to. `lines` must be
      # `split_lines(input.screen)` precomputed by the caller; unknown specs
      # yield an empty region.
      def self.region_with_lines(input, lines, spec)
        trimmed = spec.strip
        return input.osc_title if trimmed == "osc_title"
        return input.osc_progress if trimmed == "osc_progress"

        content = input.screen
        box_region(
          content,
          lines,
          trimmed
        ) ||
          marker_region(content, trimmed) ||
          parameterized_region(
            content,
            lines,
            trimmed
          )
      end

      def self.box_region(content, lines, trimmed)
        case trimmed
        # Despite the name, whole_recent is the entire capture: no recency
        # window is applied and old scrollback is not excluded.
        when "whole_recent" then content
        when "prompt_box_body" then prompt_box_body(content, lines) || ""
        when "above_prompt_box" then above_prompt_box(content, lines)
        when "after_last_horizontal_rule" then after_last_horizontal_rule(content)
        end
      end

      def self.marker_region(content, trimmed)
        case trimmed
        when "after_last_prompt_marker" then after_last_prompt_marker(content, PROMPT_MARKER)
        when "before_last_prompt_marker" then before_last_prompt_marker(content, PROMPT_MARKER)
        end
      end

      def self.parameterized_region(content, lines, trimmed)
        count = region_count(trimmed, "bottom_lines")
        unless count.nil?
          return bottom_lines(
            content,
            lines,
            count
          )
        end

        count = region_count(trimmed, "bottom_non_empty_lines")
        unless count.nil?
          return bottom_non_empty_lines(
            content,
            lines,
            count
          )
        end

        ""
      end

      # Parse the count out of a `name(count)` region spec.
      def self.region_count(spec, name)
        return nil unless spec.start_with?(name)

        rest = spec[name.length..]
        return nil unless rest.start_with?("(") && rest.end_with?(")")

        count = Integer(
          rest[1...-1],
          10,
          exception: false
        )
        count.nil? || count.negative? ? nil : count
      end

      # The suffix of `content` starting at the `count`-th line from the bottom.
      def self.bottom_lines(content, lines, count)
        slice_from_line_index(
          content,
          lines,
          [lines.length - count, 0].max
        )
      end

      # The suffix starting at the `count`-th non-empty line from the bottom;
      # blank lines in between and trailing blanks are kept.
      def self.bottom_non_empty_lines(content, lines, count)
        non_empty = lines.each_index.reject { |index| lines[index].strip.empty? }
        chosen = non_empty.last(count).first
        return "" if chosen.nil?

        slice_from_line_index(
          content,
          lines,
          chosen
        )
      end

      # The lines between the prompt box's top border and the next horizontal
      # rule below it (or the end of the screen); nil when there is no box.
      def self.prompt_box_body(content, lines)
        top = prompt_box_top_border_index(lines)
        return nil if top.nil?

        start = line_start_offset(
          content,
          lines,
          top + 1
        )
        relative = lines[(top + 1)..].index { |line| horizontal_rule?(line) }
        end_index = relative.nil? ? lines.length : top + 1 + relative
        finish = line_start_offset(
          content,
          lines,
          end_index
        )
        content[[start, content.length].min...[finish, content.length].min]
      end

      # Everything above the prompt box's top border, or the whole screen when
      # no prompt box is found.
      def self.above_prompt_box(content, lines)
        top = prompt_box_top_border_index(lines)
        return content if top.nil?

        content[0...[
          line_start_offset(
            content,
            lines,
            top
          ),
          content.length
        ].min]
      end

      # Content after the last horizontal rule line; the whole content when none.
      def self.after_last_horizontal_rule(content)
        last_rule_end = 0
        offset = 0
        split_lines(content).each do |line|
          next_offset = offset + line.length + 1
          last_rule_end = [next_offset, content.length].min if horizontal_rule?(line)
          offset = next_offset
        end
        content[last_rule_end..]
      end

      # Line index of the prompt box's top border: the second horizontal rule
      # counting up from the bottom (the bottom rule closes the box).
      def self.prompt_box_top_border_index(lines)
        border_count = 0
        (lines.length - 1).downto(0) do |index|
          next unless horizontal_rule?(lines[index])

          border_count += 1
          return index if border_count == 2
        end
        nil
      end

      # True for a line of box-drawing dashes: dashes only, or at least three
      # leading dashes followed by text (e.g. `─── context`).
      def self.horizontal_rule?(line)
        trimmed = line.strip
        return false if trimmed.empty?

        rule_chars = trimmed.each_char.take_while { |char| char == "─" }.length
        return false if rule_chars.zero?

        suffix = (trimmed[rule_chars..] || "").lstrip
        suffix.empty? || rule_chars >= 3
      end

      # Content after the last line starting with `marker`; the whole content
      # when no line does.
      def self.after_last_prompt_marker(content, marker)
        last_marker_end = 0
        offset = 0
        split_lines(content).each do |line|
          next_offset = offset + line.length + 1
          last_marker_end = [next_offset, content.length].min if line.start_with?(marker)
          offset = next_offset
        end
        content[last_marker_end..]
      end

      # Content before the last line starting with `marker`; the whole content
      # when no line does.
      def self.before_last_prompt_marker(content, marker)
        last_marker_start = content.length
        offset = 0
        split_lines(content).each do |line|
          last_marker_start = offset if line.start_with?(marker)
          offset += line.length + 1
        end
        content[0...[last_marker_start, content.length].min]
      end

      def self.slice_from_line_index(content, lines, index)
        content[[
          line_start_offset(
            content,
            lines,
            index
          ),
          content.length
        ].min..]
      end

      # Character offset where line `index` starts, assuming one-char `\n`
      # separators; clamped to the content length.
      def self.line_start_offset(content, lines, index)
        offset = lines[0...[index, lines.length].min].sum { |line| line.length + 1 }
        [offset, content.length].min
      end

      # Split into lines on `\n`, stripping a trailing `\r`,
      # with no empty final element from a terminating newline.
      def self.split_lines(text)
        return [] if text.empty?

        parts = text.split("\n", -1)
        parts.pop if text.end_with?("\n")
        parts.map { |line| line.end_with?("\r") ? line[0...-1] : line }
      end
      private_class_method :region_with_lines,
        :box_region,
        :marker_region,
        :parameterized_region,
        :bottom_lines,
        :bottom_non_empty_lines,
        :prompt_box_body,
        :above_prompt_box,
        :after_last_horizontal_rule,
        :prompt_box_top_border_index,
        :after_last_prompt_marker,
        :before_last_prompt_marker,
        :slice_from_line_index,
        :line_start_offset
    end
  end
end
