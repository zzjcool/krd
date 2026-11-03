/**
 * KRD's wordmark: three letters in the crab's own hand.
 *
 * The mascot is paths and one outline; a wordmark set in a font would be the second hand in the
 * brand — a different stroke weight, a different terminal, a different ink. So the letters are
 * built the way the crab is: capsules swept along a spine (`taper`, the same limb kit), one weight
 * for everything, one ink outline painted under the fill. K's arms and R's leg are slightly curved
 * for the same reason the crab's legs are: a straight monoline reads as a font, a swept one reads
 * as this drawing.
 *
 * Space: cap height 200 user units, stroke 30 (15% of the cap), y down. Every spine is inset by
 * half a stroke, so a stem's capsule already reaches y = 0 and y = CAP; `reach` is where a letter's
 * far end lands before its own cap is added.
 */
import { taper, INK } from './mascot.mjs';
import { bounds, mapPath } from './vector.mjs';

/* ------------------------------------------------------------------ metrics */
export const CAP = 200;          // cap height, user units
export const STROKE = 30;        // one weight for every letter: 15% of the cap
export const GAP = 46;           // ink-to-ink between letters (0.23 cap: letters, not words)
export const OUTLINE = 6;        // the crab's outline width at this size; 3 of it shows
export const LEAD = 64;          // ink-to-ink between the crab and the wordmark (0.32 cap)
export const STACK = 48;         // the same, when the wordmark sits under the crab

const HALF = STROKE / 2;         // a spine endpoint is inset by half a stroke
/* an elliptical arc as a spine: `a` in radians, 0 = right, -pi/2 = up (y down) */
const arc = (cx, cy, rx, ry, a0, a1, n = 28) => Array.from({ length: n + 1 }, (_, i) => {
  const a = a0 + ((a1 - a0) * i) / n;
  return [cx + Math.cos(a) * rx, cy + Math.sin(a) * ry];
});
const line = (pts, w = STROKE) => taper(pts, w, w);

/* -------------------------------------------------------------- letterforms */
/**
 * K: stem, arm, leg. The arm leaves the stem a little above the middle and the leg a little below,
 * so the joint is one fat corner rather than two lines crossing at a point — at 30 units of stroke
 * a true crossing leaves a spike of ink outside the stem.
 */
function letterK() {
  const reach = 110;
  return [
    line([[HALF, HALF], [HALF, CAP - HALF]]),
    line([[HALF + STROKE * 0.15, CAP * 0.54], [reach, HALF + 3]]),
    line([[HALF + STROKE * 0.15, CAP * 0.54], [reach, CAP - HALF - 3]]),
  ];
}

/**
 * R: stem, a bowl that closes at `BOWL`, and a leg that starts under the bowl's shoulder. The leg
 * bends: a straight diagonal under a round bowl is the one corner in the word with no curve in it.
 */
const BOWL = CAP * 0.56;
function letterR() {
  const reach = 96;
  return [
    line([[HALF, HALF], [HALF, CAP - HALF]]),
    line(arc(HALF, BOWL / 2, reach, BOWL / 2 - HALF, -Math.PI / 2, Math.PI / 2)),
    line([[HALF + reach * 0.46, BOWL - 10], [HALF + reach * 0.78, BOWL + 34], [reach + 10, CAP - HALF]]),
  ];
}

/** D: stem and one half ellipse from the cap line to the baseline. The widest letter, as it should be. */
function letterD() {
  const reach = 100;
  return [line([[HALF, HALF], [HALF, CAP - HALF]]), line(arc(HALF, CAP / 2, reach, (CAP - STROKE) / 2, -Math.PI / 2, Math.PI / 2))];
}

/** One letter as a single compound path: the capsules union by the nonzero rule, one outline. */
function compound(parts) {
  return parts.flat();
}

const LETTERS = [
  { name: 'K', parts: letterK() },
  { name: 'R', parts: letterR() },
  { name: 'D', parts: letterD() },
];

/* ------------------------------------------------------------------- paint */
/* The shell's sand, lit from the top like every other surface in the drawing. Declared on the
   wordmark's own cap box so the gradient does not move when a letter is placed. */
const FILL = { type: 'linear', x1: 0, y1: 0, x2: 0, y2: CAP, stops: [[0, INK.shellHi], [0.55, INK.shell], [1, INK.shellMid]] };

