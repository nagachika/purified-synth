require 'dimension_colors'

# Shared rendering/query helpers for the harmonic lattice (格子) editors and the
# tetris-shape thumbnails. Mixed into ChordEditor, ChordSelectorModal and
# SequencerBlock. Notes may arrive with either string ("a".."e") or symbol
# (:a..:e) keys, so every accessor goes through note_field.
module LatticeView
  include DimensionColors

  # Read a lattice coordinate from a note hash regardless of key type.
  def note_field(note, key)
    v = note[key.to_s]
    v = note[key.to_sym] if v.nil?
    v || 0
  end

  # Pick the active Y-axis dimension from the notes present: an 11-limit (e)
  # coordinate wins, then 7-limit (d), else default to 5-limit (c=dim 3).
  def infer_dimension(notes)
    return 3 if notes.nil? || notes.empty?
    return 5 if notes.any? { |n| note_field(n, :e) != 0 }
    return 4 if notes.any? { |n| note_field(n, :d) != 0 }
    3
  end

  # Does a note sit at lattice cell (x, y) for the given Y-axis dimension?
  def match_note?(note, x, y, dim)
    return false unless note_field(note, :b) == x
    case dim
    when 3 then note_field(note, :c) == y
    when 4 then note_field(note, :d) == y
    when 5 then note_field(note, :e) == y
    else false
    end
  end

  # Draw a small "tetris" thumbnail of a chord onto a 2D canvas context.
  # `dimension` may be nil, in which case it is inferred from the notes.
  def draw_tetris_shape(ctx, notes, w, h, dimension)
    ctx[:fillStyle] = "#222"
    ctx.call(:fillRect, 0, 0, w, h)
    return if notes.nil? || notes.empty?

    dim_to_use = dimension || infer_dimension(notes)

    coords = notes.map do |n|
      yv = case dim_to_use
           when 4 then note_field(n, :d)
           when 5 then note_field(n, :e)
           else note_field(n, :c)
           end
      { x: note_field(n, :b), y: yv }
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
end
