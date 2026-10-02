# frozen_string_literal: true

module Wefunder
  # Lazy auto-pagination over an OPAQUE cursor. Different endpoints back the cursor with an
  # int id, an ISO timestamp, or an offset, so it is never inspected — +meta.next_cursor+ is
  # fed back verbatim. Stop when +meta.has_more+ is false, +next_cursor+ is nil/absent, or a
  # cursor repeats (loop guard). The Investment Delta API always sends +next_cursor+, even on
  # the last page, so +has_more+ terminates there.
  module Pagination
    module_function

    # +(items, has_more, next_cursor)+ from a Hash page (string or symbol keys) or a generated
    # +*ListEnvelope+ object.
    def page_parts(page)
      data = read(page, :data) || []
      meta = read(page, :meta)
      has_more = read(meta, :has_more)
      [Array(data), [true, false].include?(has_more) ? has_more : nil, read(meta, :next_cursor)]
    end

    def read(obj, key)
      return nil if obj.nil?
      return (obj.key?(key.to_s) ? obj[key.to_s] : obj[key]) if obj.is_a?(Hash)

      obj.respond_to?(key) ? obj.public_send(key) : nil
    end

    # Yields every item across all pages, lazily. +fetch_page.call(nil)+ is the first page.
    def paginate(fetch_page = nil, &block)
      fetch = fetch_page || block
      Enumerator.new do |y|
        cursor = nil
        seen = {}
        loop do
          items, has_more, next_cursor = page_parts(fetch.call(cursor))
          items.each { |item| y << item }
          break if has_more == false || next_cursor.nil? || seen.key?(next_cursor)

          seen[next_cursor] = true
          cursor = next_cursor
        end
      end
    end

    def collect(fetch_page = nil, &)
      paginate(fetch_page, &).to_a
    end
  end

  def self.paginate(fetch_page = nil, &) = Pagination.paginate(fetch_page, &)
  def self.collect(fetch_page = nil, &) = Pagination.collect(fetch_page, &)
end
