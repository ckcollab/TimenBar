#!/usr/bin/env ruby
# frozen_string_literal: true

require "rexml/document"
require "time"

appcast_path, version, build, tag, enclosure_url, signature_fragment, pub_date = ARGV
abort "usage: update-appcast.rb APPCAST VERSION BUILD TAG URL SIGNATURE_FRAGMENT PUB_DATE" unless pub_date

document = REXML::Document.new(File.read(appcast_path))
channel = document.elements["/rss/channel"]
abort "appcast is missing rss/channel" unless channel

signature_match = signature_fragment.match(/sparkle:edSignature="([^"]+)".*length="(\d+)"/m)
abort "could not parse sign_update output: #{signature_fragment}" unless signature_match

channel.elements.each("item") do |item|
  item.parent.delete(item) if item.elements["sparkle:version"]&.text == build
end

item = REXML::Element.new("item")
title = REXML::Element.new("title")
title.text = "TimenBar #{version}"
item.add_element(title)

link = REXML::Element.new("link")
link.text = "https://github.com/ckcollab/TimenBar/releases/tag/#{tag}"
item.add_element(link)

sparkle_version = REXML::Element.new("sparkle:version")
sparkle_version.text = build
item.add_element(sparkle_version)

short_version = REXML::Element.new("sparkle:shortVersionString")
short_version.text = version
item.add_element(short_version)

minimum_system = REXML::Element.new("sparkle:minimumSystemVersion")
minimum_system.text = "14.0.0"
item.add_element(minimum_system)

published = REXML::Element.new("pubDate")
published.text = Time.parse(pub_date).httpdate
item.add_element(published)

enclosure = REXML::Element.new("enclosure")
enclosure.add_attribute("url", enclosure_url)
enclosure.add_attribute("sparkle:edSignature", signature_match[1])
enclosure.add_attribute("length", signature_match[2])
enclosure.add_attribute("type", "application/octet-stream")
item.add_element(enclosure)

first_item = channel.elements["item"]
if first_item
  channel.insert_before(first_item, item)
else
  channel.add_element(item)
end

formatter = REXML::Formatters::Pretty.new(2)
formatter.compact = true
File.open(appcast_path, "w") { |file| formatter.write(document, file) }
File.write(appcast_path, File.read(appcast_path) + "\n")
