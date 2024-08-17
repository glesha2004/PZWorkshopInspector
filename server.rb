# Required libraries for web server and HTML parsing
require 'sinatra'
require 'nokogiri'
require 'net/http'
require 'uri'
require 'logger'
require 'set'
require 'concurrent'

# Setting up logger to output logs to the console
logger = Logger.new(STDOUT)
logger.level = Logger::INFO

# Setting the default encoding for external and internal processing
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

# Class to handle the identification and processing of Steam Workshop URLs
class SteamWorkshopIdentifier
# Constructor initializing logger, sets, and cache for the identifier
  def initialize(logger)
    @logger = logger
    @processed_mods = Set.new 
    @cycle_detection = Set.new
    @cache = Concurrent::Hash.new
  end

# Method to check the provided URL and identify its type
  def check_url(url)
    @logger.info("Checking URL: #{url}")

    return @cache[url] if @cache.key?(url)

    invalid_urls = [
      "https://steamcommunity.com/app/108600/workshop/",
      "https://steamcommunity.com/workshop/browse/?appid=108600"
    ]

    if invalid_urls.any? { |invalid_url| url.start_with?(invalid_url) }
      @logger.warn("Invalid workshop browser link.")
      raise 'Invalid workshop browser link.'
    end

    begin
      uri = URI.parse(url)
      response = Net::HTTP.get_response(uri)
      if response.is_a?(Net::HTTPSuccess)
        html_content = response.body.force_encoding('UTF-8')
        result = identify_page_type_and_content(html_content, url)
        @logger.info("Final result to send: #{result.inspect}")

        @cache[url] = result.join("\n")
        return @cache[url]
      else
        @logger.error("Failed to load page: #{response.code} #{response.message}")
        raise "Failed to load page: #{response.code} #{response.message}"
      end
    rescue StandardError => e
      @logger.error("Failed to load page: #{e.message}")
      raise "Failed to load page: #{e.message}"
    end
  end

# Method to analyze the HTML content and extract relevant information
  def identify_page_type_and_content(html_content, url)
    @logger.info("Starting to identify page type and extract content.")
# Parsing the HTML content using Nokogiri
    doc = Nokogiri::HTML(html_content)

    workshop_ids = Set.new
    mod_ids = Set.new
    map_folders = Set.new

    workshop_id = extract_workshop_id(url)

    if url.include?('/workshop/browse')
      return ["Page Type: unknown", "URL: #{url}"]
    end

    is_modpack = check_if_modpack(doc)

    if is_modpack
      modpack_result = process_modpack(doc, url)
      @logger.info("Modpack result: #{modpack_result.inspect}")
      return modpack_result
    end

    doc.xpath('//br').each do |br|
      text = extract_text_between_br(br)
      next if text.empty? || text.strip.empty?

      if text.match?(/Workshop\s*ID:?[\s\S]*?(\d+)/i)
        match = text.match(/Workshop\s*ID:?[\s\S]*?(\d+)/i)
        workshop_ids.add(match[1].strip) if match && !match[1].strip.empty?
      elsif text.match?(/Mod\s*ID:?[\s\S]*?([\w\d\s_-]+)/i)
        match = text.match(/Mod\s*ID:?[\s\S]*?([\w\d\s_-]+)/i)
        mod_ids.add(match[1].strip) if match && !match[1].strip.empty?
      elsif text.match?(/Map\s*Folder:?[\s\S]*?([\w\d\s_-]+)/i)
        match = text.match(/Map\s*Folder:?[\s\S]*?([\w\d\s_-]+)/i)
        map_folders.add(match[1].strip) if match && !match[1].strip.empty?
      end
    end

    page_type = map_folders.empty? ? "mod" : "map"
    @logger.info("Page type identified as: #{page_type}")

    if page_type == "mod" || page_type == "map"
      if @cycle_detection.include?(workshop_id)
        @logger.warn("Cycle detected for Workshop ID #{workshop_id}, skipping to prevent infinite loop.")
        return []
      end
      @cycle_detection.add(workshop_id)
    end

    result = ["Page Type: #{page_type}"]
    result << "Workshop ID: #{workshop_ids.to_a.sort.join(', ')}" unless workshop_ids.empty?
    result << "Mod ID: #{mod_ids.to_a.sort.join(', ')}" unless mod_ids.empty?
    result << "Map Folder: #{map_folders.to_a.sort.join(', ')}" unless map_folders.empty?
    result << "URL: #{url}"

    @logger.info("Completed processing mod with Workshop ID #{workshop_id}")

    dependencies_results = process_dependencies(doc, workshop_id)
    result.concat(dependencies_results)

    @processed_mods.add(workshop_id)

    result
  end

  def check_if_modpack(doc)
    !doc.at_css('.collectionChildren').nil?
  end

