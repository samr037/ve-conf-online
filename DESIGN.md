---
name: VE Configure for Mac
description: A native Mac instrument for configuring Victron VE.Bus inverter/chargers, drawn as the installation's own single-line diagram.
colors:
  victron-blue: "#1B5FAA"
  victron-blue-dark: "#5B9BE6"
  victron-block: "#1B5FAA"
  victron-block-dark: "#2B62A6"
  dc-positive-red: "#D7262E"
  dc-positive-red-dark: "#F2575E"
  dc-negative-ink: "#1D2126"
  dc-negative-ink-dark: "#C9CED6"
  ac-line-brown: "#8A5A2B"
  ac-line-brown-dark: "#C48A52"
  ac-neutral-blue: "#3A78C2"
  ac-neutral-blue-dark: "#6FA3E0"
  unlit-wire: "#B9C0C9"
  unlit-wire-dark: "#4A525C"
  drafting-ground: "#F7F9FB"
  drafting-ground-dark: "#16191D"
  drafting-grid: "#E6EBF0"
  drafting-grid-dark: "#22272D"
  non-default-slate: "#5B6570"
  non-default-slate-dark: "#9AA4AF"
  warning-amber: "#B4531F"
  warning-amber-dark: "#F0A35E"
typography:
  display:
    fontFamily: "SF Pro, -apple-system, system-ui"
    fontSize: "26pt"
    fontWeight: 600
  headline:
    fontFamily: "SF Pro, -apple-system, system-ui"
    fontSize: "17pt"
    fontWeight: 600
  title:
    fontFamily: "SF Pro, -apple-system, system-ui"
    fontSize: "13pt"
    fontWeight: 700
  body:
    fontFamily: "SF Pro, -apple-system, system-ui"
    fontSize: "13pt"
    fontWeight: 400
  value:
    fontFamily: "SF Pro, -apple-system, system-ui"
    fontSize: "13pt"
    fontWeight: 400
    fontFeature: "\"tnum\" 1"
  callout:
    fontFamily: "SF Pro, -apple-system, system-ui"
    fontSize: "12pt"
    fontWeight: 400
  label:
    fontFamily: "SF Pro, -apple-system, system-ui"
    fontSize: "10pt"
    fontWeight: 400
    fontFeature: "\"tnum\" 1"
  diagram-label:
    fontFamily: "SF Pro, -apple-system, system-ui"
    fontSize: "10pt"
    fontWeight: 500
rounded:
  symbol: "2pt"
  block: "6pt"
  panel: "8pt"
spacing:
  hair: "2pt"
  tight: "6pt"
  row: "10pt"
  inspector: "14pt"
  grid: "16pt"
  sheet: "24pt"
  welcome: "28pt"
components:
  diagram-strip:
    backgroundColor: "{colors.drafting-ground}"
    height: "132pt"
  product-block:
    backgroundColor: "{colors.victron-block}"
    textColor: "#FFFFFF"
    rounded: "{rounded.block}"
    width: "140pt"
    height: "52pt"
  diagram-annotation:
    typography: "{typography.diagram-label}"
  diagram-annotation-changed:
    textColor: "{colors.victron-blue}"
    typography: "{typography.diagram-label}"
  value-cell:
    typography: "{typography.value}"
    width: "84pt"
  value-cell-changed:
    textColor: "{colors.victron-blue}"
    typography: "{typography.value}"
    width: "84pt"
  unit-column:
    width: "44pt"
  change-list:
    width: "270pt"
    padding: "{spacing.inspector}"
  change-list-after:
    textColor: "{colors.victron-blue}"
    typography: "{typography.label}"
  wizard-sheet:
    width: "600pt"
    height: "500pt"
    padding: "{spacing.sheet}"
  wizard-entry-panel:
    backgroundColor: "{colors.drafting-ground}"
    rounded: "{rounded.panel}"
    padding: "{spacing.inspector}"
  wizard-footer:
    typography: "{typography.label}"
    padding: "{spacing.grid}"
  memory-bar:
    backgroundColor: "{colors.drafting-grid}"
    height: "6pt"
  welcome-window:
    width: "640pt"
    height: "420pt"
---

# Design System: VE Configure for Mac

## Overview

**Creative North Star: "The Installer's Single-Line Diagram"**

