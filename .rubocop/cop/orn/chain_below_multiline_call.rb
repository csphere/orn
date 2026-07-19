# frozen_string_literal: true

module RuboCop
  module Cop
    module Orn
      # Flags a chained call whose dot starts a new line below a receiver
      # that is itself a multiline call (arguments broken across lines) or a
      # multiline hash/array literal. Assign the receiver to a named variable
      # and call the method on that instead. Chaining directly on the closing
      # delimiter line (`).entries`) stays legal, as do fluent chains off a
      # single-line receiver. No autocorrect: the variable needs a name only
      # a human can pick.
      class ChainBelowMultilineCall < Base
        MSG = "Assign the multiline receiver to a named variable instead " \
              "of chaining below it."

        def on_send(node)
          dot = node.loc.dot
          return unless dot

          receiver = node.receiver
          return unless receiver
          return unless dot.line > receiver.last_line
          return unless receiver_opens_own_multiline?(receiver)

          add_offense(dot.join(node.loc.selector))
        end
        alias on_csend on_send

        private

        # The receiver counts only when its own delimiters span lines: a call
        # whose closing paren sits below its selector, or a multiline literal.
        # A fluent chain link with single-line arguments never qualifies, so
        # ordinary chains are left alone.
        def receiver_opens_own_multiline?(receiver)
          case receiver.type
          when :send, :csend
            closing = receiver.loc.end
            selector = receiver.loc.selector
            closing && selector && closing.line > selector.line
          when :hash, :array
            receiver.multiline?
          else
            false
          end
        end
      end
    end
  end
end
