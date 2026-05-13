import { CELL_WIDTH } from "./utils.js";

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

  let isDrawing = false;
  let drawStartStep = 0;
  let drawTrackIndex = -1;
  let ghostBlock = null;

  // Cache for DOM elements to avoid full re-renders
  const trackRowsCache = new Map(); // index -> { row, controlDiv, grid, playhead, ... }
  const blockElementsCache = new Map(); // "trackIdx-startStep" -> { element, dataHash }

  // Refresh after a block was added / removed / had its notes replaced.
  // renderSequencer's per-track cleanup loop relies on cached entries to
  // detect blocks that no longer exist, so we MUST NOT clear the cache here.
  window.addEventListener("seqBlockUpdated", renderSequencer);

  // Refresh after a track-controls action (mute/solo/send/arp/select/remove/add)
  // dispatches seqTrackChanged. The track-controls component itself listens for
  // presetsUpdated, so this UI no longer needs to.
  window.addEventListener("seqTrackChanged", () => {
    blockElementsCache.clear();
    renderSequencer();
  });

  // Project loading swaps the entire Ruby sequencer state. Drop all cached
  // rows and blocks so renderSequencer rebuilds from scratch.
  window.addEventListener("projectLoaded", () => {
    trackRowsCache.forEach((cached) => cached.row.remove());
    trackRowsCache.clear();
    blockElementsCache.clear();
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

  function animate() {
    requestAnimationFrame(animate);
    if (!App.audioCtx || App.audioCtx.state === 'suspended') return;

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
    let totalSteps = 128;

    try {
        const tracksCountVal = App.call("$sequencer", "get_tracks_count");
        if (!tracksCountVal) return; // Wait for initialization
        tracksCount = parseInt(tracksCountVal.toString());
        totalSteps = parseInt(App.call("$sequencer", "total_steps").toString());
    } catch(e) {
        console.error("Error in renderSequencer initialization:", e);
        return;
    }

    // Global controls (BPM/Measures/Swing/RootFreq) are synced by the
    // <sequencer-controls> WebComponent on the seqTrackChanged / trackChanged
    // events that this UI dispatches.

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

            const tc = document.createElement("track-controls");
            tc.setAttribute("track-index", String(t));
            row.appendChild(tc);

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

            // Insert before the scroll row if it exists, or just append.
            // Note: <track-controls> connectedCallback only fires once `row`
            // enters the DOM, so we must read tc.__rubyId AFTER insertion.
            const scrollRowEl = document.getElementById("sequencer-scroll-row");
            if (scrollRowEl) {
                rowsContainer.insertBefore(row, scrollRowEl);
            } else {
                rowsContainer.appendChild(row);
            }

            const tcRef = `wc:${tc.__rubyId}`;
            cached = { row, tc, tcRef, grid, playhead };
            trackRowsCache.set(t, cached);
        }

        const grid = cached.grid;

        // Delegate all control state updates to the <track-controls> component.
        try { App.call(cached.tcRef, "refresh"); } catch(e) { console.error(e); }

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

        // Sync Blocks via <sequencer-block> WebComponents
        try {
            const blocksJson = App.call("$sequencer", "get_track_blocks_json", t).toString();
            const blocks = JSON.parse(blocksJson);
            const currentBlockKeys = new Set();

            blocks.forEach(b => {
                const key = `${t}-${b.start}`;
                currentBlockKeys.add(key);
                const cachedBlock = blockElementsCache.get(key);

                // Hash compares everything that affects rendering. Recreate the
                // block only when length or type changes; otherwise reuse and
                // call refresh() so the Ruby component re-renders content.
                const dataHash = JSON.stringify({
                    len: b.length,
                    type: trackType,
                    pid: b.pattern_id,
                    notes_count: b.notes_count
                });

                if (cachedBlock && cachedBlock.dataHash === dataHash) return;

                if (cachedBlock) {
                    App.call(cachedBlock.ref, "refresh", b.length, trackType);
                    cachedBlock.dataHash = dataHash;
                } else {
                    const el = document.createElement("sequencer-block");
                    el.setAttribute("track-index", String(t));
                    el.setAttribute("start-step", String(b.start));
                    el.setAttribute("length", String(b.length));
                    el.setAttribute("track-type", trackType);
                    grid.appendChild(el);
                    blockElementsCache.set(key, { element: el, ref: `wc:${el.__rubyId}`, dataHash });
                }
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

  window.addEventListener("trackChanged", renderSequencer);
  renderSequencer();

  return {};
}
