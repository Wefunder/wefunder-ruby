# frozen_string_literal: true

require "yaml"

# Every documented 2xx response example must build through the generated layer. Nothing else
# exercises lib/wefunder_generated end to end (rubocop excludes it, the other specs answer with
# hand-written bodies), so a spec sync can pass the suite while an operation cannot build a real
# response: an anyOf response the generator's ApiClient cannot dispatch (NoMethodError on every
# call), or an enum that rejects a value the example carries (ArgumentError).
#
# Each example goes through ApiClient#convert_to_type with the return type its generated method
# declares, which is exactly what a live call does with the response body.
GENERATED_SPEC = YAML.safe_load_file(File.join(SpecSupport::ROOT, "openapi/openapi.yaml"), aliases: true)
GENERATED_OPERATIONS = GENERATED_SPEC.fetch("paths").values.flat_map do |item|
  item.slice("get", "post", "put", "patch", "delete").values
end
# "list_offerings" => "OfferingListEnvelope" (nil for an operation that returns no body).
GENERATED_RETURN_TYPES = Dir[File.join(SpecSupport::ROOT, "lib/wefunder_generated/api/*.rb")].each_with_object({}) do |file, types|
  File.read(file).scan(/def (\w+)_with_http_info\b.*?return_type = opts\[:debug_return_type\](?: \|\| '([^']+)')?/m) do |name, type|
    types[name] = type
  end
end
GENERATED_EXAMPLES = GENERATED_OPERATIONS.flat_map do |operation|
  method = operation.fetch("operationId").gsub(/([A-Z])/) { "_#{Regexp.last_match(1).downcase}" }
  operation.fetch("responses", {}).filter_map do |status, response|
    example = response.dig("content", "application/json", "example")
    [operation["operationId"], status, method, example] if status.start_with?("2") && example
  end
end

RSpec.describe "generated layer" do
  it "has a generated method for every operationId in the spec" do
    missing = GENERATED_OPERATIONS.map { |operation| operation["operationId"] }.reject do |id|
      GENERATED_RETURN_TYPES.key?(id.gsub(/([A-Z])/) { "_#{Regexp.last_match(1).downcase}" })
    end
    expect(missing).to eq([])
  end

  it "finds the spec's response examples (so the examples below cannot pass vacuously)" do
    expect(GENERATED_EXAMPLES.size).to be >= 70
  end

  GENERATED_EXAMPLES.each do |operation_id, status, method, example|
    it "builds the documented #{status} example of #{operation_id}" do
      type = GENERATED_RETURN_TYPES.fetch(method)
      skip "#{operation_id} declares no return type" if type.nil?

      body = JSON.parse(JSON.generate(example), symbolize_names: true)
      expect(WefunderGenerated::ApiClient.new.convert_to_type(body, type)).not_to be_nil
    end
  end
end