# Method to process mod packs if identified in the page
  def process_modpack(doc, url)
    mod_links = doc.css('.collectionChildren .collectionItem .workshopItem a[href*="filedetails/?id="]')
    workshop_ids = []
    detailed_results = []

    futures = mod_links.map do |link|
      Concurrent::Future.execute do
        mod_url = link['href']
        mod_url = "https://steamcommunity.com#{mod_url}" unless mod_url.start_with?("http")
        mod_workshop_id = extract_workshop_id(mod_url)

        @logger.info("Processing mod with Workshop ID #{mod_workshop_id}")

        workshop_ids << mod_workshop_id if mod_workshop_id

        begin
          mod_html_content = fetch_html_content(mod_url).force_encoding('UTF-8')
          if mod_html_content
            mod_result = identify_page_type_and_content(mod_html_content, mod_url)
            mod_result
          else
            @logger.warn("Failed to fetch content for mod URL: #{mod_url}")
            ["Failed to fetch content for mod URL: #{mod_url}"]
          end
        rescue StandardError => e
          @logger.error("Error processing mod URL #{mod_url}: #{e.message}")
          ["Error processing mod URL #{mod_url}: #{e.message}"]
        end
      end
    end

    futures.each do |future|
      mod_result = future.value
      if mod_result.is_a?(Array)
        detailed_results.concat(mod_result)
      else
        detailed_results << mod_result
      end
    end

    @logger.info("Completed processing all mods in the modpack with URL #{url}")

    result = ["Page Type: modpack", "Modpack Contents: #{workshop_ids.to_a.sort.join(', ')}", "URL: #{url}"]
    
    detailed_results.each do |mod_result|
      result.concat(mod_result) if mod_result.is_a?(Array)
      result << mod_result if mod_result.is_a?(String)
    end
    
    @logger.info("Returning result for modpack: #{result.inspect}")
    result
  end

# Method to process and handle dependencies found in the HTML document
  def process_dependencies(doc, parent_workshop_id)
    dependencies_results = []

    dependency_links = doc.css('.requiredItemsContainer a[href*="filedetails/?id="]')

    futures = dependency_links.map do |link|
      Concurrent::Future.execute do
        dep_url = link['href']
        dep_url = "https://steamcommunity.com#{dep_url}" unless dep_url.start_with?("http")
        dep_workshop_id = extract_workshop_id(dep_url)

        if dep_workshop_id == parent_workshop_id || @cycle_detection.include?(dep_workshop_id)
          @logger.warn("Cycle detected for Dependency Workshop ID #{dep_workshop_id}, skipping to prevent infinite loop.")
          next []
        end

        begin
          dep_html_content = fetch_html_content(dep_url).force_encoding('UTF-8')
          if dep_html_content
            dep_result = identify_page_type_and_content(dep_html_content, dep_url)
            dep_result
          else
            @logger.warn("Failed to fetch content for dependency URL: #{dep_url}")
            ["Failed to fetch content for dependency URL: #{dep_url}"]
          end
        rescue StandardError => e
          @logger.error("Error processing dependency URL #{dep_url}: #{e.message}")
          ["Error processing dependency URL #{dep_url}: #{e.message}"]
        end
      end
    end

    futures.each do |future|
      dep_result = future.value
      dependencies_results.concat(dep_result) unless dep_result.empty?
    end

    dependencies_results
  end

# Method to extract the Workshop ID from the URL
  def extract_workshop_id(url)
    url.match(/id=(\d+)/)[1] rescue nil
  end

  def fetch_html_content(url)
    uri = URI.parse(url)
    response = Net::HTTP.get_response(uri)
    response.body.force_encoding('UTF-8') if response.is_a?(Net::HTTPSuccess)
  end

# Helper method to extract text between <br> tags
  def extract_text_between_br(br)
    fragments = []
    sibling = br.next_sibling
    while sibling && !sibling.name.eql?("br")
      fragments << sibling.text.strip if sibling.text?
      fragments << sibling.inner_text.strip if sibling.element?
      sibling = sibling.next_sibling
    end
    fragments.join(" ").strip.gsub(/[\n\r]/, '').squeeze(' ')
  end
end

# Configuring the Sinatra server to listen on port 4567
set :port, 4567

# Route handling POST requests to the '/analyze' endpoint
post '/analyze' do
  url = params['url']
  identifier = SteamWorkshopIdentifier.new(logger)

  begin
    result = identifier.check_url(url)
    result
  rescue StandardError => e
    status 500
    e.message
  end
end