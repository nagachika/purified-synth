require "synthesizer/voice"

# Pool of persistent voices for the sequencer's schedule_note path.
#
# Rebuilding a Voice per note costs dozens of wasm->JS bridge calls plus the
# JS-side node allocations and later GC; the pool builds each voice once,
# starts its sources permanently and reuses it by retuning pitch params and
# retriggering envelopes. Allocation happens at schedule time for future
# timestamps, so an entry is free when its busy_until lies at or before the
# new note's start_time — overlapping notes can never share a voice.
#
# Idle pooled voices keep costing audio-thread CPU (browsers don't cull
# silent subgraphs), so the pool is kept small by three measures:
# - a note's hold time is cut to attack+decay for zero-sustain envelopes
#   (the voice is silent past that point regardless of nominal duration),
# - the post-release settle wait is one release constant (~5% residual;
#   ADSREnvelope#trigger fades any residual over 5ms, so reuse is click-free),
# - at the cap, the voice deepest into its release is stolen. Voices still
#   holding their note are never stolen; if every voice is holding, the
#   caller falls back to a dynamically created Voice.
class VoicePool
  MAX_VOICES = 16

  # Extra slack after the release constant before an entry counts as free
  # without stealing (residual ~5% at release*1, fading further during it).
  SETTLE_SLACK = 0.05

  def initialize(ctx, synth, max_voices: MAX_VOICES)
    @ctx = ctx
    @synth = synth
    @max_voices = max_voices
    @entries = [] # grown lazily up to @max_voices, then reused in place
    # Only envelope-gated patches idle silently; anything else would drone
    # once its sources run permanently, so those fall back to dynamic voices.
    @poolable = (synth.custom_patch[:nodes] || []).any? { |n| n[:type] == "ADSR" }
  end

  # Schedules a note on a pooled voice. Returns false when the patch is not
  # poolable or every voice is still holding a note (caller falls back to a
  # dynamic Voice).
  def schedule_note(freq, start_time, duration, velocity)
    return false unless @poolable

    entry = acquire(start_time)
    return false unless entry

    voice = entry[:voice]
    voice.retune(freq, start_time)
    voice.trigger_at(start_time, velocity)
    hold = voice.audible_hold(duration)
    voice.release_at(start_time + duration)
    entry[:hold_until] = start_time + hold
    entry[:busy_until] = start_time + hold + voice.max_release + SETTLE_SLACK
    entry
  end

  def size
    @entries.length
  end

  def dispose_all
    @entries.each { |e| e[:voice].dispose }
    @entries.clear
  end

  private

  def acquire(start_time)
    # Prefer a fully settled voice; otherwise remember the voice deepest
    # into its release (earliest hold_until) as the steal victim.
    victim = nil
    @entries.each do |e|
      return e if e[:busy_until] <= start_time
      if e[:hold_until] <= start_time && (victim.nil? || e[:hold_until] < victim[:hold_until])
        victim = e
      end
    end

    if @entries.length < @max_voices
      voice = Voice.new(@ctx, 440.0, @synth.custom_patch, @synth)
      voice.quiesce
      voice.start_sources(@ctx[:currentTime].to_f)
      entry = { voice: voice, hold_until: 0.0, busy_until: 0.0 }
      @entries << entry
      return entry
    end

    Synthesizer.count_pool_steal if victim
    victim
  end
end
