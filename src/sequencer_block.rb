require 'js'
require 'json'
require 'web_component'

# Single timeline block on the sequencer view. The host element itself is the
# block div; sequencer_ui.js absolute-positions it within the track grid based
# on attributes and calls refresh() when length/type/notes change.
class SequencerBlock
  include WebComponent

  CELL_WIDTH = 10

  DIMENSION_COLORS = {
    1 => "#ffffff", 2 => "#ff7f50", 3 => "#20b2aa",
    4 => "#9370db", 5 => "#ffc247", 6 => "#ffd700", 7 => "#cd5c5c"
  }

  def connected_callback(element)
    @element = element
    @doc = JS.global[:document]

    @track_idx = element.call(:getAttribute, "track-index").to_i
    @start_step = element.call(:getAttribute, "start-step").to_i
    @length = element.call(:getAttribute, "length").to_i
    @track_type = element.call(:getAttribute, "track-type").to_s

    @element[:className] = "block"
    style_host
    render_content
    bind_events
  end

  # Called from sequencer_ui.js when block content/length/type changes.
  def refresh(length, track_type)
    @length = length.to_i
    @track_type = track_type.to_s
    @element[:style][:left] = "#{@start_step * CELL_WIDTH}px"
    @element[:style][:width] = "#{@length * CELL_WIDTH}px"
    @element[:innerHTML] = ""
    render_content
  end

  private

  def style_host
    s = @element[:style]
    s[:position] = "absolute"
    s[:left] = "#{@start_step * CELL_WIDTH}px"
    s[:width] = "#{@length * CELL_WIDTH}px"
    s[:height] = "100%"
    s[:border] = "1px solid #fff"
    s[:borderRadius] = "4px"
    s[:cursor] = "pointer"
    s[:zIndex] = "5"
    s[:display] = "flex"
    s[:alignItems] = "center"
    s[:justifyContent] = "center"
    s[:overflow] = "hidden"
  end

  def render_content
    if @track_type == "rhythmic"
      render_rhythmic
    else
      render_melodic
    end
  rescue => e
    puts "[SequencerBlock] render error: #{e.message}"
  end

  def render_rhythmic
    @element[:style][:background] = "#ff8787"
    pid = $sequencer.get_block_pattern_id(@track_idx, @start_step).to_s
    pname = $sequencer.get_pattern_name(pid).to_s
    @element[:textContent] = pname
    s = @element[:style]
    s[:color] = "black"
    s[:fontSize] = "0.8rem"
    s[:fontWeight] = "bold"
  end

  def render_melodic
    notes = JSON.parse($sequencer.get_block_notes_json(@track_idx, @start_step).to_s)
    @element[:style][:background] = notes.length > 0 ? "#4dabf7" : "#555"
    @element[:title] = "Start: #{@start_step}"

    canvas = @doc.call(:createElement, "canvas")
    cw = @length * CELL_WIDTH - 4
    ch = 70
    canvas[:width] = cw > 0 ? cw : 1
    canvas[:height] = ch
    canvas[:style][:display] = "block"
    draw_tetris_shape(canvas.call(:getContext, "2d"), notes, cw, ch, nil)
    @element.call(:appendChild, canvas)
  end

  def bind_events
    @element.call(:addEventListener, "click", proc { |e|
      e.call(:stopPropagation)
      on_click
    })
    @element.call(:addEventListener, "contextmenu", proc { |e|
      e.call(:preventDefault)
      on_context_menu
    })
  end

  def on_click
    if @track_type == "rhythmic"
      pid = $sequencer.get_block_pattern_id(@track_idx, @start_step).to_s
      $pattern_selector_modal&.open(@track_idx, @start_step, pid)
    else
      $chord_selector_modal&.open(@track_idx, @start_step)
    end
  end

  def on_context_menu
    confirmed = JS.global.call(:confirm, "Delete block?").to_s == "true"
    return unless confirmed
    $sequencer.remove_block(@track_idx, @start_step)
    JS.eval("setTimeout(() => window.dispatchEvent(new Event('seqBlockUpdated')), 0)")
  end

  def draw_tetris_shape(ctx, notes, w, h, dimension)
    ctx[:fillStyle] = "#222"
    ctx.call(:fillRect, 0, 0, w, h)
    return if notes.nil? || notes.empty?

    dim_to_use = dimension
    if dim_to_use.nil?
      dim_to_use = 3
      has5 = notes.any? { |n| (n["e"] || n[:e] || 0) != 0 }
      has4 = notes.any? { |n| (n["d"] || n[:d] || 0) != 0 }
      dim_to_use = 5 if has5
      dim_to_use = 4 if !has5 && has4
    end

    coords = notes.map do |n|
      yv = case dim_to_use
           when 4 then n["d"] || n[:d] || 0
           when 5 then n["e"] || n[:e] || 0
           else n["c"] || n[:c] || 0
           end
      { x: n["b"] || n[:b] || 0, y: yv }
    end

    min_x = coords.map { |p| p[:x] }.min
    max_x = coords.map { |p| p[:x] }.max
    min_y = coords.map { |p| p[:y] }.min
    max_y = coords.map { |p| p[:y] }.max

    range_x = max_x - min_x + 1
    range_y = max_y - min_y + 1
    cell_size = [w / (range_x + 1.0), h / (range_y + 1.0), 8].min
    offset_x = (w - range_x * cell_size) / 2.0 - min_x * cell_size
    offset_y = (h - range_y * cell_size) / 2.0

    coords.each do |p|
      cx = offset_x + p[:x] * cell_size
      cy = offset_y + (max_y - p[:y]) * cell_size

      if p[:x] == 0 && p[:y] == 0
        ctx[:fillStyle] = "#ffffff"
      elsif p[:y] == 0
        ctx[:fillStyle] = DIMENSION_COLORS[2]
      else
        ctx[:fillStyle] = DIMENSION_COLORS[dim_to_use]
      end

      if p[:x] == 0 && p[:y] == 0
        ctx.call(:beginPath)
        ctx.call(:arc, cx + cell_size / 2.0, cy + cell_size / 2.0, cell_size / 2.0 - 1, 0, Math::PI * 2)
        ctx.call(:fill)
        ctx[:strokeStyle] = "white"
        ctx[:lineWidth] = 1
        ctx.call(:stroke)
      else
        ctx.call(:beginPath)
        ctx.call(:roundRect, cx + 0.5, cy + 1, cell_size - 1, cell_size - 2, 2)
        ctx.call(:fill)
      end
    end
  end

  SequencerBlock.register("sequencer-block")
end
