# frozen_string_literal: true

RSpec.describe Orn::Config::GlobalTuiConfig do
  def global_with(yaml)
    dir = register_temp_dir(Dir.mktmpdir("orn-global"))
    File.write(File.join(dir, "default.yaml"), yaml)
    dir
  end

  describe ".load_from" do
    context "with no global config" do
      it "uses defaults" do
        config = described_class.load_from(nil)

        expect(config.session).to eq("orn")
        expect(config.scan_depth).to eq(3)
      end
    end

    context "with a global config" do
      it "reads the session" do
        global = global_with("tui:\n  session: dev\n")

        expect(described_class.load_from(global).session).to eq("dev")
      end

      it "reads the scan depth" do
        global = global_with("tui:\n  scan_depth: 5\n")

        expect(described_class.load_from(global).scan_depth).to eq(5)
      end

      it "reads the scan roots" do
        global = global_with("tui:\n  scan_roots: [\"/home/user/dev\", \"/home/user/work\"]\n")

        expect(described_class.load_from(global).scan_roots).to eq(["/home/user/dev", "/home/user/work"])
      end

      it "ignores unknown fields" do
        global = global_with("tui:\n  session: custom\n  unknown_field: true\n")

        expect(described_class.load_from(global).session).to eq("custom")
      end
    end

    context "with a tilde-prefixed scan root" do
      it "rejects a bare tilde" do
        global = global_with("tui:\n  scan_roots: [\"~\"]\n")

        expect { described_class.load_from(global) }
          .to raise_error(Orn::Error, /Invalid scan root.*absolute path/m)
      end

      it "rejects a tilde subdirectory, naming the root" do
        global = global_with("tui:\n  scan_roots: [\"~/dev\"]\n")

        expect { described_class.load_from(global) }
          .to raise_error(Orn::Error, %r{Invalid scan root "~/dev"})
      end
    end
  end
end
