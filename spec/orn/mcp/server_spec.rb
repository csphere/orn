# frozen_string_literal: true

require "stringio"
require "json"

RSpec.describe Orn::Mcp::Server do
  def serve(*lines)
    output = StringIO.new
    described_class.serve_io(StringIO.new(lines.join("\n")), output)
    output.string.lines.map(&:chomp)
  end

  describe ".serve_io over a full session" do
    # One session exercising initialize, a notification (skipped), tools/list,
    # tools/call with no name, an unknown method, an unparseable line, a blank
    # line, and a final initialize proving the loop survived every error.
    let(:responses) do
      lines = serve(
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}',
        '{"jsonrpc":"2.0","method":"notifications/initialized"}',
        '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}',
        '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{}}',
        '{"jsonrpc":"2.0","id":4,"method":"nonexistent","params":{}}',
        "not json",
        "",
        '{"jsonrpc":"2.0","id":5,"method":"initialize","params":{}}'
      )
      lines.map { |line| JSON.parse(line) }
    end

    it "skips the notification and blank line, yielding six responses" do
      aggregate_failures do
        expect(responses.length).to eq(6)
        expect(responses.map { |r| r["id"] }).to eq([1, 2, 3, 4, nil, 5])
        expect(responses).to all(include("jsonrpc" => "2.0"))
      end
    end

    it "answers initialize with the protocol version and orn server info" do
      aggregate_failures do
        expect(responses[0]["result"]["protocolVersion"]).to eq("2024-11-05")
        expect(responses[0]["result"]["serverInfo"]["name"]).to eq("orn")
      end
    end

    it "lists tools and reports the four error codes" do
      aggregate_failures do
        expect(responses[1]["result"]["tools"]).to be_an(Array)
        expect(responses[2]["error"]["code"]).to eq(-32_602)
        expect(responses[3]["error"]["code"]).to eq(-32_601)
        expect(responses[4]["error"]["code"]).to eq(-32_700)
        expect(responses[4]["error"]["message"]).to start_with("Parse error:")
      end
    end

    it "survives the errors and answers the final request" do
      expect(responses[5]["result"]).to be_a(Hash)
    end
  end

  describe ".serve_io byte parity" do
    it "emits a tools/list line exactly matching the golden fixture" do
      golden = File.read(File.expand_path("../../fixtures/mcp/tools_list_response.json", __dir__)).chomp

      line = serve('{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}').first

      expect(line).to eq(golden)
    end
  end
end
