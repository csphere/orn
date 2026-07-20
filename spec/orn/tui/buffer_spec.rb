# frozen_string_literal: true

module Orn
  module TUI
    RSpec.describe Buffer do
      let(:area) do
        Rect.new(
          x: 0,
          y: 0,
          width: 10,
          height: 3
        )
      end
      let(:buffer) { described_class.new(area) }

      it "writes a styled line into cells starting at the given position" do
        buffer.set_line(
          0,
          1,
          Line.styled("hi", Style.default.fg(Color::RED)),
          area.width
        )

        aggregate_failures do
          expect(buffer[[0, 1]].symbol).to eq("h")
          expect(buffer[[1, 1]].symbol).to eq("i")
          expect(buffer[[0, 1]].fg).to eq(Color::RED)
        end
      end

      it "clips a line at the maximum width" do
        buffer.set_line(
          0,
          0,
          Line.raw("abcdef"),
          3
        )

        aggregate_failures do
          expect(buffer.to_s).to include("abc")
          expect(buffer[[3, 0]].symbol).to eq(" ")
        end
      end

      it "drops characters past the buffer edge without wrapping to the next row" do
        cursor = buffer.set_line(
          8,
          0,
          Line.raw("abcdef"),
          10
        )

        aggregate_failures do
          expect(buffer[[8, 0]].symbol).to eq("a")
          expect(buffer[[9, 0]].symbol).to eq("b")
          expect(buffer[[0, 1]].symbol).to eq(" ")
          expect(buffer.to_s).not_to include("c")
          expect(cursor).to eq(14)
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

      it "builds a blank buffer over the given area with Buffer.empty" do
        empty_buffer = described_class.empty(area)

        aggregate_failures do
          expect(empty_buffer.area).to eq(area)
          expect(empty_buffer.to_s).to eq(" " * (area.width * area.height))
        end
      end

      it "exposes every cell in row-major order through content" do
        buffer.set_line(
          0,
          0,
          Line.raw("ab"),
          area.width
        )

        aggregate_failures do
          expect(buffer.content.length).to eq(area.width * area.height)
          expect(buffer.content.first(2).map(&:symbol)).to eq(%w[a b])
        end
      end
    end
  end
end
