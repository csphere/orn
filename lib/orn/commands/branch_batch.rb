# frozen_string_literal: true

module Orn
  module Commands
    # Shared driver for the batch remove commands (`orn remove`, `orn wt
    # remove`): validate branch names, discover the project, confirm prunes
    # interactively, run the per-branch block, and finish with JSON output
    # plus a failure count. One branch's failure is reported but does not
    # stop the rest.
    module BranchBatch
      def self.run(output_mode, branches, prune:, force:)
        branches.each { |branch| Orn::Git::BranchName.new(branch).validate! }
        project = Orn::Git::Project.discover
        confirm_prunes(project.root, branches) if prune && !force && !output_mode.json

        results, errors = Output.run_multi_branch(
          output_mode,
          branches,
          lambda(&:print_summary)
        ) { |branch| yield(project, branch) }
        Output.finish_multi_branch(
          output_mode,
          results.map(&:to_json_hash),
          errors,
          branches.length,
          action: "remove"
        )
      end

      def self.confirm_prunes(project_root, branches)
        branches.each { |branch| Orn::Confirm.prune_interactive(project_root, branch) }
      end
      private_class_method :confirm_prunes
    end
  end
end
