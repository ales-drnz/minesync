# MineSync: design system (`ms_ui`)

`packages/ms_ui` is the Flutter design system shared by the desktop app and
the hub web UI. The approved design is the "MineSync 0.1 Design" canvas;
everything here reproduces it in Flutter.

## Sources of truth

| What | Where | Generated |
|---|---|---|
| Colours, type scale, spacing, z-order, durations | `tokens/tokens.json` | `lib/src/tokens.g.dart` (`dart run tool/gen_tokens.dart`) |
| Icons, logo, illustrations | `icons/icons.json` | `lib/src/icons/icons.g.dart` (`dart run tool/gen_icons.dart`) |
| App icons (Windows, macOS, Linux, web) | the Sync block logo | `dart run tool/export_icon.dart` |

Tests fail when a generated file is out of date (`--check` modes).

## Pixel rules

- One grid unit is 2 design pixels and always a whole number of physical
  pixels: `unitPx = max(1, floor(dpr × 2)) + sizeStep`. At 125 % the UI is
  drawn at 80 % unless the user raises "interface size" (`sizeStep`).
- Components draw only filled, axis-aligned rectangles on that grid: no
  anti-aliasing, no rounded corners, no blurred shadows.
- Text is vector text and is the only place where anti-aliasing is allowed.
  The block look comes from borders, bevels and colours, never from the
  typeface; only the Sync block logo is pixel art.

## Type

All text is legible: Atkinson Hyperlegible (regular and bold) for every role,
JetBrains Mono for code, paths and the console. There is no pixel typeface
and no "legible text" setting.

| Role | Size / line (design px) | Weight |
|---|---|---|
| display | 40/48 | bold |
| h1 / h2 / h3 | 32/40, 24/32, 20/28 | bold |
| lg / body / small | 18/28, 16/24, 14/20 | regular |
| label (panel heads, eyebrows) | 15/24 | bold |
| small label (badges, pills, chips) | 14/20 | bold |
| mono / console | 14/20 | JetBrains Mono |

Nothing goes below 14 except the version in the title bar (13, mono).
Labels are not upper-cased: components write them with an initial capital
(`msSentenceCase`), so strings stay in their natural case.

## Theme

`MsTheme(data: MsThemeData(...))` provides:

- `palette`: `prato` (default, grass green) or `abisso` (amethyst);
- `brightness`: dark (default) or light;
- `reducedMotion`: no animation (the system setting is honoured as well);
- `sizeStep`: interface size, in physical pixels per grid unit.

Text contrast is at least 4.5:1 in all four schemes (tested).

## Components

Exported from `package:ms_ui/ms_ui.dart`:

- controls: `MsButton` (secondary, primary, danger, ghost, icon, play),
  `MsSegmented`, `MsField`, `MsTextInput`, `MsInputGroup`, `MsSelect`,
  `MsCheckbox`, `MsSwitch`, `MsRadioGroup`, `MsSlider`, `MsTabs`, `MsNav`,
  `MsSidebar`, `MsTitlebar`, `MsKbd`, `MsTooltip`, `MsMenuButton` (button
  with a menu of actions), `MsDialog` (two-step
  confirm, type-the-name confirm, `leadingActions`), `MsToast` and
  `MsToastHost`;
- display: `MsText`, `MsPanel`, `MsSlot`, `MsCard`, `MsList`, `MsTable`,
  `MsBadge`, `MsPill`, `MsChip`, `MsIconTag`, `MsLock`, `MsLive`, `MsLevel`,
  `MsAvatar`
  (generated faces, never game skins), `MsProgress`, `MsSpinner`,
  `MsSkeleton`, `MsEmptyState`, `MsAlert`, `MsStat`, `MsFacts`, `MsConsole`
  (virtualised, "back to live"), textures, `MsHorizon`, `MsHeader`;
- layout: `MsStack`, `MsRow`, `MsEqualRow` (side-by-side columns with flex
  weights, all as tall as the tallest one), `MsFillColumn`;
- icons: `MsIcon(MsIcons.x)`, `MsLogo`, `MsArt`.

`MsDialog.leadingActions` puts actions at the start of the footer, apart
from `actions` at the end, so a destructive "Remove…" stays away from the
primary "Close". In a dialog narrower than 360 design px everything wraps,
end-aligned; the footer never overflows. A leading action that opens
another dialog pops this one first: dialogs never stack.

`MsIconTag(icon, tooltip:)` is an icon-only tag: a 24×24 design px square
(the 2 px `pxOutline` ring included) on `panelHi` like `MsChip`, with a
16 px icon. The required `tooltip` is also its semantics label, so the
meaning never rests on the icon alone. Use it for exceptions that should
stand out in a row while the normal case has no marker: the desktop Mod tab
marks server-only mods with `server` and players-only mods with `user`,
mods for both have none (the `sideBoth` icon appears only in the side
selector). The tooltip needs an `Overlay` ancestor.

## Panels and columns

- A panel head (`MsPanelHead`) is always 40 design px tall, with the same
  16 px side padding as the panel body, so the head title, status and
  buttons sit on the same verticals as the content below. Its actions and
  leading element are wrapped in `MsCompact`: pills lose their outline (dot
  and text only), small buttons and `MsLevel` shrink (24 px; the level square to 28).
- Density: panel body padding 16, panel foot 16/12, list rows at least 48
  tall, 16 px between panels and columns, page padding 20/24/24.
- Page width: content is capped at `MsSize.maxWidth` (1760) and aligned
  left; screens use the width with columns (overview: "how to join" next to
  "on this PC"; home: servers next to activity; history 2:3). Settings, a
  form, stays at 1104 so controls stay near their labels.
- `Columns` puts children side by side only when the narrowest one (by
  flex weight) still gets `minWidth`; otherwise they stack.
- Columns placed side by side are equal height (`MsEqualRow`, used by the
  apps' `Columns` and by the hub web `AutoGrid(equal: true)`). It lays the
  columns out twice: first free in height, then all with the tallest
  height as a *minimum* (not a tight constraint, so a column whose content
  grows still re-measures the row). No `IntrinsicHeight`: many children
  contain `LayoutBuilder`.
- Given a minimum height, `MsPanel` fills it: body at the top, foot on the
  bottom edge. With unbounded or only max-bounded height (dialogs) it follows
  its content. A column of several panels uses `MsStack(fillLast: true)` so
  the last one reaches the bottom of the neighbouring column.

## Sizes and motion

- Badges, pills, chips and the small lock are all 32 design px tall plus
  their 2 px outline, like a small button, so they line up side by side.
- `MsSlot.square(side:)` keeps square content at any size (server icons).
- Two-step blinks (`MsLive`, the "playing" lock) change twice per period
  with a timer (`MsBlink`), not with an animation controller: an idle window
  draws about one frame per second instead of one per screen refresh.

## Navigation

- The current `MsNavItem` is a solid accent block (pixel outline and bevel,
  on-accent label, icon and trailing); `dashed: true` makes an action slot
  with the same geometry (e.g. "+ New server").
- `MsSidebar(footer: [...])` pins items (Settings) to the bottom edge under a
  full-width pixel divider.

No component contains user-facing text: every string is a parameter, so the
apps pass Italian or English.

## Goldens

Every component has goldens at 100, 125, 150 and 200 % in prato dark, plus
light and abisso variants, under `test/<group>/goldens/`. Geometry-only
goldens also assert that every pixel is a solid scheme colour. Goldens are
generated and compared on Linux (`flutter test --update-goldens`).
