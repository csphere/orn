# frozen_string_literal: true

module Orn
  module Commands
    # The sandbox-aware branches of `orn switch`: case 4 `--sbx` creation (with
    # rollback of window, sandbox, and worktree on failure) and case 2
    # reattachment of an existing sandbox. Split from Switch to keep each class
    # focused; results are Switch::Result values.
    module SwitchSandbox
      module_function

      Result = Orn::Commands::Switch::Result

      # Context bundle threaded through the provisioning helpers, so none of them
      # needs a long positional parameter list.
      Context = Data.define(
        :output_mode,
        :client,
        :project,
        :branch,
        :sbx_config,
        :agent_type
      )

      # Case 4 with `--sbx`: validate config/trust/preflight, create the
      # worktree, then provision the sandbox and window under a rollback guard.
      def create_with_sandbox(output_mode, project, branch, base_override, client)
        sbx_config = project.config.require_sbx!
        Orn::Trust.check_sbx_trust(project.root, sbx_config)
        agent_type = sbx_config.require_agent_type!
        Orn::Sandbox::Doctor.preflight(
          output_mode,
          sbx_config,
          project.root
        )

        wt_result = Wt::New.create(
          output_mode,
          project,
          branch,
          base_override
        )
        context = Context.new(
          output_mode: output_mode,
          client: client,
          project: project,
          branch: branch,
          sbx_config: sbx_config,
          agent_type: agent_type
        )
        provision_with_rollback(context, wt_result)
      end

      # Everything created after the worktree (sandbox, window, ports, services)
      # is torn down on any failure, then the error is re-raised.
      def provision_with_rollback(context, wt_result)
        state = {
          name: nil,
          session: nil,
          sandbox_created: false
        }
        host_ports = provision(context, state)
        Result.new(
          branch: wt_result.branch,
          action: :created,
          base: wt_result.base,
          worktree_path: wt_result.worktree_path,
          sandbox_name: state[:name],
          host_ports: host_ports
        )
      # Interrupt is not a StandardError; without it Ctrl-C during the
      # minutes-long provision would skip the rollback.
      rescue StandardError, Interrupt => e
        rollback(context, state)
        raise e
      end

      # Creates the sandbox, runs setup, opens the sbx-layout window, publishes
      # ports, and starts services, recording progress in `state` so a failure
      # rolls back exactly what was created.
      def provision(context, state)
        state[:name] = name = context.project.sandbox_name(context.branch)
        context.output_mode.status("Creating sandbox '#{name}'...")
        Orn::Sandbox::SbxCli.create(context.output_mode, sandbox_params(context, name))
        state[:sandbox_created] = true

        run_setup(context, name)
        open_window(
          context,
          name,
          state
        )
        host_ports = publish_ports(context, name)
        start_services(
          context.output_mode,
          context.sbx_config,
          name
        )
        host_ports
      end

      def run_setup(context, name)
        return if context.sbx_config.setup.empty?

        Orn::Sandbox.run_setup(
          context.output_mode,
          name,
          context.sbx_config.setup,
          context.sbx_config.env
        )
      end

      def open_window(context, name, state)
        layout, layout_source = context.project.config.effective_sbx_layout
        result = context.client.open_window_with_layout(
          context.project,
          context.branch,
          layout,
          layout_source,
          template_vars: { "sandbox" => name }
        )
        state[:session] = result.session
      end

      def publish_ports(context, name)
        return [] if context.sbx_config.ports.empty?

        Orn::Sandbox::Ports.setup_ports(
          context.output_mode,
          name,
          context.sbx_config.ports,
          File.join(context.project.root, ".orn")
        )
      end

      def start_services(output_mode, sbx_config, name)
        return unless sbx_config&.start

        output_mode.status("Starting services in '#{name}': #{sbx_config.start}")
        Orn::Sandbox::SbxCli.exec_detached(
          output_mode,
          name,
          sbx_config.start,
          sbx_config.env
        )
      end

      # Case 2 when the branch's sandbox still exists: reopen the window with the
      # sbx layout, republish ports, and rerun the configured start command.
      def reopen_with_sandbox(output_mode, project, branch, sbx_name, client)
        sbx_config = project.config.sbx
        Orn::Trust.check_sbx_trust(project.root, sbx_config) if sbx_config

        layout, layout_source = project.config.effective_sbx_layout
        client.open_window_with_layout(
          project,
          branch,
          layout,
          layout_source,
          template_vars: { "sandbox" => sbx_name }
        )

        host_ports = Orn::Sandbox::Ports.republish_ports(
          output_mode,
          sbx_name,
          File.join(project.root, ".orn")
        )
        start_services(
          output_mode,
          sbx_config,
          sbx_name
        )

        Result.new(
          branch: branch,
          action: :reopened,
          base: nil,
          worktree_path: nil,
          sandbox_name: sbx_name,
          host_ports: host_ports
        )
      end

      def sandbox_params(context, name)
        sbx_config = context.sbx_config
        Orn::Sandbox::CreateParams.new(
          name: name,
          template: sbx_config.template,
          kits: sbx_config.all_kits,
          cpus: sbx_config.cpus,
          memory: sbx_config.memory,
          agent_type: context.agent_type,
          worktree_path: context.project.worktree_path(context.branch),
          bare_path: File.join(context.project.root, ".bare")
        )
      end

      # Best-effort teardown: window, then sandbox, then worktree. Each step
      # ignores its own failure.
      def rollback(context, state)
        context.output_mode.status("Rolling back...")
        safe_kill_window(context, state[:session]) if state[:session]
        safe_remove_sandbox(context.output_mode, state[:name]) if state[:sandbox_created]
        safe_remove_worktree(context)
      end

      def safe_kill_window(context, session)
        context.client.kill_window(session, context.branch)
      rescue Orn::Error
        nil
      end

      def safe_remove_sandbox(output_mode, name)
        Orn::Sandbox::SbxCli.remove(output_mode, name)
      rescue Orn::Error
        nil
      end

      def safe_remove_worktree(context)
        worktree = Orn::Git::Worktree.new(
          root: context.project.root,
          output_mode: context.output_mode
        )
        worktree.remove(context.project.worktree_path(context.branch))
      rescue Orn::Error
        nil
      end
    end
  end
end
