# frozen_string_literal: true

require "pathname"

module Orn
  # Tmux session naming for a project, including detection and resolution of
  # session-name collisions between projects.
  module Session
    # The tmux session name for `project`: the configured tmux session value,
    # falling back to the project directory name.
    def self.session_name(project)
      configured = project.config.session
      return configured if configured

      directory_name(project.root)
    end

    # Whether a tmux session named `session` currently exists.
    def self.session_exists?(output_mode, session)
      result = tmux_output(output_mode, "has-session", "-t", session)
      result ? result.success? : false
    end

    # The session name of the attached tmux client, or nil when not running
    # inside tmux or on any tmux error.
    def self.current_session(output_mode)
      return nil unless ENV.key?("TMUX")

      # The escaped \#{...} is a literal tmux format string, not Ruby interpolation.
      result = tmux_output(output_mode, "display-message", "-p", "\#{client_session}")
      return nil unless result&.success?

      name = result.stdout.strip
      name.empty? ? nil : name
    end

    # Resolves a tmux session-name collision with another project. May prompt
    # interactively and, if the user picks a new name, rewrite
    # .orn/config.yaml and re-discover the project.
    def self.check_collision(output_mode, project)
      return project if project.config.session

      session = session_name(project)
      return project unless session_exists?(output_mode, session)
      return project if current_session(output_mode) == session

      existing_path = session_path(output_mode, session)
      return project if existing_path.nil?

      our_path = safe_realpath(project.root)
      return project if our_path.nil? || session_belongs_to_project?(existing_path, our_path)

      resolve_collision(project, session, existing_path)
    end

    # Whether `session_path` is the project root or a path inside it. Compares
    # whole path components, so a sibling like "orn-other" does not match "orn".
    def self.session_belongs_to_project?(session_path, project_root)
      session_parts = path_components(session_path)
      project_parts = path_components(project_root)
      session_parts[0, project_parts.length] == project_parts
    end

    # Suggests a replacement session name, "<parent>-<dir>", to disambiguate
    # projects whose directories share a name.
    def self.suggest_name(root)
      dir_name = directory_name(root)
      parent = File.dirname(root)
      parent_name = File.basename(parent)
      return dir_name if parent == root || parent_name.empty? || parent_name == File::SEPARATOR

      "#{parent_name}-#{dir_name}"
    end

    # The canonicalized #{session_path} of `session`, used to tell which project
    # directory an existing session belongs to.
    def self.session_path(output_mode, session)
      # Trailing colon forces session interpretation: display-message takes a
      # target-pane, so a bare name can resolve to a same-named window in the
      # caller's current session instead.
      # "#{session}:" interpolates the session; "\#{session_path}" is a literal
      # tmux format string.
      result = tmux_output(output_mode, "display-message", "-t", "#{session}:", "-p", "\#{session_path}")
      return nil unless result&.success?

      path = result.stdout.strip
      return nil if path.empty?

      safe_realpath(path)
    end

    def self.resolve_collision(project, session, existing_path)
      unless $stdin.tty?
        raise Orn::Error,
          "Session '#{session}' is already in use by #{existing_path}\n  " \
          "Set session: <name> in .orn/config.yaml to resolve"
      end

      suggested = suggest_name(project.root)
      warn "Session '#{session}' is already in use by #{existing_path}"
      $stderr.print "Enter session name [#{suggested}]: "
      input = $stdin.gets.to_s.strip
      name = input.empty? ? suggested : input

      Orn::Config::Validate.session_name!(name)
      Orn::Config.write_session(project.root, name)
      Orn::Git::Project.discover
    end

    def self.tmux_output(output_mode, *args)
      Orn::Cmd.new(output_mode: output_mode).output("tmux", *args)
    rescue Orn::Error
      nil
    end

    def self.directory_name(root)
      name = File.basename(root)
      name.empty? || name == File::SEPARATOR ? "default" : name
    end

    def self.path_components(path)
      Pathname.new(path).each_filename.to_a
    end

    def self.safe_realpath(path)
      File.realpath(path)
    rescue SystemCallError
      nil
    end

    private_class_method :session_path,
      :resolve_collision,
      :tmux_output,
      :directory_name,
      :path_components,
      :safe_realpath
  end
end