The app is a native macOS instrument whose spine is a drawing of the user's own installation, in the manner of the single-line diagrams in Victron's manuals: AC source(s) on the left, the Multi in the centre, AC-out loads on the right, the battery below. Every page lights the conductors it governs, and the key values are written on the wire they act on. Below the drawing, everything else is stock macOS: a sidebar, a grouped Form, an inspector, sheets, menus. The diagram carries the identity; the controls carry the platform.

Colour is functional, never decorative. Each hue has one job taken from electrical drafting (IEC conductor colours) or from the product (Victron blue for the product block and for what the user changed). Values are set in tabular figures in fixed cells so numbers never shift their row. Density is that of a professional settings pane: one setting per row, label left, value cell right, an ⓘ explanation at the trailing edge.

The diagram never invents equipment: PV is not drawn because a configuration file carries no evidence of it, and the second AC input appears only when the device has one.

**Key Characteristics:**
- A 132 pt drafting strip with a 16 pt grid heads every settings page.
- IEC conductor colours with jobs; unlit wires are grey.
- Victron blue is reserved for the product block, the lit relay, changed values and the change count.
- Native SwiftUI/AppKit controls everywhere outside the diagram; system accent for selection and the prominent button.
- SF Pro throughout; every value in monospaced digits.
- Light and dark appearances are defined as explicit pairs for every custom colour.

## Colors

A drafting palette: pale ground, grey ink for what is idle, the conductor's own IEC colour for what is lit, one product blue for the device and for change. Every custom colour is a light/dark pair resolved per appearance (light value first, dark value second in the frontmatter).

### Primary
- **Victron Blue** (`victron-blue` / `victron-blue-dark`): the change colour. Changed values in value cells, the "changed" tag beside a label, the new value in the change list, the change count in the inspector header, changed diagram annotations, the lit relay symbol and its label, the wizard's selected radio, the welcome step numerals and the memory bar fill.
- **Product Block Blue** (`victron-block` / `victron-block-dark`): fills the Multi block in the diagram. Identical to Victron Blue in light mode; deeper in dark mode so the block's white internal symbols keep at least 4.5:1.

### Secondary (conductor colours, diagram only)
- **DC Positive Red** (`dc-positive-red`): the lit DC+ conductor, and the absorption/float curve in the charge-curve chart.
- **DC Negative Ink** (`dc-negative-ink`): the lit DC− conductor, terminal dots on the Multi, and the outline ink of lit symbols (AC source, load, battery). In dark mode it inverts to a pale grey so it stays ink on the dark ground.
- **AC Line Brown** (`ac-line-brown`): the AC line conductor; always drawn with its neutral.
- **AC Neutral Blue** (`ac-neutral-blue`): the AC neutral, 3.5 pt below the line at a lighter 1.2 pt weight.

### Tertiary (status)
- **Warning Amber** (`warning-amber`): warning triangles on inline captions, wizard errors, the assistant memory bar past 90 %.
- **Non-Default Slate** (`non-default-slate`): the reset-required marker beside a label. Informative, never alarming.

### Neutral
- **Drafting Ground** (`drafting-ground`): behind the diagram strip, behind symbols (so they mask wires), and behind the wizard's numeric entry panel.
- **Drafting Grid** (`drafting-grid`): the 0.5 pt, 16 pt-pitch grid in the diagram, the welcome diagram's hairline frame, the empty track of the memory bar.
- **Unlit Wire** (`unlit-wire`): idle conductors and idle symbols, 1.2 pt.
- Everything else is the system's semantic colours: window background, `.primary`, `.secondary`, `.tertiary`, separators.

### Named Rules
**The Every-Colour-Has-A-Job Rule.** A custom colour appears only in the role listed above. No colour is introduced for decoration, branding surfaces or emphasis.

**The Lit-Path Rule.** A conductor is either lit (its own IEC colour at full weight, 2.5 pt) or unlit (grey, 1.2 pt). Energy flow is the conductor's colour at 40 % with a dashed run of its full colour travelling along it; it never borrows another hue.

**The Blue-Means-Changed Rule.** Outside the product block and the relay, Victron Blue means "differs from the loaded file". Never use it for headings, links or general emphasis. Changed state is always doubled by text (the "changed" tag, the strikethrough old value), never colour alone.

## Typography

