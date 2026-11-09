<script lang="ts">
  // The installer's single-line diagram: grid → inverter/charger → loads, battery below.
  // The inverter/charger block is the file drop target and the "choose a file" button.
  interface Props {
    grid: string
    loads: string
    battery: string
    label: string
    dropTitle: string
    dropHint: string
    dropRelease: string
    dropOpening: string
    dragging: boolean
    busy: boolean
    onchoose: () => void
  }
  let { grid, loads, battery, label, dropTitle, dropHint, dropRelease, dropOpening, dragging, busy, onchoose }: Props = $props()

  const title = $derived(busy ? dropOpening : dragging ? dropRelease : dropTitle)
</script>

<div class="diagram" class:dragging>
  <svg class="wiring" viewBox="0 0 1000 300" role="img" aria-label={label}>
    <!-- AC source -->
    <g class="symbol">
      <circle cx="96" cy="123" r="30" />
      <path d="M80 123c5-12 11-12 16 0s11 12 16 0" class="wave" />
    </g>
    <text x="96" y="186" class="part">{grid}</text>

    <!-- AC in: line over neutral -->
    <line x1="126" y1="120" x2="360" y2="120" class="ac-line base" />
    <line x1="126" y1="120" x2="360" y2="120" class="ac-line flow" />
    <line x1="126" y1="126" x2="360" y2="126" class="ac-neutral" />
    <text x="243" y="106" class="value">230 V</text>

    <!-- Product block (drawn for small screens, covered by the button on wide ones) -->
    <rect x="360" y="55" width="280" height="130" rx="6" class="block" />

    <!-- AC out -->
    <line x1="640" y1="120" x2="866" y2="120" class="ac-line base" />
    <line x1="640" y1="120" x2="866" y2="120" class="ac-line flow" />
    <line x1="640" y1="126" x2="866" y2="126" class="ac-neutral" />
    <text x="754" y="106" class="value">230 V</text>

    <!-- Loads: IEC load (lamp) symbol, a crossed circle the size of the grid's -->
    <g class="symbol">
      <circle cx="896" cy="123" r="30" />
      <path d="M874.8 101.8l42.4 42.4M917.2 101.8l-42.4 42.4" />
    </g>
    <text x="896" y="186" class="part">{loads}</text>

    <!-- DC pair to the battery -->
    <line x1="486" y1="185" x2="486" y2="240" class="dc-pos base" />
    <line x1="486" y1="185" x2="486" y2="240" class="dc-pos flow" />
    <line x1="514" y1="185" x2="514" y2="240" class="dc-neg" />
    <circle cx="486" cy="185" r="3.5" class="terminal" />
    <circle cx="514" cy="185" r="3.5" class="terminal" />
    <text x="470" y="219" class="value end">52.0 V</text>

    <!-- Battery: IEC cells -->
    <g class="cells">
      <line x1="456" y1="244" x2="544" y2="244" />
      <line x1="474" y1="254" x2="526" y2="254" class="short" />
      <line x1="456" y1="264" x2="544" y2="264" />
      <line x1="474" y1="274" x2="526" y2="274" class="short" />
    </g>
    <text x="564" y="264" class="part start">{battery} · 48 V</text>
  </svg>

  <button type="button" class="drop" onclick={onchoose} disabled={busy} aria-describedby="drop-hint">
    <svg class="icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M12 15V4M7.5 8.5 12 4l4.5 4.5M5 15v4h14v-4" /></svg>
    <span class="drop-title">{title}</span>
    <span class="drop-hint" id="drop-hint">{dropHint}</span>
  </button>
</div>

<style>
  .diagram {
    position: relative;
    width: 100%;
    max-width: 1000px;
    aspect-ratio: 1000 / 300;
    margin: 0 auto;
  }
  .wiring {
    position: absolute;
    inset: 0;
    width: 100%;
    height: 100%;
    overflow: visible;
  }
  .symbol circle {
    fill: var(--ground);
    stroke: var(--dc-negative);
    stroke-width: 1.8;
  }
  .symbol path {
    fill: none;
    stroke: var(--dc-negative);
    stroke-width: 1.8;
    stroke-linecap: round;
  }
  .part {
    font: 600 15px var(--font-sans);
    fill: var(--ink);
    text-anchor: middle;
  }
  .part.start { text-anchor: start; }
  .value {
    font: 500 14px var(--font-mono);
    fill: var(--muted);
    text-anchor: middle;
  }
  .value.end { text-anchor: end; }

  /* Lit conductors: their own colour at 40 %, a dashed run of full colour travelling along. */
  .ac-line, .dc-pos { stroke-width: 2.5; stroke-linecap: round; fill: none; }
  .ac-line { stroke: var(--ac-line); }
  .dc-pos { stroke: var(--dc-positive); }
  .base { opacity: 0.4; }
  .flow {
    stroke-dasharray: 6 18;
    animation: flow 1s linear infinite;
  }
  .ac-neutral { stroke: var(--ac-neutral); stroke-width: 1.2; }
  .dc-neg { stroke: var(--dc-negative); stroke-width: 2.5; }
  .terminal { fill: var(--dc-negative); }
  .cells line { stroke: var(--dc-negative); stroke-width: 2.5; }
  .cells .short { stroke-width: 4.5; }
  .block { fill: var(--accent); }

  @keyframes flow { to { stroke-dashoffset: -24; } }
  @media (prefers-reduced-motion: reduce) { .flow { animation: none; } }

  .drop {
    position: absolute;
    left: 36%;
    top: 18.333%;
    width: 28%;
    height: 43.333%;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 4px;
    border: 0;
    border-radius: var(--radius-block);
    background: var(--accent);
    color: var(--on-accent);
    font: inherit;
    cursor: pointer;
    outline: 1.5px dashed color-mix(in srgb, var(--on-accent) 45%, transparent);
    outline-offset: -12px;
    transition: transform 0.25s cubic-bezier(0.16, 1, 0.3, 1), background-color 0.2s ease, outline-color 0.2s ease, box-shadow 0.25s ease;
  }
  .drop:hover { background: var(--accent-hover); }
  .drop:focus-visible { box-shadow: var(--focus), 0 0 0 6px var(--ground); }
  .drop:disabled { cursor: progress; }
  .dragging .drop {
    transform: scale(1.04);
    outline-color: var(--on-accent);
    box-shadow: 0 18px 40px -16px color-mix(in srgb, var(--accent) 70%, transparent);
  }
  .icon {
    width: 22px;
    height: 22px;
    fill: none;
    stroke: currentColor;
    stroke-width: 1.8;
    stroke-linecap: round;
    stroke-linejoin: round;
    opacity: 0.9;
  }
  .drop-title { font-size: clamp(14px, 1.6vw, 18px); font-weight: 600; }
  .drop-hint { font-size: clamp(12px, 1.2vw, 14px); color: color-mix(in srgb, var(--on-accent) 78%, transparent); }

  /* Small screens: the drawing stays a picture, the drop target becomes a full-width button below it. */
  @media (max-width: 720px) {
    .diagram { aspect-ratio: auto; display: flex; flex-direction: column; gap: 20px; }
    .wiring { position: static; height: auto; aspect-ratio: 1000 / 300; }
    .part { font-size: 30px; }
    .value { display: none; }
    .drop {
      position: static;
      width: 100%;
      height: auto;
      min-height: 112px;
      padding: 20px;
      outline-offset: -10px;
    }
    .drop-title { font-size: 17px; }
    .drop-hint { font-size: 14px; }
  }
</style>
