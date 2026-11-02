/**
 * KRD's mascot, as data: a hermit crab in a spiral shell.
 *
 * `scene()` is the one drawing everything else is made from — the README's SVG, the lab's half
 * blocks and characters, the favicon, and the loading card krd paints before its first frame (the
 * Swift copy, Sources/krd/MascotArt.swift, is generated from this file by `node build.mjs`).
 * Change a number here and every output moves with it.
 *
 * Space: 256 x 224 user units, y down, light from the upper left.
 * Groups, each one something a pose can move: crab > {eyes > look, claw > dactyl, legs}.
 * The crab is clipped to "everything but the shell's body", so a crab that ducks into its shell
 * goes behind it instead of sliding over it.
 */
import { ellipse, circle, poly, smooth, linear, radial, clockwise, anticlockwise, mapPath } from './vector.mjs';

/* ------------------------------------------------------------------ colours */
export const INK = {
  line: '#3b2416',                                  // one warm outline for every part
  shellHi: '#fff7e6', shell: '#f3dfb8', shellMid: '#dfbd8b', shellLo: '#bb8c59', shellDeep: '#8e643a',
  band: '#c4884e', suture: '#6b4528',
  lip: '#fde8d6', lipLo: '#eebd9c', hole: '#4d2719', holeDeep: '#220f08',
  coralHi: '#ffb48c', coral: '#f4845a', coralLo: '#d8603c', coralDeep: '#a8432a',
  eye: '#fffaf2', eyeLo: '#e6d6c3', pupil: '#1c1420', glint: '#ffffff', blue: '#5eb8ff',
  blush: '#ff6f6f', mouth: '#5a1c10', shadow: '#2a1a10',
};

/* ------------------------------------------------------------------- shell */
/* A logarithmic spiral: every whorl is the previous one scaled by G, so the sutures, the bands and
   the silhouette are one curve at different radii — which is also why it survives being drawn
   48 dots wide. */
const C = [96, 118];                     // spiral centre
const R = 80;                            // radius where the last whorl ends, at the aperture
const G = 1.72;                          // growth per turn
const KG = Math.log(G) / (2 * Math.PI);
const TE = (24 * Math.PI) / 180;         // where the spiral ends: right and a little down
const TAU = 2 * Math.PI;
const rad = th => R * Math.exp(KG * (th - TE));
const at = (th, f = 1) => [C[0] + Math.cos(th) * rad(th) * f, C[1] + Math.sin(th) * rad(th) * f];
const run = (a, b, f, perTurn) => {
  const n = Math.max(4, Math.ceil((Math.abs(b - a) / TAU) * perTurn));
  return Array.from({ length: n + 1 }, (_, i) => at(a + ((b - a) * i) / n, f));
};
/** the strip between radius factors f(t) = [f0, f1] along the spiral from angle a to b */
function ribbon(fn, a, b, perTurn = 16) {
  if (typeof fn !== 'function') { const [f0, f1] = [fn, perTurn]; perTurn = 16; fn = () => [f0, f1]; }
  const n = Math.max(4, Math.ceil((Math.abs(b - a) / TAU) * perTurn));
  const o = [], i = [];
  for (let k = 0; k <= n; k++) {
    const t = k / n, th = a + (b - a) * t, [f0, f1] = fn(t);
    o.push(at(th, f1)); i.push(at(th, f0));
  }
  const outer = smooth(o, false), inner = smooth(i.reverse(), false);
  return [...outer, ['L', ...inner[0].slice(1)], ...inner.slice(1), ['Z']];
}
const band = (f0, f1, a, b) => ribbon(() => [f0, f1], a, b);

const APEX = TE - TAU * 4.2;             // small enough to be a point
const LAST = TE - TAU;                   // the last suture meets the aperture here
export const SHELL = [...smooth(run(LAST, TE, 1, 32), false), ['Z']];

/* The aperture: an oval across the spiral's end, leaning forward; a pearly lip around a dark hole */
const AP = at(TE, (1 + 1 / G) / 2 + 0.035);
const AR = (R * (1 - 1 / G)) / 2;
const LIP = ellipse(AP[0] + 3, AP[1] + 2, AR * 1.36, AR * 2.05, TE - 0.22);
const HOLE = ellipse(AP[0] + 1, AP[1] + 3, AR * 0.92, AR * 1.62, TE - 0.22);

