// KaTeX, as its OWN bundle.
//
// Not imported by `editor.js`, deliberately. Measured with the surface pool's
// memory test, one pane, ten notes:
//
//     without KaTeX in the bundle ....  39.3 MB resident
//     with KaTeX in the bundle ......  68.8 MB resident
//
// +29.5 MB per surface, for 261 KB of code — the parse and JIT cost, paid
// whether or not the note contains any mathematics. Per SURFACE is what makes
// it matter: `CM6EditorSurfacePool` exists because ~40 MB per web view is the
// constraint this whole milestone is shaped around, and a split view would have
// gone from 79 MB to 138 MB for a feature most notes never use.
//
// So it loads on demand, the first time a document containing `$` is seen, and
// a vault of prose never pays for it at all.
import katex from "katex"
window.__loreKatex = katex
