<!-- The charge curve (ChargeCurvePaintBox): bulk, absorption and float with the configured voltages. -->
<script lang="ts">
  import type { DeviceConfiguration } from '../../lib/engine/deviceConfiguration'
  import { L, ValueCodec, catalog, formatFixed } from '../../lib/rules'

  let { config, baseline }: { config: DeviceConfiguration; baseline: DeviceConfiguration } = $props()
  let width = $state(560)

  const read = (name: string, c: DeviceConfiguration) => {
    const v = catalog().variables.get(name)
    return v ? ValueCodec.forSetting(v.index)?.display(c) : undefined
  }

  const abs = $derived(read('EPROM_UBatAbs', config))
  const float = $derived(read('EPROM_UBatFloat', config))
  const hours = $derived(read('EPROM_AbsorptionHours', config))
  const absChanged = $derived(abs !== read('EPROM_UBatAbs', baseline))
  const floatChanged = $derived(float !== read('EPROM_UBatFloat', baseline))
  const fixed = $derived(config.raw(10) === 1)
  const volts = (v: number) => formatFixed(v, 2, false) + ' V'

  const shape = $derived.by(() => {
    if (abs === undefined || float === undefined) return undefined
    const w = Math.max(width, 280), h = 132, top = 26, bottom = h - 24
    const lo = Math.min(float, abs) * 0.9, hi = Math.max(abs, float) * 1.01
    const y = (v: number) => bottom - ((v - lo) / (hi - lo)) * (bottom - top)
    const x1 = w * 0.28, x2 = w * 0.62
    const start = lo + (abs - lo) * 0.35
    const path = `M0 ${y(start)} C${x1 * 0.5} ${y(lo + (abs - lo) * 0.7)} ${x1 * 0.8} ${y(abs)} ${x1} ${y(abs)} L${x2} ${y(abs)} L${x2 + 10} ${y(float)} L${w} ${y(float)}`
    const fill = `${path} L${w} ${bottom} L0 ${bottom} Z`
    return { w, h, top, bottom, x1, x2, path, fill, yAbs: y(abs), yFloat: y(float) }
  })
</script>

{#if shape && abs !== undefined && float !== undefined}
  <figure bind:clientWidth={width}>
    <svg width={shape.w} height={shape.h} viewBox="0 0 {shape.w} {shape.h}" role="img"
      aria-label={L('Charge curve: absorption %@ volt, float %@ volt', formatFixed(abs, 2, false), formatFixed(float, 2, false))}>
      <defs>
        <linearGradient id="curve-fill" x1="0" x2="0" y1="0" y2="1">
          <stop offset="0" stop-color="var(--dc-positive)" stop-opacity="0.14" />
          <stop offset="1" stop-color="var(--dc-positive)" stop-opacity="0" />
        </linearGradient>
      </defs>
      <line x1="0" y1={shape.bottom} x2={shape.w} y2={shape.bottom} stroke="var(--line)" />
      {#each [shape.x1, shape.x2] as x (x)}
        <line x1={x} y1={shape.top - 8} x2={x} y2={shape.bottom} stroke="var(--line-strong)" stroke-dasharray="3 3" />
      {/each}
      <path d={shape.fill} fill="url(#curve-fill)" />
      <path d={shape.path} fill="none" stroke="var(--dc-positive)" stroke-width="2.2" stroke-linejoin="round" />
      <text x={(shape.x1 + shape.x2) / 2} y={shape.yAbs - 9} text-anchor="middle" class="v" class:changed={absChanged}>{volts(abs)}</text>
      <text x={(shape.x2 + shape.w) / 2} y={shape.yFloat - 9} text-anchor="middle" class="v" class:changed={floatChanged}>{volts(float)}</text>
      {#if hours !== undefined}
        <text x={(shape.x1 + shape.x2) / 2} y={shape.yAbs + 17} text-anchor="middle" class="h">{fixed ? L('%@ h', formatFixed(hours, 0, false)) : L('max %@ h', formatFixed(hours, 0, false))}</text>
      {/if}
      <text x={shape.x1 / 2} y={shape.h - 6} text-anchor="middle" class="phase">{L('Bulk')}</text>
      <text x={(shape.x1 + shape.x2) / 2} y={shape.h - 6} text-anchor="middle" class="phase">{fixed ? L('Absorption') : L('Absorption (adaptive)')}</text>
      <text x={(shape.x2 + shape.w) / 2} y={shape.h - 6} text-anchor="middle" class="phase">{L('Float')}</text>
    </svg>
  </figure>
{/if}

<style>
  figure { margin: 0; width: 100%; overflow: hidden; }
  svg { display: block; }
  .v { font: 600 12px var(--font-mono); fill: var(--ink); }
  .v.changed { fill: var(--changed); }
  .h { font: 400 11px var(--font-mono); fill: var(--muted); }
  .phase { font: 500 11px var(--font-sans); fill: var(--muted); }
</style>
