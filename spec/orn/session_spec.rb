# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"

RSpec.describe Orn::Session do
  let(:output_mode) { Orn::OutputMode.default }

  def project_at(root)
    Orn::Git::Project.new(
      root: root,
      config: Orn::Config.load_from("/nonexistent", nil)
    )
  end

  # The escaped \#{...} strings below are literal tmux format strings, matching
  # the argv the session module sends.
  def client_session_argv
    ["tmux", "display-message", "-p", "\#{client_session}"]
  end

  def has_session_argv(session)
    ["tmux", "has-session", "-t", session]
  end

  def session_path_argv(session)
    ["tmux", "display-message", "-t", "#{session}:", "-p", "\#{session_path}"]
  end

  def script_collision(fake, session, existing_path)
    fake.script(has_session_argv(session))
    fake.script(session_path_argv(session), stdout: "#{existing_path}\n")
  end

  # Runs check_collision from inside the project directory (so rediscovery
  # can find it) with a fake interactive terminal answering the prompt.
  def resolve_interactively(project, input)
    Dir.chdir(project.root) do
      with_interactive_stdin(input) do
        described_class.check_collision(output_mode, project)
      end
    end
  end

  describe ".session_name" do
    it "uses the project directory name" do
      expect(described_class.session_name(project_at("/home/user/dev/my-project"))).to eq("my-project")
    end

    it "defaults to 'default' when there is no directory name" do
      expect(described_class.session_name(project_at("/"))).to eq("default")
    end

    it "prefers the configured session" do
      project = make_project(make_bare_project, "tmux:\n  session: custom-name\n")

      expect(described_class.session_name(project)).to eq("custom-name")
    end
  end

  describe ".session_belongs_to_project?" do
    it "matches the project root exactly" do
      expect(described_class.session_belongs_to_project?("/home/user/dev/orn", "/home/user/dev/orn")).to be(true)
    end

    it "matches a worktree inside the project" do
      expect(described_class.session_belongs_to_project?("/home/user/dev/orn/main", "/home/user/dev/orn")).to be(true)
    end

    it "matches a nested worktree" do
      nested = "/home/user/dev/orn/issues/108"

      expect(described_class.session_belongs_to_project?(nested, "/home/user/dev/orn")).to be(true)
    end

    it "rejects a sibling with a shared prefix" do
      expect(described_class.session_belongs_to_project?("/home/user/dev/orn-other", "/home/user/dev/orn")).to be(false)
    end

    it "rejects an unrelated path" do
      expect(described_class.session_belongs_to_project?("/home/user/dev/api", "/home/user/dev/orn")).to be(false)
    end
  end

  describe ".suggest_name" do
    it "combines the parent and directory names" do
      expect(described_class.suggest_name("/home/user/work/api")).to eq("work-api")
    end

    it "uses the directory name alone when there is no parent" do
      expect(described_class.suggest_name("/api")).to eq("api")
    end
  end

  describe ".current_session" do
    it "returns nil when not inside tmux" do
      ENV.delete("TMUX")

      expect(described_class.current_session(output_mode)).to be_nil
    end

    it "returns the attached client's session name" do
      ENV["TMUX"] = "/tmp/tmux-0/default,1,0"

      with_fake_cmd do |fake|
        fake.script(client_session_argv, stdout: "work\n")

        expect(described_class.current_session(output_mode)).to eq("work")
      end
    end

    it "returns nil when tmux reports an empty session name" do
      ENV["TMUX"] = "/tmp/tmux-0/default,1,0"

      with_fake_cmd do |fake|
        fake.script(client_session_argv, stdout: "\n")

        expect(described_class.current_session(output_mode)).to be_nil
      end
    end

    it "returns nil when the tmux query fails" do
      ENV["TMUX"] = "/tmp/tmux-0/default,1,0"

      with_fake_cmd do |fake|
        fake.script(client_session_argv, status: 1)

        expect(described_class.current_session(output_mode)).to be_nil
      end
    end

    it "returns nil when tmux is not installed" do
      ENV["TMUX"] = "/tmp/tmux-0/default,1,0"

      with_fake_cmd do |fake|
        fake.script_missing(client_session_argv)

        expect(described_class.current_session(output_mode)).to be_nil
      end
    end
  end

  describe ".session_exists?" do
    it "reports the session absent when tmux is not installed" do
      with_fake_cmd do |fake|
        fake.script_missing(has_session_argv("work"))

        expect(described_class.session_exists?(output_mode, "work")).to be(false)
      end
    end
  end

  describe ".check_collision" do
    before { ENV.delete("TMUX") }

    def collision_project(config_yaml = "")
      make_project(make_bare_project, config_yaml)
    end

    def other_project_root
      register_temp_dir(Dir.mktmpdir("orn-other"))
    end

    it "keeps the project when a session name is already configured" do
      project = collision_project("tmux:\n  session: custom-name\n")

      with_fake_cmd do |fake|
        expect(described_class.check_collision(output_mode, project)).to be(project)
        expect(fake.invocations).to be_empty
      end
    end

    it "keeps the project when no session with its name exists" do
      project = collision_project
      session = described_class.session_name(project)

      with_fake_cmd do |fake|
        fake.script(has_session_argv(session), status: 1)

        expect(described_class.check_collision(output_mode, project)).to be(project)
      end
    end

    it "keeps the project when the session is the one currently attached" do
      project = collision_project
      session = described_class.session_name(project)
      ENV["TMUX"] = "/tmp/tmux-0/default,1,0"

      with_fake_cmd do |fake|
        fake.script(has_session_argv(session))
        fake.script(client_session_argv, stdout: "#{session}\n")

        expect(described_class.check_collision(output_mode, project)).to be(project)
        expect(fake.invocations).to eq([has_session_argv(session), client_session_argv])
      end
    end

    it "keeps the project when tmux cannot report the existing session's path" do
      project = collision_project
      session = described_class.session_name(project)

      with_fake_cmd do |fake|
        fake.script(has_session_argv(session))
        fake.script(session_path_argv(session), status: 1)

        expect(described_class.check_collision(output_mode, project)).to be(project)
      end
    end

    it "keeps the project when the session path query cannot run at all" do
      project = collision_project
      session = described_class.session_name(project)

      with_fake_cmd do |fake|
        fake.script(has_session_argv(session))
        fake.script_missing(session_path_argv(session))

        expect(described_class.check_collision(output_mode, project)).to be(project)
      end
    end

    it "keeps the project when the existing session reports an empty path" do
      project = collision_project
      session = described_class.session_name(project)

      with_fake_cmd do |fake|
        fake.script(has_session_argv(session))
        fake.script(session_path_argv(session), stdout: "\n")

        expect(described_class.check_collision(output_mode, project)).to be(project)
      end
    end

    it "keeps the project when the existing session's path no longer exists" do
      project = collision_project
      session = described_class.session_name(project)

      with_fake_cmd do |fake|
        script_collision(
          fake,
          session,
          "/nonexistent/orn-elsewhere"
        )

        expect(described_class.check_collision(output_mode, project)).to be(project)
      end
    end

    it "keeps the project when its own root cannot be resolved on disk" do
      project = project_at("/nonexistent/orn-collision")

      with_fake_cmd do |fake|
        script_collision(
          fake,
          "orn-collision",
          other_project_root
        )

        expect(described_class.check_collision(output_mode, project)).to be(project)
      end
    end

    it "keeps the project when the existing session lives inside this project" do
      project = collision_project
      session = described_class.session_name(project)
      worktree_path = File.join(project.root, "main")
      FileUtils.mkdir_p(worktree_path)

      with_fake_cmd do |fake|
        script_collision(
          fake,
          session,
          worktree_path
        )

        expect(described_class.check_collision(output_mode, project)).to be(project)
      end
    end

    context "when another project holds the session" do
      it "raises with a config hint when it cannot prompt" do
        project = collision_project
        session = described_class.session_name(project)

        with_fake_cmd do |fake|
          script_collision(
            fake,
            session,
            other_project_root
          )

          with_stdin(StringIO.new) do
            expect do
              described_class.check_collision(output_mode, project)
            end.to raise_error(Orn::Error, %r{is already in use by.+Set session: <name> in \.orn/config\.yaml}m)
          end
        end
      end

      it "rewrites the config and rediscovers the project with the typed name" do
        isolate_global_config
        project = collision_project
        session = described_class.session_name(project)

        with_fake_cmd do |fake|
          script_collision(
            fake,
            session,
            other_project_root
          )

          rediscovered, prompt_output = resolve_interactively(project, "picked-name\n")

          aggregate_failures do
            expect(rediscovered.config.session).to eq("picked-name")
            expect(rediscovered.root).to eq(File.realpath(project.root))
            expect(File.read(File.join(project.root, ".orn/config.yaml"))).to include("session: picked-name")
            expect(prompt_output).to include("Session '#{session}' is already in use by")
          end
        end
      end

      it "falls back to the suggested name on empty input" do
        isolate_global_config
        project = collision_project
        session = described_class.session_name(project)
        suggested = described_class.suggest_name(project.root)

        with_fake_cmd do |fake|
          script_collision(
            fake,
            session,
            other_project_root
          )

          rediscovered, prompt_output = resolve_interactively(project, "\n")

          aggregate_failures do
            expect(rediscovered.config.session).to eq(suggested)
            expect(prompt_output).to include("Enter session name [#{suggested}]: ")
          end
        end
      end

      it "propagates a rejected session name and leaves the config unchanged" do
        project = collision_project
        session = described_class.session_name(project)
        config_path = File.join(project.root, ".orn/config.yaml")

        with_fake_cmd do |fake|
          script_collision(
            fake,
            session,
            other_project_root
          )

          with_interactive_stdin("bad name!\n") do
            expect do
              described_class.check_collision(output_mode, project)
            end.to raise_error(Orn::Error, /session name contains invalid character/)
          end
          expect(File.read(config_path)).to eq("")
        end
      end
    end
  end
end
