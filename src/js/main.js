import { DefaultRubyVM } from "https://cdn.jsdelivr.net/npm/@ruby/wasm-wasi@2.8.1/dist/esm/browser.js";
import { setupSequencer } from "./sequencer_ui.js";
import { setupUI } from "./synth_ui.js";
import { setupMIDI } from "./midi_handler.js";
import { setupVisualizer } from "./visualizer.js";
import { setupProjectManager } from "./project_manager.js";

const startBtn = document.getElementById("start-btn");
const overlay = document.getElementById("start-overlay");

// Central Application Object
window.App = {
  vm: null,
  audioCtx: null,

  // Safe Ruby evaluation with centralized error handling
  eval(code, context = "Main") {
    try {
      const result = this.vm.eval(code);
      return result;
    } catch (e) {
      console.error(`[Ruby Error in ${context}]:`, e);
      if (e.stack) console.error(e.stack);
      return null;
    }
  },

  // Safe Method Call via JSON Facade
  call(target, method, ...args) {
    const jsonArgs = JSON.stringify(args);
    window._tempJsonArgs = jsonArgs;
    const code = `js_bridge_dispatch('${target}', '${method}', JS.global[:_tempJsonArgs].to_s)`;
    const result = this.eval(code, `Call(${target}.${method})`);
    delete window._tempJsonArgs;
    return result;
  }
};

// Scheduler performance metrics (verification harness for voice pooling).
// Tick durations are pushed from the sequencer's setInterval body; heap is
// sampled at 1Hz; longtasks (>50ms main-thread tasks) come from a
// PerformanceObserver. Ruby-side counters are merged in by summary().
window.__seqMetrics = {
  ticks: [],
  heap: [],
  longtasks: [],

  reset() {
    this.ticks.length = 0;
    this.heap.length = 0;
    this.longtasks.length = 0;
    if (window.App && window.App.vm) {
      window.App.eval("$sequencer.reset_metrics if defined?($sequencer)", "MetricsReset");
    }
  },

  percentile(arr, p) {
    if (arr.length === 0) return 0;
    const sorted = [...arr].sort((a, b) => a - b);
    return sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * p))];
  },

  summary() {
    // Heap slope (bytes/sec) via least squares; GC count = drop count > 1MB
    let gcCount = 0;
    for (let i = 1; i < this.heap.length; i++) {
      if (this.heap[i].used < this.heap[i - 1].used - 1e6) gcCount++;
    }
    let heapSlope = 0;
    if (this.heap.length >= 2) {
      const n = this.heap.length;
      const t0 = this.heap[0].t;
      let sx = 0, sy = 0, sxy = 0, sxx = 0;
      for (const s of this.heap) {
        const x = (s.t - t0) / 1000;
        sx += x; sy += s.used; sxy += x * s.used; sxx += x * x;
      }
      heapSlope = (n * sxy - sx * sy) / (n * sxx - sx * sx || 1);
    }
    let rubyMetrics = null;
    if (window.App && window.App.vm) {
      const r = window.App.eval("$sequencer.metrics_json if defined?($sequencer)", "MetricsDump");
      if (r) { try { rubyMetrics = JSON.parse(r.toString()); } catch (e) { /* ignore */ } }
    }
    return {
      tickCount: this.ticks.length,
      tickP50: this.percentile(this.ticks, 0.5),
      tickP95: this.percentile(this.ticks, 0.95),
      tickMax: this.ticks.length ? Math.max(...this.ticks) : 0,
      tickTotalMs: this.ticks.reduce((a, b) => a + b, 0),
      longtaskCount: this.longtasks.length,
      longtaskTotalMs: this.longtasks.reduce((a, b) => a + b.duration, 0),
      gcCount,
      heapSlopeBytesPerSec: heapSlope,
      heapSamples: this.heap.length,
      ruby: rubyMetrics
    };
  }
};