/** One letter's ink box, outline included: [x0, y0, x1, y1]. */
function letterBounds(parts) {
  const probe = { view: [0, 0, CAP, CAP], groups: {}, layers: [{ d: compound(parts), stroke: INK.line, w: OUTLINE }] };
  return bounds(probe, { lod: 'hi' });
}

/**
 * The three letters, laid out by their ink: each one is placed so its own left edge lands on the
 * cursor, and the cursor advances by the letter's ink width plus `GAP`. Returns a scene with no
 * groups — a wordmark does not animate, and `place()` below can move it as a whole.
 */
export function wordmark() {
  const layers = [];
  let cursor = 0;
  const boxes = {};
  for (const { name, parts } of LETTERS) {
    const [x0, y0, x1] = letterBounds(parts);
    const d = mapPath(compound(parts), (x, y) => [x - x0 + cursor, y - y0]);
    layers.push({ d, fill: shiftPaint(FILL, cursor - x0, -y0), stroke: INK.line, w: OUTLINE, minPx: 1, under: true });
    boxes[name] = [cursor, cursor + (x1 - x0)];
    cursor += x1 - x0 + GAP;
  }
  /* every letter was moved by its own ink box, so the word's ink is exactly [0, width] x
     [0, CAP + OUTLINE]; the view adds half an outline (and a hair for the flattening error) so
     the drawing is never cropped by its own stroke */
  const width = cursor - GAP, m = OUTLINE / 2 + 0.5, height = CAP + OUTLINE;
  return { view: [-m, -m, width + 2 * m, height + 2 * m], groups: {}, layers, boxes, width, height };
}

const shiftPaint = (p, dx, dy) => {
  if (!p || typeof p === 'string') return p;
  return p.type === 'linear'
    ? { ...p, x1: p.x1 + dx, y1: p.y1 + dy, x2: p.x2 + dx, y2: p.y2 + dy }
    : { ...p, cx: p.cx + dx, cy: p.cy + dy };
};
/** A whole scene moved by [dx, dy]: paths, paints, clips, group pivots and group clips. */
export function translate(scene, dx, dy) {
  const groups = {};
  for (const [name, g] of Object.entries(scene.groups || {})) {
    const out = { ...g };
    if (g.pivot) out.pivot = [g.pivot[0] + dx, g.pivot[1] + dy];
    if (g.clip) out.clip = { ...g.clip, d: mapPath(g.clip.d, (x, y) => [x + dx, y + dy]) };
    if (g.lod) {
      out.lod = {};
      for (const [lod, o] of Object.entries(g.lod)) {
        out.lod[lod] = { ...o };
        if (o.pivot) out.lod[lod].pivot = [o.pivot[0] + dx, o.pivot[1] + dy];
        if (o.clip) out.lod[lod].clip = { ...o.clip, d: mapPath(o.clip.d, (x, y) => [x + dx, y + dy]) };
      }
    }
    groups[name] = out;
  }
  const layers = scene.layers.map(l => ({
    ...l,
    d: mapPath(l.d, (x, y) => [x + dx, y + dy]),
    fill: shiftPaint(l.fill, dx, dy),
    stroke: shiftPaint(l.stroke, dx, dy),
    clip: l.clip ? { ...l.clip, d: mapPath(l.clip.d, (x, y) => [x + dx, y + dy]) } : undefined,
  }));
  const [vx, vy, vw, vh] = scene.view;
  return { ...scene, view: [vx + dx, vy + dy, vw, vh], groups, layers };
}

