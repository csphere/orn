# frozen_string_literal: true

module Orn
  module TUI
    RSpec.describe TermBackend do
      let(:backend) { described_class.new }

      it "decodes arrow, enter, escape, backspace, and printable keys" do
        aggregate_failures do
          expect(backend.send(:decode, "\e[A").code).to eq(:up)
          expect(backend.send(:decode, "\e[B").code).to eq(:down)
          expect(backend.send(:decode, "\r").code).to eq(:enter)
          expect(backend.send(:decode, "\e").code).to eq(:esc)
          expect(backend.send(:decode, "\x7f").code).to eq(:backspace)
          expect(backend.send(:decode, "q")).to eq(KeyEvent.char("q"))
          expect(backend.send(:decode, "")).to be_nil
        end
      end

      it "emits an SGR sequence carrying foreground, background, and bold" do
        cell = Cell.new(
          symbol: "x",
          fg: Color::RED,
          bg: Color::WHITE,
          bold: true
        )

        expect(backend.send(:sgr, cell)).to eq("\e[0;1;31;47m")
      end

      it "renders a buffer row with a cursor move and a clear-to-end" do
        area = Rect.new(
          x: 0,
          y: 0,
          width: 3,
          height: 1
        )
        buffer = Buffer.new(area)
        buffer.set_line(
          0,
          0,
          Line.raw("hi"),
          3
        )

        output = backend.render(buffer)

        aggregate_failures do
          expect(output).to include("\e[1;1H")
          expect(output).to include("hi")
          expect(output).to include("\e[K")
        end
      end
    end
  end
end
