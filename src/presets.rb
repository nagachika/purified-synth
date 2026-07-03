require 'js'
require 'json'

class Presets
  STORAGE_KEY = "ruby_synth_presets"

  # Ruby-side accessor (name => patch-JSON-string Hash). get_presets below
  # returns JSON for the JS bridge; Ruby callers should use this to skip the
  # serialize round trip. Treat as read-only — mutate via update_preset etc.
  attr_reader :presets

  def initialize
    load
  end

  def load
    raw = JS.global[:localStorage].call(:getItem, STORAGE_KEY).to_s
    @presets = (raw.empty? || raw == "null") ? {} : JSON.parse(raw)
  rescue => e
    puts "[Presets] load error: #{e.message}"
    @presets = {}
  end

  def get_presets
    @presets.to_json
  end

  def update_preset(name, json_str)
    @presets[name] = json_str
    save
  end

  def delete_preset(name)
    @presets.delete(name)
    save
  end

  def set_presets(new_presets)
    @presets = new_presets || {}
    save
  end

  private

  def save
    JS.global[:localStorage].call(:setItem, STORAGE_KEY, @presets.to_json)
  end
end
