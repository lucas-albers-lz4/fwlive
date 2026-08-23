# fwlive chrome alignment options

Presentation-only HTML/CSS prototypes for the LuCI chrome alignment polish. They intentionally contain no application wiring or behavior; the open `<details>` element simply keeps the Display options drawer visible for comparison.

## A: Toolbar rail

**Optimizes for:** a compact, left-to-right scan. Status, actions, and view controls share one rail, while tiny labels above the segmented controls preserve orientation without adding another row.

**Tradeoffs:** the rail is efficient at desktop widths but can become dense when labels or translations grow. The separators provide rhythm, though they add more visual punctuation than the other options.

## B: Form grid

**Optimizes for:** predictable alignment and grouping. Vertical dividers separate the watch-strip groups, and the drawer uses explicit label/control columns so every field starts on the same axis.

**Tradeoffs:** it is the most structured and easiest to scan, but consumes more horizontal space. Its form-like appearance may feel slightly heavier for a small set of options.

## C: Soft cards

**Optimizes for:** touch-friendly calm. Related watch controls sit in pill groups with a consistent 32px touch height, while the drawer’s sections become subtle inset cards that establish clear local boundaries.

**Tradeoffs:** rounded surfaces and extra padding increase visual weight and vertical space. The treatment is friendly and forgiving, but less dense than the current LuCI chrome.

## Recommendation

Choose **B: Form grid** as the implementation direction. It gives the strongest alignment improvement with the fewest decorative changes, keeps the existing two-column drawer model legible, and has the clearest responsive fallback. Borrow A’s micro-labels only if testing shows the segmented controls need additional orientation.

## Preview

```sh
python3 -m http.server 8765 --directory lab/ui-polish-mockups
# open http://localhost:8765/alignment/
```