**Display Font:** SF Pro (system)
**Body Font:** SF Pro (system)
**Label/Mono Font:** SF Pro with monospaced digits (`.monospacedDigit()`); no separate mono face except the `.caption.monospaced()` control identifier at the foot of the ⓘ popover.

**Character:** One platform face doing instrument work. Hierarchy comes from the macOS text styles, not from a second family; figures are tabular wherever a number is shown.

### Hierarchy
- **Display** (semibold, 26 pt): the app name on the welcome window only.
- **Headline** (semibold, `.title2`, 17 pt): the wizard step title.
- **Title** (`.headline`, 13 pt bold): inspector "Changes", device model in the sidebar, sheet and popover titles, assistant names.
- **Body** (13 pt): setting labels, wizard prose.
- **Value** (13 pt, tabular figures): every editable number, right-aligned in its fixed cell.
- **Callout** (12 pt): change-list setting names, inline captions, popover text, welcome steps.
- **Label** (`.caption` 10 pt, tabular figures): device identity, change-list old → new values, wizard progress, footnotes.
- **Diagram Label** (10 pt medium; semibold when a changed annotation): part names and annotations drawn on the canvas.

### Named Rules
**The Tabular Figures Rule.** Any number a user reads or edits (values, serial, firmware, change list, progress, byte counts, annotations) is set with monospaced digits so a changing value never moves its row.

## Layout

Three-column `NavigationSplitView`: sidebar 200–280 pt (ideal 220) with device identity (model, serial, firmware, read date) as the list header and the seven tabs below it in VE Configure's order; content column; trailing inspector 240–360 pt (ideal 270) holding the change list. The content column stacks the 132 pt diagram strip, a divider, an optional centred segmented sub-page picker (8 pt vertical padding), then the grouped Form. Commands live in the macOS menus; the toolbar carries only the Changes toggle.

Spacing rhythm is small and native: 6 pt between a row's inline parts, 10 pt between radio or check options, 14 pt inspector and panel padding, 16 pt sheet footers and the drafting grid pitch, 24 pt wizard content inset, 28 pt welcome inset. Sheets are fixed-size: wizard 600 × 500 pt, grid code password 420 pt wide, battery presets 680 pt wide, ⓘ popover 380 pt wide (max 460 pt tall). The welcome window is 640 × 420 pt: a 360 pt left pane with a diagram, title and Open button, divider, then the four steps and recent files.

## Elevation & Depth

Flat. The app adds no shadows of its own; depth is the system's: sidebar and inspector materials, grouped Form insets, sheets and popovers. Within the diagram, symbols are filled with the drafting ground so they sit on top of wires; that masking is the only layering.

The app icon (`scripts/make-icon.swift`) is the exception allowed by macOS icon convention: a blue gradient tile with a soft drop shadow carrying the diagram's symbols in white and one red DC+ stroke.

### Named Rules
**The Flat-Instrument Rule.** No custom shadows, glows or blurs in the window. Separation is a Divider or a system container.

## Shapes

Drafting geometry: thin uniform strokes (0.5 pt grid, 1.2 pt unlit, 1.8 pt lit symbol outline, 2.5 pt lit conductor), circles for AC sources (11 pt radius, wave or "G" inside), a crossed 24 × 18 pt box for loads, IEC cell bars for the battery, 5 pt terminal dots. Corners are nearly square: 2 pt on load and converter symbols, 6 pt on the product block, 8 pt on the two framed panels (welcome diagram, wizard entry panel). Capsules only for the memory bar. Native controls keep their own shapes.

## Components

### Buttons
- **Shape:** system bezel shapes; no custom button styles beyond the system set.
- **Primary:** `.borderedProminent`, `.large`, full width: "Save…" at the foot of the change list (disabled with no changes, ⌘S) and "Open Configuration…" on the welcome window (⌘O). Both use the system accent.
- **Sheet actions:** default bordered buttons, trailing; Cancel bound to Esc, the forward action to Return.
- **Borderless:** the ⓘ info button and the toolbar Changes toggle.

