<script lang="ts">
  // A faithful static rendition of the editor on the Charger tab, for the landing page.
  import type { LandingKey } from '../lib/i18n/landing'

  interface Props {
    t: (key: LandingKey) => string
    decimal: string
  }
  let { t, decimal }: Props = $props()

  const n = (s: string) => s.replace('.', decimal)
  const tabs: LandingKey[] = ['pvGeneral', 'pvGrid', 'pvInverter', 'pvCharger', 'pvVirtualSwitch', 'pvAssistants', 'pvAdvanced']
</script>

<figure class="window" aria-label={t('pvCharger')}>
  <div class="chrome" aria-hidden="true">
    <span class="dot"></span><span class="dot"></span><span class="dot"></span>
    <span class="file">home-2026-11.rvsc</span>
  </div>
  <div class="body">
    <nav class="side" aria-hidden="true">
      {#each tabs as tab (tab)}
        <span class:current={tab === 'pvCharger'}>{t(tab)}</span>
      {/each}
    </nav>

    <div class="content">
      <div class="strip" aria-hidden="true">
        <svg viewBox="0 0 560 96">
          <line x1="20" y1="40" x2="200" y2="40" class="unlit" />
          <rect x="200" y="18" width="140" height="44" rx="6" class="block" />
          <text x="270" y="45" class="block-label">MultiPlus-II</text>
          <line x1="340" y1="40" x2="520" y2="40" class="unlit" />
          <line x1="262" y1="62" x2="262" y2="84" class="dc-pos" />
          <line x1="278" y1="62" x2="278" y2="84" class="dc-neg" />
          <line x1="250" y1="86" x2="290" y2="86" class="cell" />
          <line x1="258" y1="91" x2="282" y2="91" class="cell short" />
          <text x="300" y="80" class="annot">{n('52.0')} · {n('51.0')} V</text>
        </svg>
      </div>

      <div class="curve">
        <svg viewBox="0 0 520 120" role="img" aria-label={t('pvCurveLabel')}>
          <line x1="10" y1="100" x2="510" y2="100" class="axis" />
          <path d="M10 88 C80 60 130 26 160 22 L320 22 C338 22 348 38 366 38 L510 38" class="volt" />
          <path d="M10 28 L160 28 C214 44 280 86 320 92 L510 95" class="amp" />
          <text x="166" y="15" class="tag">{n('52.0')} V</text>
          <text x="372" y="31" class="tag">{n('51.0')} V</text>
          <text x="85" y="116" class="phase">{t('pvBulk')}</text>
          <text x="240" y="116" class="phase">{t('pvAbsorptionPhase')}</text>
          <text x="440" y="116" class="phase">{t('pvFloatPhase')}</text>
        </svg>
      </div>

      <dl class="rows">
        <div class="row">
          <dt>{t('pvAbsorption')} <span class="changed-tag">{t('pvChanged')}</span></dt>
          <dd><span class="cell-value changed">{n('52.0')}</span><span class="unit">V</span></dd>
        </div>
        <div class="row">
          <dt>{t('pvFloat')}</dt>
          <dd><span class="cell-value">{n('51.0')}</span><span class="unit">V</span></dd>
        </div>
        <div class="row">
          <dt>{t('pvChargeCurrent')} <span class="changed-tag">{t('pvChanged')}</span></dt>
          <dd><span class="cell-value changed">70</span><span class="unit">A</span></dd>
        </div>
      </dl>
    </div>

    <aside class="changes" aria-hidden="true">
      <div class="changes-head"><span>{t('pvChanges')}</span><span class="count">3</span></div>
      <div class="change"><span>{t('pvAbsorption')}</span><span class="diff"><s>{n('51.2')}</s> → <b>{n('52.0')} V</b></span></div>
      <div class="change"><span>{t('pvChargeCurrent')}</span><span class="diff"><s>50</s> → <b>70 A</b></span></div>
      <div class="change"><span>{t('pvEssCapacity')}</span><span class="diff"><s>96</s> → <b>200 Ah</b></span></div>
      <span class="save">{t('pvSave')}</span>
    </aside>
  </div>
</figure>

<style>
  .window {
    margin: 0;
    border: 1px solid var(--line-strong);
    border-radius: 12px;
    background: var(--surface);
    overflow: hidden;
    box-shadow: 0 30px 60px -30px rgba(20, 24, 29, 0.35), 0 2px 6px -2px rgba(20, 24, 29, 0.08);
  }
  .chrome {
    height: 40px;
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 0 16px;
    border-bottom: 1px solid var(--line);
    background: var(--surface-sunken);
  }
  .dot { width: 11px; height: 11px; border-radius: 50%; background: var(--line-strong); }
  .file { margin-left: 14px; font: 12px var(--font-mono); color: var(--muted); }
  .body { display: flex; flex-wrap: wrap; }
  @media (min-width: 861px) { .body { min-height: 420px; } }

  .side {
    flex: 0 0 188px;
    padding: 16px 10px;
    display: flex;
    flex-direction: column;
    gap: 2px;
    border-right: 1px solid var(--line);
    background: var(--surface-sunken);
    font-size: 13px;
  }
  .side span { padding: 7px 10px; border-radius: 6px; color: var(--ink-2); }
  .side .current { background: var(--accent-soft); color: var(--accent); font-weight: 600; }

  .content { flex: 999 1 380px; min-width: 0; display: flex; flex-direction: column; }
  .strip {
    height: 112px;
    padding: 8px 24px;
    border-bottom: 1px solid var(--line);
    background-color: var(--ground);
    background-image: linear-gradient(var(--ground-grid) 1px, transparent 1px), linear-gradient(90deg, var(--ground-grid) 1px, transparent 1px);
    background-size: 16px 16px;
  }
  .strip svg { width: 100%; height: 100%; }
  .unlit { stroke: var(--unlit); stroke-width: 1.2; }
  .block { fill: var(--accent); }
  .block-label { font: 600 12px var(--font-sans); fill: var(--on-accent); text-anchor: middle; }
  .dc-pos { stroke: var(--dc-positive); stroke-width: 2.5; }
  .dc-neg { stroke: var(--dc-negative); stroke-width: 2.5; }
  .cell { stroke: var(--dc-negative); stroke-width: 2; }
  .cell.short { stroke-width: 3.5; }
  .annot { font: 600 11px var(--font-sans); fill: var(--accent); font-variant-numeric: tabular-nums; }

  .curve { padding: 20px 24px 4px; }
  .curve svg { width: 100%; height: auto; display: block; }
  .axis { stroke: var(--line); }
  .volt { fill: none; stroke: var(--dc-positive); stroke-width: 2.2; }
  .amp { fill: none; stroke: var(--muted); stroke-width: 1.4; stroke-dasharray: 4 4; }
  .tag { font: 600 11px var(--font-sans); fill: var(--ink); font-variant-numeric: tabular-nums; }
  .phase { font: 11px var(--font-sans); fill: var(--muted); text-anchor: middle; }

  .rows { margin: 8px 24px 24px; }
  .row {
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 12px;
    padding: 11px 0;
    border-top: 1px solid var(--line-faint);
  }
  dt { font-size: 14px; display: flex; align-items: baseline; gap: 8px; flex-wrap: wrap; }
  dd { margin: 0; display: flex; align-items: baseline; }
  .changed-tag { font-size: 11px; color: var(--accent); font-weight: 600; }
  .cell-value { width: 64px; text-align: right; font: 14px var(--font-sans); font-variant-numeric: tabular-nums; }
  .cell-value.changed { color: var(--accent); font-weight: 600; }
  .unit { width: 28px; padding-left: 8px; font-size: 13px; color: var(--muted); }

  .changes {
    flex: 1 1 230px;
    max-width: 270px;
    padding: 18px 16px;
    border-left: 1px solid var(--line);
    display: flex;
    flex-direction: column;
    gap: 14px;
    font-size: 13px;
  }
  .changes-head { display: flex; justify-content: space-between; font-weight: 700; }
  .count { color: var(--accent); font-variant-numeric: tabular-nums; }
  .change { display: flex; flex-direction: column; gap: 2px; }
  .diff { font-size: 12px; color: var(--muted); font-variant-numeric: tabular-nums; }
  .diff s { text-decoration-color: var(--muted); }
  .diff b { color: var(--accent); font-weight: 600; }
  .save {
    margin-top: auto;
    height: 36px;
    display: flex;
    align-items: center;
    justify-content: center;
    border-radius: 6px;
    background: var(--accent);
    color: var(--on-accent);
    font-weight: 600;
  }

  @media (max-width: 860px) {
    .side, .changes { display: none; }
  }
</style>
