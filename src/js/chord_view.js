import { drawTetrisShape, dimensionColors } from "./utils.js";
import { getChords, saveChords, updateChord, deleteChord } from "./chord_manager.js";
import { getPresets } from "./presets.js";

let currentChordName = "";
let currentChordNotes = [];
let chordSelectedCell = {x: 0, y: 0};

export function setupChordView(App) {
  const nameInput = document.getElementById("chord-name-input");
  const saveBtn = document.getElementById("save-chord-btn");
  const createBtn = document.getElementById("create-chord-btn");
  const listContainer = document.getElementById("chord-list");
  const editorGrid = document.getElementById("chord-editor-grid");
  const yAxisSel = document.getElementById("chord-y-axis");
  const previewSel = document.getElementById("chord-preview-preset");
  const previewBtn = document.getElementById("preview-chord-btn");

  // Prevent editor keybinds when typing name
  nameInput.addEventListener("keydown", (e) => {
    e.stopPropagation();
  });

  // Preview Button Logic
  previewBtn.onclick = () => {
    if (currentChordNotes.length === 0) return;
    const now = App.audioCtx.currentTime;
    // Play all notes in chord simultaneously
    currentChordNotes.forEach(note => {
        try {
          const freqVal = App.call("$sequencer", "calculate_freq_from_coords", note.a, note.b, note.c, note.d, note.e);
          const freq = parseFloat(freqVal.toString());
          App.call("$previewSynth", "schedule_note", freq, now, 0.5);
        } catch(e) { console.error(e); }
    });
  };

  // Populate Preview Presets (sync with main presets)
  function updatePreviewPresets() {
    const presets = getPresets();
    previewSel.innerHTML = '<option value="">-- Preview Sound --</option>';
    Object.keys(presets).forEach(name => {
      const opt = document.createElement("option");
      opt.value = name;
      opt.textContent = name;
      previewSel.appendChild(opt);
    });
  }
  window.addEventListener("presetsUpdated", updatePreviewPresets);
  updatePreviewPresets();

  // Refresh chord list on external update
  window.addEventListener("chordsUpdated", () => renderChordList(App));

  previewSel.onchange = (e) => {
    const name = e.target.value;
    if (name) {
       const presets = getPresets();
       if (presets[name]) {
         const json = presets[name];
         const data = JSON.parse(json);
         if (data.nodes) {
            App.call("$previewSynth", "import_patch", json);
         } else {
            console.warn("Legacy preset format is no longer supported in preview.");
         }
       }
    }
  };

  createBtn.onclick = () => {
    currentChordName = "";
    currentChordNotes = [];
    chordSelectedCell = {x: 0, y: 0};
    nameInput.value = "";
    syncToRuby();
    renderChordEditor(App);
  };

  saveBtn.onclick = () => {
    const name = nameInput.value.trim();
    if (!name) return alert("Please enter a chord name.");
    if (currentChordNotes.length === 0) return alert("Chord is empty.");

    updateChord(name, {
        notes: JSON.parse(JSON.stringify(currentChordNotes)),
        dimension: parseInt(yAxisSel.value)
    });
    renderChordList(App);
    alert(`Chord "${name}" saved!`);
  };

  yAxisSel.onchange = () => {
      const newDim = parseInt(yAxisSel.value);

      // Transcribe notes to the new dimension
      currentChordNotes.forEach(note => {
          // Find existing Y value from any dimension (c, d, or e)
          // Since the editor operates on a 2D slice, a note should typically strictly belong to one Y-dimension or be 0.
          let yVal = 0;
          if (note.c !== 0) { yVal = note.c; note.c = 0; }
          else if (note.d !== 0) { yVal = note.d; note.d = 0; }
          else if (note.e !== 0) { yVal = note.e; note.e = 0; }

          // Apply to new dimension
          if (newDim === 3) note.c = yVal;
          else if (newDim === 4) note.d = yVal;
          else if (newDim === 5) note.e = yVal;
      });

      syncToRuby();
      renderChordEditor(App);
  };

  function renderChordList(App) {
    listContainer.innerHTML = "";
    const chords = getChords();
    Object.keys(chords).forEach(name => {
      const entry = chords[name];
      const isLegacy = Array.isArray(entry);
      const notes = isLegacy ? entry : entry.notes;
      const dim = isLegacy ? null : entry.dimension;

      const item = document.createElement("div");
      item.style.background = "#444";
      item.style.padding = "5px";
      item.style.borderRadius = "4px";
      item.style.cursor = "pointer";
      item.style.display = "flex";
      item.style.alignItems = "center";
      item.style.gap = "10px";

      // Thumbnail
      const canvas = document.createElement("canvas");
      canvas.width = 40;
      canvas.height = 40;
      drawTetrisShape(canvas.getContext("2d"), notes, 40, 40, dim);

      const label = document.createElement("span");
      label.textContent = name;
      label.style.flexGrow = "1";

      const delBtn = document.createElement("span");
      delBtn.className = "material-icons";
      delBtn.textContent = "delete";
      delBtn.style.fontSize = "1rem";
      delBtn.style.color = "#aaa";
      delBtn.onclick = (e) => {
        e.stopPropagation();
        if(confirm(`Delete chord "${name}"?`)){
          deleteChord(name);
          renderChordList(App);
        }
      };

      item.onclick = () => {
        currentChordName = name;
        // Deep copy notes
        currentChordNotes = JSON.parse(JSON.stringify(notes));
        chordSelectedCell = {x: 0, y: 0};

        // Restore dimension
        if (dim) {
            yAxisSel.value = dim;
        } else {
            // Infer
            let inferred = 3;
            if (notes.some(n => n.e !== 0)) inferred = 5;
            else if (notes.some(n => n.d !== 0)) inferred = 4;
            yAxisSel.value = inferred;
        }

        nameInput.value = name;
        syncToRuby();
        renderChordEditor(App);
      };

      item.appendChild(canvas);
      item.appendChild(label);
      item.appendChild(delBtn);
      listContainer.appendChild(item);
    });
  }

  function toggleNote(x, y) {
    const dim = parseInt(yAxisSel.value);
    const idx = currentChordNotes.findIndex(n => {
        let match = (n.b === x);
        if (dim === 3) match = match && (n.c === y);
        else if (dim === 4) match = match && (n.d === y);
        else if (dim === 5) match = match && (n.e === y);
        return match;
    });

    if (idx >= 0) {
        currentChordNotes.splice(idx, 1);
    } else {
        const newNote = { a: 0, b: x, c: 0, d: 0, e: 0 };
        if (dim === 3) newNote.c = y;
        else if (dim === 4) newNote.d = y;
        else if (dim === 5) newNote.e = y;
        currentChordNotes.push(newNote);

        // Audition
        playPreviewNote(App, newNote);
    }

    syncToRuby();
    chordSelectedCell = {x, y};
    renderChordEditor(App);
  }

  function renderChordEditor(App) {
    const dim = parseInt(yAxisSel.value);

    // Generic Lattice Renderer
    renderGenericLattice(editorGrid, currentChordNotes, dim, chordSelectedCell, (x, y) => {
        toggleNote(x, y);
    }, (x, y, delta) => {
        const note = currentChordNotes.find(n => {
            let match = (n.b === x);
            if (dim === 3) match = match && (n.c === y);
            else if (dim === 4) match = match && (n.d === y);
            else if (dim === 5) match = match && (n.e === y);
            return match;
        });
        if (note) {
            note.a += delta;
            playPreviewNote(App, note);
        } else {
            const newNote = { a: delta, b: x, c: 0, d: 0, e: 0 };
            if (dim === 3) newNote.c = y;
            else if (dim === 4) newNote.d = y;
            else if (dim === 5) newNote.e = y;
            currentChordNotes.push(newNote);
            playPreviewNote(App, newNote);
        }
        syncToRuby();
        chordSelectedCell = { x, y };
        renderChordEditor(App);
    });
  }

  // Handle Keyboard for editor
  window.addEventListener("keydown", (e) => {
      const viewChord = document.getElementById("view-chord");
      if (!viewChord || !viewChord.classList.contains("active")) return;
      if (!chordSelectedCell) return;

      if (e.key === " ") {
          toggleNote(chordSelectedCell.x, chordSelectedCell.y);
          e.preventDefault();
          return;
      }

      // Shift Octave logic for selected cell
      if (e.key === "+" || e.key === "=" || e.key === "-") {
          const delta = (e.key === "+" || e.key === "=") ? 1 : -1;
          const dim = parseInt(yAxisSel.value);
          const note = currentChordNotes.find(n => {
              let match = (n.b === chordSelectedCell.x);
              if (dim === 3) match = match && (n.c === chordSelectedCell.y);
              else if (dim === 4) match = match && (n.d === chordSelectedCell.y);
              else if (dim === 5) match = match && (n.e === chordSelectedCell.y);
              return match;
          });

          if (note) {
              note.a += delta;
              playPreviewNote(App, note);
              renderChordEditor(App);
          }
      }

      // Move Selection
      let dx = 0, dy = 0;
      if(e.key === "ArrowUp") dy = 1;
      if(e.key === "ArrowDown") dy = -1;
      if(e.key === "ArrowLeft") dx = -1;
      if(e.key === "ArrowRight") dx = 1;

      if (dx !== 0 || dy !== 0) {
          if (!chordSelectedCell) chordSelectedCell = {x: 0, y: 0};
          chordSelectedCell.x += dx;
          chordSelectedCell.y += dy;
          // Bounds
          if(chordSelectedCell.x < -3) chordSelectedCell.x = -3;
          if(chordSelectedCell.x > 3) chordSelectedCell.x = 3;
          if(chordSelectedCell.y < -2) chordSelectedCell.y = -2;
          if(chordSelectedCell.y > 2) chordSelectedCell.y = 2;

          renderChordEditor(App);
          e.preventDefault();
      }
  });

  renderChordList(App);
  renderChordEditor(App);

  function syncToRuby() {
    try {
      App.call("$midiProcessor", "set_chord_notes", JSON.stringify(currentChordNotes));
      App.call("$midiProcessor", "set_chord_dimension", parseInt(yAxisSel.value));
    } catch (_) {}
  }

  return {
    reRenderChord() {
      const json = App.call("$midiProcessor", "get_chord_notes_json").toString();
      currentChordNotes = JSON.parse(json);
      renderChordEditor(App);
    },
    setChordDimension(dim) {
      yAxisSel.value = dim;
    }
  };
}

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

    // Drag state shared across cells
    let dragState = null; // { cell, x, y, startY, baseA, hasNote, delta }

    const onMouseMove = (e) => {
        if (!dragState) return;
        const delta = Math.round((dragState.startY - e.clientY) / 30);
        dragState.delta = delta;
        const displayA = dragState.hasNote ? dragState.baseA + delta : delta;
        if (displayA > 0) dragState.cell.textContent = `↑${displayA}`;
        else if (displayA < 0) dragState.cell.textContent = `↓${Math.abs(displayA)}`;
        else dragState.cell.textContent = dragState.hasNote ? "" : "";
    };

    const onMouseUp = (e) => {
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

    // Grid: X: -3 to 3 (7 cols), Y: 2 to -2 (5 rows)
    for (let y = 2; y >= -2; y--) {
      for (let x = -3; x <= 3; x++) {
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

        // Selection
        if (selectedCell && selectedCell.x === x && selectedCell.y === y) {
          cell.style.borderColor = "#fff";
          cell.style.boxShadow = "inset 0 0 0 2px #fff";
          cell.style.zIndex = "10";
        }

        // Find Note
        const note = notes.find(n => {
            let match = (n.b === x);
            if (dim === 3) match = match && (n.c === y);
            if (dim === 4) match = match && (n.d === y);
            if (dim === 5) match = match && (n.e === y);
            return match;
        });

        if (note) {
          // Color Logic: center=white, x-axis=2d, others=current dim
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

        // Drag for octave change, click for toggle
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
