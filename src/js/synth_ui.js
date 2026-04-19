const NODE_TYPES = {
  Oscillator: {
    initParams: { type: "sawtooth", frequency: 440 },
    inputs: ["frequency", "detune"],
    hasOutput: true,
    hasInput: false
  },
  Noise: {
    initParams: {},
    inputs: [],
    hasOutput: true,
    hasInput: false
  },
  Constant: {
    initParams: { offset: 1.0 },
    inputs: ["offset"],
    hasOutput: true,
    hasInput: false
  },
  BiquadFilter: {
    initParams: { type: "lowpass", frequency: 2000, q: 1.0 },
    inputs: ["frequency", "detune", "Q", "gain"],
    hasOutput: true,
    hasInput: true
  },
  CombFilter: {
    initParams: { frequency: 440, q: 0.5 },
    inputs: ["frequency", "q"],
    hasOutput: true,
    hasInput: true
  },
  Gain: {
    initParams: { gain: 1.0 },
    inputs: ["gain"],
    hasOutput: true,
    hasInput: true
  },
  ADSR: {
    initParams: { attack: 0.1, decay: 0.2, sustain: 0.5, release: 0.5 },
    inputs: [],
    hasOutput: true,
    hasInput: false
  },
  Destination: {
    initParams: {},
    inputs: [],
    hasOutput: false,
    hasInput: true,
    isSpecial: true
  }
};

class ModularEditor {
  constructor(containerId, App) {
    this.container = d3.select(containerId);
    this.App = App;
    this.nodes = [];
    this.connections = [];
    this.svg = null;
    this.initSVG();
    this.loadDefaultPatch();
  }

  initSVG() {
    this.container.selectAll("*").remove();
    const width = this.container.node().clientWidth;
    const height = this.container.node().clientHeight;

    this.svg = this.container.append("svg")
      .attr("width", "100%")
      .attr("height", "100%");

    // Arrow marker for connections
    this.svg.append("defs").append("marker")
      .attr("id", "arrowhead")
      .attr("viewBox", "0 -5 10 10")
      .attr("refX", 8)
      .attr("refY", 0)
      .attr("orient", "auto")
      .attr("markerWidth", 6)
      .attr("markerHeight", 6)
      .append("path")
      .attr("class", "arrowhead-path")
      .attr("d", "M0,-5L10,0L0,5");

    this.edgeGroup = this.svg.append("g").attr("class", "edges");
    this.nodeGroup = this.svg.append("g").attr("class", "nodes");

    // Auto Layout Button
    this.container.append("button")
      .text("Auto Layout")
      .attr("class", "auto-layout-btn")
      .on("click", () => this.autoLayout());

    // Drag line for creating new connections
    this.dragLine = this.svg.append("line")
      .attr("class", "drag-line"); // Let events pass through to target ports

    this.svg.on("mousemove", (e) => this.onMouseMove(e))
            .on("mouseup", () => this.onMouseUp())
            .on("click", (e) => {
              if (e.target.tagName === 'svg') this.select(null);
              this.hideContextMenu();
            })
            .on("contextmenu", (e) => {
               e.preventDefault();
               const [x, y] = d3.pointer(e);
               this.showContextMenu(e.pageX, e.pageY, x, y);
            });

    this.createContextMenu();
    this.createParamEditor();
    this.draggingConnection = null;
    this.selected = null; // { type: 'node'|'edge', id: string }

    d3.select("body").on("keydown.modular", (e) => {
       const tag = e.target.tagName.toUpperCase();
       if (tag === "INPUT" || tag === "SELECT" || tag === "TEXTAREA") return;

       if (e.key === "Backspace" || e.key === "Delete") {
         this.deleteSelected();
       }
    });
  }

  createParamEditor() {
    this.paramEditor = d3.select("body").append("div")
      .attr("class", "param-editor")
      .style("display", "none");

    this.paramEditorOverlay = d3.select("body").append("div")
      .attr("class", "param-editor-overlay")
      .style("display", "none")
      .on("click", () => this.hideParamEditor());
  }

