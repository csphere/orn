# frozen_string_literal: true

module Orn
  module Commands
    module Sbx
      # `orn sbx list`: all sandboxes on the host, matched back to this project's
      # worktree branches where possible, each annotated with its persisted port
      # mappings.
      class List
        # `branch` is nil for sandboxes not owned by this project (serialized as
        # null); `ports` is omitted when empty.
        Entry = Data.define(:name, :branch, :status, :ports) do
          def to_json_hash
            hash = { "name" => name, "branch" => branch, "status" => status }
            hash["ports"] = ports.map(&:to_json_hash) unless ports.empty?
            hash
          end
        end

        Result = Data.define(:sandboxes)

        def self.run_inner(output_mode, project)
          Orn::Sandbox.require_sbx_cli!(output_mode)

          entries = Orn::Sandbox.list(output_mode)
          orn_dir = File.join(project.root, ".orn")
          branches = worktree_branches(output_mode, project)

          sandboxes = entries.map do |entry|
            ports = ports_for(orn_dir, entry.name)
            branch = find_branch_for_sandbox(project, branches, entry.name)
            Entry.new(name: entry.name, branch: branch, status: entry.status, ports: ports)
          end
          Result.new(sandboxes: sandboxes)
        end

        def self.worktree_branches(output_mode, project)
          Orn::Git::Worktree.new(root: project.root, output_mode: output_mode).entries
        rescue Orn::Error
          []
        end

        def self.ports_for(orn_dir, name)
          Orn::Sandbox.read_ports(orn_dir, name)
        rescue Orn::Error
          []
        end

        # Reverse-maps a sandbox name to the worktree branch that would generate
        # it, since the branch-to-name derivation is not invertible.
        def self.find_branch_for_sandbox(project, branches, sandbox_name)
          branches.find do |branch|
            project.sandbox_name(branch) == sandbox_name
          rescue Orn::Error
            false
          end
        end

        def initialize(output_mode:)
          @output_mode = output_mode
        end

        def run
          project = Orn::Git::Project.discover
          result = self.class.run_inner(@output_mode, project)
          emit(result)
        end

        private

        def emit(result)
          return Commands::Output.print_json("sandboxes" => result.sandboxes.map(&:to_json_hash)) if @output_mode.json

          if result.sandboxes.empty?
            puts "No sandboxes found"
            return
          end

          rows = result.sandboxes.map do |entry|
            [entry.name, entry.branch || "", entry.status, entry.ports.join(", ")]
          end
          puts "Sandboxes:\n\n"
          puts Commands::Output.render_table(%w[Name Branch Status Ports], rows)
        end

        private_class_method :worktree_branches, :ports_for, :find_branch_for_sandbox
      end
    end
  end
end
