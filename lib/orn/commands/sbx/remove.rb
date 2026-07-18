# frozen_string_literal: true

module Orn
  module Commands
    module Sbx
      # `orn sbx remove`: destroy a branch's sandbox and its persisted port
      # state. Best-effort: `removed` is false when no sandbox existed, and the
      # ports file is deleted either way.
      class Remove
        Result = Data.define(
          :name,
          :branch,
          :removed
        ) do
          def to_json_hash
            {
              "name" => name,
              "branch" => branch,
              "removed" => removed
            }
          end
        end

        def initialize(output_mode:)
          @output_mode = output_mode
        end

        def run_inner(project, branch)
          Orn::Sandbox.require_sbx_cli!(@output_mode)

          name = project.sandbox_name(branch)
          removed = Orn::Sandbox.try_remove(@output_mode, name)
          @output_mode.status("Removed sandbox '#{name}'") if removed

          Orn::Sandbox.remove_ports_file(File.join(project.root, ".orn"), name)

          Result.new(
            name: name,
            branch: branch,
            removed: removed
          )
        end

        def run(branch)
          Orn::Git::BranchName.new(branch).validate!
          project = Orn::Git::Project.discover
          result = run_inner(project, branch)
          emit(result)
        end

        private

        def emit(result)
          return Commands::Output.print_json(result.to_json_hash) if @output_mode.json

          if result.removed
            puts "Removed sandbox: #{result.name}"
          else
            puts "No sandbox found for '#{result.branch}'"
          end
        end
      end
    end
  end
end
