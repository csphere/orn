# frozen_string_literal: true

module RuboCop
  module Cop
    module Orn
      # Flags blank lines between the items of a multiline array or hash,
      # including braceless keyword arguments. Comment lines between items
      # stay legal; only fully blank lines are removed. An item that opens
      # a heredoc ends at the heredoc terminator, so blank lines inside the
      # heredoc body are left alone.
      class EmptyLinesBetweenCollectionItems < Base
        include RangeHelp
        extend AutoCorrector

        MSG = "Do not leave blank lines between collection items."

        def on_hash(node)
          check_gaps(node)
        end

        def on_array(node)
          check_gaps(node)
        end

        private

        def check_gaps(node)
          node.children.each_cons(2) do |left_item, right_item|
            blank_lines = blank_lines_between(left_item, right_item)
            next if blank_lines.empty?

            add_offense(right_item) do |corrector|
              blank_lines.each do |line_number|
                line = processed_source.buffer.line_range(line_number)
                corrector.remove(range_by_whole_lines(line, include_final_newline: true))
              end
            end
          end
        end

        def blank_lines_between(left_item, right_item)
          gap_lines = (last_line_with_heredocs(left_item) + 1)...right_item.first_line
          gap_lines.select do |line_number|
            processed_source.lines[line_number - 1].strip.empty?
          end
        end

        def last_line_with_heredocs(node)
          heredoc_end_lines = [node, *node.each_descendant].filter_map do |child|
            child.loc.heredoc_end.line if child.loc.respond_to?(:heredoc_end)
          end
          [node.last_line, *heredoc_end_lines].max
        end
      end
    end
  end
end
