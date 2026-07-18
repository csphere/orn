# frozen_string_literal: true

module Orn
  module TUI
    RSpec.describe Paragraph do
      it "draws each line on its own row" do
        area = Rect.new(
          x: 0,
          y: 0,
          width: 12,
          height: 4
        )
        buffer = Buffer.new(area)

        described_class.new([Line.raw("first"), Line.raw("second")]).render(area, buffer)

        aggregate_failures do
          expect(buffer[[0, 0]].symbol).to eq("f")
          expect(buffer[[0, 1]].symbol).to eq("s")
        end
      end

      it "clips lines past the area height" do
        area = Rect.new(
          x: 0,
          y: 0,
          width: 12,
          height: 1
        )
        buffer = Buffer.new(area)

        described_class.new([Line.raw("one"), Line.raw("two")]).render(area, buffer)

        expect(buffer.to_s).not_to include("two")
      end
    end
  end
end
