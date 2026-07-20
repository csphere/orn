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

    # Resolves a tmux session-name collision with another project. May prompt
    # interactively and, if the user picks a new name, rewrite
    # .orn/config.yaml and re-discover the project.
    def self.check_collision(client, project)
      return project if project.config.session

      session = session_name(project)
      return project unless client.session_exists?(session)
      return project if client.client_session == session

      existing_path = client.session_path(session)
      return project if existing_path.nil?

      our_path = safe_realpath(project.root)
      return project if our_path.nil? || session_belongs_to_project?(existing_path, our_path)

      resolve_collision(
        project,
        session,
        existing_path
      )
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

      "#{sanitize_name(parent_name)}-#{dir_name}"
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

    def self.directory_name(root)
      name = File.basename(root)
      return "default" if name.empty? || name == File::SEPARATOR

      sanitize_name(name)
    end

    # tmux forbids '.' and ':' in session names (they are target-syntax
    # separators), so a repo like next.js would produce a session every
    # tmux target misses. Directory-derived names map anything outside
    # [a-zA-Z0-9_-] to '-'; configured names are validated instead.
    def self.sanitize_name(name)
      name.gsub(/[^a-zA-Z0-9_-]/, "-")
    end

    def self.path_components(path)
      Pathname.new(path).each_filename.to_a
    end

    def self.safe_realpath(path)
      File.realpath(path)
    rescue SystemCallError
      nil
    end

    private_class_method :resolve_collision,
      :directory_name,
      :sanitize_name,
      :path_components,
      :safe_realpath
  end
end
