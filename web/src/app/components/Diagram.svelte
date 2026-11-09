<!--
  The installation as a single-line diagram (port of SystemDiagram.swift): AC source(s) left, the Multi in the
  centre, loads right, the battery below. A lit conductor keeps its IEC colour (AC line brown + neutral blue,
  DC+ red, DC− ink); unlit ones are grey. Energy flow travels along the lit conductor in its own colour.
  The brand blue belongs to the product block, lit symbols and changed values only.
-->
<script module lang="ts">
  export interface Annotation { text: string; changed: boolean }
</script>

<script lang="ts">
  import { L } from '../../lib/rules'

  interface Props {
    lit: Set<string>
    model: string
    hasSecondInput: boolean
    showsRelay?: boolean
    annotations?: Partial<Record<string, Annotation>>
    height?: number
    decorative?: boolean
  }

  let { lit, model, hasSecondInput, showsRelay = true, annotations = {}, height = 148, decorative = false }: Props = $props()

  let width = $state(900)
  const any = (...parts: string[]) => parts.some((p) => lit.has(p))

  const g = $derived.by(() => {
    const w = Math.max(width, 340)
    const h = height
    const midY = h * 0.42
    const left = Math.max(28, w * 0.06)
    const right = w - left
    const multi = { x: w * 0.5 - 76, y: midY - 28, w: 152, h: 56 }
    const in1 = { x: left + 14, y: hasSecondInput ? midY - 14 : midY }
    const in2 = { x: left + 14, y: midY + 20 }
    const load = { x: right - 14, y: midY }
    const battery = { x: multi.x + multi.w / 2 - 24, y: h - 30, w: 48, h: 16 }
    return { w, h, midY, multi, in1, in2, load, battery }
  })

  const in1Lit = $derived(any('acIn', 'charger', 'feedIn', 'transferSwitch'))
  const in2Lit = $derived(any('acIn2', 'generator'))
  const outLit = $derived(any('acOut', 'inverter'))
  const dcLit = $derived(any('dcBus', 'battery', 'charger', 'inverter'))
  const in1Flow = $derived(lit.has('feedIn') ? -1 : lit.has('charger') ? 1 : 0)
  const outFlow = $derived(lit.has('inverter') ? 1 : 0)
  const dcFlow = $derived(lit.has('charger') ? 1 : any('inverter', 'feedIn') ? -1 : 0)

  const summary = $derived.by(() => {
    const names = [...lit].sort().join(', ')
    let s = L('System diagram of the %@. Highlighted: %@.', model, names.length ? names : L('none'))
    const values = Object.values(annotations).filter((a) => a).map((a) => a!.text).join(', ')
    if (values) s += ' ' + values
    return s
  })

  const cx = $derived(g.multi.x + g.multi.w / 2)
  const my = $derived(g.multi.y + g.multi.h / 2)
  const tx = $derived(g.multi.x + 24)
  const bx = $derived(g.multi.x + g.multi.w - 48)
  const rx = $derived(g.multi.x + g.multi.w - 18)
  const ry = $derived(g.multi.y - 14)
  const batOn = $derived(any('battery', 'charger'))
  const rOn = $derived(lit.has('relay'))
  const terminals = $derived([[g.multi.x, g.in1.y], [g.multi.x + g.multi.w, g.midY], [cx - 10, g.multi.y + g.multi.h], [cx + 10, g.multi.y + g.multi.h], ...(hasSecondInput ? [[g.multi.x, g.in2.y]] : [])] as [number, number][])

  const flowClass = (f: number) => (f > 0 ? 'flow fwd' : f < 0 ? 'flow back' : '')
</script>

