import { CELL_WIDTH, drawTetrisShape } from "./utils.js";
import { getChords } from "./chord_manager.js";
import { getPresets } from "./presets.js";

// Queue for future playhead updates from Ruby
const playheadQueue = [];
let lastProcessedStep = -1;

export function setupSequencer(App, opts = {}) {
  const chordSelectorRef = opts.chordSelectorRef;
  const patternSelectorRef = opts.patternSelectorRef;
  const openChordSelector = (t, s) => {
    if (chordSelectorRef) App.call(chordSelectorRef, "open", t, s);
  };
  const openPatternSelector = (t, s, currentPatternId) => {
    if (patternSelectorRef) App.call(patternSelectorRef, "open", t, s, currentPatternId || "");
  };
  const rowsContainer = document.getElementById("sequencer-rows");
  const playBtn = document.getElementById("seq-play-btn");
  const addTrackBtn = document.getElementById("add_track_btn");
  const addRhythmTrackBtn = document.getElementById("add_rhythm_track_btn");
  const bpmInput = document.getElementById("bpm");
  const bpmDisplay = document.getElementById("val_bpm");
  const measuresInput = document.getElementById("measures");
  const measuresDisplay = document.getElementById("val_measures");
  const rootFreqInput = document.getElementById("root_freq");
  const swingInput = document.getElementById("swing_amount");

  let isDrawing = false;
  let drawStartStep = 0;
  let drawTrackIndex = -1;
  let ghostBlock = null;

  // Cache for DOM elements to avoid full re-renders
  const trackRowsCache = new Map(); // index -> { row, controlDiv, grid, playhead, ... }
  const blockElementsCache = new Map(); // "trackIdx-startStep" -> { element, dataHash }

  // Refresh after the chord selector modal applies new notes to a block.
  window.addEventListener("seqBlockUpdated", () => {
    blockElementsCache.clear();
    renderSequencer();
  });

  window.addEventListener("presetsUpdated", () => {
    const presets = getPresets();
    trackRowsCache.forEach((cached) => {
      if (cached.trackType === "melodic") {
        const currentValue = cached.presetSel.value;
        cached.presetSel.innerHTML = '<option value="">(Default)</option>';
        Object.keys(presets).forEach(name => {
          const opt = document.createElement("option");
          opt.value = name;
          opt.textContent = name;
          cached.presetSel.appendChild(opt);
        });
        cached.presetSel.value = currentValue;
      }
    });
  });

  // Expose queue function to App
  App.queuePlayheadUpdates = (json) => {
    try {
      const updates = JSON.parse(json);
      updates.forEach(upd => {
        if (upd.sequencer === "$sequencer") {
           window._currentSequencerStep = upd.step;
           window._lastSequencerTime = upd.time;
        } else if (upd.sequencer === "$patternSequencer") {
           window._currentPreviewStep = upd.step;
           window._lastPreviewTime = upd.time;
        }
      });
    } catch(e) { console.error("Error parsing playhead updates:", e); }
  };

  function updatePlayheadVisuals(stepIndex) {
    const x = stepIndex * CELL_WIDTH;
    trackRowsCache.forEach(cached => {
      if (cached.playhead) {
        cached.playhead.style.transform = `translateX(${x}px)`;
      }
    });

    const scrollContainer = document.getElementById("master-scroll-container");
    if (scrollContainer) {
        const left = x;
        const width = scrollContainer.clientWidth;
        if (left < scrollContainer.scrollLeft || left > scrollContainer.scrollLeft + width) {
            scrollContainer.scrollLeft = left - width / 2;
        }
    }
  }

  let _lastIsPlayingUI = null;
  function updatePlayBtnUI() {
    if (!playBtn) return;
    try {
      const isPlayingVal = App.call("$sequencer", "is_playing");
      const isPlaying = isPlayingVal && isPlayingVal.toString() === "true";
      if (isPlaying === _lastIsPlayingUI) return;
      _lastIsPlayingUI = isPlaying;
      if (isPlaying) {
        playBtn.innerHTML = '<span class="material-icons">stop</span> Stop';
        playBtn.style.background = "#dc3545";
      } else {
        playBtn.innerHTML = '<span class="material-icons">play_arrow</span> Play';
        playBtn.style.background = "#007bff";
      }
    } catch (e) {}
  }

  function animate() {
    requestAnimationFrame(animate);
    if (!App.audioCtx || App.audioCtx.state === 'suspended') return;

    updatePlayBtnUI();

    const now = App.audioCtx.currentTime;

    // Process main sequencer visual update
    if (window._currentSequencerStep !== undefined && window._currentSequencerStep !== lastProcessedStep) {
        // We check time to be more precise if needed, but for now step is enough
        updatePlayheadVisuals(window._currentSequencerStep);
        lastProcessedStep = window._currentSequencerStep;
    }
  }
  requestAnimationFrame(animate);

  function renderSequencer() {
    let tracksCount = 0;
    let currentTrackIndex = 0;
    let totalSteps = 128;

    try {
        const tracksCountVal = App.call("$sequencer", "get_tracks_count");
        if (!tracksCountVal) return; // Wait for initialization
        tracksCount = parseInt(tracksCountVal.toString());
        currentTrackIndex = parseInt(App.call("$sequencer", "current_track_index").toString());
        totalSteps = parseInt(App.call("$sequencer", "total_steps").toString());
    } catch(e) {
        console.error("Error in renderSequencer initialization:", e);
        return;
    }

    // Sync global controls with Ruby state (e.g. after project load)
    try {
        const bars = Math.max(1, Math.floor(totalSteps / 32));
        if (measuresInput && parseInt(measuresInput.value) !== bars) {
            measuresInput.value = bars;
            if (measuresDisplay) measuresDisplay.textContent = bars;
        }
        const bpmVal = parseInt(App.call("$sequencer", "bpm").toString());
        if (bpmInput && parseInt(bpmInput.value) !== bpmVal) {
            bpmInput.value = bpmVal;
            if (bpmDisplay) bpmDisplay.textContent = bpmVal;
        }
        const swingVal = parseFloat(App.call("$sequencer", "swing_amount").toString());
        if (swingInput && parseFloat(swingInput.value) !== swingVal) {
            swingInput.value = swingVal;
            const sd = document.getElementById("val_swing");
            if (sd) sd.textContent = Math.round(swingVal * 100);
        }
        const rootVal = parseFloat(App.call("$sequencer", "root_freq").toString());
        if (rootFreqInput && parseFloat(rootFreqInput.value) !== rootVal) {
            rootFreqInput.value = rootVal;
        }
    } catch(e) { /* ignore sync errors */ }

    // Ensure master scroll container exists
    let scrollContainer = document.getElementById("master-scroll-container");
    if (!scrollContainer) {
        scrollContainer = document.createElement("div");
        scrollContainer.id = "master-scroll-container";
        scrollContainer.style.overflowX = "scroll";
        scrollContainer.style.overflowY = "hidden";
        scrollContainer.style.marginTop = "10px";
        scrollContainer.style.marginBottom = "10px";
        scrollContainer.style.border = "1px solid #444";
        scrollContainer.style.background = "#222";
        scrollContainer.style.height = "15px";

        scrollContainer.onscroll = (e) => {
            const left = e.target.scrollLeft;
            document.querySelectorAll(".timeline-wrapper").forEach(wrapper => wrapper.scrollLeft = left);
            window._lastScrollLeft = left;
        };
    }

    // Update scroll spacer width
    let scrollSpacer = scrollContainer.querySelector(".scroll-spacer");
    if (!scrollSpacer) {
        scrollSpacer = document.createElement("div");
        scrollSpacer.className = "scroll-spacer";
        scrollSpacer.style.height = "1px";
        scrollContainer.appendChild(scrollSpacer);
    }
    scrollSpacer.style.width = `${totalSteps * CELL_WIDTH}px`;

    // --- Start position marker row ---
    let markerRow = document.getElementById("seq-start-marker-row");
    let markerGrid, marker;
    if (!markerRow) {
        markerRow = document.createElement("div");
        markerRow.id = "seq-start-marker-row";
        markerRow.style.display = "flex";
        markerRow.style.gap = "0";
        markerRow.style.alignItems = "stretch";
        markerRow.style.marginBottom = "4px";
        markerRow.style.height = "14px";
        markerRow.style.flexShrink = "0";

        const mLeft = document.createElement("div");
        mLeft.style.width = "180px";
        mLeft.style.flexShrink = "0";
        mLeft.style.marginRight = "10px";
        mLeft.style.fontSize = "0.75rem";
        mLeft.style.color = "#888";
        mLeft.style.display = "flex";
        mLeft.style.alignItems = "center";
        mLeft.style.justifyContent = "flex-end";
        mLeft.style.paddingRight = "10px";
        mLeft.textContent = "Start";
        markerRow.appendChild(mLeft);

        const mWrapper = document.createElement("div");
        mWrapper.className = "timeline-wrapper";
        mWrapper.style.flexGrow = "1";
        mWrapper.style.overflowX = "hidden";
        mWrapper.style.overflowY = "hidden";
        mWrapper.style.position = "relative";
        mWrapper.style.background = "#1a1a1a";

        markerGrid = document.createElement("div");
        markerGrid.id = "seq-start-marker-grid";
        markerGrid.style.height = "100%";
        markerGrid.style.position = "relative";
        markerGrid.style.cursor = "pointer";

        marker = document.createElement("div");
        marker.id = "seq-start-marker";
        marker.style.position = "absolute";
        marker.style.top = "0";
        marker.style.left = "0";
        marker.style.width = "14px";
        marker.style.height = "14px";
        marker.style.background = "#ffd43b";
        marker.style.clipPath = "polygon(0 0, 100% 0, 50% 100%)";
        marker.style.cursor = "ew-resize";
        marker.style.transform = `translateX(-7px)`;
        marker.dataset.step = "0";
        marker.title = "Drag to set playback start position";

        markerGrid.appendChild(marker);
        mWrapper.appendChild(markerGrid);
        markerRow.appendChild(mWrapper);
        rowsContainer.insertBefore(markerRow, rowsContainer.firstChild);

        const getTotalSteps = () => parseInt(markerGrid.dataset.totalSteps) || 128;
        const setMarkerStep = (step) => {
            const ts = getTotalSteps();
            const clamped = Math.max(0, Math.min(ts - 1, step));
            marker.style.transform = `translateX(${clamped * CELL_WIDTH - 7}px)`;
            marker.dataset.step = clamped;
            return clamped;
        };

        marker.onmousedown = (e) => {
            e.preventDefault();
            e.stopPropagation();
            const onMove = (me) => {
                const rect = markerGrid.getBoundingClientRect();
                const x = me.clientX - rect.left;
                const step = Math.round(x / CELL_WIDTH);
                setMarkerStep(step);
            };
            const onUp = () => {
                window.removeEventListener("mousemove", onMove);
                window.removeEventListener("mouseup", onUp);
                App.call("$sequencer", "set_start_step", parseInt(marker.dataset.step));
            };
            window.addEventListener("mousemove", onMove);
            window.addEventListener("mouseup", onUp);
        };

        markerGrid.onmousedown = (e) => {
            if (e.target === marker) return;
            const rect = markerGrid.getBoundingClientRect();
            const x = e.clientX - rect.left;
            const step = setMarkerStep(Math.round(x / CELL_WIDTH));
            App.call("$sequencer", "set_start_step", step);
        };
    } else {
        markerGrid = document.getElementById("seq-start-marker-grid");
        marker = document.getElementById("seq-start-marker");
    }
    markerGrid.style.width = `${totalSteps * CELL_WIDTH}px`;
    markerGrid.dataset.totalSteps = totalSteps;
    // Sync marker position with Ruby state
    try {
        const startStep = parseInt(App.call("$sequencer", "start_step").toString());
        const clamped = Math.max(0, Math.min(totalSteps - 1, startStep));
        marker.style.transform = `translateX(${clamped * CELL_WIDTH - 7}px)`;
        marker.dataset.step = clamped;
    } catch(e) {}

    // --- Measure ruler row ---
    let rulerRow = document.getElementById("seq-measure-ruler-row");
    let rulerGrid;
    if (!rulerRow) {
        rulerRow = document.createElement("div");
        rulerRow.id = "seq-measure-ruler-row";
        rulerRow.style.display = "flex";
        rulerRow.style.gap = "0";
        rulerRow.style.alignItems = "stretch";
        rulerRow.style.marginBottom = "4px";
        rulerRow.style.height = "18px";
        rulerRow.style.flexShrink = "0";

        const rLeft = document.createElement("div");
        rLeft.style.width = "180px";
        rLeft.style.flexShrink = "0";
        rLeft.style.marginRight = "10px";
        rulerRow.appendChild(rLeft);

        const rWrapper = document.createElement("div");
        rWrapper.className = "timeline-wrapper";
        rWrapper.style.flexGrow = "1";
        rWrapper.style.overflowX = "hidden";
        rWrapper.style.overflowY = "hidden";
        rWrapper.style.position = "relative";
        rWrapper.style.background = "#1a1a1a";

        rulerGrid = document.createElement("div");
        rulerGrid.id = "seq-measure-ruler-grid";
        rulerGrid.style.height = "100%";
        rulerGrid.style.position = "relative";

        rWrapper.appendChild(rulerGrid);
        rulerRow.appendChild(rWrapper);
        markerRow.insertAdjacentElement("afterend", rulerRow);
    } else {
        rulerGrid = document.getElementById("seq-measure-ruler-grid");
    }

    rulerGrid.style.width = `${totalSteps * CELL_WIDTH}px`;
    if (rulerGrid.dataset.totalSteps !== String(totalSteps)) {
        rulerGrid.dataset.totalSteps = totalSteps;
        rulerGrid.innerHTML = "";
        const measures = Math.ceil(totalSteps / 32);
        for (let m = 0; m < measures; m++) {
            const label = document.createElement("span");
            label.textContent = m + 1;
            label.style.position = "absolute";
            label.style.left = `${m * 32 * CELL_WIDTH + 14}px`;
            label.style.top = "2px";
            label.style.fontSize = "0.65rem";
            label.style.color = "#aaa";
            label.style.lineHeight = "1";
            label.style.pointerEvents = "none";
            label.style.userSelect = "none";
            rulerGrid.appendChild(label);
        }
    }

    // Remove tracks that no longer exist
    for (const [tIdx, cached] of trackRowsCache.entries()) {
        if (tIdx >= tracksCount) {
            cached.row.remove();
            trackRowsCache.delete(tIdx);
            // Also clean up block cache for this track
            for (const key of blockElementsCache.keys()) {
                if (key.startsWith(`${tIdx}-`)) blockElementsCache.delete(key);
            }
        }
    }

    for (let t = 0; t < tracksCount; t++) {
        let cached = trackRowsCache.get(t);
        let trackType = App.call("$sequencer", "get_track_type", t).toString();

        if (!cached) {
            const row = document.createElement("div");
            row.style.display = "flex";
            row.style.gap = "0";
            row.style.alignItems = "stretch";
            row.style.marginBottom = "10px";
            row.style.height = "80px";
            row.style.flexShrink = "0";

            const controlDiv = document.createElement("div");
            controlDiv.style.display = "flex";
            controlDiv.style.flexDirection = "column";
            controlDiv.style.width = "180px";
            controlDiv.style.flexShrink = "0";
            controlDiv.style.borderRight = "1px solid #555";
            controlDiv.style.paddingRight = "10px";
            controlDiv.style.marginRight = "10px";
            controlDiv.style.justifyContent = "center";
            controlDiv.style.gap = "5px";

            const labelBtn = document.createElement("button");
            labelBtn.style.padding = "4px";
            labelBtn.style.fontSize = "0.8rem";
            labelBtn.style.border = "1px solid #555";
            labelBtn.style.cursor = "pointer";
            labelBtn.onclick = () => selectTrack(t);

            const presetSel = document.createElement("select");
            presetSel.style.fontSize = "0.8rem";
            presetSel.style.padding = "2px";
            presetSel.style.width = "100%";

            const removeBtn = document.createElement("button");
            removeBtn.innerHTML = '<span class="material-icons" style="font-size: 1.2rem;">delete</span>';
            removeBtn.style.padding = "4px";
            removeBtn.style.background = "#dc3545";
            removeBtn.style.color = "white";
            removeBtn.style.border = "none";
            removeBtn.style.cursor = "pointer";
            removeBtn.onclick = () => removeTrack(t);

            const muteBtn = document.createElement("button");
            muteBtn.style.padding = "4px";
            muteBtn.style.color = "white";
            muteBtn.style.border = "1px solid #555";
            muteBtn.style.cursor = "pointer";

            const soloBtn = document.createElement("button");
            soloBtn.style.padding = "4px";
            soloBtn.style.border = "1px solid #555";
            soloBtn.style.cursor = "pointer";

            const sendBtn = document.createElement("button");
            sendBtn.style.padding = "4px";
            sendBtn.style.border = "1px solid #555";
            sendBtn.style.cursor = "pointer";
            sendBtn.title = "Send to Effects";

            const arpBtn = document.createElement("button");
            arpBtn.style.padding = "4px";
            arpBtn.style.border = "1px solid #555";

            const knobContainer = document.createElement("div");
            knobContainer.style.display = "flex";
            knobContainer.style.alignItems = "center";
            knobContainer.style.justifyContent = "center";
            knobContainer.style.cursor = "ns-resize";
            knobContainer.title = "Volume";
            const knobIcon = document.createElement("span");
            knobIcon.className = "material-icons";
            knobIcon.textContent = "arrow_circle_up";
            knobIcon.style.fontSize = "1.5rem";
            knobIcon.style.color = "#4dabf7";
            knobContainer.appendChild(knobIcon);

            const btnRow = document.createElement("div");
            btnRow.style.display = "flex";
            btnRow.style.gap = "2px";
            btnRow.appendChild(removeBtn);
            btnRow.appendChild(muteBtn);
            btnRow.appendChild(soloBtn);
            btnRow.appendChild(sendBtn);
            btnRow.appendChild(arpBtn);
            btnRow.appendChild(knobContainer);

            controlDiv.appendChild(labelBtn);
            controlDiv.appendChild(presetSel);
            controlDiv.appendChild(btnRow);
            row.appendChild(controlDiv);

            const timelineWrapper = document.createElement("div");
            timelineWrapper.className = "timeline-wrapper";
            timelineWrapper.style.flexGrow = "1";
            timelineWrapper.style.overflowX = "hidden";
            timelineWrapper.style.overflowY = "hidden";
            timelineWrapper.style.position = "relative";
            timelineWrapper.style.background = "#222";
            timelineWrapper.style.border = "1px solid #444";

            const grid = document.createElement("div");
            grid.className = "timeline-grid";
            grid.style.height = "100%";
            grid.style.position = "relative";
            grid.dataset.track = t;

            timelineWrapper.appendChild(grid);
            row.appendChild(timelineWrapper);

            // Create persistent playhead for this track
            const playhead = document.createElement("div");
            playhead.className = "playhead-cursor";
            grid.appendChild(playhead);

            // Insert before the scroll row if it exists, or just append
            const scrollRowEl = document.getElementById("sequencer-scroll-row");
            if (scrollRowEl) {
                rowsContainer.insertBefore(row, scrollRowEl);
            } else {
                rowsContainer.appendChild(row);
            }

            cached = {
                row, controlDiv, grid, labelBtn, presetSel, muteBtn, soloBtn, sendBtn, arpBtn, knobIcon, knobContainer, playhead, trackType: null
            };
            trackRowsCache.set(t, cached);
        }

        // Update Track Content & State
        const row = cached.row;
        const grid = cached.grid;

        // Type-specific UI update
        if (cached.trackType !== trackType) {
            cached.labelBtn.textContent = (trackType === "rhythmic" ? "🥁 " : "🎹 ") + `Track ${t + 1}`;
            if (trackType === "melodic") {
                const presets = getPresets();
                cached.presetSel.disabled = false;
                cached.presetSel.innerHTML = '<option value="">(Default)</option>';
                Object.keys(presets).forEach(name => {
                    const opt = document.createElement("option");
                    opt.value = name;
                    opt.textContent = name;
                    cached.presetSel.appendChild(opt);
                });
                if (!cached._presetListenersAttached) {
                    cached.presetSel.addEventListener("mousedown", () => {
                        cached.presetSel._presetOpen = true;
                        cached.presetSel._prevValue = cached.presetSel.value;
                    });
                    cached.presetSel.addEventListener("change", (e) => {
                        cached.presetSel._presetOpen = false;
                        const name = e.target.value;
                        if (name) {
                            const freshPresets = getPresets();
                            if (freshPresets[name]) {
                                App.call("$sequencer", "import_track_patch", t, freshPresets[name]);
                                App.call("$sequencer", "set_track_preset_name", t, name);
                            }
                        } else {
                            const patchJson = App.eval("$previewSynth.export_patch").toJS();
                            App.call("$sequencer", "import_track_patch", t, patchJson);
                            App.call("$sequencer", "set_track_preset_name", t, "");
                        }
                    });
                    cached.presetSel.addEventListener("blur", () => {
                        if (cached.presetSel._presetOpen) {
                            cached.presetSel._presetOpen = false;
                            const prev = cached.presetSel._prevValue;
                            const curr = cached.presetSel.value;
                            if (prev === curr && prev !== "") {
                                const freshPresets = getPresets();
                                if (freshPresets[prev]) {
                                    App.call("$sequencer", "import_track_patch", t, freshPresets[prev]);
                                    App.call("$sequencer", "set_track_preset_name", t, prev);
                                }
                            } else if (prev === curr && prev === "") {
                                const patchJson = App.eval("$previewSynth.export_patch").toJS();
                                App.call("$sequencer", "import_track_patch", t, patchJson);
                                App.call("$sequencer", "set_track_preset_name", t, "");
                            }
                        }
                    });
                    cached._presetListenersAttached = true;
                }
                cached.arpBtn.style.cursor = "pointer";
                cached.arpBtn.style.opacity = "1";
                cached.arpBtn.title = "Arpeggiator ON/OFF";
            } else {
                cached.presetSel.disabled = true;
                cached.presetSel.innerHTML = '<option>Drum Kit</option>';
                cached.arpBtn.style.cursor = "default";
                cached.arpBtn.style.opacity = "0.3";
                cached.arpBtn.title = "";
            }
            cached.trackType = trackType;
        }

        // Selection
        if (t === currentTrackIndex) {
            cached.labelBtn.style.background = "#007bff";
            cached.labelBtn.style.color = "white";
        } else {
            cached.labelBtn.style.background = "#333";
            cached.labelBtn.style.color = "#ccc";
        }

        // Preset Value (skip while dropdown is open to avoid overriding user interaction)
        if (trackType === "melodic" && !cached.presetSel._presetOpen) {
            cached.presetSel.value = App.call("$sequencer", "get_track_preset_name", t).toString();
        }

        // Mute/Solo
        let isMuted = App.call("$sequencer", "get_track_mute", t).toString() === "true";
        let isSolo = App.call("$sequencer", "get_track_solo", t).toString() === "true";
        let isSend = App.call("$sequencer", "get_track_send", t).toString() === "true";

        cached.muteBtn.innerHTML = `<span class="material-icons" style="font-size: 1.2rem;">${isMuted ? "volume_off" : "volume_up"}</span>`;
        cached.muteBtn.style.background = isMuted ? "#6c757d" : "#444";
        cached.muteBtn.onclick = () => {
            App.call("$sequencer", "set_track_mute", t, !isMuted);
            renderSequencer();
        };

        cached.soloBtn.innerHTML = `<span class="material-icons" style="font-size: 1.2rem;">${isSolo ? "grade" : "star_outline"}</span>`;
        cached.soloBtn.style.background = isSolo ? "#fcc419" : "#444";
        cached.soloBtn.style.color = isSolo ? "black" : "white";
        cached.soloBtn.onclick = () => {
            App.call("$sequencer", "set_track_solo", t, !isSolo);
            renderSequencer();
        };

        cached.sendBtn.innerHTML = `<span class="material-icons" style="font-size: 1.2rem;">${isSend ? "blur_on" : "blur_off"}</span>`;
        cached.sendBtn.style.background = isSend ? "#be4bdb" : "#444";
        cached.sendBtn.style.color = isSend ? "white" : "#ccc";
        cached.sendBtn.onclick = () => {
            App.call("$sequencer", "set_track_send", t, !isSend);
            renderSequencer();
        };

        // Arp
        if (trackType === "melodic") {
            let isArp = App.call("$sequencer", "get_arpeggiator_status", t).toString() === "true";
            cached.arpBtn.innerHTML = `<span class="material-icons" style="font-size: 1.2rem;">${isArp ? "clear_all" : "dehaze"}</span>`;
            cached.arpBtn.style.background = isArp ? "#4dabf7" : "#444";
            cached.arpBtn.style.color = isArp ? "white" : "#ccc";
            cached.arpBtn.onclick = () => {
                App.call("$sequencer", "set_arpeggiator_enabled", t, !isArp);
                renderSequencer();
            };
        } else {
            cached.arpBtn.innerHTML = `<span class="material-icons" style="font-size: 1.2rem;">dehaze</span>`;
            cached.arpBtn.style.background = "#222";
            cached.arpBtn.style.color = "#555";
            cached.arpBtn.onclick = null;
        }

        // Volume
        let currentVol = parseFloat(App.call("$sequencer", "get_track_volume", t).toString());
        cached.knobIcon.style.transform = `rotate(${(currentVol - 1.0) * 160}deg)`;
        cached.knobContainer.onmousedown = (e) => {
            const startY = e.clientY;
            const startVol = currentVol;
            const onMove = (me) => {
                let nv = startVol + (startY - me.clientY) / 100;
                if(nv < 0) nv = 0; if(nv > 2) nv = 2;
                App.call("$sequencer", "set_track_volume", t, nv);
                cached.knobIcon.style.transform = `rotate(${(nv - 1.0) * 160}deg)`;
            };
            const onUp = () => {
                window.removeEventListener("mousemove", onMove);
                window.removeEventListener("mouseup", onUp);
            };
            window.addEventListener("mousemove", onMove);
            window.addEventListener("mouseup", onUp);
        };

        // Grid Background & Width
        grid.style.width = `${totalSteps * CELL_WIDTH}px`;
        grid.style.backgroundImage = `repeating-linear-gradient(90deg,#888 0px,#888 1px,transparent 1px,transparent ${CELL_WIDTH * 32}px),repeating-linear-gradient(90deg,#555 0px,#555 1px,transparent 1px,transparent ${CELL_WIDTH * 8}px),repeating-linear-gradient(90deg,#333 0px,#333 1px,transparent 1px,transparent ${CELL_WIDTH}px)`;

        // Grid Events
        grid.onmousedown = (e) => {
            if (e.target.classList.contains("block") || e.target.tagName === "CANVAS") return;
            isDrawing = true;
            drawTrackIndex = t;
            drawStartStep = Math.floor((e.clientX - grid.getBoundingClientRect().left) / CELL_WIDTH);
            ghostBlock = document.createElement("div");
            ghostBlock.style.position = "absolute";
            ghostBlock.style.height = "100%";
            ghostBlock.style.background = "rgba(77, 171, 247, 0.5)";
            ghostBlock.style.left = `${drawStartStep * CELL_WIDTH}px`;
            ghostBlock.style.width = `${CELL_WIDTH}px`;
            ghostBlock.style.pointerEvents = "none";
            grid.appendChild(ghostBlock);
        };
        grid.onmousemove = (e) => {
            if (!isDrawing || drawTrackIndex !== t) return;
            const cur = Math.floor((e.clientX - grid.getBoundingClientRect().left) / CELL_WIDTH);
            const s = Math.min(drawStartStep, cur);
            const len = Math.max(drawStartStep, cur) - s + 1;
            ghostBlock.style.left = `${s * CELL_WIDTH}px`;
            ghostBlock.style.width = `${len * CELL_WIDTH}px`;
        };

        // Sync Blocks
        try {
            const blocksJson = App.call("$sequencer", "get_track_blocks_json", t).toString();
            const blocks = JSON.parse(blocksJson);
            const currentBlockKeys = new Set();

            blocks.forEach(b => {
                const key = `${t}-${b.start}`;
                currentBlockKeys.add(key);
                const cachedBlock = blockElementsCache.get(key);

                // Simple hash to detect changes (start, length, content-specifics)
                const dataHash = JSON.stringify({
                    len: b.length,
                    chord: b.chord_name,
                    pid: b.pattern_id,
                    notes_count: b.notes_count
                });

                if (cachedBlock && cachedBlock.dataHash === dataHash) {
                    // No change
                    return;
                }

                // Update or Create
                if (cachedBlock) cachedBlock.element.remove();

                const blockDiv = document.createElement("div");
                blockDiv.className = "block";
                blockDiv.style.position = "absolute";
                blockDiv.style.left = `${b.start * CELL_WIDTH}px`;
                blockDiv.style.width = `${b.length * CELL_WIDTH}px`;
                blockDiv.style.height = "100%";
                blockDiv.style.border = "1px solid #fff";
                blockDiv.style.borderRadius = "4px";
                blockDiv.style.cursor = "pointer";
                blockDiv.style.zIndex = "5";
                blockDiv.style.display = "flex";
                blockDiv.style.alignItems = "center";
                blockDiv.style.justifyContent = "center";
                blockDiv.style.overflow = "hidden";

                if (trackType === "rhythmic") {
                    blockDiv.style.background = "#ff8787";
                    const pName = App.call("$sequencer", "get_pattern_name", b.pattern_id).toString();
                    blockDiv.innerText = pName;
                    blockDiv.style.color = "black";
                    blockDiv.style.fontSize = "0.8rem";
                    blockDiv.style.fontWeight = "bold";
                    blockDiv.onclick = (e) => {
                        e.stopPropagation();
                        openPatternSelector(t, b.start, b.pattern_id);
                    };
                } else {
                    blockDiv.style.background = b.notes_count > 0 ? "#4dabf7" : "#555";
                    blockDiv.title = b.chord_name || `Start: ${b.start}`;
                    const canvas = document.createElement("canvas");
                    const cw = b.length * CELL_WIDTH - 4;
                    const ch = 70;
                    canvas.width = cw > 0 ? cw : 1;
                    canvas.height = ch;
                    canvas.style.display = "block";
                    try {
                        const notesJson = App.call("$sequencer", "get_block_notes_json", t, b.start).toString();
                        const notes = JSON.parse(notesJson);
                        drawTetrisShape(canvas.getContext("2d"), notes, cw, ch);
                    } catch(e){}
                    blockDiv.appendChild(canvas);
                    blockDiv.onclick = (e) => {
                        e.stopPropagation();
                        openChordSelector(t, b.start);
                    };
                }

                blockDiv.oncontextmenu = (e) => {
                    e.preventDefault();
                    if(confirm("Delete block?")) {
                        App.call("$sequencer", "remove_block", t, b.start);
                        renderSequencer();
                    }
                };

                grid.appendChild(blockDiv);
                blockElementsCache.set(key, { element: blockDiv, dataHash });
            });

            // Cleanup removed blocks
            for (const [key, cachedBlock] of blockElementsCache.entries()) {
                if (key.startsWith(`${t}-`) && !currentBlockKeys.has(key)) {
                    cachedBlock.element.remove();
                    blockElementsCache.delete(key);
                }
            }
        } catch(e){ console.error(e); }
    } // end tracks loop

    // Append master scroll if not present
    let scrollRow = document.getElementById("sequencer-scroll-row");
    if (!scrollRow) {
        scrollRow = document.createElement("div");
        scrollRow.id = "sequencer-scroll-row";
        scrollRow.style.display = "flex";
        const spacer = document.createElement("div");
        spacer.style.width = "150px"; spacer.style.flexShrink = "0";
        scrollRow.appendChild(spacer);
        scrollRow.appendChild(scrollContainer);
        rowsContainer.appendChild(scrollRow);
    }

    // Restore scroll position after potential track changes
    setTimeout(() => { if(window._lastScrollLeft) scrollContainer.scrollLeft = window._lastScrollLeft; }, 0);
  } // end renderSequencer

  function selectTrack(t) {
      App.call("$sequencer", "select_track", t);
      renderSequencer();
  }

  function removeTrack(t) {
      if(confirm(`Remove Track ${t+1}?`)) {
          App.call("$sequencer", "remove_track", t);
          renderSequencer();
      }
  }

  // The chord selector modal is implemented as the <chord-selector-modal>
  // WebComponent (src/chord_selector_modal.rb); openChordSelector at the top
  // of this function delegates to it via App.call.

  // --- Event Listeners ---

  window.addEventListener("mouseup", () => {
    if (isDrawing && ghostBlock) {
        const left = parseInt(ghostBlock.style.left);
        const width = parseInt(ghostBlock.style.width);
        const start = Math.round(left / CELL_WIDTH);
        const len = Math.round(width / CELL_WIDTH);
        try {
            // Check type of track
            const trackType = App.call("$sequencer", "get_track_type", drawTrackIndex).toString();

            // Default length for rhythm blocks if it's just a click
            let finalLen = len;
            if (trackType === "rhythmic" && len <= 1) {
                finalLen = 32; // 1 bar (16 steps of 1/16th notes)
            }

            // Add block
            App.call("$sequencer", "add_or_update_block", drawTrackIndex, start, finalLen);
            renderSequencer();

            if (trackType === "melodic") {
                openChordSelector(drawTrackIndex, start);
            } else {
                const pidVal = App.call("$sequencer", "get_block_pattern_id", drawTrackIndex, start);
                const pid = pidVal ? pidVal.toString() : "";
                openPatternSelector(drawTrackIndex, start, pid);
            }
        } catch(e){ console.error(e); }
        ghostBlock.remove();
        ghostBlock = null;
    }
    isDrawing = false;
    drawTrackIndex = -1;
  });

  addTrackBtn.onclick = () => {
      try {
          App.call("$sequencer", "add_track");
          renderSequencer();
      } catch(e) { console.error(e); }
  };

  if (addRhythmTrackBtn) {
      addRhythmTrackBtn.onclick = () => {
          try {
              App.call("$sequencer", "add_rhythm_track");
              renderSequencer();
          } catch(e) { console.error(e); }
      };
  }

  playBtn.onclick = () => {
    try {
      const isPlayingVal = App.call("$sequencer", "is_playing");
      const isPlaying = isPlayingVal && isPlayingVal.toString() === "true";
      if (isPlaying) {
        App.call("$sequencer", "stop");
      } else {
        App.call("$sequencer", "start");
      }
    } catch (e) { console.error("Sequencer play/stop UI error:", e); }
  };
  measuresInput.addEventListener("input", () => {
      if (measuresDisplay) measuresDisplay.textContent = measuresInput.value;
      try { App.call("$sequencer", "set_total_bars", parseInt(measuresInput.value)); renderSequencer(); } catch(e){}
  });
  bpmInput.addEventListener("input", () => {
      if (bpmDisplay) bpmDisplay.textContent = bpmInput.value;
      try{App.call("$sequencer", "set_bpm", parseInt(bpmInput.value));}catch(e){}
  });
  rootFreqInput.addEventListener("change", () => { try{App.call("$sequencer", "set_root_freq", parseFloat(rootFreqInput.value));}catch(e){} });

  if (swingInput) {
      swingInput.addEventListener("input", () => {
          try{
              App.call("$sequencer", "set_swing_amount", parseFloat(swingInput.value));
              const display = document.getElementById("val_swing");
              if (display) display.textContent = Math.round(swingInput.value * 100);
          }catch(e){}
      });
  }

  window.addEventListener("trackChanged", renderSequencer);
  renderSequencer();

  // --- Master Volume Slider ---
  const masterVolumeSlider = document.getElementById("seq-master-volume");
  const masterVolumeDisplay = document.getElementById("val_seq-master-volume");
  if (masterVolumeSlider) {
    masterVolumeSlider.addEventListener("input", () => {
      const vol = parseFloat(masterVolumeSlider.value);
      if (masterVolumeDisplay) masterVolumeDisplay.textContent = vol.toFixed(2);
      try { App.call("$sequencer", "master_volume=", vol); } catch(_) {}
      try { App.call("$previewSynth", "volume=", vol); } catch(_) {}
      try { App.call("$chordSynth", "volume=", vol); } catch(_) {}
    });
  }

  return {};
}
