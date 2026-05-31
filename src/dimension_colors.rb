# Shared color palette for the lattice (格子) editor and tetris-shape previews.
# Indices 1..5 map to the dimension axis used by chord notes;
# the center note (x=0, y=0) is always white, the X axis (y=0) uses DIMENSION_COLORS[2],
# and off-axis notes use DIMENSION_COLORS[dim] for the active dim (3, 4, or 5).
module DimensionColors
  DIMENSION_COLORS = {
    1 => "#ffffff",
    2 => "#F27A91",
    3 => "#6EDA87",
    4 => "#B399EE",
    5 => "#FFC149",
    6 => "#ffd700",
    7 => "#cd5c5c"
  }
end