<div class="diagram" bind:clientWidth={width} style:height="{height}px">
  <svg
    width={g.w}
    {height}
    viewBox="0 0 {g.w} {height}"
    role={decorative ? undefined : 'img'}
    aria-hidden={decorative ? 'true' : undefined}
    aria-label={decorative ? undefined : summary}
  >
    {#snippet conductor(x1: number, y1: number, x2: number, y2: number, color: string, on: boolean, flow: number, weight = 2.5)}
      {#if !on}
        <line {x1} {y1} {x2} {y2} stroke="var(--unlit)" stroke-width="1.2" />
      {:else if flow === 0}
        <line {x1} {y1} {x2} {y2} stroke={color} stroke-width={weight} />
      {:else}
        <line {x1} {y1} {x2} {y2} stroke={color} stroke-opacity="0.35" stroke-width={weight} />
        <line class={flowClass(flow)} {x1} {y1} {x2} {y2} stroke={color} stroke-width={weight} stroke-linecap="round" stroke-dasharray="6 6" />
      {/if}
    {/snippet}

    {#snippet acPair(x1: number, y: number, x2: number, on: boolean, flow: number)}
      {@render conductor(x1, y, x2, y, 'var(--ac-line)', on, flow)}
      {@render conductor(x1, y + 3.5, x2, y + 3.5, 'var(--ac-neutral)', on, 0, 1.2)}
    {/snippet}

    {#snippet source(x: number, y: number, on: boolean, label: string, generator: boolean)}
      <circle cx={x} cy={y} r="11" fill="var(--ground)" stroke={on ? 'var(--dc-negative)' : 'var(--unlit)'} stroke-width={on ? 1.8 : 1.2} />
      {#if generator}
        <text {x} y={y + 4} text-anchor="middle" class="sym" fill={on ? 'var(--dc-negative)' : 'var(--unlit)'}>G</text>
      {:else}
        <path d="M{x - 6} {y} C{x - 2} {y - 8} {x + 2} {y + 8} {x + 6} {y}" fill="none" stroke={on ? 'var(--dc-negative)' : 'var(--unlit)'} stroke-width="1.4" />
      {/if}
      <text {x} y={y + 25} text-anchor="middle" class="label">{label}</text>
    {/snippet}

    {#snippet note(part: string, x: number, y: number, anchor: 'middle' | 'end' = 'middle')}
      {@const a = annotations[part]}
      {#if a}
        <text {x} {y} text-anchor={anchor} class="value" class:changed={a.changed}>{a.text}</text>
      {/if}
    {/snippet}

    <!-- AC-in 1 (or the single AC input) -->
    {@render source(g.in1.x, g.in1.y, in1Lit, hasSecondInput ? L('AC-in 1') : L('AC in'), false)}
    {@render acPair(g.in1.x + 12, g.in1.y, g.multi.x, in1Lit, in1Flow)}
    {@render note('acIn', (g.in1.x + g.multi.x) / 2, g.in1.y - 9)}
    {#if hasSecondInput}
      {@render source(g.in2.x, g.in2.y, in2Lit, L('AC-in 2'), true)}
      {@render acPair(g.in2.x + 12, g.in2.y, g.multi.x, in2Lit, 0)}
    {/if}

    <!-- AC-out to the loads -->
    {@render acPair(g.multi.x + g.multi.w, g.midY, g.load.x - 11, outLit, outFlow)}
    <circle cx={g.load.x} cy={g.midY} r="11" fill="var(--ground)" stroke={outLit ? 'var(--dc-negative)' : 'var(--unlit)'} stroke-width={outLit ? 1.8 : 1.2} />
    <path d="M{g.load.x - 7.8} {g.midY - 7.8} L{g.load.x + 7.8} {g.midY + 7.8} M{g.load.x + 7.8} {g.midY - 7.8} L{g.load.x - 7.8} {g.midY + 7.8}" stroke={outLit ? 'var(--dc-negative)' : 'var(--unlit)'} stroke-width={outLit ? 1.4 : 1} />
    <text x={g.load.x} y={g.midY + 24} text-anchor="middle" class="label">{L('AC out')}</text>
    {@render note('acOut', (g.multi.x + g.multi.w + g.load.x) / 2, g.midY - 9)}

    <!-- DC pair to the battery -->
    {@render conductor(cx - 10, g.multi.y + g.multi.h, cx - 10, g.battery.y, 'var(--dc-positive)', dcLit, dcFlow)}
    {@render conductor(cx + 10, g.battery.y, cx + 10, g.multi.y + g.multi.h, 'var(--dc-negative)', dcLit, dcFlow)}
    {#each [0, 1, 2] as i (i)}
      {@const x = g.battery.x + 8 + i * 13}
      <line x1={x} y1={g.battery.y} x2={x} y2={g.battery.y + g.battery.h} stroke={batOn ? 'var(--dc-negative)' : 'var(--unlit)'} stroke-width={batOn ? 2 : 1.4} />
      <line x1={x + 5} y1={g.battery.y + 4} x2={x + 5} y2={g.battery.y + g.battery.h - 4} stroke={batOn ? 'var(--dc-negative)' : 'var(--unlit)'} stroke-width={batOn ? 3 : 2} />
    {/each}
    <text x={g.battery.x + g.battery.w + 10} y={g.battery.y + 12} class="label">{L('Battery')}</text>
    {#if g.w >= 600}{@render note('battery', cx - 22, (g.multi.y + g.multi.h + g.battery.y) / 2 + 4, 'end')}{/if}

    <!-- The Multi -->
    <rect x={g.multi.x} y={g.multi.y} width={g.multi.w} height={g.multi.h} rx="6" fill="var(--accent)" />
    <path d="M{tx - 8} {my} L{tx} {my} L{tx + 10} {my - 7} M{tx + 12} {my} L{tx + 20} {my}" fill="none" stroke="var(--on-accent)" stroke-width={lit.has('transferSwitch') ? 2.2 : 1.4} />
    <rect x={bx} y={my - 15} width="30" height="30" rx="2" fill="none" stroke="var(--on-accent)" stroke-width={any('inverter', 'charger') ? 2.2 : 1.4} />
    <line x1={bx} y1={my + 15} x2={bx + 30} y2={my - 15} stroke="var(--on-accent)" stroke-width={any('inverter', 'charger') ? 2.2 : 1.4} />
    <text x={bx + 8} y={my - 3} text-anchor="middle" class="sym on">~</text>
    <text x={bx + 22} y={my + 12} text-anchor="middle" class="sym on">=</text>
    <text x={g.multi.x} y={g.multi.y - 6} class="model">{model}</text>
    {#each terminals as [px, py], i (i)}
      <circle cx={px} cy={py} r="2.5" fill="var(--dc-negative)" />
    {/each}

    {#if showsRelay}
      <path d="M{rx - 10} {ry} L{rx - 3} {ry} L{rx + 5} {ry - 6} M{rx + 4} {ry} L{rx + 10} {ry} M{rx} {ry + 2} L{rx} {ry + 14}" fill="none" stroke={rOn ? 'var(--accent)' : 'var(--unlit)'} stroke-width={rOn ? 2 : 1.2} />
      {#if rOn}<text x={rx + 16} y={ry + 4} class="label relay">{L('Relay')}</text>{/if}
    {/if}
  </svg>
</div>

<style>
  .diagram {
    position: relative;
    width: 100%;
    overflow: hidden;
    background-color: var(--ground);
    background-image: linear-gradient(var(--ground-grid) 1px, transparent 1px), linear-gradient(90deg, var(--ground-grid) 1px, transparent 1px);
    background-size: 16px 16px;
  }
  svg { display: block; }
  .label { font: 500 10.5px var(--font-sans); fill: var(--muted); }
  .label.relay { fill: var(--accent); }
  .model { font: 600 11px var(--font-sans); fill: var(--ink); }
  .value { font: 500 10.5px var(--font-mono); fill: var(--muted); }
  .value.changed { font-weight: 600; fill: var(--changed); }
  .sym { font: 700 11px var(--font-sans); }
  .sym.on { fill: var(--on-accent); }
  .flow { animation: flow 0.9s linear infinite; }
  .flow.back { animation-direction: reverse; }
  @keyframes flow { to { stroke-dashoffset: -24; } }
  @media (prefers-reduced-motion: reduce) { .flow { animation: none; } }
</style>
