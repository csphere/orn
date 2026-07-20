# frozen_string_literal: true

module Orn
  module TUI
    RSpec.describe TermBackend do
      let(:backend) { described_class.new }

      # Polls a backend whose input is a pipe preloaded with `bytes`, so key
      # decoding runs through the public poll/read path. The writer stays open
      # so reading stops at end of buffered input, as with a live terminal.
      def poll_bytes(bytes)
        pipe_reader, pipe_writer = IO.pipe
        pipe_writer.write(bytes)
        described_class.new(input: pipe_reader).poll(0)
      ensure
        pipe_writer.close
        pipe_reader.close
      end

      it "decodes arrow, enter, escape, and backspace sequences from poll" do
        aggregate_failures do
          expect(poll_bytes("\e[A")).to eq(KeyEvent.key(:up))
          expect(poll_bytes("\e[B")).to eq(KeyEvent.key(:down))
          expect(poll_bytes("\r")).to eq(KeyEvent.key(:enter))
          expect(poll_bytes("\n")).to eq(KeyEvent.key(:enter))
          expect(poll_bytes("\e")).to eq(KeyEvent.key(:esc))
          expect(poll_bytes("\x7f")).to eq(KeyEvent.key(:backspace))
          expect(poll_bytes("\b")).to eq(KeyEvent.key(:backspace))
        end
      end

      it "decodes a printable byte as a character event" do
        expect(poll_bytes("q")).to eq(KeyEvent.char("q"))
      end

      it "returns nil from poll for a non-printable byte" do
        expect(poll_bytes("\x01")).to be_nil
      end

      it "returns nil from poll when the input closes without sending bytes" do
        pipe_reader, pipe_writer = IO.pipe
        pipe_writer.close
        closed_backend = described_class.new(input: pipe_reader)

        expect(closed_backend.poll(0)).to be_nil
      ensure
        pipe_reader.close
      end

      it "returns nil from poll when no key arrives before the timeout" do
        pipe_reader, pipe_writer = IO.pipe
        idle_backend = described_class.new(input: pipe_reader)

        expect(idle_backend.poll(0)).to be_nil
      ensure
        pipe_writer.close
        pipe_reader.close
      end

      it "reports the console size as the drawable area" do
        input = instance_double(IO, winsize: [30, 100])
        sized_backend = described_class.new(input: input)
        expected_area = Rect.new(
          x: 0,
          y: 0,
          width: 100,
          height: 30
        )

        expect(sized_backend.area).to eq(expected_area)
      end

      it "falls back to a 24x80 area when reading the size raises IOError" do
        input = instance_double(IO)
        allow(input).to receive(:winsize).and_raise(IOError)
        fallback_backend = described_class.new(input: input)
        fallback_area = Rect.new(
          x: 0,
          y: 0,
          width: 80,
          height: 24
        )

        expect(fallback_backend.area).to eq(fallback_area)
      end

      it "falls back to a 24x80 area when the input is not a tty" do
        input = instance_double(IO)
        allow(input).to receive(:winsize).and_raise(Errno::ENOTTY)
        fallback_backend = described_class.new(input: input)
        fallback_area = Rect.new(
          x: 0,
          y: 0,
          width: 80,
          height: 24
        )

        expect(fallback_backend.area).to eq(fallback_area)
      end

      # StringIO stands in for the terminal: it answers tty? with false, so
      # the raw!/cooked! toggles stay guarded off while the escape-sequence
      # contract and the idempotence flags run for real.
      describe "start/stop lifecycle" do
        let(:output) { StringIO.new }
        let(:io_backend) do
          described_class.new(
            input: StringIO.new,
            output: output
          )
        end

        it "enters the alt screen and hides the cursor once, even if started twice" do
          io_backend.start
          io_backend.start

          expect(output.string).to eq("\e[?1049h\e[?25l")
        end

        it "writes nothing when stopped before it ever started" do
          io_backend.stop

          expect(output.string).to eq("")
        end

        it "restores the cursor and main screen once on stop" do
          io_backend.start
          io_backend.stop
          io_backend.stop

          expect(output.string).to eq("\e[?1049h\e[?25l\e[?25h\e[?1049l")
        end

        it "flushes a buffer as a home-cursor move plus the rendered rows" do
          area = Rect.new(
            x: 0,
            y: 0,
            width: 2,
            height: 1
          )

          io_backend.flush(Buffer.new(area))

          expect(output.string).to eq("\e[H#{io_backend.render(Buffer.new(area))}")
        end

        it "clears the whole screen" do
          io_backend.clear

          expect(output.string).to eq("\e[2J")
        end

        it "toggles raw mode on start and cooked mode on stop for a tty input" do
          tty_input = instance_double(IO, tty?: true)
          allow(tty_input).to receive(:raw!)
          allow(tty_input).to receive(:cooked!)
          tty_backend = described_class.new(
            input: tty_input,
            output: output
          )

          tty_backend.start
          tty_backend.stop

          aggregate_failures do
            expect(tty_input).to have_received(:raw!)
            expect(tty_input).to have_received(:cooked!)
            expect(output.string).to eq("\e[?1049h\e[?25l\e[?25h\e[?1049l")
          end
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
