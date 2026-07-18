# frozen_string_literal: true

module RuboCop
  module Cop
    module Orn
      # Flags hashes that keep more than one key/value pair on the same line,
      # covering both braced literals and braceless keyword arguments. The
      # autocorrect only inserts the missing line breaks; the enabled Layout
      # cops (FirstHashElementLineBreak, FirstMethodArgumentLineBreak, the
      # indentation and brace-layout cops) finish the formatting on later
      # autocorrect passes.
      class MultiPairHashLineBreaks < Base
        include RangeHelp
        extend AutoCorrector

        MSG = "Write each pair of a multi-pair hash on its own line."

        def on_hash(node)
          return if node.children.size < 2

          node.children.each_cons(2) do |left_pair, right_pair|
            next unless right_pair.first_line == left_pair.last_line

            add_offense(right_pair) do |corrector|
              break_before(corrector, left_pair, right_pair)
            end
          end
        end

        private

        # Replace the ", " separator with ",\n" when it is plain, so the
        # corrected line carries no trailing whitespace; otherwise fall back
        # to inserting a bare newline and let Layout/TrailingWhitespace mop up.
        def break_before(corrector, left_pair, right_pair)
          separator = range_between(
            left_pair.source_range.end_pos,
            right_pair.source_range.begin_pos
          )
          if separator.source.match?(/\A,\s*\z/)
            corrector.replace(separator, ",\n")
          else
            corrector.insert_before(right_pair, "\n")
          end
        end
      end
    end
  end
end