### Inputs / Fields (setting rows)
Character: one setting per row, every row aligned on the same trailing edge.
- **Container:** native grouped Form (`.formStyle(.grouped)`), `LabeledContent` per row.
- **Label column:** setting name, then optional lock glyph (password-protected), reset arrow in Non-Default Slate, and a `caption2` "changed" tag in Victron Blue.
- **Numeric row:** value cell 84 pt, right-aligned, tabular figures (Victron Blue when changed), then a stepper, then a 44 pt unit column (leading-aligned, scales to 0.8), then the ⓘ button.
- **Choice row:** menu picker, then a 44 pt clear spacer so the ⓘ lines up with numeric rows. Small option sets render as radios under the label, indented 9 pt.
- **Toggle row:** switch-style toggle, then ⓘ.
- **Disabled:** whole row at 55 % opacity.
- **ⓘ popover:** 380 pt wide, 16 pt inset: title, description, range and default (ruler symbol), help text, reset and password notes, control identifier in tertiary mono caption.
- **Restore:** every row has a context menu to restore its loaded value.

### Change List (inspector)
- Header: "Changes" (headline) with the count right-aligned in Victron Blue (secondary "None" when empty), 14 × 10 pt padding.
- Rows: setting name in callout; old value struck through in secondary, a tertiary arrow, new value in Victron Blue medium, all caption with tabular figures. Context menu restores the loaded value.
- Empty state: "No changes yet" plus a one-sentence explanation, centred, 200 pt max width.
- Footer: a caption reminding the upload path through VRM, then the full-width prominent Save… button, 14 pt padding.

### Wizard Sheet
- Fixed 600 × 500 pt on the window background. Header: step title in title2 semibold, 24 pt sides, 20 pt top, 14 pt bottom, divider.
- Body scrolls, 24 pt inset, 14 pt between paragraphs, the assistant's own words. Radios use a circle / filled-circle glyph, Victron Blue when selected; checks are native checkboxes; numeric entries sit in a Drafting Ground panel (8 pt radius, 14 pt padding) with 90 pt tabular value fields whose tooltip gives range and default.
- Footer after a divider, 16 pt padding: progress ("Energy Storage System · Step 6 of 8") in caption tabular secondary on the left; Cancel, Previous, Next on the right.

### Navigation
- Sidebar list with SF Symbols per tab, system selection highlight. Device identity header in caption tabular secondary with the model in headline primary.
- Sub-pages (Grid codes, Virtual switch sheets) use a centred segmented control above the Form.

### System Diagram (signature component)
- 132 pt strip on Drafting Ground with the 16 pt grid. Multi block 140 × 52 pt centred at 36 % height, model name above it at 10 pt semibold; transfer switch and ~/= converter drawn inside in white, thickened to 2.2 pt when lit.
- AC is always a pair (brown line over blue neutral). DC is a red/ink pair down to the battery. Programmable relay above the block's right edge, Victron Blue only when lit.
- Lit set follows the page, and follows the hovered Form group while the pointer is over it.
- Annotations: AC-in current limit on the AC-in conductor, AC-out voltage on the AC-out conductor, "Absorption · Float" against the DC pair; secondary when unchanged, Victron Blue semibold when changed.
- Motion: dashed flow at 24 pt/s along lit conductors when charger, inverter or feed-in is lit, 30 fps cap; fully static under Reduce Motion.
- Accessibility: one element summarising model, highlighted parts and annotated values.

### Assistant Memory Bar
6 pt capsule: Drafting Grid track, Victron Blue fill, Warning Amber past 90 %, with the byte count in tabular figures above it.

## Do's and Don'ts

### Do:
- **Do** put every new setting in a grouped Form row with the 84 pt value cell, stepper, 44 pt unit column and ⓘ at the trailing edge, or a 44 pt spacer where there is no unit.
- **Do** write a key value on the conductor it governs when a page has one, and light the parts the page governs.
- **Do** define any new custom colour as a light/dark pair in `Theme`, and give it one named job.
- **Do** double every colour signal with text or a symbol: "changed" tag, strikethrough old value, warning triangle.
- **Do** keep commands in the macOS menus with their standard shortcuts.

### Don't:
- **Don't** use Victron Blue for headings, links, backgrounds or decoration; it means product block, lit relay or changed.
- **Don't** colour an unlit conductor; idle wires are grey at 1.2 pt.
- **Don't** draw equipment the configuration file does not prove (no PV, no second input unless the device has one).
- **Don't** set numbers in proportional figures.
- **Don't** add custom shadows, gradients or blurs inside the window.
