# frozen_string_literal: true

RSpec.describe Orn::Mcp::Protocol do
  describe ".success_response" do
    it "carries the result and no error" do
      response = described_class.success_response(1, "ok" => true)

      aggregate_failures do
        expect(response["result"]).to eq("ok" => true)
        expect(response).not_to have_key("error")
        expect(response["jsonrpc"]).to eq("2.0")
      end
    end

    it "recursively sorts the result keys for a stable order" do
      response = described_class.success_response(1, "b" => 1, "a" => { "z" => 1, "y" => 2 })

      aggregate_failures do
        expect(response["result"].keys).to eq(%w[a b])
        expect(response["result"]["a"].keys).to eq(%w[y z])
      end
    end
  end

  describe ".error_response" do
    it "carries the error code and no result" do
      response = described_class.error_response(1, -32_601, "Method not found")

      aggregate_failures do
        expect(response["error"]).to eq("code" => -32_601, "message" => "Method not found")
        expect(response).not_to have_key("result")
      end
    end
  end

  describe ".initialize_result" do
    it "advertises the protocol version, tools capability, and orn server info" do
      result = described_class.initialize_result

      aggregate_failures do
        expect(result["protocolVersion"]).to eq("2024-11-05")
        expect(result["capabilities"]).to eq("tools" => {})
        expect(result["serverInfo"]).to eq("name" => "orn", "version" => Orn::VERSION)
      end
    end
  end

  describe "tool results" do
    it "omits isError on success" do
      expect(described_class.tool_success("ok")).not_to have_key("isError")
    end

    it "sets isError true on failure" do
      result = described_class.tool_error("fail")

      aggregate_failures do
        expect(result["isError"]).to be(true)
        expect(result["content"]).to eq([{ "type" => "text", "text" => "fail" }])
      end
    end
  end
end