/* --------------------------------------------------------------- limb kit */
/** a smooth spine swept with a width that goes from w0 to w1, round at both ends: stalks, limbs */
export function taper(pts, w0, w1, n = 8) {
  const curve = t => {
    const s = t * (pts.length - 1), i = Math.min(pts.length - 2, Math.floor(s)), u = s - i;
    const a = pts[Math.max(0, i - 1)], b = pts[i], c = pts[i + 1], d = pts[Math.min(pts.length - 1, i + 2)];
    const cr = (p0, p1, p2, p3) => 0.5 * (2 * p1 + (-p0 + p2) * u + (2 * p0 - 5 * p1 + 4 * p2 - p3) * u * u
                                          + (-p0 + 3 * p1 - 3 * p2 + p3) * u * u * u);
    return [cr(a[0], b[0], c[0], d[0]), cr(a[1], b[1], c[1], d[1])];
  };
  const dir = t => {
    const q = curve(Math.min(1, t + 0.01)), o = curve(Math.max(0, t - 0.01)), l = Math.hypot(q[0] - o[0], q[1] - o[1]) || 1;
    return [(q[0] - o[0]) / l, (q[1] - o[1]) / l];
  };
  const left = [], right = [];
  for (let k = 0; k <= n; k++) {
    const t = k / n, p = curve(t), [ux, uy] = dir(t), h = (w0 + (w1 - w0) * t) / 2;
    left.push([p[0] - uy * h, p[1] + ux * h]);
    right.push([p[0] + uy * h, p[1] - ux * h]);
  }
  /* caps: half circles, left -> front -> right at the end, right -> back -> left at the start */
  const cap = (p, [ux, uy], h, sign) => [1, 2, 3].map(k => {
    const a = (Math.PI * k) / 4;
    return [p[0] + (-uy * Math.cos(a) + ux * Math.sin(a)) * h * sign, p[1] + (ux * Math.cos(a) + uy * Math.sin(a)) * h * sign];
  });
  const end = cap(curve(1), dir(1), w1 / 2, 1), start = cap(curve(0), dir(0), w0 / 2, -1);
  return smooth([...left, ...end, ...right.reverse(), ...start], true, 1);
}

/** the big claw, drawn pointing along +x from its wrist at the origin, then turned and placed */
function clawParts(wrist, deg, k = 1) {
  const a = (deg * Math.PI) / 180, c = Math.cos(a) * k, s = Math.sin(a) * k;
  const pt = (x, y) => [wrist[0] + x * c - y * s, wrist[1] + x * s + y * c];
  const put = d => mapPath(d, pt);
  return {
    /* the palm: a fat mitten */
    palm: put(smooth([[-2, -10], [9, -17], [23, -17], [33, -9], [35, 3], [28, 14], [13, 17], [0, 11]])),
    /* the fixed finger, under: grows out of the palm's front and curls up at the tip */
    pollex: put(smooth([[22, 1], [34, 1], [45, -2], [52, -7], [52, 1], [45, 9], [32, 13]])),
    /* the moving finger, over: hinged at the palm's top front, curls down to meet the other */
    dactyl: put(smooth([[19, -13], [31, -20], [44, -20], [54, -13], [51, -8], [41, -9], [28, -5]])),
    shine: put(ellipse(12, -7, 7.5, 3.6, -0.3)),
    hinge: pt(24, -10),
  };
}

/* ------------------------------------------------------------------- scene */
export const VIEW = [0, 0, 256, 224];
/* The outline is painted under each part (paint-order: stroke), so only its outer half shows:
   a thin leg keeps all of its colour, and two touching parts get one line between them, not two. */
const OUT = 6.4;                          // outline width, user units (3.2 of it shows)
const OUTPX = 2.1;                        // ...never less than this many output pixels (1 shows)

const HEAD = smooth([[150, 124], [166, 106], [192, 103], [211, 119], [212, 149], [192, 168], [164, 169], [148, 151]]);
const EYES = [{ c: [157, 56], stalk: [[168, 122], [163, 92], [158, 68]] },
              { c: [208, 52], stalk: [[190, 120], [201, 90], [206, 64]] }];
const EYE_R = 19.5;
const WRIST = [213, 152];
const CLAW = clawParts(WRIST, -50, 0.9);