  showParamEditor(node) {
    if (node.type === "Destination") return;

    this.paramEditor.html("");
    this.paramEditor.append("h3").text(`Edit Node`);

    // Node ID (Name)
    const idRow = this.paramEditor.append("div").attr("class", "param-editor-row");
    idRow.append("label").text("Node ID: ");
    idRow.append("input")
      .attr("type", "text")
      .attr("value", node.id)
      .on("change", (event) => {
         const newId = event.target.value.trim();
         if (newId && newId !== node.id) {
           // Check for collision
           if (this.nodes.find(n => n.id === newId)) {
             alert("ID already exists!");
             event.target.value = node.id;
             return;
           }
           // Update connections
           this.connections.forEach(c => {
             if (c.from === node.id) c.from = newId;
             if (c.to.split('.')[0] === node.id) {
               c.to = newId + (c.to.includes('.') ? '.' + c.to.split('.')[1] : '');
             }
           });
           node.id = newId;
           this.render();
           this.syncToRuby();
         }
      });

    // Frequency tracking toggle for Oscillators
    if (node.type === "Oscillator") {
      const row = this.paramEditor.append("div").attr("class", "param-editor-row inline");
      row.append("label").text("Keyboard Tracking: ");
      row.append("input")
        .attr("type", "checkbox")
        .property("checked", node.freq_track)
        .on("change", function() {
          node.freq_track = this.checked;
          editor.syncToRuby();
        });
    }

    const typeInfo = NODE_TYPES[node.type];
    Object.keys(typeInfo.initParams).forEach(param => {
      const val = node.params[param];
      const row = this.paramEditor.append("div").attr("class", "param-editor-row");
      row.append("label").text(param + ": ");

      let input;
      if (param === "type" && (node.type === "Oscillator" || node.type === "BiquadFilter")) {
         input = row.append("select")
           .on("change", function() {
              node.params[param] = this.value;
              editor.syncToRuby();
           });

         const options = node.type === "Oscillator" ?
           ["sawtooth", "square", "triangle", "sine"] :
           ["lowpass", "highpass", "bandpass", "notch", "peaking", "allpass", "lowshelf", "highshelf"];

         options.forEach(opt => {
           input.append("option").text(opt).attr("value", opt).property("selected", val === opt);
         });
      } else {
         input = row.append("input")
           .attr("type", typeof val === "number" ? "number" : "text")
           .attr("step", "any")
           .attr("value", val)
           .on("change", function() {
              const newVal = (this.type === "number") ? parseFloat(this.value) : this.value;
              node.params[param] = newVal;
              editor.syncToRuby();
           });
      }
    });

    this.paramEditorOverlay.style("display", "block");
    this.paramEditor.style("display", "block");
    const editor = this;
  }

  hideParamEditor() {
    this.paramEditor.style("display", "none");
    this.paramEditorOverlay.style("display", "none");
  }

  createContextMenu() {
    this.contextMenu = d3.select("body").append("div")
      .attr("class", "context-menu")
      .style("display", "none");
  }

  showContextMenu(pageX, pageY, nodeX, nodeY, item = null) {
    this.contextMenu.html("");

    if (!item) {
      const items = Object.keys(NODE_TYPES).filter(t => t !== "Destination");
      items.forEach(type => {
        this.contextMenu.append("div")
          .text("Add " + type)
          .attr("class", "context-menu-item")
          .on("click", () => {
             this.addNode(type, nodeX, nodeY);
             this.hideContextMenu();
          });
      });
    } else if (item.type === 'node') {
      const node = this.nodes.find(n => n.id === item.id);
      if (node && node.type !== 'Destination') {
        this.contextMenu.append("div")
          .text("Delete Node")
          .attr("class", "context-menu-item delete")
          .on("click", (e) => {
             e.stopPropagation();
             this.select(item);
             this.deleteSelected();
             this.hideContextMenu();
          });
      }
      this.contextMenu.append("div")
        .text("Edit Parameters")
        .attr("class", "context-menu-item")
        .on("click", (e) => {
           e.stopPropagation();
           this.showParamEditor(node);
           this.hideContextMenu();
        });
    } else if (item.type === 'edge') {
      this.contextMenu.append("div")
        .text("Delete Connection")
        .attr("class", "context-menu-item delete")
        .on("click", (e) => {
           e.stopPropagation();
           this.select(item);
           this.deleteSelected();
           this.hideContextMenu();
        });
    }

    this.contextMenu
      .style("left", pageX + "px")
      .style("top", pageY + "px")
      .style("display", "block");
    this.contextMenu.nodeX = nodeX;
    this.contextMenu.nodeY = nodeY;
  }

