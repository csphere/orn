# frozen_string_literal: true

module Orn
  module Commands
    module Sbx
      # `orn sbx build`: build the sandbox template image from the project's
      # Dockerfile. Dockerfile lookup is relative to the current directory, so
      # run from the worktree that contains it. `build_args` values come from
      # the environment and are trust-checked.
      class Build
        Result = Data.define(:template, :dockerfile) do
          def to_json_hash
            {
              "template" => template,
              "dockerfile" => dockerfile
            }
          end
        end

        def initialize(output_mode:)
          @output_mode = output_mode
        end

        def run_inner(project)
          sbx_config = project.config.require_sbx!
          build, template = sbx_config.require_build!

          dockerfile = build.dockerfile || "Dockerfile"
          raise Orn::Error, "Dockerfile not found: #{dockerfile}" unless File.exist?(dockerfile)

          Orn::Sandbox.require_docker!(@output_mode)
          Orn::Sandbox.require_sbx_cli!(@output_mode)
          Orn::Trust.check_sbx_trust(project.root, sbx_config)

          announce(
            template,
            dockerfile,
            build.build_args
          )
          Orn::Sandbox.build(
            @output_mode,
            dockerfile,
            template,
            build.build_args,
            "."
          )

          Result.new(
            template: template,
            dockerfile: dockerfile
          )
        end

        def run
          project = Orn::Git::Project.discover
          result = run_inner(project)
          emit(result)
        end

        private

        def announce(template, dockerfile, build_args)
          if build_args.empty?
            @output_mode.status("Building template '#{template}' from #{dockerfile}...")
          else
            @output_mode.status(
              "Building template '#{template}' from #{dockerfile} (build args: #{build_args.join(", ")})"
            )
          end
        end

        def emit(result)
          return Commands::Output.print_json(result.to_json_hash) if @output_mode.json

          puts "Built template: #{result.template}"
          puts "Dockerfile: #{result.dockerfile}"
        end
      end
    end
  end
end
