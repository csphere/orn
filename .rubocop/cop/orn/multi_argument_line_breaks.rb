# frozen_string_literal: true

module RuboCop
  module Cop
    module Orn
      # Flags calls whose argument count exceeds MaxArgsOnOneLine while any
      # two arguments share a line. The autocorrect inserts the line breaks;
      # the enabled Layout cops finish the formatting on later passes. A
      # braceless keyword-argument hash counts as one argument here, since
      # Orn/MultiPairHashLineBreaks already handles its pairs. Methods in
      # AllowedMethods (CLI wrappers whose arguments are shell words) stay
      # inline at any argument count.
      class MultiArgumentLineBreaks < Base
        include RangeHelp
        extend AutoCorrector

        MSG = "Write each argument on its own line when a call has more " \
              "than %<max>d arguments."

        def on_send(node)
          return if allowed_method?(node.method_name)

          arguments = node.arguments
          return if arguments.size <= max_args_on_one_line

          arguments.each_cons(2) do |left_arg, right_arg|
            next unless right_arg.first_line == left_arg.last_line

            message = format(MSG, max: max_args_on_one_line)
            add_offense(right_arg, message: message) do |corrector|
              break_before(corrector, left_arg, right_arg)
            end
          end
        end
        alias on_csend on_send

        private

        def max_args_on_one_line
          cop_config.fetch("MaxArgsOnOneLine", 2)
        end

        def allowed_method?(method_name)
          cop_config.fetch("AllowedMethods", []).include?(method_name.to_s)
        end

        # Replace the ", " separator with ",\n" when it is plain, so the
        # corrected line carries no trailing whitespace; otherwise fall back
        # to inserting a bare newline and let Layout/TrailingWhitespace mop up.
        def break_before(corrector, left_arg, right_arg)
          separator = range_between(
            left_arg.source_range.end_pos,
            right_arg.source_range.begin_pos
          )
          if separator.source.match?(/\A,\s*\z/)
            corrector.replace(separator, ",\n")
          else
            corrector.insert_before(right_arg, "\n")
          end
        end
      end
    end
  end
end
