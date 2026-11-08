<!-- VE Configure's battery type dialog (TBatteryDefaultForm): presets in this system's voltage. -->
<script lang="ts">
  import { BatteryPresets, L, ValueCodec, catalog, catalogText, dcVoltageClass, type BatteryPreset, type VariableRef } from '../../lib/rules'
  import { editor } from '../store.svelte'
  import Dialog from './Dialog.svelte'

  let { onclose }: { onclose: () => void } = $props()

  const c = $derived((editor.rev, editor.doc!.config))
  const presets = catalog().batteryPresets
  const current = $derived(BatteryPresets.matching(c))
  let chosen = $state<string | undefined>(undefined)
  const selected = $derived(presets.find((p) => p.id === (chosen ?? current?.id)) ?? presets[0])

  function label(name: string, ref: VariableRef): string {
    return (ref.kind === 'flag' ? catalog().labelFlag(ref.index) : catalog().label(ref.index)) ?? name
  }

  function valueText(p: BatteryPreset, name: string, ref: VariableRef): string {
    const v = BatteryPresets.value(p, name, c)
    if (v === undefined) return L('unchanged')
    if (ref.kind === 'flag') return v !== 0 ? L('On') : L('Off')
    if (name === 'EPROM_ChargeCharacteristic') {
      const t = ({ 1: 'Fixed', 2: 'Adaptive', 3: 'Adaptive + BatterySafe' } as Record<number, string>)[v]
      return t ? catalogText(t) : String(v)
    }
    if (name === 'EPROM_TBatStopCharge' && v <= -20.5) return L('Off')
    const k = ValueCodec.forSetting(ref.index)
    const unit = catalog().settingControls.get(ref.index)?.unit
    const u = unit ? (unit === 'Hr' ? ' h' : ' ' + catalogText(unit)) : ''
    return (k ? k.format(v, c) : String(v)) + u
  }

  const rows = $derived.by(() => {
    if (!selected) return []
    const out: { label: string; value: string }[] = []
    for (const name of BatteryPresets.order) {
      const ref = catalog().variables.get(name)
      if (!ref) continue
      if (ref.kind === 'flag' ? !c.supportsFlag(ref.index) : !c.info.info(ref.index)?.isSupported) continue
      out.push({ label: label(name, ref), value: valueText(selected, name, ref) })
    }
    return out
  })

  function apply() {
    if (!selected) return
    onclose()
    editor.doc?.applyBatteryPreset(selected)
  }
</script>

<Dialog title={L('Battery Presets')} width={720} oncancel={onclose} initialFocus="[aria-selected='true']">
  <p class="lead">{L('Sets the charger for a battery type in one step. Values shown are for this %@ V system. The preset is not stored in the device; every value stays editable afterwards.', String(dcVoltageClass(c)))}</p>
  <div class="cols">
    <div class="list" role="listbox" aria-label={L('Battery type')}>
      {#each presets as p (p.id)}
        <button type="button" role="option" aria-selected={p.id === selected?.id} onclick={() => (chosen = p.id)}>
          <span>{catalogText(p.name)}</span>
          {#if p.id === current?.id}<span class="current">{L('current')}</span>{/if}
        </button>
      {/each}
    </div>
    <dl>
      {#each rows as r (r.label)}
        <dt>{r.label}</dt>
        <dd>{r.value}</dd>
      {/each}
    </dl>
  </div>
  {#snippet footer()}
    <button type="button" class="btn" onclick={onclose}>{L('Cancel')}</button>
    <button type="button" class="btn primary" disabled={!selected} onclick={apply}>{L('Apply')}</button>
  {/snippet}
</Dialog>

<style>
  .lead { margin: 0 0 16px; font-size: 13px; color: var(--muted); }
  .cols { display: flex; flex-wrap: wrap; gap: 18px; }
  .list { flex: 1 1 240px; max-width: 300px; max-height: 340px; overflow: auto; display: flex; flex-direction: column; gap: 2px; padding: 4px; border: 1px solid var(--line); border-radius: var(--radius-panel); background: var(--surface-sunken); }
  .list button { display: flex; justify-content: space-between; align-items: center; gap: 8px; padding: 8px 10px; border: 0; border-radius: 6px; background: none; text-align: left; font: 13.5px var(--font-sans); color: var(--ink); cursor: pointer; }
  .list button:hover { background: var(--line-faint); }
  .list button[aria-selected='true'] { background: var(--accent); color: var(--on-accent); }
  .current { font-size: 11px; font-weight: 600; color: var(--changed); }
  [aria-selected='true'] .current { color: var(--on-accent-muted); }
  dl { flex: 2 1 300px; display: grid; grid-template-columns: minmax(0, 1fr) auto; gap: 7px 16px; margin: 0; align-content: start; font-size: 13px; }
  dt { color: var(--muted); }
  dd { margin: 0; font-family: var(--font-mono); font-size: 12.5px; color: var(--ink); text-align: right; font-variant-numeric: tabular-nums; }
</style>