  hideContextMenu() {
    this.contextMenu.style("display", "none");
  }

  addNode(type, x, y) {
    let baseId = type.toLowerCase();
    let id = baseId;
    let i = 2;
    while (this.nodes.find(n => n.id === id)) {
      id = baseId + i;
      i++;
    }

    const node = {
      id: id,
      type: type,
      x: x,
      y: y,
      params: { ...NODE_TYPES[type].initParams },
      freq_track: (type === "Oscillator") // Default to true for new oscillators
    };
    this.nodes.push(node);
    this.render();
    this.syncToRuby();
  }

  select(item) {
    this.selected = item;
    this.render();
  }

  deleteSelected() {
    if (!this.selected) return;

    if (this.selected.type === "node") {
      // Don't delete Output node
      if (this.selected.id === "out") return;

      this.nodes = this.nodes.filter(n => n.id !== this.selected.id);
      this.connections = this.connections.filter(c => c.from !== this.selected.id && c.to.split('.')[0] !== this.selected.id);
    } else if (this.selected.type === "edge") {
      this.connections = this.connections.filter(c => `${c.from}-${c.to}` !== this.selected.id);
    }

    this.selected = null;
    this.render();
    this.syncToRuby();
  }

  onMouseMove(event) {
    if (!this.draggingConnection) return;
    const [x, y] = d3.pointer(event);
    this.dragLine
      .attr("x2", x)
      .attr("y2", y);
  }

  onMouseUp() {
    if (this.draggingConnection) {
      this.dragLine.style("display", "none");
      this.draggingConnection = null;
    }
  }

  startConnectionDrag(nodeId, x, y) {
    this.draggingConnection = { sourceId: nodeId };
    this.dragLine
      .attr("x1", x)
      .attr("y1", y)
      .attr("x2", x)
      .attr("y2", y)
      .style("display", "block");
  }

    completeConnection(targetId, targetParam) {
      if (!this.draggingConnection) return;

      const sourceId = this.draggingConnection.sourceId;
      if (sourceId === targetId) return; // Prevent self-connection

      // Logic:
      // If targetParam is null, it's the main input -> connect to "targetId"
      // If targetParam is string, it's a param -> connect to "targetId.targetParam"

      const targetKey = targetParam ? `${targetId}.${targetParam}` : targetId;

      // Check if connection already exists
      const exists = this.connections.some(c => c.from === sourceId && c.to === targetKey);

      // Also handle legacy "out" mapping if connecting to Destination
      const targetNode = this.nodes.find(n => n.id === targetId);
      let finalKey = targetKey;
      if (targetNode && targetNode.type === "Destination") {
          finalKey = "out";
      }

      if (!exists) {
        // Remove any existing connection if we are replacing it?
        // Modular synthesizers usually allow multiple cables to one input (mixing)
        // or one output to multiple (splitting).
        // WebAudio params can take multiple connections (summing).
        // So allow multiple.

        this.connections.push({ from: sourceId, to: finalKey });
        this.renderEdges();
        this.syncToRuby();
      }

      this.dragLine.style("display", "none");
      this.draggingConnection = null;
    }
  autoLayout() {
    if (!window.ELK) {
      console.error("ELK.js not loaded");
      return;
    }

    const elk = new ELK();

    const graph = {
      id: "root",
      layoutOptions: {
        'elk.algorithm': 'layered',
        'elk.direction': 'RIGHT',
        'elk.spacing.nodeNode': '40',
        'elk.layered.spacing.nodeNodeBetweenLayers': '60'
      },
      children: this.nodes.map(n => ({
        id: n.id,
        width: 140,
        height: this.getNodeHeight(n)
      })),
      edges: this.connections.map(c => ({
        id: `${c.from}-${c.to}`,
        sources: [c.from],
        targets: [c.to.split('.')[0]]
      }))
    };

    elk.layout(graph).then(layoutedGraph => {
      layoutedGraph.children.forEach(child => {
        const node = this.nodes.find(n => n.id === child.id);
        if (node) {
          node.x = child.x + 50; // Add some padding/offset
          node.y = child.y + 50;
        }
      });
      this.render();
    }).catch(console.error);
  }

