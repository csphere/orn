# frozen_string_literal: true

module Orn
  module TUI
    RSpec.describe Style do
      it "builds foreground, background, and bold without mutating the base" do
        base = described_class.default
        styled = base.fg(Color::RED).bg(Color::WHITE).bold

        aggregate_failures do
          expect(styled.foreground).to eq(Color::RED)
          expect(styled.background).to eq(Color::WHITE)
          expect(styled.bold?).to be(true)
          expect(base.foreground).to be_nil
          expect(base.bold?).to be(false)
        end
      end

      it "compares equal by resolved colours and weight" do
        one = described_class.default.fg(Color::RED)
        two = described_class.default.fg(Color::RED)

        expect(one).to eq(two)
      end
    end
  end
end
