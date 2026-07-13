# frozen_string_literal: true

module Orn
  module TUI
    RSpec.describe Buffer do
      let(:area) { Rect.new(x: 0, y: 0, width: 10, height: 3) }
      let(:buffer) { described_class.new(area) }

      it "writes a styled line into cells starting at the given position" do
        buffer.set_line(0, 1, Line.styled("hi", Style.default.fg(Color::RED)), area.width)

        aggregate_failures do
          expect(buffer[[0, 1]].symbol).to eq("h")
          expect(buffer[[1, 1]].symbol).to eq("i")
          expect(buffer[[0, 1]].fg).to eq(Color::RED)
        end
      end

      it "clips a line at the maximum width" do
        buffer.set_line(0, 0, Line.raw("abcdef"), 3)

        aggregate_failures do
          expect(buffer.to_s).to include("abc")
          expect(buffer[[3, 0]].symbol).to eq(" ")
        end
      end

      it "leaves cells outside the written run blank and unstyled" do
        aggregate_failures do
          expect(buffer[[5, 2]].symbol).to eq(" ")
          expect(buffer[[5, 2]].bg).to eq(Color::RESET)
        end
      end

      it "returns nil for a cell outside the area" do
        expect(buffer.cell(99, 99)).to be_nil
      end
    end
  end
end