  loadDefaultPatch() {
    this.nodes = [
      { id: "vco", type: "Oscillator", x: 50, y: 50, params: { type: "sawtooth" }, freq_track: true },
      { id: "vcf", type: "BiquadFilter", x: 250, y: 50, params: { type: "lowpass", frequency: 2000, q: 1 } },
      { id: "vca", type: "Gain", x: 450, y: 50, params: { gain: 1 } },
      { id: "env", type: "ADSR", x: 450, y: 200, params: { attack: 0.1, decay: 0.2, sustain: 0.5, release: 0.5 } },
      { id: "out", type: "Destination", x: 650, y: 50 }
    ];

    this.connections = [
      { from: "vco", to: "vcf" },
      { from: "vcf", to: "vca" },
      { from: "vca", to: "out" },
      { from: "env", to: "vca.gain" }
    ];

    this.render();
    this.syncToRuby();
  }

  loadPatch(patch) {
    if (!patch || !patch.nodes) return;
    this.nodes = patch.nodes.map(n => ({
        ...n,
        // Ensure x,y exist (if loaded from Ruby export, they might not, so we might need autoLayout)
        x: n.x || 0,
        y: n.y || 0
    }));

    // Check if we need autoLayout (e.g. generated from legacy preset without coords)
    // Do this BEFORE adding the manual 'out' node which has fixed coords.
    const needsLayout = this.nodes.length > 0 && this.nodes.every(n => n.x === 0 && n.y === 0);

    // Ruby export structure might need adjustment to match Editor's expectations
    // Editor uses "Destination" type node for "out". Ruby doesn't have it in nodes list.
    // So we must add "out" node manually if missing.
    if (!this.nodes.find(n => n.id === "out")) {
         this.nodes.push({ id: "out", type: "Destination", x: 600, y: 50 });
    }

    this.connections = patch.connections;
    this.render();

    if (needsLayout) {
        this.autoLayout();
    }
  }

  render() {
    this.renderEdges();
    this.renderNodes();
  }

  renderNodes() {
    const editor = this;
    const nodes = this.nodeGroup.selectAll(".node")
      .data(this.nodes, d => d.id);

    nodes.exit().remove();

    const nodeEnter = nodes.enter().append("g")
      .attr("class", "node")
      .call(d3.drag()
        .on("drag", function(event, d) {
          d.x += event.dx;
          d.y += event.dy;
          d3.select(this).attr("transform", `translate(${d.x},${d.y})`);
          editor.renderEdges();
        })
        .on("end", () => {
          // editor.syncToRuby(); // Optional: sync on drag end
        })
      );

    nodeEnter.append("rect")
      .attr("width", 140)
      .attr("height", d => this.getNodeHeight(d))
      .attr("rx", 5)
      .on("click", function(event, d) {
        event.stopPropagation();
        editor.select({ type: 'node', id: d.id });
      })
      .on("dblclick", function(event, d) {
         event.stopPropagation();
         const node = editor.nodes.find(n => n.id === d.id);
         if (node) editor.showParamEditor(node);
      })
      .on("contextmenu", function(event, d) {
        event.preventDefault();
        event.stopPropagation();
        const [x, y] = d3.pointer(event, editor.svg.node());
        editor.showContextMenu(event.pageX, event.pageY, x, y, { type: 'node', id: d.id });
      });

    nodeEnter.append("text")
      .attr("class", "node-label")
      .attr("x", 10)
      .attr("y", 20)
      .text(d => d.id.toUpperCase());

    nodeEnter.append("text")
      .attr("class", "node-type")
      .attr("x", 10)
      .attr("y", 35)
      .text(d => d.type);

    // Ports
    nodeEnter.each(function(d) {
      const g = d3.select(this);
      const typeInfo = NODE_TYPES[d.type];

            // Output port (on the right)
            if (typeInfo.hasOutput) {
              g.append("circle")
                .attr("class", "port output")
                .attr("cx", 140)
                .attr("cy", 20)
                .attr("r", 6)
                .on("mousedown", function(event) {
                   event.stopPropagation();
                   const [mx, my] = d3.pointer(event, editor.svg.node());
                   editor.startConnectionDrag(d.id, mx, my);
                });
            }

            // Main Audio Input (Cream color)
            if (typeInfo.hasInput) {
              const y = 20; // Aligned with node name
              g.append("circle")
                .attr("class", "port input-main")
                .attr("cx", 0)
                .attr("cy", y)
                .attr("r", 6)
                .on("mouseup", function(event) {
                   event.stopPropagation();
                   editor.completeConnection(d.id, null);
                });
            }

            // Parameter Input ports (Pink color)
            typeInfo.inputs.forEach((input, i) => {
              const y = 55 + i * 20;

              g.append("circle")
                .attr("class", "port input-param")
                .attr("cx", 0)
                .attr("cy", y)
                .attr("r", 6)
                .attr("data-port", input)
                .on("mouseup", function(event) {
                   event.stopPropagation();
                   editor.completeConnection(d.id, input);
                });

              g.append("text")
                .attr("class", "port-label")
                .attr("x", 12)
                .attr("y", y + 4)
                .text(input);
            });
          });

          nodes.merge(nodeEnter)
            .attr("transform", d => `translate(${d.x},${d.y})`)
            .classed("selected", d => (editor.selected && editor.selected.type === 'node' && editor.selected.id === d.id));
        }
  getNodeHeight(d) {
    const typeInfo = NODE_TYPES[d.type];
    if (d.type === "Destination") return 45;
    return 45 + (typeInfo.inputs.length * 20);
  }