if (typeof PerformanceObserver !== "undefined") {
  try {
    new PerformanceObserver((list) => {
      for (const e of list.getEntries()) {
        window.__seqMetrics.longtasks.push({ start: e.startTime, duration: e.duration });
      }
    }).observe({ entryTypes: ["longtask"] });
  } catch (e) {
    console.warn("longtask observer unavailable:", e);
  }
}

setInterval(() => {
  if (performance.memory) {
    window.__seqMetrics.heap.push({ t: performance.now(), used: performance.memory.usedJSHeapSize });
  }
}, 1000);

const main = async () => {
  // Pre-load Ruby VM
  const response = await fetch("https://cdn.jsdelivr.net/npm/@ruby/3.3-wasm-wasi@2.8.1/dist/ruby+stdlib.wasm");
  const buffer = await response.arrayBuffer();
  const module = await WebAssembly.compile(buffer);
  const { vm } = await DefaultRubyVM(module);

  App.vm = vm;
  console.log("Ruby VM loaded");

  // Enable the start button and update text now that VM is ready
  startBtn.disabled = false;
  startBtn.textContent = "Click to Start";

  // Ensure JS module is loaded
  App.eval("require 'js'");

  startBtn.onclick = async () => {
    if (!App.audioCtx) App.audioCtx = new (window.AudioContext || window.webkitAudioContext)();
    if (App.audioCtx.state === 'suspended') await App.audioCtx.resume();
    // Expose for visualizer (Legacy support if needed, or update visualizer)
    window.audioCtx = App.audioCtx;

    // Initialize Ruby global $ctx
    App.eval("$ctx = JS.eval('return window.App.audioCtx;')");

    overlay.style.display = "none";

    console.log("Loading Ruby scripts...");

    const rubyFiles = [
      "src/synthesizer/audio_node_wrapper.rb",
      "src/synthesizer/nodes.rb",
      "src/synthesizer/adsr_envelope.rb",
      "src/synthesizer/voice.rb",
      "src/synthesizer/voice_pool.rb",
      "src/synthesizer.rb",
      "src/synthesizer/drum_machine.rb",
      "src/effects_chain.rb",
      "src/sequencer.rb",
      "src/midi_processor.rb",
      "src/js_bridge.rb",
      "src/web_component.rb",
      "src/dimension_colors.rb",
      "src/lattice_view.rb",
      "src/chord_manager.rb",
      "src/presets.rb",
      "src/pattern_editor.rb",
      "src/chord_editor.rb",
      "src/effects_panel.rb",
      "src/presets_panel.rb",
      "src/tab_bar.rb",
      "src/chord_selector_modal.rb",
      "src/pattern_selector_modal.rb",
      "src/track_controls.rb",
      "src/sequencer_controls.rb",
      "src/sequencer_block.rb"
    ];

    // Fetch all Ruby sources in parallel; only the VFS writes (VM evals)
    // below have to stay serial.
    const fileContents = await Promise.all(rubyFiles.map(async (file) => {
      const res = await fetch(`${file}?_=${Date.now()}`);
      if (!res.ok) {
        console.error(`Failed to load ${file}`);
        return null;
      }
      return { file, text: await res.text() };
    }));

    // Create every needed VFS directory in a single eval.
    const dirs = [...new Set(
      fileContents.filter(Boolean)
        .map(({ file }) => '/' + file.substring(0, file.lastIndexOf('/')))
        .filter(d => d !== '/')
    )];
    window._tempDirs = JSON.stringify(dirs);
    App.eval(`
      require 'json'
      JSON.parse(JS.global[:_tempDirs].to_s).each do |dir|
        current = ''
        dir.split('/').reject(&:empty?).each do |part|
          current = current + '/' + part
          Dir.mkdir(current) unless Dir.exist?(current)
        end
      end
    `, "DirSetup");
    delete window._tempDirs;

    for (const entry of fileContents) {
      if (!entry) continue;

      // Force absolute path for VFS to ensure it matches $LOAD_PATH.
      const vfsPath = '/' + entry.file;

      // Pass content to Ruby via global variables to avoid escaping issues.
      window._rubyFileContent = entry.text;
      window._tempPath = vfsPath;
      App.eval(`File.write(JS.global[:_tempPath].to_s, JS.global[:_rubyFileContent])`, "FileWrite");

      // Verify write
      const exists = App.eval(`File.exist?(JS.global[:_tempPath].to_s)`, "FileExistCheck").toJS();
      if (!exists) {
        console.error(`Failed to write ${vfsPath}`);
      }
      delete window._tempPath;
    }

    // Clean up
    delete window._rubyFileContent;

    // Add src to load path
    App.eval("$LOAD_PATH.unshift '/src'");

    // Load entry points
    const loadScript = (script) => {
      window._tempScript = script;
      App.eval(`
        begin
          require JS.global[:_tempScript].to_s
        rescue LoadError => e
          puts "Error loading #{JS.global[:_tempScript].to_s}: #{e.message}"
          puts e.backtrace
          raise e
        end
      `, `LoadScript`);
      delete window._tempScript;
      console.log(`Loaded ${script}`);
    };

    loadScript('/src/synthesizer.rb');
    loadScript('/src/effects_chain.rb');
    loadScript('/src/sequencer.rb');
    loadScript('/src/midi_processor.rb');
    loadScript('/src/js_bridge.rb');

    // WebComponent base mixin (subclasses are required after this and
    // their register() is called at require time; matching custom elements
    // must NOT be in the DOM at that point — insert them only after require)
    loadScript('/src/web_component.rb');

    // Data layer (localStorage-backed)
    loadScript('/src/chord_manager.rb');
    loadScript('/src/presets.rb');
    App.eval("$chordManager = ChordManager.new");
    App.eval("$presets = Presets.new");

    // Init Sequencer & Synth
    App.eval("$sequencer = Sequencer.new($ctx, name: '$sequencer')");
    App.eval("$synth = $sequencer.current_track.synth");

    // Pattern Preview Sequencer
    App.eval("$patternSequencer = Sequencer.new($ctx, name: '$patternSequencer')");
    App.eval("$patternSequencer.add_rhythm_track");
    App.eval("$patternSequencer.set_patterns_reference($sequencer.patterns)");
    App.eval("$patternSequencer.set_total_bars(1)"); // Preview is 1 bar (32 steps)

    // Create a standalone synth for the Synthesizer tab preview.
    // Delay/reverb are no longer built in: wire DelayEffect/ReverbEffect
    // nodes into the patch graph instead.
    // Setup: Synth -> Analyser -> Compressor -> Destination
    App.eval("$previewSynth = Synthesizer.new($ctx)");
    App.eval("$previewAnalyser = AnalyserNode.new($ctx)");
    App.eval("$previewAnalyser.fft_size = 2048");

    // Connect Chain
    App.eval("$previewSynth.connect($previewAnalyser)");
    App.eval("$previewComp = DynamicsCompressorNode.new($ctx)");
    App.eval("$previewComp.threshold.value = -24.0");
    App.eval("$previewAnalyser.connect($previewComp)");
    App.eval("$previewComp.connect($ctx[:destination])");

    // --- Chord Synth Setup ---
    App.eval("$chordSynth = Synthesizer.new($ctx)");
    App.eval("$chordComp = DynamicsCompressorNode.new($ctx)");
    App.eval("$chordComp.threshold.value = -24.0");
    App.eval("$chordSynth.connect($chordComp)");
    App.eval("$chordComp.connect($ctx[:destination])");

    // --- Audition Synth ---
    // Dedicated dry synth for lattice note auditions (chord editor + sequencer
    // grid editor). Kept independent of $previewSynth so insert Delay/Reverb
    // nodes in the Synthesizer patch don't color pitch previews.
    App.eval("$auditionSynth = Synthesizer.new($ctx)");
    App.eval("$auditionComp = DynamicsCompressorNode.new($ctx)");
    App.eval("$auditionComp.threshold.value = -24.0");
    App.eval("$auditionSynth.connect($auditionComp)");
    App.eval("$auditionComp.connect($ctx[:destination])");

    // Default to preview synth for UI initially
    App.eval("$synth = $previewSynth");
    window.synthAnalyser = App.eval("$previewAnalyser.native_node").toJS();

    console.log("Initialized");

    setupUI(App);
    setupVisualizer(App);
    setupProjectManager(App);

    // Register WebComponents (must happen AFTER dependent globals like
    // $sequencer/$patternSequencer are initialized; $midiProcessor is
    // initialized just below — the modal handles its absence at open time).
    loadScript('/src/pattern_editor.rb');
    loadScript('/src/chord_editor.rb');
    loadScript('/src/effects_panel.rb');
    loadScript('/src/presets_panel.rb');
    loadScript('/src/tab_bar.rb');
    loadScript('/src/chord_selector_modal.rb');
    loadScript('/src/pattern_selector_modal.rb');
    loadScript('/src/track_controls.rb');
    loadScript('/src/sequencer_controls.rb');
    loadScript('/src/sequencer_block.rb');

    const patternView = document.getElementById("view-pattern");
    if (patternView) {
      patternView.appendChild(document.createElement("pattern-editor"));
    }

    const chordView = document.getElementById("view-chord");
    let chordEditorRef = null;
    if (chordView) {
      const chordEditorEl = document.createElement("chord-editor");
      chordView.appendChild(chordEditorEl);
      chordEditorRef = `wc:${chordEditorEl.__rubyId}`;
    }

    const effectsHost = document.getElementById("effects-panel-host");
    if (effectsHost) {
      effectsHost.appendChild(document.createElement("effects-panel"));
    }

    const presetsHost = document.getElementById("presets-panel-host");
    if (presetsHost) {
      presetsHost.appendChild(document.createElement("presets-panel"));
    }

    const tabBarHost = document.getElementById("tab-bar-host");
    if (tabBarHost) {
      tabBarHost.appendChild(document.createElement("tab-bar"));
    }

    let chordSelectorRef = null;
    const chordSelectorHost = document.getElementById("chord-selector-host");
    if (chordSelectorHost) {
      const el = document.createElement("chord-selector-modal");
      chordSelectorHost.appendChild(el);
      chordSelectorRef = `wc:${el.__rubyId}`;
    }

    let patternSelectorRef = null;
    const patternSelectorHost = document.getElementById("pattern-selector-host");
    if (patternSelectorHost) {
      const el = document.createElement("pattern-selector-modal");
      patternSelectorHost.appendChild(el);
      patternSelectorRef = `wc:${el.__rubyId}`;
    }

    const sequencerControlsHost = document.getElementById("sequencer-controls-host");
    if (sequencerControlsHost) {
      sequencerControlsHost.appendChild(document.createElement("sequencer-controls"));
    }

    // Sequencer UI must be wired up after the selector modals exist.
    setupSequencer(App, { chordSelectorRef, patternSelectorRef });

    // Initialize MIDI Processor
    App.eval("$midiProcessor = MIDIProcessor.new($sequencer, $previewSynth, $chordSynth)");

    // Setup Web MIDI API
    setupMIDI(App, () => ({
      reRenderChord:     () => { if (chordEditorRef) App.call(chordEditorRef, "re_render_chord"); },
      setChordDimension: (d) => { if (chordEditorRef) App.call(chordEditorRef, "set_chord_dimension", d); },
      reRenderSeq:       () => { if (chordSelectorRef) App.call(chordSelectorRef, "re_render_seq"); },
      setSeqDimension:   (d) => { if (chordSelectorRef) App.call(chordSelectorRef, "set_seq_dimension", d); },
      setSynthDimension: (d) => App.call("$midiProcessor", "set_synth_dimension", d),
    }));
  };
};

main();
