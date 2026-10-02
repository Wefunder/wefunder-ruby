# frozen_string_literal: true

# operationId: getOffering — one offering by its ofr_ id (read:public).
require "wefunder"

module GetOfferingExample
  def self.example(wf, offering_id = "ofr_9m2ExampleRound00")
    # region getOffering
    begin
      offering = wf.offerings.get(offering_id)
    rescue Wefunder::Error => e
      # 404 → e.type == "not_found"; e.request_id is what support asks for.
      puts "#{e.status} #{e.type} #{e.request_id}"
      raise
    end
    puts "#{offering.attributes.company_name} #{offering.attributes.status}"
    # endregion
    offering
  end
end