/** A whole scene scaled about the origin: paths, paints, clips, pivots, stroke widths. */
export function scale(scene, k) {
  const paint = p => {
    if (!p || typeof p === 'string') return p;
    return p.type === 'linear'
      ? { ...p, x1: p.x1 * k, y1: p.y1 * k, x2: p.x2 * k, y2: p.y2 * k }
      : { ...p, cx: p.cx * k, cy: p.cy * k, r: p.r * k };
  };
  const path = d => mapPath(d, (x, y) => [x * k, y * k]);
  const groups = {};
  for (const [name, g] of Object.entries(scene.groups || {})) {
    const out = { ...g };
    if (g.pivot) out.pivot = [g.pivot[0] * k, g.pivot[1] * k];
    if (g.clip) out.clip = { ...g.clip, d: path(g.clip.d) };
    if (g.lod) {
      out.lod = {};
      for (const [lod, o] of Object.entries(g.lod)) {
        out.lod[lod] = { ...o };
        if (o.pivot) out.lod[lod].pivot = [o.pivot[0] * k, o.pivot[1] * k];
        if (o.clip) out.lod[lod].clip = { ...o.clip, d: path(o.clip.d) };
      }
    }
    groups[name] = out;
  }
  const layers = scene.layers.map(l => ({
    ...l,
    d: path(l.d),
    fill: paint(l.fill),
    stroke: paint(l.stroke),
    w: l.w == null ? l.w : l.w * k,
    minPx: l.minPx == null ? l.minPx : l.minPx * k,   // the stroke floor enlarges with the drawing
    clip: l.clip ? { ...l.clip, d: path(l.clip.d) } : undefined,
  }));
  const [vx, vy, vw, vh] = scene.view;
  return { ...scene, view: [vx * k, vy * k, vw * k, vh * k], groups, layers };
}

/**
 * The crab and the wordmark in one scene, ink aligned:
 *   side by side  the crab's ink bottom and the wordmark's baseline are the same line
 *   stacked       both centred on one vertical axis, `STACK` of air between the ink
 * `clear` is the margin as a fraction of the cap height, so the lockup has air to breathe in.
 * `crabScale` only applies side by side; the stacked lockup has its own ratio (56% of the word's
 * width) because its balance is vertical, not horizontal.
 * The crab comes in from the caller (logo-tui owns the mascot module), so this file has no
 * second copy of the drawing and no import cycle.
 */
export function lockup(crab, { stacked = false, lod = 'hi', clear = 0.14, crabScale = 1.2 } = {}) {
  let [cx0, cy0, cx1, cy1] = bounds(crab, { lod });
  let crabW = cx1 - cx0, crabH = cy1 - cy0;
  const w = wordmark();
  /* a letter's ink box is its own path plus half an outline, and the layout places those boxes:
     the wordmark's ink is exactly [0, width] x [0, CAP] */
  const wordW = w.width, wordH = w.height;
  let crabAt, wordAt, totalW, totalH;
  if (stacked) {
    /* the mark sits above the word at half the word's width, the way a stacked lockup reads: the
       drawing is the eye, the letters are the name, and neither is a caption for the other */
    const big = scale(crab, (wordW * 0.56) / crabW);
    const [bx0, by0, bx1, by1] = bounds(big, { lod });
    crabW = bx1 - bx0; crabH = by1 - by0;
    totalW = Math.max(crabW, wordW);
    totalH = crabH + STACK + wordH;
    crabAt = [(totalW - crabW) / 2 - bx0, -by0];
    wordAt = [(totalW - wordW) / 2, crabH + STACK];
    const at = translate(big, crabAt[0], crabAt[1]), word = translate(w, wordAt[0], wordAt[1]);
    return { view: [-clear * CAP, -clear * CAP, totalW + 2 * clear * CAP, totalH + 2 * clear * CAP],
             groups: at.groups, layers: [...at.layers, ...word.layers], size: [totalW, totalH],
             parts: { crab: bounds(at, { lod }), word: bounds(word, { lod }) } };
  }
  /* side by side: the crab stands on the wordmark's baseline */
  if (crabScale !== 1) {
    crab = scale(crab, crabScale);
    [cx0, cy0, cx1, cy1] = bounds(crab, { lod });
    crabW = cx1 - cx0; crabH = cy1 - cy0;
  }
  totalW = crabW + LEAD + wordW;
  totalH = Math.max(crabH, wordH);
  crabAt = [-cx0, totalH - crabH - cy0];
  wordAt = [crabW + LEAD, totalH - wordH];
  const at = translate(crab, crabAt[0], crabAt[1]), word = translate(w, wordAt[0], wordAt[1]);
  const mx = clear * CAP;
  return {
    view: [-mx, -mx, totalW + 2 * mx, totalH + 2 * mx],
    groups: at.groups,
    layers: [...at.layers, ...word.layers],
    size: [totalW, totalH],
    parts: { crab: bounds(at, { lod }), word: bounds(word, { lod }) },
  };
}
