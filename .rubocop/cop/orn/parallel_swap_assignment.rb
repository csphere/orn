# frozen_string_literal: true

module RuboCop
  module Cop
    module Orn
      # Flags parallel assignment whose right-hand values read the variables
      # being assigned (the swap idiom `a, b = b, a`). Stock
      # Style/ParallelAssignment already forbids independent parallel
      # assignment but deliberately permits swaps; this closes that gap.
      # Rewrite with a temporary variable. Destructuring a method return
      # (`first, rest = entries`) stays legal: it has no sequential form.
      # No autocorrect: the temporary needs a human-chosen name.
      class ParallelSwapAssignment < Base
        MSG = "Use separate assignments with a temporary variable instead " \
              "of a parallel swap."

        def on_masgn(node)
          lhs, rhs = *node
          return unless rhs.array_type?

          target_sources = lhs.children.map(&:source)
          value_reads = [rhs, *rhs.each_descendant].map(&:source)
          return if (target_sources & value_reads).none?

          add_offense(node)
        end
      end
    end
  end
end