export function scene() {
  const L = [];
  const add = (d, o = {}) => L.push({ d, ...o });
  const lined = (d, fill, o = {}) => add(d, { fill, stroke: INK.line, w: OUT, minPx: OUTPX, under: true, ...o });
  const grad = (x1, y1, x2, y2, ...stops) => linear(x1, y1, x2, y2, stops.map((h, i) => [i / (stops.length - 1), h]));

  /* ground shadow: soft, big outputs only (a terminal has no "under") */
  for (const [rx, ry, a] of [[100, 12, 0.06], [80, 9.5, 0.08], [60, 7, 0.1]])
    add(ellipse(134, 208, rx, ry), { fill: INK.shadow, alpha: a, lod: 'hi' });

  /* ---- the shell ---- */
  const inside = { clip: { d: SHELL } };
  lined(SHELL, radial(C[0] - 30, C[1] - 46, R * 1.6,
    [[0, INK.shellHi], [0.3, INK.shell], [0.62, INK.shellMid], [0.86, INK.shellLo], [1, INK.shellDeep]]), { w: OUT * 1.12 });
  /* each whorl: a caramel band, a shadow along the inner edge, a lit crest near the outer */
  add(band(1.16, 1.42, APEX + TAU * 0.6, TE), { fill: INK.band, alpha: 0.4, ...inside });
  add(band(1.0, 1.13, APEX + TAU * 0.3, TE), { fill: INK.shellDeep, alpha: 0.3, ...inside });
  add(band(1.5, 1.66, APEX + TAU, TE), { fill: linear(C[0] - 60, C[1] - 70, C[0] + 50, C[1] + 60,
    [[0, INK.shellHi, 0.95], [0.6, INK.shellHi, 0.45], [1, INK.shellHi, 0.05]]), ...inside });
  /* growth lines across the last whorl: fine, big outputs only */
  for (let k = 0; k < 15; k++) {
    const th = LAST + 0.35 + k * 0.4;
    add(smooth([at(th, 1.08 / G), at(th + 0.03, (1 / G + 1) / 2), at(th + 0.05, 0.965)], false),
        { stroke: INK.shellLo, w: 1.1, alpha: 0.26, lod: 'hi', ...inside });
  }
  /* the suture: a dark line that thins to nothing at the apex */
  add(ribbon(t => { const k = 0.052 * Math.min(1, t * 3); return [1 - k, 1 + k]; }, APEX, LAST + 0.02, 16),
      { fill: INK.suture, ...inside });
  /* rim light along the top edge, a glossy spot, the apex */
  add(band(0.9, 0.955, LAST + TAU * 0.02, LAST + TAU * 0.48), { fill: '#ffffff', alpha: 0.55, ...inside });
  add(ellipse(C[0] - 27, C[1] - 40, 10.5, 5.4, -0.6), { fill: '#ffffff', alpha: 0.62 });
  add(circle(C[0] - 11, C[1] - 48, 2.6), { fill: '#ffffff', alpha: 0.75, lod: 'hi' });
  add(circle(...at(APEX + 0.4, 0.6), 2.4), { fill: INK.suture });

  /* the aperture: a pearly lip around a dark hole */
  lined(LIP, linear(AP[0] - 20, AP[1] - 30, AP[0] + 20, AP[1] + 30, [[0, INK.lip], [1, INK.lipLo]]), { w: OUT * 1.05 });
  add(HOLE, { fill: radial(AP[0] + 10, AP[1] + 8, AR * 1.9, [[0, INK.hole], [0.7, INK.holeDeep], [1, INK.holeDeep]]) });

  /* ---- the crab ---- */
  /* ---- walking legs: out of the aperture, over the lip, under the head; the far pair darker ---- */
  const legs = [
    { hip: [158, 158], knee: [137, 167], foot: [129, 195], w: 11, far: true },
    { hip: [204, 156], knee: [224, 168], foot: [231, 195], w: 11, far: true },
    { hip: [170, 164], knee: [151, 181], foot: [147, 208], w: 12.5 },
    { hip: [190, 165], knee: [205, 182], foot: [209, 209], w: 12.5 },
  ];
  for (const g of legs) {
    const col = g.far ? INK.coralLo : INK.coral;
    lined(taper([g.knee, g.foot], g.w * 0.9, 1.2), col, { group: 'legs' });
    lined(taper([g.hip, g.knee], g.w, g.w * 0.9), col, { group: 'legs' });
    if (!g.far) add(taper([g.hip, g.knee], g.w * 0.24, g.w * 0.18), { fill: INK.coralHi, alpha: 0.8, group: 'legs', lod: 'hi' });
  }

  /* the small claw, tucked under the head on the left */
  lined(smooth([[148, 152], [159, 145], [171, 150], [172, 162], [161, 171], [148, 166]]), INK.coralLo, { group: 'crab' });

  /* antennae: long and thin, behind the eyes; big outputs only */
  add(smooth([[176, 112], [170, 70], [150, 24], [124, 10]], false), { stroke: INK.coralDeep, w: 2.2, lod: 'hi', group: 'crab' });
  add(smooth([[190, 110], [198, 68], [220, 22], [246, 12]], false), { stroke: INK.coralDeep, w: 2.2, lod: 'hi', group: 'crab' });

  /* stalks go behind the head, so eyes that pull down slide their stalks out of sight */
  for (const e of EYES)
    lined(taper(e.stalk, 12.5, 10), grad(e.stalk[0][0] - 7, 0, e.stalk[0][0] + 7, 0, INK.coralLo, INK.coral, INK.coralHi),
          { group: 'eyes' });

  /* the head: soft, round, a sheen on top and a shade underneath */
  lined(HEAD, grad(162, 106, 196, 168, INK.coralHi, INK.coral, INK.coralLo), { group: 'crab' });
  add(smooth([[147, 140], [160, 161], [188, 168], [170, 162], [156, 150]]), { fill: INK.coralDeep, alpha: 0.32, group: 'crab', clip: { d: HEAD } });
  add(ellipse(186, 114, 12, 4.4, -0.12), { fill: '#ffffff', alpha: 0.36, group: 'crab' });

  /* the face */
  for (const x of [161, 200]) add(ellipse(x, 143, 7.2, 4.5), { fill: INK.blush, alpha: 0.5, group: 'crab' });
  add(smooth([[174, 142], [178.5, 147.5], [183, 144.5], [187.5, 147.5], [192, 142]], false),
      { stroke: INK.mouth, w: 2.8, minPx: 1, group: 'crab' });

  /* the eyes: big, glinting, looking at you; shut = a happy curve */
  for (const [n, e] of EYES.entries()) {
    const [x, y] = e.c, r = EYE_R, px = x + (n ? -2.5 : 2.5), py = y + 2.5;
    lined(circle(x, y, r), radial(x - r * 0.35, y - r * 0.4, r * 1.25, [[0, '#ffffff'], [0.6, INK.eye], [1, INK.eyeLo]]),
          { group: 'eyes', only: 'open' });
    add(ellipse(px, py, r * 0.6, r * 0.66), { fill: INK.pupil, group: 'look', only: 'open' });
    add(ellipse(px - 3.8, py + 7.2, 4.4, 2.4, -0.4), { fill: INK.blue, group: 'look', only: 'open' });
    add(circle(px + 4.2, py - 6.3, 4.6), { fill: INK.glint, group: 'look', only: 'open' });
    add(circle(px - 4.6, py - 1.7, 1.9), { fill: INK.glint, group: 'look', only: 'open', lod: 'hi' });
    lined(circle(x, y, r), grad(x, y - r, x, y + r, INK.coralHi, INK.coral), { group: 'eyes', only: 'shut' });
    add(smooth([[x - r * 0.62, y + 1], [x, y + r * 0.42], [x + r * 0.62, y + 1]], false),
        { stroke: INK.line, w: 3, minPx: 1, group: 'eyes', only: 'shut' });
  }

  /* ---- the big claw, in front: arm, the fixed finger, the palm, then the finger that moves ---- */
  lined(taper([[198, 160], [207, 158], WRIST], 13.5, 12.5), INK.coral, { group: 'claw' });
  lined(CLAW.pollex, grad(...CLAW.hinge, WRIST[0] + 40, WRIST[1] - 26, INK.coral, INK.coralLo), { group: 'claw' });
  lined(CLAW.palm, grad(WRIST[0] + 4, WRIST[1] - 14, WRIST[0] + 22, WRIST[1] + 14, INK.coralHi, INK.coral, INK.coralLo), { group: 'claw' });
  add(CLAW.shine, { fill: '#ffffff', alpha: 0.42, group: 'claw' });
  lined(CLAW.dactyl, grad(...CLAW.hinge, WRIST[0] + 36, WRIST[1] - 40, INK.coralHi, INK.coral), { group: 'dactyl' });

  return {
    view: VIEW,
    groups: {
      crab: { parent: null, clip: crabClip(), pivot: [180, 140] },
      eyes: { parent: 'crab', pivot: [178, 118] },
      /* the pupils look around inside the whites: the clip stays with the eyes */
      look: { parent: 'eyes', clip: { d: EYES.flatMap(e => circle(...e.c, EYE_R - 1)) } },
      legs: { parent: 'crab' },
      claw: { parent: 'crab', pivot: WRIST },
      dactyl: { parent: 'claw', pivot: CLAW.hinge },
    },
    layers: L,
  };
}

/** everything except the shell's body: the crab may be over the lip and the hole, or outside */
function crabClip() {
  const [x, y, w, h] = VIEW, m = 96;
  const box = poly([[x - m, y - m], [x + w + m, y - m], [x + w + m, y + h + m], [x - m, y + h + m]]);
  return { d: [...clockwise(box), ...anticlockwise(SHELL), ...clockwise(LIP)], rule: 'nonzero' };
}

/* ------------------------------------------------------------------- poses */
/** A pose: how far each group moves (user units) or turns (degrees), and whether the eyes are shut */
export const REST = { move: {}, turn: {}, eyes: 'open' };
export const pose = ({ duck = 0, look = [0, 0], snip = 0, wave = 0, eyes = 'open' } = {}) => ({
  move: { crab: [-5 * duck, 5 * duck], eyes: [0, 24 * duck], look },
  turn: { dactyl: -snip, claw: wave },
  eyes,
});
