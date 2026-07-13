# frozen_string_literal: true

module Orn
  module Commands
    module Sbx
      # `orn sbx new`: create a sandbox for a branch that already has a worktree.
      # Validates `sbx` config, trust, and preflight; requires the worktree to
      # exist and the sandbox not to; then creates the container, runs setup, and
      # publishes configured ports. Unlike `switch --sbx` it neither opens a tmux
      # window nor runs the start command.
      class New
        Result = Data.define(:name, :branch, :agent_type, :template, :host_ports) do
          # Omits nil template and empty host_ports.
          def to_json_hash
            hash = { "name" => name, "branch" => branch, "agent_type" => agent_type }
            hash["template"] = template if template
            hash["host_ports"] = host_ports.map(&:to_json_hash) unless host_ports.empty?
            hash
          end
        end

        # Testable core: create the sandbox in an already-discovered `project`.
        def self.run_inner(output_mode, project, branch)
          sbx_config = project.config.require_sbx!
          agent_type = sbx_config.require_agent_type!

          wt_path = project.worktree_path(branch)
          unless File.exist?(wt_path)
            raise Orn::Error, "Worktree does not exist at #{wt_path}\n  Use 'orn new #{branch}' to create it first"
          end

          Orn::Trust.check_sbx_trust(project.root, sbx_config)
          Orn::Sandbox.preflight(output_mode, sbx_config, project.root)

          name = project.sandbox_name(branch)
          raise Orn::Error, "Sandbox '#{name}' already exists" if Orn::Sandbox.exists?(output_mode, name)

          output_mode.status("Creating sandbox '#{name}'...")
          Orn::Sandbox.create(output_mode, create_params(project, sbx_config, agent_type, name, wt_path))
          run_setup(output_mode, sbx_config, name)
          host_ports = publish_ports(output_mode, project, sbx_config, name)

          Result.new(
            name: name, branch: branch, agent_type: agent_type,
            template: sbx_config.template, host_ports: host_ports
          )
        end

        def self.create_params(project, sbx_config, agent_type, name, wt_path)
          Orn::Sandbox::CreateParams.new(
            name: name, template: sbx_config.template, kits: sbx_config.all_kits,
            cpus: sbx_config.cpus, memory: sbx_config.memory, agent_type: agent_type,
            worktree_path: wt_path, bare_path: File.join(project.root, ".bare")
          )
        end

        def self.run_setup(output_mode, sbx_config, name)
          return if sbx_config.setup.empty?

          Orn::Sandbox.run_setup(output_mode, name, sbx_config.setup, sbx_config.env)
        end

        def self.publish_ports(output_mode, project, sbx_config, name)
          return [] if sbx_config.ports.empty?

          Orn::Sandbox.setup_ports(output_mode, name, sbx_config.ports, File.join(project.root, ".orn"))
        end

        def initialize(output_mode:)
          @output_mode = output_mode
        end

        def run(branch)
          Orn::Git::BranchName.new(branch).validate!
          project = Orn::Git::Project.discover
          result = self.class.run_inner(@output_mode, project, branch)
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

        private_class_method :create_params, :run_setup, :publish_ports
      end
    end
  end
end
