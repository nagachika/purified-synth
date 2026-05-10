// Lattice grid renderer + chord preview note helper.
// Used by sequencer_ui.js for the inline chord-selector modal.
// The standalone Chord view uses an equivalent Ruby implementation in chord_editor.rb.
import { dimensionColors } from "./utils.js";

export function playPreviewNote(App, noteObj) {
    try {
        const freqVal = App.call("$sequencer", "calculate_freq_from_coords", noteObj.a, noteObj.b, noteObj.c, noteObj.d, noteObj.e);
        const freq = parseFloat(freqVal.toString());
        const now = App.audioCtx.currentTime;
        App.call("$previewSynth", "schedule_note", freq, now, 0.3);
    } catch(e) { console.error(e); }
}

export function renderGenericLattice(container, notes, dim, selectedCell, onToggle, onOctaveChange) {
    container.innerHTML = "";

    let dragState = null;

    const onMouseMove = (e) => {
        if (!dragState) return;
        const delta = Math.round((dragState.startY - e.clientY) / 30);
        dragState.delta = delta;
        const displayA = dragState.hasNote ? dragState.baseA + delta : delta;
        if (displayA > 0) dragState.cell.textContent = `↑${displayA}`;
        else if (displayA < 0) dragState.cell.textContent = `↓${Math.abs(displayA)}`;
        else dragState.cell.textContent = dragState.hasNote ? "" : "";
    };

    const onMouseUp = () => {
        if (!dragState) return;
        const { x, y, delta } = dragState;
        dragState = null;
        window.removeEventListener("mousemove", onMouseMove);
        window.removeEventListener("mouseup", onMouseUp);
        if (delta !== 0 && onOctaveChange) {
            onOctaveChange(x, y, delta);
        } else {
            onToggle(x, y);
        }
    };

    for (let y = 2; y >= -2; y--) {
      for (let x = -4; x <= 4; x++) {
        const cell = document.createElement("div");
        cell.style.background = "#222";
        cell.style.color = "#fff";
        cell.style.display = "flex";
        cell.style.alignItems = "center";
        cell.style.justifyContent = "center";
        cell.style.aspectRatio = "1 / 1";
        cell.style.cursor = "pointer";
        cell.style.fontSize = "0.8rem";
        cell.style.border = "1px solid #333";
        cell.style.userSelect = "none";

        if (selectedCell && selectedCell.x === x && selectedCell.y === y) {
          cell.style.borderColor = "#fff";
          cell.style.boxShadow = "inset 0 0 0 2px #fff";
          cell.style.zIndex = "10";
        }

        const note = notes.find(n => {
            let match = (n.b === x);
            if (dim === 3) match = match && (n.c === y);
            if (dim === 4) match = match && (n.d === y);
            if (dim === 5) match = match && (n.e === y);
            return match;
        });

        if (note) {
          if (x === 0 && y === 0) {
            cell.style.background = "#fff";
            cell.style.color = "#000";
          } else if (y === 0) {
            cell.style.background = dimensionColors[2];
          } else {
            cell.style.background = dimensionColors[dim];
          }

          if (note.a > 0) cell.textContent = `↑${note.a}`;
          else if (note.a < 0) cell.textContent = `↓${Math.abs(note.a)}`;
        }

        const cellX = x, cellY = y;
        cell.addEventListener("mousedown", (e) => {
            e.preventDefault();
            const cellNote = notes.find(n => {
                let match = (n.b === cellX);
                if (dim === 3) match = match && (n.c === cellY);
                if (dim === 4) match = match && (n.d === cellY);
                if (dim === 5) match = match && (n.e === cellY);
                return match;
            });
            dragState = {
                cell, x: cellX, y: cellY,
                startY: e.clientY,
                baseA: cellNote ? cellNote.a : 0,
                hasNote: !!cellNote,
                delta: 0
            };
            window.addEventListener("mousemove", onMouseMove);
            window.addEventListener("mouseup", onMouseUp);
        });

        container.appendChild(cell);
      }
    }
}
