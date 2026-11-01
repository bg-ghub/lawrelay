require "digest"
require "fileutils"
require "json"
require "net/http"
require "nokogiri"
require "optparse"
require "time"
require "timeout"
require "uri"

# Build reviewed routing input from the source URLs already in the court catalogue.
# The output and optional HTML cache belong in ignored tmp/, never in public Git.
class CourtAddressCollector
  MAX_BODY_BYTES = 1_048_576
  TIMEOUT_SECONDS = 15
  MAX_REQUESTS = 320
  ORDINARY_HOSTS = %w[www.tribunaux-rechtbanken.be tribunaux-rechtbanken.be
    www.rechtbanken-tribunaux.be rechtbanken-tribunaux.be].freeze
  SPECIAL_URLS = %w[https://www.courdecassation.be/nl/Acces-Toegang.html
    https://fr.const-court.be/footer/contacts
    https://www.raadvst-consetat.be/?lang=nl&page=contact].freeze
  Response = Data.define(:status, :body, :location, :content_type)

  class FetchError < StandardError
    attr_reader :status, :final_url

    def initialize(status, final_url: nil)
      @status = status
      @final_url = final_url
      super(status)
    end
  end

  attr_reader :request_count

  def initialize(sources:, transport: nil, clock: nil, sleeper: nil, html_cache: nil, request_limit: MAX_REQUESTS)
    raise ArgumentError, "Invalid request limit" unless request_limit.is_a?(Integer) && request_limit.between?(1, MAX_REQUESTS)

    @sources = sources.uniq.freeze
    @transport = transport || method(:http_get)
    @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    @sleeper = sleeper || ->(duration) { sleep(duration) }
    @html_cache = html_cache
    @request_limit = request_limit
    @request_count = 0
    @last_request_at = nil
  end

  def collect(source)
    unless @sources.include?(source) && self.class.safe_url?(source)
      return record(source, status: "unsafe_url")
    end

    response, final_url = Timeout.timeout(TIMEOUT_SECONDS) { fetch(source) }
    return record(source, status: "http_error", final_url:, http_status: response.status) unless response.status.between?(200, 299)
    return record(source, status: "unsupported_content", final_url:) unless response.content_type.to_s.match?(/\A(?:text\/html|application\/xhtml\+xml)\b/i)

    parsed = self.class.parse(response.body)
    cache_html(source, response.body)
    record(source, **parsed, final_url:, http_status: response.status)
  rescue FetchError => error
    record(source, status: error.status, final_url: error.final_url)
  rescue Timeout::Error, Net::OpenTimeout, Net::ReadTimeout, SocketError, IOError, SystemCallError,
    OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::ProtocolError
    record(source, status: "unavailable")
  end

  def self.safe_url?(url)
    return false unless url.is_a?(String) && url.bytesize <= 2_048

    uri = URI.parse(url)
    return false unless uri.is_a?(URI::HTTPS) && uri.port == 443 && uri.userinfo.nil? && uri.fragment.nil?
    return true if SPECIAL_URLS.include?(url)

    ORDINARY_HOSTS.include?(uri.host&.downcase) && uri.query.nil? && uri.path.start_with?("/")
  rescue URI::InvalidURIError
    false
  end

  def self.parse(html)
    raise FetchError, "body_too_large" if html.to_s.bytesize > MAX_BODY_BYTES

    document = Nokogiri::HTML(html)
    main = document.at_css("main, #main, #main-content, .region-content")
    return { status: "not_found", title: nil, addresses: [] } unless main

    title_node = main.at_css("h1") || document.at_css("h1") || document.at_css("title")
    title = title_node&.text&.gsub(/[[:space:]]+/, " ")&.strip&.slice(0, 250)
    nodes = main.css(".paragraph--type--address, address").reject do |node|
      node.ancestors.any? { |ancestor| %w[footer header nav].include?(ancestor.name) }
    end
    addresses = nodes.flat_map do |node|
      candidates = node.css("address")
      candidates = node.css("li") if candidates.empty?
      candidates = [ node ] if candidates.empty?
      candidates.filter_map { |candidate| address_text(candidate) }
    end
    addresses.concat(contact_addresses(main))
    addresses.uniq! { |address| address.downcase.gsub(/[[:punct:]\s]+/, " ").strip }
    status = addresses.empty? ? "not_found" : (addresses.one? ? "ok" : "ambiguous")
    { status:, title:, addresses: }
  end

  # Follow an actual court-specific Contact anchor, never a guessed URL or the
  # shared footer contact page.
  def self.contact_link(html, source_url:)
    return unless safe_url?(source_url) && ORDINARY_HOSTS.include?(URI(source_url).host)

    source_path = URI(source_url).path.sub(%r{/\z}, "")
    links = Nokogiri::HTML(html).css("a[href]").filter_map do |anchor|
      label = anchor.text.gsub(/[[:space:]]+/, " ").strip
      next unless label.match?(/\Acontact(?:en|s|gegevens)?\z/i)

      begin
        url = URI.join(source_url, anchor["href"]).to_s
        next unless safe_url?(url)
        target = URI(url)
        next unless ORDINARY_HOSTS.include?(target.host) && target.path.start_with?("#{source_path}/") &&
          target.path.match?(%r{/contact(?:en|s|gegevens)?/?\z}i)

        url
      rescue URI::InvalidURIError
        nil
      end
    end.uniq
    links.first if links.one?
  end

  def self.generic_destination?(url)
    path = URI(url).path.sub(%r{/\z}, "")
    path.empty? || path.match?(%r{\A/(?:nl|fr|de|en)\z}i) ||
      path.match?(%r{\A/(?:nl|fr|de|en)/(?:contact|contacten|contacts|contacteer-ons|contactez-nous)\z}i) ||
      path.match?(%r{\A/(?:nl|fr|de|en)/(?:rechtbanken|hoven|cours|tribunaux)(?:/[^/]+)?\z}i)
  end

  def self.address_matches_city?(address, city_names:)
    normalized_address = normalized_place(address)
    city_names.any? { |city| normalized_address.end_with?(" #{normalized_place(city)}") }
  end

  def self.normalized_place(value)
    value.to_s.unicode_normalize(:nfkd).gsub(/\p{M}/, "").downcase.gsub(/[^a-z0-9]+/, " ").strip
  end
  private_class_method :normalized_place

  def self.address_text(node)
    copy = node.dup
    copy.css("script, style, svg, a, button, h1, h2, h3, h4").remove
    copy.css("br").each { |line_break| line_break.replace("\n") }
    text = copy.text.gsub(/[[:space:]]+/, " ").strip
    return if text.empty? || text.length > 500 || text.include?("@")
    return unless text.match?(/\p{L}.*(?:\s|,)\s*(?:B[-\s]?)?[1-9]\d{3}\s+\p{L}/u)
    return if text.match?(/\b(?:postbus|bo[iî]te postale)\b/i)

    text
  end
  private_class_method :address_text

  def self.contact_addresses(main)
    contact = main.at_css("#list-contact")
    return [] unless contact

    contact.css(".paragraph--type--remark-html p").flat_map do |paragraph|
      copy = paragraph.dup
      copy.css("script, style, svg, a, button").remove
      copy.css("br").each { |line_break| line_break.replace("\n") }
      lines = copy.text.split(/\r?\n/).map { |line| line.gsub(/[[:space:]]+/, " ").strip }.reject(&:empty?)
      lines.each_with_index.filter_map do |line, index|
        next if index.zero? || !line.match?(/\A(?:B[-\s]?)?[1-9]\d{3}\s+\p{L}[\p{L}\p{M}\p{Zs}'().-]*\z/u)

        street = lines[index - 1]
        next unless street.match?(/\p{L}.*\d/u)
        next if street.match?(/@|\b(?:floor|verdieping|[eé]tage|telefoon|phone|IBAN|postbus|bo[iî]te postale)\b|\bt[eé]l[.:]|\bBE\d{2}/i)

        address = "#{street} #{line}"
        address if address.length <= 500
      end
    end
  end
  private_class_method :contact_addresses

  private

  def fetch(source)
    current_url = source
    seen = []
    3.times do |attempt|
      raise FetchError, "unsafe_redirect" unless self.class.safe_url?(current_url)
      raise FetchError, "redirect_loop" if seen.include?(current_url)

      seen << current_url
      response = request(URI(current_url))
      raise FetchError, "body_too_large" if response.body.to_s.bytesize > MAX_BODY_BYTES
      return [ response, current_url ] unless response.status.between?(300, 399)
      raise FetchError, "too_many_redirects" if attempt == 2
      raise FetchError, "unsafe_redirect" if response.location.to_s.empty?

      current_url = URI.join(current_url, response.location).to_s
      if self.class.safe_url?(current_url) && self.class.generic_destination?(current_url)
        raise FetchError.new("generic_redirect", final_url: current_url)
      end
    end
  rescue URI::InvalidURIError
    raise FetchError, "unsafe_redirect"
  end

  def request(uri)
    raise FetchError, "request_limit" if @request_count >= @request_limit

    if @last_request_at
      remaining = 1.0 - (@clock.call - @last_request_at)
      @sleeper.call(remaining) if remaining.positive?
    end
    @last_request_at = @clock.call
    @request_count += 1
    @transport.call(uri)
  end

  def http_get(uri)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_PEER
    http.open_timeout = 5
    http.read_timeout = 8
    http.max_retries = 0
    request = Net::HTTP::Get.new(uri.request_uri,
      "Accept" => "text/html", "User-Agent" => "LawRelay court-address data preparation (+https://lawrelay.be)")
    http.start do |client|
      client.request(request) do |response|
        body = +"".b
        if response.is_a?(Net::HTTPSuccess)
          response.read_body do |chunk|
            raise FetchError, "body_too_large" if body.bytesize + chunk.bytesize > MAX_BODY_BYTES

            body << chunk
          end
        end
        return Response.new(status: response.code.to_i, body:, location: response["location"],
          content_type: response["content-type"])
      end
    end
  end

  def cache_html(source, html)
    return unless @html_cache

    FileUtils.mkdir_p(@html_cache)
    File.binwrite(File.join(@html_cache, "#{Digest::SHA256.hexdigest(source)}.html"), html)
  end

  def record(source, status:, title: nil, addresses: [], final_url: nil, http_status: nil)
    { source_url: source, final_url:, title:, addresses:, status:, http_status:,
      fetched_at: Time.now.utc.iso8601 }
  end

  class CLI
    def self.run(arguments)
      root = File.expand_path("../..", __dir__)
      options = { catalogue: File.join(root, "config/courts.be.json"),
        output: File.join(root, "tmp/court-addresses/official-court-addresses.json"), limit: MAX_REQUESTS }
      OptionParser.new do |parser|
        parser.banner = "Usage: ruby script/ops/collect-court-addresses.rb [options]"
        parser.on("--catalogue PATH") { |value| options[:catalogue] = value }
        parser.on("--output PATH") { |value| options[:output] = value }
        parser.on("--source URL", "Collect one catalogue source") { |value| options[:source] = value }
        parser.on("--limit NUMBER", Integer, "Maximum sources this run (1-320)") { |value| options[:limit] = value }
        parser.on("--retry-failures", "Retry cached failures, not successful or ambiguous records") { options[:retry_failures] = true }
        parser.on("--html-cache PATH", "Temporarily keep source HTML for parser review (may include staff contacts)") { |value| options[:html_cache] = value }
        parser.on("--contact-pass", "Follow cached actual Contact links for ordinary not_found courts (max20requests)") { options[:contact_pass] = true }
      end.parse!(arguments)
      abort "Limit must be between 1 and #{MAX_REQUESTS}." unless options[:limit].between?(1, MAX_REQUESTS)

      catalogue = JSON.parse(File.read(options[:catalogue]))
      sources = catalogue.fetch("courts").map { |court| court.fetch("source") }.uniq
      abort "Catalogue contains more than #{MAX_REQUESTS} source URLs." if sources.length > MAX_REQUESTS
      if options[:source]
        abort "Source is not in the existing catalogue." unless sources.include?(options[:source])
        sources = [ options[:source] ]
      end
      output = options[:output]
      records = File.exist?(output) ? JSON.parse(File.read(output)).fetch("records") : {}
      return contact_pass(options:, sources:, records:, output:, catalogue:) if options[:contact_pass]

      pending = sources.reject do |source|
        previous = records[source]
        previous && (!options[:retry_failures] || %w[ok ambiguous].include?(previous.fetch("status")))
      end.first(options[:limit])
      collector = CourtAddressCollector.new(sources:, html_cache: options[:html_cache])
      FileUtils.mkdir_p(File.dirname(output))
      pending.each_with_index do |source, index|
        break if collector.request_count >= MAX_REQUESTS

        records[source] = collector.collect(source)
        save(output, records)
        if ((index + 1) % 25).zero? || index == pending.length - 1
          puts JSON.generate(completed_this_run: index + 1, http_requests: collector.request_count,
            total_cached: records.length, statuses: records.values.map { |record| record[:status] || record.fetch("status") }.tally)
          $stdout.flush
        end
      end
      puts "No uncached sources to collect." if pending.empty?
    end

    def self.contact_pass(options:, sources:, records:, output:, catalogue:)
      abort "Contact pass stores parsed records only." if options[:html_cache]

      candidates = sources.filter_map do |source|
        record = records[source]
        next unless record && record["status"] == "not_found" && ORDINARY_HOSTS.include?(URI(source).host)
        next if record["contact_url"] && !options[:retry_failures]

        cache = File.join(File.dirname(output), "html", "#{Digest::SHA256.hexdigest(source)}.html")
        next unless File.file?(cache)

        contact_url = CourtAddressCollector.contact_link(File.binread(cache), source_url: source)
        [ source, contact_url ] if contact_url
      end.first([ options[:limit], 20 ].min)
      collector = CourtAddressCollector.new(sources: candidates.map(&:last), request_limit: 20)
      candidates.each_with_index do |(source, contact_url), index|
        break if collector.request_count >= 20

        result = collector.collect(contact_url)
        court = catalogue.fetch("courts").find { |entry| entry.fetch("source") == source }
        city = court.fetch("city")
        city_names = [ city, *catalogue.fetch("places").fetch(city, {}).values ]
        if result.fetch(:status) == "ok" && !CourtAddressCollector.address_matches_city?(result.fetch(:addresses).fetch(0), city_names:)
          result[:status] = "venue_mismatch"
        end
        result[:expected_city] = city
        records[source] = result.merge(source_url: source, contact_url:)
        save(output, records)
        puts JSON.generate(completed_contact_sources: index + 1, http_requests: collector.request_count,
          status: result.fetch(:status), total_cached: records.length)
        $stdout.flush
      end
      puts "No cached court-specific Contact links to collect." if candidates.empty?
    end

    def self.save(output, records)
      payload = { schema_version: 1, updated_at: Time.now.utc.iso8601, records: }
      temporary = "#{output}.tmp"
      File.write(temporary, JSON.pretty_generate(payload) + "\n")
      File.rename(temporary, output)
    end
    private_class_method :contact_pass, :save
  end
end

CourtAddressCollector::CLI.run(ARGV) if $PROGRAM_NAME == __FILE__
