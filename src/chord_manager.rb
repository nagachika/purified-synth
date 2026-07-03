require 'js'
require 'json'

class ChordManager
  STORAGE_KEY = "ruby_synth_chords"

  # Ruby-side accessor (string-keyed Hash). get_chords below returns JSON for
  # the JS bridge; Ruby callers should use this to skip the serialize round trip.
  # Treat as read-only — mutate via update_chord / delete_chord / set_chords.
  attr_reader :chords

  def initialize
    load
  end

  def load
    raw = JS.global[:localStorage].call(:getItem, STORAGE_KEY).to_s
    @chords = (raw.empty? || raw == "null") ? {} : JSON.parse(raw)
  rescue => e
    puts "[ChordManager] load error: #{e.message}"
    @chords = {}
  end

  def get_chords
    @chords.to_json
  end

  def update_chord(name, data)
    @chords[name] = data
    save
  end

  def delete_chord(name)
    @chords.delete(name)
    save
  end

  def set_chords(new_chords)
    @chords = new_chords || {}
    save
  end

  private

  def save
    JS.global[:localStorage].call(:setItem, STORAGE_KEY, @chords.to_json)
  end
end
