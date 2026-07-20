# frozen_string_literal: true

module Orn
  module Commands
    module Sbx
      # `orn sbx new`: create a sandbox for a branch that already has a worktree.
      # Validates `sbx` config, trust, and preflight; requires the worktree to
      # exist and the sandbox not to; then creates the sandbox, runs setup, and
      # publishes configured ports. Unlike `switch --sbx` it neither opens a tmux
      # window nor runs the start command.
      class New
        Result = Data.define(
          :name,
          :branch,
          :agent_type,
          :template,
          :host_ports
        ) do
          # Omits nil template and empty host_ports.
          def to_json_hash
            hash = {
              "name" => name,
              "branch" => branch,
              "agent_type" => agent_type
            }
            hash["template"] = template if template
            hash["host_ports"] = host_ports.map(&:to_json_hash) unless host_ports.empty?
            hash
          end
        end

        def initialize(output_mode:)
          @output_mode = output_mode
        end

        # Creates the sandbox in an already-discovered `project`.
        def run_inner(project, branch)
          sbx_config = project.config.require_sbx!
          agent_type = sbx_config.require_agent_type!

          wt_path = project.worktree_path(branch)
          unless File.exist?(wt_path)
            raise Orn::Error, "Worktree does not exist at #{wt_path}\n  Use 'orn wt new #{branch}' to create it first"
          end

          Orn::Trust.check_sbx_trust(project.root, sbx_config)
          Orn::Sandbox::Doctor.preflight(
            @output_mode,
            sbx_config,
            project.root
          )

          name = project.sandbox_name(branch)
          raise Orn::Error, "Sandbox '#{name}' already exists" if Orn::Sandbox::SbxCli.exists?(@output_mode, name)

          _, host_ports = Orn::Sandbox.provision(
            @output_mode,
            project,
            branch,
            sbx_config,
            agent_type
          )

          Result.new(
            name: name,
            branch: branch,
            agent_type: agent_type,
            template: sbx_config.template,
            host_ports: host_ports
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

          puts "Created sandbox: #{result.name}"
          puts "Branch: #{result.branch}"
          puts "Agent: #{result.agent_type}"
          puts "Template: #{result.template}" if result.template
          result.host_ports.each { |mapping| puts "Port: #{mapping}" }
        end
      end
    end
  end
end
