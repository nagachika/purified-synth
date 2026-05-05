export const CELL_WIDTH = 10; // px

export const dimensionColors = {
  1: "#ffffff",
  2: "#ff7f50", // coral
  3: "#20b2aa", // lightseagreen
  4: "#9370db", // mediumpurple
  5: "#ffc247", // amber yellow
  6: "#ffd700", // gold
  7: "#cd5c5c"  // indianred
};

export function drawTetrisShape(ctx, notes, w, h, dimension) {
    ctx.fillStyle = "#222";
    ctx.fillRect(0, 0, w, h);
    if (!notes || notes.length === 0) return;

    // Determine dimension to use if not provided
    let dimToUse = dimension;
    if (!dimToUse) {
        dimToUse = 3; // Default
        const has5 = notes.some(n => n.e !== 0);
        const has4 = notes.some(n => n.d !== 0);
        if (has5) dimToUse = 5;
        else if (has4) dimToUse = 4;
    }

    const coords = notes.map(n => {
        let y = n.c;
        if (dimToUse === 4) y = n.d;
        if (dimToUse === 5) y = n.e;
        return { x: n.b, y: y };
    });

    let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity;
    coords.forEach(p => {
        if(p.x < minX) minX = p.x;
        if(p.x > maxX) maxX = p.x;
        if(p.y < minY) minY = p.y;
        if(p.y > maxY) maxY = p.y;
    });

    const rangeX = maxX - minX + 1;
    const rangeY = maxY - minY + 1;

    // Decrease max cell size and increase margin to ensure it fits
    const cellSize = Math.min(w / (rangeX + 1), h / (rangeY + 1), 8);

    const offsetX = (w - (rangeX * cellSize)) / 2 - (minX * cellSize);
    const offsetY = (h - (rangeY * cellSize)) / 2;

    coords.forEach(p => {
        const cx = offsetX + p.x * cellSize;
        const cy = offsetY + (maxY - p.y) * cellSize;

        // Color Logic: center=white, x-axis=2d, others=dimToUse
        if (p.x === 0 && p.y === 0) {
            ctx.fillStyle = "#ffffff";
        } else if (p.y === 0) {
            ctx.fillStyle = dimensionColors[2];
        } else {
            ctx.fillStyle = dimensionColors[dimToUse];
        }

        if (p.x === 0 && p.y === 0) {
            ctx.beginPath();
            ctx.arc(cx + cellSize/2, cy + cellSize/2, cellSize/2 - 1, 0, Math.PI * 2);
            ctx.fill();
            ctx.strokeStyle = "white";
            ctx.lineWidth = 1;
            ctx.stroke();
        } else {
            const r = 2;
            ctx.beginPath();
            // Ensure we don't draw outside bounds by using a small inset
            ctx.roundRect(cx + 0.5, cy + 1, cellSize - 1, cellSize - 2, r);
            ctx.fill();
        }
    });
}
