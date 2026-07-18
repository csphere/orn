# frozen_string_literal: true

require "pathname"
require "fileutils"

module Orn
  # Config-driven symlinks into new worktrees: shares files from the base
  # worktree (e.g. .env) or the project root, with path-traversal validation
  # and .gitignore handling for the created links.
  module Symlink
    # One resolved symlink entry: its destination name and the absolute
    # source/destination paths, after trimming and traversal validation.
    ResolvedEntry = Data.define(
      :dest_name,
      :src,
      :dst
    )

    # Rejects absolute paths and any ".." component so config entries cannot
    # escape the project directory.
    def self.validate_entry!(entry)
      raise Orn::Error, "path traversal: absolute paths not allowed: #{entry}" if File.absolute_path?(entry)

      Pathname.new(entry).each_filename do |component|
        raise Orn::Error, "path traversal: '..' not allowed in symlink entry: #{entry}" if component == ".."
      end
    end

    # Creates all configured symlinks in wt_path and returns the destination
    # names as [created, skipped]. Missing sources and conflicting destinations
    # warn and skip; filesystem errors raise. Links that already point to the
    # right place count as neither.
    def self.create_symlinks(project_root, wt_path, base, config)
      created = []
      skipped = []

      base_wt = File.join(project_root, base)
      if !config.base.empty? && !File.exist?(base_wt)
        warn "warning: base worktree '#{base}' not found at #{base_wt}, skipping worktree symlinks"
      end

      resolve_symlink_entries(
        project_root,
        wt_path,
        base,
        config
      ).each do |entry|
        create_one(
          entry,
          created,
          skipped
        )
      end

      [created, skipped]
    end

    # Whether `path` is ignored by git in wt_path.
    def self.gitignored?(output_mode, wt_path, path)
      result = git_output(
        output_mode,
        wt_path,
        "check-ignore",
        "-q",
        path
      )
      result ? result.success? : false
    end

    # Destination names for symlinks that would actually be created: the source
    # exists and nothing occupies the destination yet.
    def self.collect_symlink_destinations(project_root, wt_path, base, config)
      resolve_symlink_entries(
        project_root,
        wt_path,
        base,
        config
      ).filter_map do |entry|
        next unless File.exist?(entry.src)
        next if File.exist?(entry.dst) || File.symlink?(entry.dst)

        entry.dest_name
      end
    end

    def self.find_unignored(output_mode, wt_path, destinations)
      destinations.reject do |destination|
        gitignored?(
          output_mode,
          wt_path,
          destination
        )
      end
    end

    # Appends `paths` to the worktree's .gitignore (creating it if needed), then
    # stages it with `git add`.
    def self.add_to_gitignore_and_stage(output_mode, wt_path, paths)
      gitignore_path = File.join(wt_path, ".gitignore")
      content = File.exist?(gitignore_path) ? File.read(gitignore_path) : ""
      content += "\n" if !content.empty? && !content.end_with?("\n")
      paths.each { |path| content += "#{path}\n" }
      File.write(gitignore_path, content)

      result = git_output(
        output_mode,
        wt_path,
        "add",
        ".gitignore"
      )
      raise Orn::Error, "Failed to run git add .gitignore" if result.nil?
      raise Orn::Error, "Failed to stage .gitignore: #{result.stderr.strip}" unless result.success?

      nil
    end

    # Collects symlink destinations, hands the ones not yet in .gitignore to the
    # block (which auto-adds, prompts, or raises), then creates the symlinks.
    def self.apply(output_mode, root, wt_path, base, config)
      if !config.base.empty? || !config.root.empty?
        destinations = collect_symlink_destinations(
          root,
          wt_path,
          base,
          config
        )
        unignored = find_unignored(
          output_mode,
          wt_path,
          destinations
        )
        yield(unignored) if block_given? && !unignored.empty?
      end
      create_symlinks(
        root,
        wt_path,
        base,
        config
      )
      nil
    end

    def self.create_one(entry, created, skipped)
      unless File.exist?(entry.src)
        warn "warning: source not found: #{entry.src}"
        skipped << entry.dest_name
        return
      end

      outcome = create_relative_symlink(entry.src, entry.dst)
      case outcome
      when :created then created << entry.dest_name
      when :already_correct then nil
      else
        warn "warning: #{entry.dest_name}: #{outcome.last}"
        skipped << entry.dest_name
      end
    end

    # Resolves the base-worktree and root symlink entries from `config`. Base
    # entries are dropped entirely when the base worktree directory is missing.
    def self.resolve_symlink_entries(project_root, wt_path, base, config)
      base_entries(
        project_root,
        wt_path,
        base,
        config
      ) + root_entries(
        project_root,
        wt_path,
        config
      )
    end

    def self.base_entries(project_root, wt_path, base, config)
      base_wt = File.join(project_root, base)
      return [] unless File.exist?(base_wt)

      config.base.filter_map do |raw|
        entry = raw.strip
        next if entry.empty?

        validate_entry!(entry)
        ResolvedEntry.new(
          dest_name: entry,
          src: File.join(base_wt, entry),
          dst: File.join(wt_path, entry)
        )
      end
    end

    def self.root_entries(project_root, wt_path, config)
      config.root.map do |root_symlink|
        validate_entry!(root_symlink.source)
        dest_name = root_symlink.effective_dest
        validate_entry!(dest_name)
        src = File.join(project_root, root_symlink.source)
        ResolvedEntry.new(
          dest_name: dest_name,
          src: src,
          dst: File.join(wt_path, dest_name)
        )
      end
    end

    # Creates a relative symlink at `dst` pointing to `src`. A symlink already
    # resolving to `src` is left alone; any other existing destination is
    # skipped, never overwritten. Returns :created, :already_correct, or
    # [:skipped, reason]; raises on a filesystem error.
    def self.create_relative_symlink(src, dst)
      if File.symlink?(dst)
        target = File.readlink(dst)
        return :already_correct if same_file?(File.expand_path(target, File.dirname(dst)), src)

        return [:skipped, "symlink exists but points to #{target}, not #{src}"]
      end

      return [:skipped, "destination already exists (not a symlink)"] if File.exist?(dst)

      FileUtils.mkdir_p(File.dirname(dst))
      File.symlink(relative_path(src, File.dirname(dst)), dst)
      :created
    rescue SystemCallError => e
      raise Orn::Error, "symlink #{dst}: #{e.message}"
    end

    def self.same_file?(first, second)
      File.realpath(first) == File.realpath(second)
    rescue SystemCallError
      false
    end

    def self.relative_path(src, from_dir)
      Pathname.new(src).relative_path_from(Pathname.new(from_dir)).to_s
    rescue ArgumentError
      raise Orn::Error, "cannot compute relative path from #{from_dir} to #{src}"
    end

    def self.git_output(output_mode, wt_path, *args)
      Orn::Cmd.new(output_mode: output_mode).output("git", "-C", wt_path, *args)
    rescue Orn::Error
      nil
    end

    private_class_method :create_one,
      :resolve_symlink_entries,
      :base_entries,
      :root_entries,
      :create_relative_symlink,
      :same_file?,
      :relative_path,
      :git_output
  end
end