    renderEdges() {
      const editor = this;
      const links = this.connections.map(c => {
        const source = this.nodes.find(n => n.id === c.from);

        // Handle simple ID target or ID.param target
        const parts = c.to.split('.');
        const targetId = parts[0];
        const targetParam = parts.length > 1 ? parts[1] : null;

        const target = this.nodes.find(n => n.id === targetId);

        if (!source || !target) return null;

        const typeInfoTarget = NODE_TYPES[target.type];

        let yOffset;
        if (targetParam && targetParam !== "in") { // "in" for legacy destination support
            // Parameter Input
            const inputIdx = typeInfoTarget.inputs.indexOf(targetParam);
            yOffset = 55 + inputIdx * 20;
        } else {
            // Main Audio Input
            yOffset = 20;
        }

        return {
          id: `${c.from}-${c.to}`,
          x1: source.x + 140,
          y1: source.y + 20,
          x2: target.x,
          y2: target.y + yOffset
        };
      }).filter(l => l);
    const edges = this.edgeGroup.selectAll(".edge")
      .data(links, d => d.id);

    edges.exit().remove();

    edges.enter().append("line")
      .attr("class", "edge")
      .attr("marker-end", "url(#arrowhead)")
      .on("click", function(event, d) {
        event.stopPropagation();
        editor.select({ type: 'edge', id: d.id });
      })
      .on("contextmenu", function(event, d) {
        event.preventDefault();
        event.stopPropagation();
        const [x, y] = d3.pointer(event, editor.svg.node());
        editor.showContextMenu(event.pageX, event.pageY, x, y, { type: 'edge', id: d.id });
      })
      .merge(edges)
      .classed("selected", d => (this.selected && this.selected.type === 'edge' && this.selected.id === d.id))
      .attr("x1", d => d.x1)
      .attr("y1", d => d.y1)
      .attr("x2", d => d.x2)
      .attr("y2", d => d.y2);
  }

  syncToRuby() {
    const patch = {
      nodes: this.nodes.filter(n => n.type !== "Destination").map(n => ({
        id: n.id,
        type: n.type,
        params: n.params,
        freq_track: !!n.freq_track
      })),
      connections: this.connections.map(c => ({
        from: c.from,
        to: c.to === "out" ? "out" : c.to
      }))
    };

    const json = JSON.stringify(patch);
    this.App.call("$synth", "import_patch", json);
  }
}

export function setupUI(App) {
  const editor = new ModularEditor("#modular-editor", App);
  window.modularEditor = editor;

  // Effects are still global panels for now
  const effectIds = [
    "delay_time", "delay_feedback", "delay_mix",
    "reverb_seconds", "reverb_mix"
  ];

  effectIds.forEach(id => {
    const el = document.getElementById(id);
    const display = document.getElementById(`val_${id}`);
    if (el) {
      el.addEventListener("input", () => {
        let val = el.value;
        if (id.includes('time') || id.includes('seconds')) val += ' s';
        if (display) display.textContent = val;
        // Use $effect_controller for effects, which might be $previewEffects or $sequencer.effects_chain
        App.call("$effect_controller", `${id}=`, parseFloat(el.value));
      });
    }
  });
}

