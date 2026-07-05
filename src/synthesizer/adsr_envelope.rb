class ADSREnvelope
  attr_accessor :attack, :decay, :sustain, :release

  def initialize(attack: 0.1, decay: 0.1, sustain: 0.5, release: 0.1)
    @attack = attack
    @decay = decay
    @sustain = sustain
    @release = release
    @target_param = nil
  end

  def connect(param)
    @target_param = param
  end

  # Force the gated param to 0 immediately (idle state for pooled voices,
  # whose sources keep running while the voice is silent).
  def quiesce
    @target_param&.value = 0.0
  end

  # Pooled voices may be retriggered (or stolen) while their previous release
  # tail is still sounding; fading that residual to the floor over a few ms
  # instead of jumping keeps the transition click-free at any residual level.
  RETRIGGER_FADE = 0.005

  def trigger(time, velocity = 1.0)
    return unless @target_param

    t = time.to_f
    # Web Audio ramp quirks: target value for exponential ramp cannot be 0
    min_val = 0.001
    peak_val = [velocity.to_f, min_val].max

    @target_param.cancel_and_hold_at_time(t)
    @target_param.linear_ramp_to_value_at_time(min_val, t + RETRIGGER_FADE)

    # Attack
    @target_param.linear_ramp_to_value_at_time(peak_val, t + RETRIGGER_FADE + @attack)

    # Decay
    sus_val = (@sustain * peak_val <= min_val) ? min_val : (@sustain * peak_val)
    @target_param.exponential_ramp_to_value_at_time(sus_val, t + RETRIGGER_FADE + @attack + @decay)
  end

  def release_at(time)
    return unless @target_param

    t = time.to_f

    # Use setTargetAtTime for smooth release from any current value
    # This avoids "clicks" if the note is released before Attack/Decay phase finishes.
    # Target = 0, Start = t, TimeConstant = release / 3
    # Value reaches ~5% (e^-3) after 1.0 * release time.

    @target_param.cancel_and_hold_at_time(t)

    # Ensure release is not zero to avoid division by zero or instant change artifacts
    safe_release = @release.to_f
    safe_release = 0.01 if safe_release < 0.01

    time_constant = safe_release / 3.0
    @target_param.set_target_at_time(0.0, t, time_constant)
  end
end
