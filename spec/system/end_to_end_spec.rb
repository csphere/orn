# frozen_string_literal: true

require "open3"
require "tmpdir"
require "fileutils"

# End-to-end smoke test of the real `orn` executable inside the system-test
# container. Covers the wired non-tmux, non-sbx flow (init -> wt list ->
# config show). tmux-driven commands (switch, wt open) and sbx flows join this
# suite as they land. Gated by `:system` so it never touches a host environment.
RSpec.describe "orn end-to-end", :system do
  # Isolate only the global config (via XDG_CONFIG_HOME) per example: a
  # pre-seeded (empty) default.yaml makes project scaffolding skip its
  # interactive bootstrap. HOME is left intact so the container's git committer
  # identity (needed by init's initial commit) and bundler still resolve.
  let(:xdg) { Dir.mktmpdir("orn-e2e-xdg") }

  before do
    FileUtils.mkdir_p(File.join(xdg, "orn"))
    File.write(File.join(xdg, "orn", "default.yaml"), "")
  end

  after { FileUtils.remove_entry(xdg, true) }

  def orn(*args, chdir:)
    Open3.capture3({ "XDG_CONFIG_HOME" => xdg }, "orn", *args.map(&:to_s), chdir: chdir)
  end

  it "initializes a bare-worktree project" do
    Dir.mktmpdir("orn-e2e-project") do |dir|
      _stdout, stderr, status = orn("init", "--base", "main", chdir: dir)

      aggregate_failures do
        expect(status).to be_success, "orn init failed: #{stderr}"
        expect(File).to be_directory(File.join(dir, ".bare"))
        expect(File).to be_directory(File.join(dir, "main"))
        expect(File).to exist(File.join(dir, ".orn", "config.yaml"))
      end
    end
  end

  it "lists the base worktree after init" do
    Dir.mktmpdir("orn-e2e-project") do |dir|
      orn("init", "--base", "main", chdir: dir)

      stdout, stderr, status = orn("wt", "list", "--json", chdir: dir)

      aggregate_failures do
        expect(status).to be_success, "orn wt list failed: #{stderr}"
        expect(stdout).to include("main")
      end
    end
  end

  it "shows configuration with source annotations" do
    Dir.mktmpdir("orn-e2e-project") do |dir|
      orn("init", "--base", "main", chdir: dir)

      stdout, stderr, status = orn("config", "show", chdir: File.join(dir, "main"))

      aggregate_failures do
        expect(status).to be_success, "orn config show failed: #{stderr}"
        expect(stdout).to include("main")
      end
    end
  end
end
