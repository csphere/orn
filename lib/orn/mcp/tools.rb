# frozen_string_literal: true

require "json"

module Orn
  module Mcp
    # Tool catalog and dispatch for the orn MCP server: maps tool names onto the
    # same run_inner command implementations the CLI uses. The definitions are
    # locked by a golden fixture; only the values a tool returns differ.
    module Tools
      # The tool catalog advertised via `tools/list`. Every entry has a matching
      # arm in `run_tool`.
      DEFINITIONS = [
        {
          "name" => "worktree_switch",
          "description" => "Switch to a branch, creating the worktree and tmux window if needed. Handles all cases: switches to an existing tmux window, reopens a closed window, fetches a remote branch, or creates a new branch from the base. Use when the user wants to work on any branch, whether it already exists or is brand new. The branch name typically follows a convention like 'feature/ABC-1234', 'defect/BCDE-5678', or 'spike/try-redis'.",
          "inputSchema" => {
            "properties" => {
              "base" => {
                "description" => "Base branch to fork from when creating a new branch. Defaults to the configured base (usually 'main'). Ignored if the branch already exists.",
                "type" => "string"
              },
              "branch" => {
                "description" => "Branch name (e.g. 'feature/ABC-1234', 'defect/BCDE-5678', 'spike/try-redis')",
                "type" => "string"
              },
              "sbx" => {
                "description" => "Also create a sandbox with port publishing and services when creating a new branch. Requires sbx config. Ignored if the branch already exists.",
                "type" => "boolean"
              }
            },
            "required" => [
              "branch"
            ],
            "type" => "object"
          }
        },
        {
          "name" => "worktree_remove",
          "description" => "Remove a git worktree and close its tmux window. Use when the user is done with a branch or wants to clean up a workspace. DESTRUCTIVE: prune=true deletes the local git branch permanently. Remote branch deletion requires both prune=true and confirm_remote_delete=true. The configured base branch (e.g. 'main', 'develop') cannot be pruned.",
          "inputSchema" => {
            "properties" => {
              "branch" => {
                "description" => "Branch name of the worktree to remove (e.g. 'feature/ABC-1234')",
                "type" => "string"
              },
              "confirm_remote_delete" => {
                "default" => false,
                "description" => "If true (and prune is also true), also delete the remote branch on origin. Default: false. Use only when the work is fully merged.",
                "type" => "boolean"
              },
              "prune" => {
                "default" => false,
                "description" => "If true, delete the local git branch. Default: false.",
                "type" => "boolean"
              }
            },
            "required" => [
              "branch"
            ],
            "type" => "object"
          }
        },
        {
          "name" => "worktree_list",
          "description" => "List all active git worktrees in the current repository with their tmux window status. Use when the user wants to see what branches they have checked out, what workspaces are active, or get an overview of their current work.",
          "inputSchema" => {
            "properties" => {},
            "required" => [],
            "type" => "object"
          }
        },
        {
          "name" => "sandbox_new",
          "description" => "Create a sandbox (dev container) for a branch. Builds the sandbox image from the project template if needed, then starts a container with port publishing and services. Use when the user wants an isolated development environment for a branch.",
          "inputSchema" => {
            "properties" => {
              "branch" => {
                "description" => "Branch name to create the sandbox for (e.g. 'feature/ABC-1234')",
                "type" => "string"
              }
            },
            "required" => [
              "branch"
            ],
            "type" => "object"
          }
        },
        {
          "name" => "sandbox_remove",
          "description" => "Destroy a sandbox (dev container) for a branch. Stops and removes the container. Use when the user is done with an isolated development environment and wants to free resources.",
          "inputSchema" => {
            "properties" => {
              "branch" => {
                "description" => "Branch name whose sandbox should be removed (e.g. 'feature/ABC-1234')",
                "type" => "string"
              }
            },
            "required" => [
              "branch"
            ],
            "type" => "object"
          }
        },
        {
          "name" => "sandbox_list",
          "description" => "List all sandboxes in the current project with their status and published ports. Use when the user wants to see which branches have active sandboxes or check sandbox health.",
          "inputSchema" => {
            "properties" => {},
            "required" => [],
            "type" => "object"
          }
        },
        {
          "name" => "sandbox_build",
          "description" => "Build and load the sandbox template image for the current project. Use when the user wants to prepare or update the base image that sandboxes are created from.",
          "inputSchema" => {
            "properties" => {},
            "required" => [],
            "type" => "object"
          }
        }
      ].freeze

      TOOL_NAMES = DEFINITIONS.map { |definition| definition["name"] }.freeze

      def self.definitions
        DEFINITIONS
      end

      # Executes a tool call, converting any error into an `isError` tool result
      # rather than propagating it.
      def self.dispatch(name, arguments)
        Protocol.tool_success(dispatch_inner(name, arguments))
      rescue StandardError => e
        Protocol.tool_error(e.message)
      end

      def self.dispatch_inner(name, arguments)
        # Reject unknown tools before project discovery so the error does not
        # depend on the working directory being an orn project.
        raise Orn::Error, "Unknown tool: #{name}" unless TOOL_NAMES.include?(name)

        validate_arguments(name, arguments)
        output = Orn::OutputMode.quiet
        project = Orn::Git::Project.discover
        project = Orn::Session.check_collision(output, project) if name == "worktree_switch"

        JSON.pretty_generate(run_tool(name, output, project, arguments).to_json_hash)
      end

      # Validates branch-name arguments up front so malformed names fail before
      # any command logic runs.
      def self.validate_arguments(name, arguments)
        case name
        when "worktree_switch"
          Orn::Git::BranchName.new(require_str(arguments, "branch")).validate!
          base = string_arg(arguments, "base")
          Orn::Git::BranchName.new(base).validate! if base
        when "worktree_remove", "sandbox_new", "sandbox_remove"
          Orn::Git::BranchName.new(require_str(arguments, "branch")).validate!
        end
      end

      def self.run_tool(name, output, project, arguments)
        run_worktree_tool(name, output, project, arguments) ||
          run_sandbox_tool(name, output, project, arguments)
      end

      def self.run_worktree_tool(name, output, project, arguments)
        case name
        when "worktree_switch"
          Commands::Switch.perform(
            output, project, require_str(arguments, "branch"),
            string_arg(arguments, "base"), bool_arg(arguments, "sbx")
          )
        when "worktree_remove"
          prune = bool_arg(arguments, "prune")
          confirm = bool_arg(arguments, "confirm_remote_delete")
          Commands::Remove.run_inner_with_remote(output, project, require_str(arguments, "branch"), prune, prune && confirm)
        when "worktree_list" then Commands::List.run_inner(output, project)
        end
      end

      def self.run_sandbox_tool(name, output, project, arguments)
        case name
        when "sandbox_new" then Commands::Sbx::New.run_inner(output, project, require_str(arguments, "branch"))
        when "sandbox_remove" then Commands::Sbx::Remove.run_inner(output, project, require_str(arguments, "branch"))
        when "sandbox_list" then Commands::Sbx::List.run_inner(output, project)
        when "sandbox_build" then Commands::Sbx::Build.run_inner(output, project)
        end
      end

      # A required string argument; null, non-string, and empty all count as
      # missing.
      def self.require_str(arguments, key)
        value = arguments.is_a?(Hash) ? arguments[key] : nil
        raise Orn::Error, "missing required argument: #{key}" unless value.is_a?(String) && !value.empty?

        value
      end

      def self.string_arg(arguments, key)
        value = arguments.is_a?(Hash) ? arguments[key] : nil
        value.is_a?(String) ? value : nil
      end

      def self.bool_arg(arguments, key)
        arguments.is_a?(Hash) && arguments[key] == true
      end

      private_class_method :dispatch_inner, :validate_arguments, :run_tool, :run_worktree_tool,
        :run_sandbox_tool, :require_str, :string_arg, :bool_arg
    end
  end
end
