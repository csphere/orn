# frozen_string_literal: true

RSpec.describe Orn::Git::BranchName do
  describe "#validate!" do
    context "with a valid name" do
      it "accepts a simple name" do
        expect(described_class.new("my-feature").validate!).to eq("my-feature")
      end

      it "accepts slash-separated segments" do
        expect(described_class.new("feature/ABC-1234").validate!).to eq("feature/ABC-1234")
      end

      it "accepts nested slashes" do
        expect(described_class.new("feature/team/ABC-1234").validate!).to eq("feature/team/ABC-1234")
      end

      it "accepts underscores and hyphens" do
        expect(described_class.new("fix_the-bug").validate!).to eq("fix_the-bug")
      end

      it "accepts digits" do
        expect(described_class.new("release/2024").validate!).to eq("release/2024")
      end

      it "accepts uppercase letters" do
        expect(described_class.new("Feature/ABC").validate!).to eq("Feature/ABC")
      end
    end

    context "when empty" do
      it "reports that the name cannot be empty" do
        expect { described_class.new("").validate! }
          .to raise_error(Orn::Error, /cannot be empty/)
      end
    end

    context "with whitespace" do
      it "rejects a space" do
        expect { described_class.new("my feature").validate! }
          .to raise_error(Orn::Error, /contains space/)
      end

      it "rejects a tab as a control character" do
        expect { described_class.new("my\tfeature").validate! }
          .to raise_error(Orn::Error, /contains control character/)
      end

      it "rejects a newline as a control character" do
        expect { described_class.new("my\nfeature").validate! }
          .to raise_error(Orn::Error, /contains control character/)
      end
    end

    context "with control characters" do
      it "rejects a null byte" do
        expect { described_class.new("my\0feature").validate! }
          .to raise_error(Orn::Error, /contains control character/)
      end

      it "rejects the delete character" do
        expect { described_class.new("my\x7Ffeature").validate! }
          .to raise_error(Orn::Error, /contains control character/)
      end
    end

    context "with git ref-format violations" do
      it "rejects a double dot" do
        expect { described_class.new("feature..lock").validate! }
          .to raise_error(Orn::Error, /contains '\.\.'/)
      end

      it "rejects a tilde" do
        expect { described_class.new("feature~1").validate! }
          .to raise_error(Orn::Error, /contains '~'/)
      end

      it "rejects a caret" do
        expect { described_class.new("feature^2").validate! }
          .to raise_error(Orn::Error, /contains '\^'/)
      end

      it "rejects a colon" do
        expect { described_class.new("feature:name").validate! }
          .to raise_error(Orn::Error, /contains ':'/)
      end

      it "rejects a question mark" do
        expect { described_class.new("feature?").validate! }
          .to raise_error(Orn::Error, /contains '\?'/)
      end

      it "rejects an asterisk" do
        expect { described_class.new("feature*").validate! }
          .to raise_error(Orn::Error, /contains '\*'/)
      end

      it "rejects an open bracket" do
        expect { described_class.new("feature[0]").validate! }
          .to raise_error(Orn::Error, /contains '\['/)
      end

      it "rejects a backslash" do
        expect { described_class.new("feature\\name").validate! }
          .to raise_error(Orn::Error, /contains '\\'/)
      end

      it "rejects an at-brace sequence" do
        expect { described_class.new("feature@{0}").validate! }
          .to raise_error(Orn::Error, /contains '@\{'/)
      end

      it "rejects a bare at sign" do
        expect { described_class.new("@").validate! }
          .to raise_error(Orn::Error, /cannot be '@'/)
      end

      it "rejects a leading slash" do
        expect { described_class.new("/feature").validate! }
          .to raise_error(Orn::Error, %r{cannot start with '/'})
      end

      it "rejects a trailing slash" do
        expect { described_class.new("feature/").validate! }
          .to raise_error(Orn::Error, %r{cannot end with '/'})
      end

      it "rejects a double slash" do
        expect { described_class.new("feature//name").validate! }
          .to raise_error(Orn::Error, %r{contains '//'})
      end

      it "rejects a trailing dot" do
        expect { described_class.new("feature.").validate! }
          .to raise_error(Orn::Error, /cannot end with '\.'/)
      end

      it "rejects a .lock suffix" do
        expect { described_class.new("feature.lock").validate! }
          .to raise_error(Orn::Error, /cannot end with '\.lock'/)
      end

      it "rejects a component starting with a dot" do
        expect { described_class.new("feature/.hidden").validate! }
          .to raise_error(Orn::Error, /component cannot start with '\.'/)
      end

      it "rejects a leading dot" do
        expect { described_class.new(".feature").validate! }
          .to raise_error(Orn::Error, /component cannot start with '\.'/)
      end
    end

    context "with a tmux-breaking dot inside the name" do
      it "rejects the dot" do
        expect { described_class.new("v1.0-hotfix").validate! }
          .to raise_error(Orn::Error, /contains '\.'/)
      end
    end

    context "when reporting the offending name" do
      it "includes the branch name in the message" do
        expect { described_class.new("bad name").validate! }
          .to raise_error(Orn::Error, /'bad name'/)
      end
    end
  end
end
