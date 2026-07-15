# frozen_string_literal: true

require "open3"
require "net/http"

# Full-stack sandbox system spec: a dummy Rails app backed by postgres,
# redis, and a sidekiq-style worker, provisioned entirely through the
# project's sbx config (template build, setup commands, env injection,
# detached start, port publishing) and torn down through `orn remove`.
#
# Heavyweight: builds a template image and creates a real sandbox, so it is
# gated by `:sbx_system` (Docker auth) on top of `:system`.
RSpec.describe "orn sandbox full-stack app", :sbx_system, :system do
  include_context "with a sandbox system project"

  let(:branch) { "feature/rails" }
  let(:app_dir) { File.join(workspace, "app", branch) }

  let(:project_config) do
    <<~YAML
      orn_version: "#{Orn::VERSION}"
      git:
        base: main
      tmux:
        session: "#{session}"
      sbx:
        agent_type: shell
        template: "orn-system-rails:latest"
        setup:
          - service postgresql start && service redis-server start
          - cd "$APP_DIR" && bin/setup
        start: cd "$APP_DIR" && bin/start
        build:
          dockerfile: "#{File.join(fixture_dir, "Dockerfile")}"
        env:
          APP_DIR: "#{app_dir}"
          DATABASE_URL: "#{database_url}"
          REDIS_URL: "#{redis_url}"
        ports:
          - container: 3000
            host_range: [3300, 3400]
    YAML
  end

  def fixture_dir
    File.expand_path("fixtures/rails-app", __dir__)
  end

  def database_url
    "postgres://rails:railspw@127.0.0.1:5432/rails_dummy_development"
  end

  def redis_url
    "redis://127.0.0.1:6379/0"
  end

  # One example carries the whole round trip: the template build and sandbox
  # provisioning are far too expensive to repeat per assertion.
  it "provisions the app through the sandbox config and tears it down" do
    project = clone_project(make_remote(fixture_dir), project_config)

    # The build approves the sbx commands at the trust prompt; every later
    # run reuses the saved approval non-interactively.
    build_output, build_status = orn_pty("sbx", "build", chdir: project, input: "y\n")
    expect(build_status).to be_success, "orn sbx build failed:\n#{build_output}"

    # One command provisions everything: worktree, tmux window, sandbox,
    # setup (services + database), published port, detached app start.
    result = orn_json("switch", "--sbx", branch, chdir: project)
    expect(result).to include("branch" => branch, "sandbox_name" => sandbox_name)

    expect_app_healthy(result.fetch("host_ports").first.fetch("host"))
    expect_job_processed

    orn_ok("remove", branch, chdir: project)
    expect_torn_down(project)
  end

  # The app stub reports its own health plus postgres and redis connectivity
  # from inside the sandbox, through the published port.
  def expect_app_healthy(host_port)
    healthy = wait_until(120) do
      body = health_body(host_port)
      !body.nil? && body.include?('"postgres":"ok"') && body.include?('"redis":"ok"')
    end
    expect(healthy).to be(true), <<~MESSAGE
      app never became healthy on port #{host_port}
      last response: #{health_body(host_port).inspect}
      #{app_logs}
    MESSAGE
  end

  def health_body(host_port)
    response = Net::HTTP.start("127.0.0.1", host_port, open_timeout: 5, read_timeout: 5) do |http|
      http.get("/up")
    end
    response.is_a?(Net::HTTPSuccess) ? response.body : nil
  rescue SystemCallError, Net::OpenTimeout, Net::ReadTimeout, EOFError
    nil
  end

  # Worker round trip: enqueue through redis, the worker records the job in
  # postgres, and the count comes back through the database.
  def expect_job_processed
    _stdout, stderr, status = app_exec("bin/rails jobs:enqueue system-test-job")
    expect(status).to be_success, "jobs:enqueue failed: #{stderr}"

    processed = wait_until(60) do
      stdout, _stderr, count_status = app_exec("bin/rails jobs:count")
      count_status.success? && stdout.strip.to_i >= 1
    end
    expect(processed).to be(true), "worker never processed the job\n#{app_logs}"
  end

  def expect_torn_down(project)
    aggregate_failures do
      expect(File).not_to exist(app_dir)
      expect(listed_sandbox_names(project)).not_to include(sandbox_name)
    end
  end

  # Runs a command in the sandbox from the app directory, with the same env
  # the app was configured with.
  def app_exec(command)
    Open3.capture3(
      "sbx", "exec", sandbox_name, "--",
      "env", "DATABASE_URL=#{database_url}", "REDIS_URL=#{redis_url}",
      "sh", "-c", "cd '#{app_dir}' && #{command}"
    )
  end

  def app_logs
    stdout, _stderr, _status = app_exec("tail -50 log/rails.log log/sidekiq.log 2>&1")
    "app logs:\n#{stdout}"
  end
end
