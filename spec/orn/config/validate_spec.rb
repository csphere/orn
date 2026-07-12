# frozen_string_literal: true

RSpec.describe Orn::Config::Validate do
  describe ".session_name!" do
    context "with a valid name" do
      it "accepts alphanumeric names" do
        expect { described_class.session_name!("mySession123") }.not_to raise_error
      end

      it "accepts hyphens and underscores" do
        expect { described_class.session_name!("work-api") }.not_to raise_error
        expect { described_class.session_name!("my_project") }.not_to raise_error
      end

      it "accepts slashes" do
        expect { described_class.session_name!("work/api") }.not_to raise_error
      end
    end

    context "with an invalid name" do
      it "rejects an empty name" do
        expect { described_class.session_name!("") }.to raise_error(Orn::Error, /must not be empty/)
      end

      it "rejects a colon" do
        expect { described_class.session_name!("victim:0") }.to raise_error(Orn::Error, /invalid character ':'/)
      end

      it "rejects a dot" do
        expect { described_class.session_name!("sess.name") }.to raise_error(Orn::Error, /invalid character '\.'/)
      end

      it "rejects a space" do
        expect { described_class.session_name!("my session") }.to raise_error(Orn::Error, /invalid character/)
      end

      it "rejects shell and tmux metacharacters" do
        ["$session", "{session}", "sess%ion", "sess!", "sess+1"].each do |name|
          expect { described_class.session_name!(name) }.to raise_error(Orn::Error, /invalid character/)
        end
      end
    end
  end

  describe ".sandbox_name!" do
    context "with a valid name" do
      it "accepts alphanumeric names, hyphens, and dots" do
        expect { described_class.sandbox_name!("mySandbox123") }.not_to raise_error
        expect { described_class.sandbox_name!("my-sandbox") }.not_to raise_error
        expect { described_class.sandbox_name!("sbx.name") }.not_to raise_error
      end

      it "accepts a two-character name" do
        expect { described_class.sandbox_name!("ab") }.not_to raise_error
      end
    end

    context "with an invalid name" do
      it "rejects names shorter than two characters" do
        expect { described_class.sandbox_name!("") }.to raise_error(Orn::Error, /at least 2 characters/)
        expect { described_class.sandbox_name!("a") }.to raise_error(Orn::Error, /at least 2 characters/)
      end

      it "rejects an underscore, naming the offending character" do
        expect { described_class.sandbox_name!("my_sandbox") }.to raise_error(Orn::Error, /'_'/)
      end

      it "rejects a slash, naming the offending character" do
        expect { described_class.sandbox_name!("feature/branch") }.to raise_error(Orn::Error, %r{'/'})
      end

      it "rejects a colon" do
        expect { described_class.sandbox_name!("sbx:name") }.to raise_error(Orn::Error, /invalid character/)
      end

      it "rejects a name not starting with a letter or digit" do
        expect { described_class.sandbox_name!("-leading") }.to raise_error(Orn::Error, /must start with/)
        expect { described_class.sandbox_name!(".leading") }.to raise_error(Orn::Error, /must start with/)
      end

      it "rejects a name ending with a hyphen" do
        expect { described_class.sandbox_name!("trailing-") }.to raise_error(Orn::Error, /must not end with a hyphen/)
      end
    end
  end

  describe ".host_range!" do
    context "with a valid range" do
      it "accepts start below end" do
        expect { described_class.host_range!([3000, 3100]) }.not_to raise_error
      end

      it "accepts equal start and end" do
        expect { described_class.host_range!([3000, 3000]) }.not_to raise_error
      end
    end

    context "with an invalid range" do
      it "rejects a reversed range" do
        expect { described_class.host_range!([3100, 3000]) }.to raise_error(Orn::Error, /start/)
      end

      it "rejects a zero start" do
        expect { described_class.host_range!([0, 3000]) }.to raise_error(Orn::Error, /greater than 0/)
      end

      it "rejects a zero end" do
        expect { described_class.host_range!([3000, 0]) }.to raise_error(Orn::Error, /greater than 0/)
      end

      it "rejects both ports zero" do
        expect { described_class.host_range!([0, 0]) }.to raise_error(Orn::Error, /greater than 0/)
      end
    end
  end
end
