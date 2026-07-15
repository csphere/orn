# frozen_string_literal: true

require "yaml"
require "fileutils"

module Orn
  module Commands
    # Shared scaffolding for the project-creating commands (clone, init,
    # convert): the .git pointer file, .orn/ config, blackboard, root CLAUDE.md,
    # optional global-config bootstrap, and the base worktree.
    module Setup
      # Writes the .git pointer file that makes the project root look like a
      # repo to git tooling while the real repo lives in .bare/.
      def self.write_git_pointer(dir)
        File.write(File.join(dir, ".git"), "gitdir: ./.bare\n")
        nil
      end

      # Bare-clones `url` into an existing empty `project_dir` and scaffolds the
      # orn project structure around it. Shared with convert, which prepares the
      # directory itself.
      def self.clone_into(output_mode, project_dir, project_name, url, base)
        cmd = Orn::Cmd.new(output_mode: output_mode)

        output_mode.status("  Cloning repository")
        cmd.exec("git", "-C", project_dir, "clone", "--bare", url, ".bare")

        output_mode.status("  Writing .git pointer file")
        write_git_pointer(project_dir)

        output_mode.status("  Configuring remote fetch refspec")
        cmd.exec("git", "-C", project_dir, "config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*")

        output_mode.status("  Fetching branches")
        cmd.exec("git", "-C", project_dir, "fetch", "origin")

        scaffold_project(output_mode, project_dir, project_name, base)
      end

      # Creates the non-git parts of a new project (.orn/config.yaml, blackboard,
      # root CLAUDE.md), offers to bootstrap the global config, and adds the base
      # worktree. Expects the bare repo and .git pointer to exist already.
      def self.scaffold_project(output_mode, project_dir, project_name, base)
        orn_dir = File.join(project_dir, ".orn")
        output_mode.status("  Creating .orn/config.yaml")
        FileUtils.mkdir_p(orn_dir)
        File.write(File.join(orn_dir, "config.yaml"), serialize_config(base))

        output_mode.status("  Creating .orn/blackboard/")
        Orn::Blackboard.ensure_dir(project_dir)

        output_mode.status("  Writing root CLAUDE.md")
        File.write(File.join(project_dir, "CLAUDE.md"), generate_claude_md(project_name, base))

        bootstrap_global_config_interactive(output_mode)

        output_mode.status("  Creating worktree: #{base}")
        Orn::Cmd.new(output_mode: output_mode).exec("git", "-C", project_dir, "worktree", "add", base, base)
        nil
      end

      # Renders the project config: version and base branch as data (YAML-safe
      # for any base), followed by the commented option examples.
      def self.serialize_config(base)
        header = dump_header("orn_version" => Orn::VERSION, "git" => { "base" => base })
        "#{header}\n#{Orn::Template.new("config.yaml").read}"
      end

      def self.serialize_global_config
        header = dump_header("orn_version" => Orn::VERSION)
        "#{header}\n#{Orn::Template.new("config_global.yaml").read}"
      end

      def self.generate_claude_md(project_name, base)
        Orn::Template.new("CLAUDE.md").read.gsub("{project_name}", project_name).gsub("{base}", base)
      end

      def self.bootstrap_global_config_interactive(output_mode)
        bootstrap_global_config(output_mode, Orn::Config.global_config_dir, $stdin, $stderr)
      end

      # Offers to create the global default.yaml on first project setup. No-op
      # when the config dir is unavailable, the file already exists, or the user
      # declines.
      def self.bootstrap_global_config(output_mode, global_dir, reader, writer)
        return if global_dir.nil?

        config_path = File.join(global_dir, "default.yaml")
        return if File.exist?(config_path)
        return unless Orn::Confirm.global_config(config_path, reader, writer)

        FileUtils.mkdir_p(global_dir)
        File.write(config_path, serialize_global_config)
        output_mode.status("  Created #{config_path}")
        nil
      end

      def self.dump_header(data)
        YAML.dump(data).sub(/\A---\s*\n/, "")
      end
      private_class_method :dump_header
    end
  end
end
