# frozen_string_literal: true

RSpec.describe Orn do
  describe "VERSION" do
    it "is a semantic version string" do
      expect(Orn::VERSION).to match(/\A\d+\.\d+\.\d+/)
    end
  end

  describe ".root" do
    it "points at the gem directory that holds the templates" do
      expect(File).to be_directory(File.join(described_class.root, "templates"))
    end
  end
end
