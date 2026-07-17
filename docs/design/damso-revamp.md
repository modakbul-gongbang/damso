# Meeting Hub Revamp Design (Token Translation)

## Source and approach

The visual language is translated from the VoltAgent `awesome-design-md` Figma design system analysis: a confident black-and-white editorial frame interrupted by hand-cut pastel color blocks.
Per the approved PRD (D-03), the system is applied as a token translation, not a literal reproduction: colors, radii, and mood carry over; typography maps to the system font at native macOS scales; controls stay native.

## Token translation table

| Reference token | Reference value | Meeting Hub token | Translated value | Notes |
| --- | --- | --- | --- | --- |
| ink / primary | `#000000` | `inkSpec` | `#0A0A0A` light / `#F5F5F2` dark | Adaptive; pure black softened one step |
| canvas | `#ffffff` | `canvasSpec` | `#FFFFFF` light / `#1F1F1F` dark | Dark canvas matches contrast test surface |
| surface-soft | `#f7f7f5` | `surfaceSoftSpec` | `#F7F7F5` light / `#262626` dark | Cards, speaker cards |
| hairline | `#e6e6e6` | `hairlineSpec` | `#E6E6E6` light / `#333333` dark | Section rules, card borders |
| block-lime | `#dceeb1` | `blockLime` | same, appearance-invariant | Transcribe stage |
| block-lilac | `#c5b0f4` | `blockLilac` | same | Speakers stage, accent dark value |
| block-cream | `#f4ecd6` | `blockCream` | same | Captured stage, duplicate chip |
| block-pink | `#efd4d4` | `blockPink` | same | Recording banner |
| block-mint | `#c8e6cd` | `blockMint` | same | Summary stage |
| block-coral | `#f3c9b6` | `blockCoral` | same | Failed stage cards |
| block-navy | `#1f1d3d` | `blockNavy` | same, white ink | Reserved |
| accent-magenta | `#ff3d8b` | `criticalSpec` | `#B3125F` light / `#FF7AB8` dark | Darkened to hold 4.5:1; live recording |
| semantic-success | `#1ea64a` | `successSpec` | `#11703A` light / `#5FD68D` dark | Darkened to hold 4.5:1 |
| (product accent) | — | `accentSpec` | `#5B3FAE` light / `#C5B0F4` dark | Deep lilac derived from block-lilac |
| (warning) | — | `warningSpec` | `#853D05` light / `#FFB35E` dark | Carried from HV1, fits the palette |
| rounded xs/sm/md/lg/pill | 2/6/8/24/50px | `radiusXS/SM/compactRadius/radius/LG`, `Capsule` | 2/6/8/12/24pt + pill | 12pt kept for main cards |
| spacing scale | 4..96px | `spacingXXS..XL` | 4/8/12/16/24/32pt | 8pt grid |
| eyebrow/caption (figmaMono) | mono, tracked | `Font.damsoEyebrow` | system monospaced caption, uppercase | Metadata, stage labels, chips |
| display (figmaSans 340) | 86px light | `Font.damsoDisplay` | system largeTitle medium | No bundled font |
| button-primary | black pill | `DamsoPillButtonStyle` | ink capsule, canvas text | Secondary: canvas + ink border |

## Block rules

- Pastel blocks keep the same value in light and dark appearance (sticky notes on either canvas). Text on a block always uses the block ink (near-black; white on navy), which holds ≥ 4.5:1 on every block. Regression-tested in `DesignTokenTests`.
- The monochrome frame stays achromatic (channel spread < 0.03) so the blocks carry all the color. Regression-tested.

## Structure

- Three-column layout retained (D-09): sidebar (Meeting Log / People / import + record action), list, detail.
- The detail header leads with a mono eyebrow metadata line, a display-scale title, and the four-stage pipeline indicator (Captured → Transcribed → Speakers → Summary), each stage a pastel block segment with complete / current / failed / pending states.
- Stage cards below the header use the matching block color: lime while processing, lilac for the speaker gate, coral for retryable failures, mint for summary.
- People identity uses deterministic pastel block avatars.

## Accessibility

- Every adaptive semantic color is regression-tested at ≥ 4.5:1 on both canvas values.
- System typography and dynamic type; no motion added; state changes remain immediate.
