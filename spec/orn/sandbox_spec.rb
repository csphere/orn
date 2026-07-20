# frozen_string_literal: true

RSpec.describe Orn::Sandbox do
  describe Orn::Sandbox::PortMapping do
    it "displays as host:container" do
      expect(
        described_class.new(
          host: 3042,
          container: 3000
        ).to_s
      ).to eq("3042:3000")
    end

    it "serializes to string-keyed JSON fields" do
      json_hash = described_class.new(
        host: 3042,
        container: 3000
      ).to_json_hash

      expect(json_hash).to eq(
        "host" => 3042,
        "container" => 3000
      )
    end
  end

  describe ".require_sbx_cli! and .require_docker!" do
    let(:mode) { Orn::OutputMode.default }

    it "passes silently when sbx is on PATH" do
      with_fake_cmd do |fake|
        fake.script(%w[which sbx])

        expect { described_class.require_sbx_cli!(mode) }.not_to raise_error
      end
    end

    it "raises with an install hint when sbx is missing" do
      with_fake_cmd do |fake|
        fake.script(%w[which sbx], status: 1)

        expect { described_class.require_sbx_cli!(mode) }
          .to raise_error(Orn::Error, %r{sbx not found on PATH\n  Install: https://})
      end
    end

    it "passes silently when docker is on PATH" do
      with_fake_cmd do |fake|
        fake.script(%w[which docker])

        expect { described_class.require_docker!(mode) }.not_to raise_error
      end
    end

    it "raises with an install hint when docker is missing" do
      with_fake_cmd do |fake|
        fake.script(%w[which docker], status: 1)

        expect { described_class.require_docker!(mode) }
          .to raise_error(Orn::Error, %r{docker not found on PATH\n  Install: https://})
      end
    end

    it "treats a broken which lookup as the tool being missing" do
      with_fake_cmd do |fake|
        fake.script_missing(%w[which sbx])

        expect { described_class.require_sbx_cli!(mode) }.to raise_error(Orn::Error, /sbx not found on PATH/)
      end
    end
  end

  describe ".run_setup" do
    def exec_argv(command)
      ["sbx", "exec", "my-sbx", "--", "sh", "-c", command]
    end

    it "announces a single command without step numbers" do
      with_fake_cmd do |fake|
        fake.script(exec_argv("bin/setup"))

        expect do
          described_class.run_setup(
            Orn::OutputMode.default,
            "my-sbx",
            ["bin/setup"],
            {}
          )
        end.to output("Running setup in 'my-sbx': bin/setup\n").to_stderr
      end
    end

    it "numbers the steps when there are several commands" do
      with_fake_cmd do |fake|
        fake.script(exec_argv("bundle install"))
        fake.script(exec_argv("bin/rails db:setup"))

        expect do
          described_class.run_setup(
            Orn::OutputMode.default,
            "my-sbx",
            ["bundle install", "bin/rails db:setup"],
            {}
          )
        end.to output(
          "Running setup [1/2] in 'my-sbx': bundle install\n" \
            "Running setup [2/2] in 'my-sbx': bin/rails db:setup\n"
        ).to_stderr
      end
    end

    it "stops at the first failing step and names it" do
      with_fake_cmd do |fake|
        fake.script(exec_argv("step-one"))
        fake.script(
          exec_argv("step-two"),
          stderr: "boom",
          status: 1
        )

        expect do
          described_class.run_setup(
            Orn::OutputMode.quiet,
            "my-sbx",
            %w[step-one step-two step-three],
            {}
          )
        end.to raise_error(Orn::Error, "Setup step 2 failed: step-two")
        expect(fake.invocations).to eq([exec_argv("step-one"), exec_argv("step-two")])
      end
    end
  end

  describe Orn::Sandbox::Check do
    it "builds a passing error check" do
      check = described_class.pass("test", "ok")

      expect(check).to have_attributes(
        passed: true,
        severity: :error,
        name: "test",
        message: "ok"
      )
    end

    it "builds a failing error check" do
      check = described_class.fail("test", "bad")

      expect(check).to have_attributes(
        passed: false,
        severity: :error,
        name: "test",
        message: "bad"
      )
    end

    it "builds a failing warning check" do
      check = described_class.warning(
        "test",
        false,
        "warn msg"
      )

      expect(check).to have_attributes(
        passed: false,
        severity: :warning,
        name: "test",
        message: "warn msg"
      )
    end

    it "builds a passing warning check" do
      check = described_class.warning(
        "test",
        true,
        "ok msg"
      )

      expect(check).to have_attributes(
        passed: true,
        severity: :warning
      )
    end

    it "serializes kind as a lowercase string" do
      aggregate_failures do
        expect(
          described_class.warning(
            "test",
            false,
            "msg"
          ).to_json_hash["severity"]
        ).to eq("warning")
        expect(described_class.fail("test", "msg").to_json_hash["severity"]).to eq("error")
      end
    end
  end
end
