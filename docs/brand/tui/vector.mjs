/**
 * The vector kit behind the mascot: paths, paints, one rasteriser, one SVG writer.
 *
 * The mascot is drawn more than once — as SVG for the README, as pixels for a terminal (the lab in
 * logo-tui.mjs, and krd's own loading card in Sources/krd/LoadingView.swift). If those came from
 * separate drawings they would drift the first time somebody touched one of them. So there is one
 * drawing — a list of layers in the vocabulary below — and every output is a function of it.
 *
 * The vocabulary is what SVG 1.1, this rasteriser and CoreGraphics all draw the same way:
 *   path     M / L / C / Z in absolute user units; every builder below produces only these
 *   fill     a colour or a user-space linear/radial gradient; nonzero or evenodd
 *   stroke   round caps and round joins only: a capsule chain, which is exactly what the rasteriser
 *            tests (distance to the polyline <= w/2), so the two cannot disagree about a corner.
 *            `under: true` paints it before the fill (SVG paint-order="stroke"): a cartoon outline
 *            that only shows outside the shape, so a thin limb keeps all of its colour
 *   clip     one path per layer (in the layer's space) or per group (in the parent's space)
 *   alpha    fill-opacity / stroke-opacity per layer, never group opacity
 * No filters, no masks, no blend modes, no text. Zero dependencies, Node 18+.
 */
import { deflateSync } from 'node:zlib';

/* ------------------------------------------------------------------ colour */
export const rgb = h => [1, 3, 5].map(i => parseInt(h.slice(i, i + 2), 16));
const clamp8 = v => Math.max(0, Math.min(255, Math.round(v)));
export const hex = c => '#' + c.slice(0, 3).map(v => clamp8(v).toString(16).padStart(2, '0')).join('');
export const mix = (a, b, t) => { const x = rgb(a), y = rgb(b); return hex(x.map((v, i) => v + (y[i] - v) * t)); };

/* ------------------------------------------------------------------- paths */
/* A path is an array of commands in absolute user units:
     ['M', x, y]   ['L', x, y]   ['C', x1, y1, x2, y2, x, y]   ['Z']
   Several subpaths in one array make a compound path (holes come from the fill rule). */
const K = 0.5522847498307936;            // a quarter circle as one cubic

export function ellipse(cx, cy, rx, ry = rx, rot = 0) {
  const c = Math.cos(rot), s = Math.sin(rot);
  const T = (x, y) => [cx + x * c - y * s, cy + x * s + y * c];
  const q = [[rx, 0], [rx, K * ry], [K * rx, ry], [0, ry], [-K * rx, ry], [-rx, K * ry], [-rx, 0],
             [-rx, -K * ry], [-K * rx, -ry], [0, -ry], [K * rx, -ry], [rx, -K * ry], [rx, 0]].map(([x, y]) => T(x, y));
  return [['M', ...q[0]], ['C', ...q[1], ...q[2], ...q[3]], ['C', ...q[4], ...q[5], ...q[6]],
          ['C', ...q[7], ...q[8], ...q[9]], ['C', ...q[10], ...q[11], ...q[12]], ['Z']];
}
export const circle = (cx, cy, r) => ellipse(cx, cy, r, r);

export function poly(pts, closed = true) {
  const p = pts.map(([x, y], i) => [i ? 'L' : 'M', x, y]);
  return closed ? [...p, ['Z']] : p;
}

export function roundRect(x, y, w, h, r) {
  r = Math.min(r, w / 2, h / 2);
  const k = r * (1 - K);
  return [['M', x + r, y], ['L', x + w - r, y], ['C', x + w - k, y, x + w, y + k, x + w, y + r],
          ['L', x + w, y + h - r], ['C', x + w, y + h - k, x + w - k, y + h, x + w - r, y + h],
          ['L', x + r, y + h], ['C', x + k, y + h, x, y + h - k, x, y + h - r],
          ['L', x, y + r], ['C', x, y + k, x + k, y, x + r, y], ['Z']];
}

/** A smooth curve through every point (Catmull-Rom as cubics). `t` < 1 tightens it. */
export function smooth(pts, closed = true, t = 1) {
  const n = pts.length, at = i => closed ? pts[(i + n) % n] : pts[Math.max(0, Math.min(n - 1, i))];
  const out = [['M', ...pts[0]]];
  for (let i = 0; i < (closed ? n : n - 1); i++) {
    const p0 = at(i - 1), p1 = at(i), p2 = at(i + 1), p3 = at(i + 2);
    out.push(['C', p1[0] + (p2[0] - p0[0]) * t / 6, p1[1] + (p2[1] - p0[1]) * t / 6,
                   p2[0] - (p3[0] - p1[0]) * t / 6, p2[1] - (p3[1] - p1[1]) * t / 6, p2[0], p2[1]]);
  }
  return closed ? [...out, ['Z']] : out;
}

/** Every point through `f(x, y) -> [x, y]` — an affine `f` keeps cubics exact. */
export const mapPath = (path, f) => path.map(([op, ...v]) => {
  const o = [op];
  for (let i = 0; i < v.length; i += 2) o.push(...f(v[i], v[i + 1]));
  return o;
});
export const move = (path, dx, dy) => mapPath(path, (x, y) => [x + dx, y + dy]);

/** Split into subpaths of {start, segs: [[...ctrl, x, y]], closed}. */
function subpaths(path) {
  const out = [];
  let cur = null;
  for (const [op, ...v] of path) {
    if (op === 'M') { cur = { start: v, segs: [], closed: false }; out.push(cur); }
    else if (op === 'Z') { if (cur) cur.closed = true; }
    else cur.segs.push(op === 'L' ? [v[0], v[1]] : v);
  }
  return out;
}

/** The same path, every subpath walked the other way (for the nonzero rule). */
export function reverse(path) {
  const out = [];
  for (const sp of subpaths(path)) {
    const pts = [sp.start, ...sp.segs.map(s => s.slice(-2))];
    out.push(['M', ...pts[pts.length - 1]]);
    for (let i = sp.segs.length - 1; i >= 0; i--) {
      const s = sp.segs[i], to = pts[i];
      out.push(s.length === 2 ? ['L', ...to] : ['C', s[2], s[3], s[0], s[1], ...to]);
    }
    if (sp.closed) out.push(['Z']);
  }
  return out;
}

/** Signed area after flattening. y points down, so > 0 is clockwise on screen. */
export function area(path) {
  let a = 0;
  for (const c of flatten(path, 0.05)) {
    const p = c.pts;
    for (let i = 0; i < p.length; i++) {
      const [x0, y0] = p[i], [x1, y1] = p[(i + 1) % p.length];
      a += x0 * y1 - x1 * y0;
    }
  }
  return a / 2;
}
export const clockwise = p => area(p) >= 0 ? p : reverse(p);
export const anticlockwise = p => area(p) < 0 ? p : reverse(p);

const num = (v, dp = 2) => {
  const s = (Math.round(v * 10 ** dp) / 10 ** dp).toFixed(dp).replace(/\.?0+$/, '');
  return s === '-0' ? '0' : s;
};
/** SVG path data. Same string the Swift side parses: absolute M/L/C/Z, spaces only. */
export const pathData = (path, dp = 1) => path.map(([op, ...v]) => [op, ...v.map(x => num(x, dp))].join(' ')).join(' ');

/** Polylines: [{pts, closed}], every point through `xf` first (affine), tolerance in xf's units. */
export function flatten(path, tol = 0.2, xf = (x, y) => [x, y]) {
  const out = [];
  for (const sp of subpaths(path)) {
    let p = xf(...sp.start);
    const pts = [p];
    for (const s of sp.segs) {
      if (s.length === 2) { p = xf(s[0], s[1]); pts.push(p); continue; }
      const c1 = xf(s[0], s[1]), c2 = xf(s[2], s[3]), e = xf(s[4], s[5]);
      // Wang's formula: segments needed so the chord never strays more than tol from the curve
      const m = Math.max(Math.hypot(p[0] - 2 * c1[0] + c2[0], p[1] - 2 * c1[1] + c2[1]),
                         Math.hypot(c1[0] - 2 * c2[0] + e[0], c1[1] - 2 * c2[1] + e[1]));
      const n = Math.max(1, Math.min(256, Math.ceil(Math.sqrt(0.75 * m / tol))));
      for (let i = 1; i <= n; i++) {
        const t = i / n, u = 1 - t;
        const a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t;
        pts.push([a * p[0] + b * c1[0] + c * c2[0] + d * e[0], a * p[1] + b * c1[1] + c * c2[1] + d * e[1]]);
      }
      p = e;
    }
    out.push({ pts, closed: sp.closed });
  }
  return out;
}

/* ------------------------------------------------------------------ paints */
export const linear = (x1, y1, x2, y2, stops) => ({ type: 'linear', x1, y1, x2, y2, stops });
export const radial = (cx, cy, r, stops) => ({ type: 'radial', cx, cy, r, stops });

/** paint -> (u, v) -> [r, g, b, a] with r,g,b in 0..255 and a in 0..1; sRGB interpolation like SVG */
function painter(paint) {
  if (typeof paint === 'string') { const c = [...rgb(paint), 1]; return () => c; }
  const stops = paint.stops.map(([o, h, a = 1]) => [o, ...rgb(h), a]);
  const at = t => {
    if (t <= stops[0][0]) return stops[0].slice(1);
    for (let i = 1; i < stops.length; i++) {
      const s = stops[i];
      if (t <= s[0]) {
        const p = stops[i - 1], k = (t - p[0]) / (s[0] - p[0] || 1);
        return [1, 2, 3, 4].map(j => p[j] + (s[j] - p[j]) * k);
      }
    }
    return stops[stops.length - 1].slice(1);
  };
  if (paint.type === 'linear') {
    const { x1, y1, x2, y2 } = paint, dx = x2 - x1, dy = y2 - y1, l = dx * dx + dy * dy || 1;
    return (u, v) => at(((u - x1) * dx + (v - y1) * dy) / l);
  }
  const { cx, cy, r } = paint;
  return (u, v) => at(Math.hypot(u - cx, v - cy) / r);
}

/* ------------------------------------------------------------------- scene */
/* scene = { view: [x, y, w, h], groups: {name: {parent, pivot?}}, layers: [...] }
   layer = { d, fill?, stroke?, w?, rule?, alpha?, clip?: {d, rule}, group?, only?, lod?, minPx? }
     group  a name from scene.groups. A pose moves a group by [dx, dy] and turns it by degrees
            about its pivot; children inherit both, the way nested SVG <g transform> do
     only   'open' | 'shut' — drawn only when pose.eyes says so (the blink)
     lod    'hi' (big outputs only) | 'lo' (small pixel outputs only) | undefined (both)
     minPx  a stroke never thinner than this many output pixels (a 1 px outline at 40 px wide) */
export const chain = (scene, g) => {
  const out = [];
  while (g) { out.unshift(g); g = scene.groups[g]?.parent ?? null; }
  return out;
};

/**
 * A group's definition at one lod. A group may carry `lod: { lo: { pivot, clip } }` — the sprite's
 * eyes are lower than the drawing's, so the clip that keeps their pupils inside them has to move
 * with them. Only the keys named in the override change; everything else is the group's.
 */
export const groupDef = (scene, g, lod) => {
  const d = scene.groups[g];
  const o = lod ? d?.lod?.[lod] : null;
  return o ? { ...d, ...o } : d;
};
/* affine matrices as [a, b, c, d, e, f]: x' = a x + c y + e, y' = b x + d y + f (SVG's order) */
export const I = [1, 0, 0, 1, 0, 0];
export const mul = (m, n) => [m[0] * n[0] + m[2] * n[1], m[1] * n[0] + m[3] * n[1],
                              m[0] * n[2] + m[2] * n[3], m[1] * n[2] + m[3] * n[3],
                              m[0] * n[4] + m[2] * n[5] + m[4], m[1] * n[4] + m[3] * n[5] + m[5]];
export const apply = (m, x, y) => [m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5]];
/** one group's own transform: rotate about its pivot, then translate (SVG: translate() rotate(a px py)) */
export function local(scene, pose, g, lod) {
  const [dx, dy] = pose?.move?.[g] || [0, 0], deg = pose?.turn?.[g] || 0;
  if (!deg) return [1, 0, 0, 1, dx, dy];
  const [px, py] = groupDef(scene, g, lod).pivot || [0, 0], a = (deg * Math.PI) / 180, c = Math.cos(a), s = Math.sin(a);
  return [c, s, -s, c, px - c * px + s * py + dx, py - s * px - c * py + dy];
}
export const groupMatrix = (scene, pose, g, lod) =>
  chain(scene, g).reduce((m, n) => mul(m, local(scene, pose, n, lod)), I);
export const visible = (layer, { lod, pose }) =>
  (!layer.lod || layer.lod === lod) && (!layer.only || layer.only === (pose?.eyes || 'open'));

/* -------------------------------------------------------------- rasteriser */
/** One layer's coverage, at sample resolution, rows [j0, j1) of the band. */
function fillMask(contours, rule, mask, W, j0, j1) {
  const rows = Array.from({ length: j1 - j0 }, () => []);
  for (const { pts } of contours) {
    for (let i = 0, n = pts.length; i < n; i++) {
      const [ax, ay] = pts[i], [bx, by] = pts[(i + 1) % n];
      if (ay === by) continue;
      const dir = by > ay ? 1 : -1, lo = Math.min(ay, by), hi = Math.max(ay, by);
      const r0 = Math.max(j0, Math.ceil(lo - 0.5)), r1 = Math.min(j1, Math.ceil(hi - 0.5));
      for (let j = r0; j < r1; j++) {
        const y = j + 0.5;
        rows[j - j0].push(ax + (y - ay) * (bx - ax) / (by - ay), dir);
      }
    }
  }
  for (let j = j0; j < j1; j++) {
    const r = rows[j - j0];
    if (!r.length) continue;
    const idx = [];
    for (let k = 0; k < r.length; k += 2) idx.push(k);
    idx.sort((a, b) => r[a] - r[b]);
    let wind = 0;
    for (let k = 0; k < idx.length - 1; k++) {
      wind += r[idx[k] + 1];
      const inside = rule === 'evenodd' ? (wind & 1) !== 0 : wind !== 0;
      if (!inside) continue;
      const a = Math.max(0, Math.ceil(r[idx[k]] - 0.5)), b = Math.min(W, Math.ceil(r[idx[k + 1]] - 0.5));
      const base = (j - j0) * W;
      for (let i = a; i < b; i++) mask[base + i] = 1;
    }
  }
}

function strokeMask(contours, rad, mask, W, j0, j1) {
  const r2 = rad * rad;
  const cap = (ax, ay, bx, by) => {
    const vx = bx - ax, vy = by - ay, l = vx * vx + vy * vy;
    const ya = Math.max(j0, Math.floor(Math.min(ay, by) - rad)), yb = Math.min(j1 - 1, Math.ceil(Math.max(ay, by) + rad));
    const xa = Math.max(0, Math.floor(Math.min(ax, bx) - rad)), xb = Math.min(W - 1, Math.ceil(Math.max(ax, bx) + rad));
    for (let j = ya; j <= yb; j++) {
      const py = j + 0.5, base = (j - j0) * W;
      for (let i = xa; i <= xb; i++) {
        if (mask[base + i]) continue;
        const px = i + 0.5;
        let t = l ? ((px - ax) * vx + (py - ay) * vy) / l : 0;
        t = t < 0 ? 0 : t > 1 ? 1 : t;
        const dx = px - (ax + vx * t), dy = py - (ay + vy * t);
        if (dx * dx + dy * dy <= r2) mask[base + i] = 1;
      }
    }
  };
  for (const { pts, closed } of contours) {
    if (pts.length === 1) cap(...pts[0], ...pts[0]);
    for (let i = 0; i < pts.length - 1; i++) cap(...pts[i], ...pts[i + 1]);
    if (closed && pts.length > 2) cap(...pts[pts.length - 1], ...pts[0]);
  }
}

/**
 * Draw the scene into width x height pixels: premultiplied RGBA floats (0..1), ss x ss point
 * samples per pixel, box-filtered. `aspect` stretches x (a terminal cell that is not two of its
 * own widths tall). Rendered in bands so a large PNG does not need one buffer per sample.
 */
export function render(scene, { width, height, ss = 4, pose = {}, lod = 'lo', aspect = 1, view = null } = {}) {
  const [vx, vy, vw, vh] = view || scene.view;
  /* one uniform scale that fits the view, centred: pixels stay square in the output's own terms */
  const s = Math.min(width / (vw * aspect), height / vh);
  const kx = s * aspect * ss, ky = s * ss;
  const ox = (width * ss - vw * kx) / 2, oy = (height * ss - vh * ky) / 2;
  const W = width * ss, H = height * ss;
  const prepared = [];
  for (const layer of scene.layers) {
    if (!visible(layer, { lod, pose })) continue;
    const m = groupMatrix(scene, pose, layer.group, lod);
    const xf = (x, y) => { const [u, v] = apply(m, x, y); return [ox + (u - vx) * kx, oy + (v - vy) * ky]; };
    /* the inverse, for gradients: sample (i, j) -> user space of the layer */
    const det = m[0] * m[3] - m[1] * m[2];
    const inv = (i, j) => {
      const u = (i + 0.5 - ox) / kx + vx - m[4], v = (j + 0.5 - oy) / ky + vy - m[5];
      return [(m[3] * u - m[2] * v) / det, (-m[1] * u + m[0] * v) / det];
    };
    /* a group's clip lives in its parent's space (it stays put while the group moves through
       it); a layer's own clip moves with the layer */
    const clips = [];
    for (const g of chain(scene, layer.group)) {
      const c = groupDef(scene, g, lod).clip;
      if (!c) continue;
      const pm = groupMatrix(scene, pose, scene.groups[g].parent, lod);
      clips.push({ contours: flatten(c.d, 0.15, (x, y) => { const [u, v] = apply(pm, x, y); return [ox + (u - vx) * kx, oy + (v - vy) * ky]; }), rule: c.rule });
    }
    if (layer.clip) clips.push({ contours: flatten(layer.clip.d, 0.15, xf), rule: layer.clip.rule });
    const contours = flatten(layer.d, 0.15, xf);
    const paints = [];
    if (layer.fill) paints.push({ kind: 'fill', paint: painter(layer.fill) });
    if (layer.stroke) {
      const px = Math.max((layer.w || 1) * s, layer.minPx || 0);
      const st = { kind: 'stroke', paint: painter(layer.stroke), rad: px * ss / 2 };
      if (layer.under) paints.unshift(st); else paints.push(st);
    }
    prepared.push({ layer, contours, clips, paints, inv });
  }
  const out = new Float32Array(width * height * 4);
  const BAND = Math.max(ss, Math.floor(65536 / Math.max(1, W)) * ss);
  for (let j0 = 0; j0 < H; j0 += BAND) {
    const j1 = Math.min(H, j0 + BAND), n = (j1 - j0) * W;
    const acc = new Float32Array(n * 4), mask = new Uint8Array(n), cm = new Uint8Array(n);
    for (const p of prepared) {
      let clipMask = null;
      if (p.clips.length) {
        clipMask = new Uint8Array(n).fill(1);
        for (const c of p.clips) {
          cm.fill(0);
          fillMask(c.contours, c.rule, cm, W, j0, j1);
          for (let k = 0; k < n; k++) clipMask[k] &= cm[k];
        }
      }
      for (const pt of p.paints) {
        mask.fill(0);
        if (pt.kind === 'fill') fillMask(p.contours, p.layer.rule, mask, W, j0, j1);
        else strokeMask(p.contours, pt.rad, mask, W, j0, j1);
        const alpha = p.layer.alpha ?? 1;
        for (let k = 0; k < n; k++) {
          if (!mask[k] || (clipMask && !clipMask[k])) continue;
          const i = k % W, j = j0 + Math.floor(k / W);
          const [r, g, b, a0] = pt.paint(...p.inv(i, j));
          const a = a0 * alpha, q = k * 4, keep = 1 - a;
          acc[q] = r / 255 * a + acc[q] * keep;
          acc[q + 1] = g / 255 * a + acc[q + 1] * keep;
          acc[q + 2] = b / 255 * a + acc[q + 2] * keep;
          acc[q + 3] = a + acc[q + 3] * keep;
        }
      }
    }
    /* box filter the band down to whole pixels */
    const inv = 1 / (ss * ss);
    for (let y = j0 / ss; y < j1 / ss; y++) {
      for (let x = 0; x < width; x++) {
        let r = 0, g = 0, b = 0, a = 0;
        for (let sy = 0; sy < ss; sy++) {
          const row = (y * ss + sy - j0) * W;
          for (let sx = 0; sx < ss; sx++) {
            const q = (row + x * ss + sx) * 4;
            r += acc[q]; g += acc[q + 1]; b += acc[q + 2]; a += acc[q + 3];
          }
        }
        const o = (y * width + x) * 4;
        out[o] = r * inv; out[o + 1] = g * inv; out[o + 2] = b * inv; out[o + 3] = a * inv;
      }
    }
  }
  return { width, height, px: out };
}

/**
 * Pixel art: the same scene, drawn the way a sprite is drawn by hand. Every pixel is point-sampled
 * at its centre (no blended edges), and an outlined part (`under: true`) gets its outline as a
 * one-pixel ring around its own mask, painted just before it — so every line is exactly one pixel
 * at any size, which an anti-aliased stroke at 48 pixels wide cannot be. Strokes that are lines
 * in their own right (a mouth) are drawn 8-connected, one pixel wide.
 *
 * This is what a terminal gets: half blocks are 1x2 pixels per cell, and a blended edge there is
 * a muddy cell, not a smooth one. Returns the same shape as render(): premultiplied RGBA floats.
 */
export function pixels(scene, { width, height, pose = {}, lod = 'lo', aspect = 1, view = null, ss = 3 } = {}) {
  const [vx, vy, vw, vh] = view || scene.view;
  const s = Math.min(width / (vw * aspect), height / vh);
  const kx = s * aspect, ky = s, ox = (width - vw * kx) / 2, oy = (height - vh * ky) / 2;
  const n = width * height, rgba = new Float32Array(n * 4);
  const toPx = m => (x, y) => { const [u, v] = apply(m, x, y); return [ox + (u - vx) * kx, oy + (v - vy) * ky]; };
  /* a pixel is in a shape when at least half of its ss x ss samples are */
  const cover = (contours, rule) => {
    const W = width * ss, H = height * ss, hi = new Uint8Array(W * H);
    const up = contours.map(c => ({ pts: c.pts.map(([x, y]) => [x * ss, y * ss]), closed: c.closed }));
    fillMask(up, rule, hi, W, 0, H);
    const out = new Uint8Array(n), need = (ss * ss) / 2;
    for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
      let c = 0;
      for (let j = 0; j < ss; j++) for (let i = 0; i < ss; i++) c += hi[(y * ss + j) * W + x * ss + i];
      out[y * width + x] = c >= need ? 1 : 0;
    }
    return out;
  };
  const line = (contours, mask) => {           // 8-connected, one pixel
    const plot = (x, y) => { if (x >= 0 && y >= 0 && x < width && y < height) mask[y * width + x] = 1; };
    for (const { pts, closed } of contours) {
      const seq = closed ? [...pts, pts[0]] : pts;
      for (let i = 0; i < seq.length - 1; i++) {
        const [ax, ay] = seq[i], [bx, by] = seq[i + 1];
        const steps = Math.max(1, Math.ceil(Math.max(Math.abs(bx - ax), Math.abs(by - ay)) * 2));
        for (let k = 0; k <= steps; k++) plot(Math.floor(ax + ((bx - ax) * k) / steps), Math.floor(ay + ((by - ay) * k) / steps));
      }
    }
  };
  const ring = mask => {                        // the outside neighbours of a mask, 4-connected
    const out = new Uint8Array(n);
    for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
      const k = y * width + x;
      if (mask[k]) continue;
      if ((x > 0 && mask[k - 1]) || (x < width - 1 && mask[k + 1]) || (y > 0 && mask[k - width]) || (y < height - 1 && mask[k + width])) out[k] = 1;
    }
    return out;
  };
  const paintMask = (mask, clip, paint, alpha, inv) => {
    for (let k = 0; k < n; k++) {
      if (!mask[k] || (clip && !clip[k])) continue;
      const [r, g, b, a0] = paint(...inv(k % width, Math.floor(k / width)));
      const a = a0 * alpha, q = k * 4, keep = 1 - a;
      rgba[q] = r / 255 * a + rgba[q] * keep; rgba[q + 1] = g / 255 * a + rgba[q + 1] * keep;
      rgba[q + 2] = b / 255 * a + rgba[q + 2] * keep; rgba[q + 3] = a + rgba[q + 3] * keep;
    }
  };
  for (const layer of scene.layers) {
    if (!visible(layer, { lod, pose })) continue;
    const m = groupMatrix(scene, pose, layer.group, lod), xf = toPx(m);
    const det = m[0] * m[3] - m[1] * m[2];
    const inv = (i, j) => {
      const u = (i + 0.5 - ox) / kx + vx - m[4], v = (j + 0.5 - oy) / ky + vy - m[5];
      return [(m[3] * u - m[2] * v) / det, (-m[1] * u + m[0] * v) / det];
    };
    let clip = null;
    const clipBy = c => { clip = clip || new Uint8Array(n).fill(1); for (let k = 0; k < n; k++) clip[k] &= c[k]; };
    for (const g of chain(scene, layer.group)) {
      const c = groupDef(scene, g, lod).clip;
      if (c) clipBy(cover(flatten(c.d, 0.05, toPx(groupMatrix(scene, pose, scene.groups[g].parent, lod))), c.rule));
    }
    if (layer.clip) clipBy(cover(flatten(layer.clip.d, 0.05, xf), layer.clip.rule));
    const contours = flatten(layer.d, 0.05, xf), alpha = layer.alpha ?? 1;
    if (layer.fill) {
      const mask = cover(contours, layer.rule);
      if (layer.stroke && layer.under) paintMask(ring(mask), clip, painter(layer.stroke), alpha, inv);
      paintMask(mask, clip, painter(layer.fill), alpha, inv);
    } else if (layer.stroke) {
      const w = (layer.w || 1) * s, mask = new Uint8Array(n);
      if (w <= 1.6) line(contours, mask);
      else strokeMask(contours, w / 2, mask, width, 0, height);
      paintMask(mask, clip, painter(layer.stroke), alpha, inv);
    }
  }
  return { width, height, px: rgba };
}

/** Straight-alpha RGBA bytes, optionally composited onto an opaque background colour. */
export function rgba8({ width, height, px }, bg = null) {
  const out = new Uint8ClampedArray(width * height * 4), b = bg && rgb(bg);
  for (let k = 0; k < width * height; k++) {
    const q = k * 4, a = px[q + 3];
    if (b) {
      for (let c = 0; c < 3; c++) out[q + c] = Math.round((px[q + c] + b[c] / 255 * (1 - a)) * 255);
      out[q + 3] = 255;
    } else {
      for (let c = 0; c < 3; c++) out[q + c] = a > 0 ? Math.round(px[q + c] / a * 255) : 0;
      out[q + 3] = Math.round(a * 255);
    }
  }
  return out;
}

/* --------------------------------------------------------------------- PNG */
const CRC = Array.from({ length: 256 }, (_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});
const crc = buf => { let c = 0xffffffff; for (const b of buf) c = CRC[(c ^ b) & 0xff] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
const chunk = (type, body) => {
  const head = Buffer.alloc(4), tail = Buffer.alloc(4), name = Buffer.from(type, 'latin1');
  head.writeUInt32BE(body.length);
  tail.writeUInt32BE(crc(Buffer.concat([name, body])));
  return Buffer.concat([head, name, body, tail]);
};
/** RGBA8 -> PNG bytes (colour type 6), node:zlib only. */
export function png(bytes, width, height) {
  const raw = Buffer.alloc((width * 4 + 1) * height);
  for (let y = 0; y < height; y++) {
    raw[y * (width * 4 + 1)] = 0;
    Buffer.from(bytes.buffer, bytes.byteOffset + y * width * 4, width * 4).copy(raw, y * (width * 4 + 1) + 1);
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0); ihdr.writeUInt32BE(height, 4); ihdr[8] = 8; ihdr[9] = 6;
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk('IHDR', ihdr),
                        chunk('IDAT', deflateSync(raw, { level: 9 })), chunk('IEND', Buffer.alloc(0))]);
}

/* --------------------------------------------------------------------- SVG */
function transformOf(scene, pose, g, lod) {
  const [dx, dy] = pose?.move?.[g] || [0, 0], deg = pose?.turn?.[g] || 0, [px, py] = groupDef(scene, g, lod).pivot || [0, 0];
  const t = [];
  if (dx || dy) t.push(`translate(${num(dx)} ${num(dy)})`);
  if (deg) t.push(`rotate(${num(deg)} ${num(px)} ${num(py)})`);
  return t.length ? ` transform="${t.join(' ')}"` : '';
}
const esc = s => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

/**
 * The scene as one SVG document. Groups nest as <g id>, a group's clip wraps it in the parent's
 * space (so a pose that moves the group does not drag its clip along), gradients are user-space.
 */
export function svg(scene, { width, height, title, desc, lod = 'hi', pose = {}, css = '', pad = 0,
                             viewBox = null, extra = '' } = {}) {
  const [vx, vy, vw, vh] = viewBox || scene.view;
  const defs = new Map();
  const ref = (kind, key, make) => {
    if (!defs.has(key)) defs.set(key, { id: `${kind}${defs.size}`, body: make(`${kind}${defs.size}`) });
    return defs.get(key).id;
  };
  const stops = st => st.map(([o, h, a = 1]) =>
    `<stop offset="${num(o, 3)}" stop-color="${h}"${a < 1 ? ` stop-opacity="${num(a, 3)}"` : ''}/>`).join('');
  const paint = p => {
    if (typeof p === 'string') return p;
    const key = JSON.stringify(p);
    const id = ref('g', key, id => p.type === 'linear'
      ? `<linearGradient id="${id}" gradientUnits="userSpaceOnUse" x1="${num(p.x1)}" y1="${num(p.y1)}" x2="${num(p.x2)}" y2="${num(p.y2)}">${stops(p.stops)}</linearGradient>`
      : `<radialGradient id="${id}" gradientUnits="userSpaceOnUse" cx="${num(p.cx)}" cy="${num(p.cy)}" r="${num(p.r)}">${stops(p.stops)}</radialGradient>`);
    return `url(#${id})`;
  };
  const clip = c => `url(#${ref('c', JSON.stringify(c), id =>
    `<clipPath id="${id}" clipPathUnits="userSpaceOnUse"><path d="${pathData(c.d)}"${c.rule === 'evenodd' ? ' clip-rule="evenodd"' : ''}/></clipPath>`)})`;

  let body = '', open = [];
  const indent = () => '  '.repeat(open.length + 1);
  for (const layer of scene.layers) {
    if (!visible(layer, { lod, pose })) continue;
    const want = chain(scene, layer.group);
    while (open.length && open[open.length - 1] !== want[open.length - 1]) {
      const g = open.pop();
      body += `${indent()}</g>\n`;
      if (groupDef(scene, g, lod).clip) body += `${indent()}</g>\n`;
    }
    while (open.length < want.length) {
      const g = want[open.length], def = groupDef(scene, g, lod);
      if (def.clip) body += `${indent()}<g clip-path="${clip(def.clip)}">\n`;
      body += `${indent()}<g class="${g}"${transformOf(scene, pose, g, lod)}>\n`;
      open.push(g);
    }
    const a = [`d="${pathData(layer.d)}"`];
    const stroke = layer.stroke
      ? [`stroke="${paint(layer.stroke)}"`, `stroke-width="${num(layer.w || 1)}"`,
         'stroke-linecap="round"', 'stroke-linejoin="round"',
         ...((layer.alpha ?? 1) < 1 ? [`stroke-opacity="${num(layer.alpha, 3)}"`] : [])]
      : [];
    const fill = [`fill="${layer.fill ? paint(layer.fill) : 'none'}"`];
    if (layer.fill && layer.rule === 'evenodd') fill.push('fill-rule="evenodd"');
    if (layer.fill && (layer.alpha ?? 1) < 1) fill.push(`fill-opacity="${num(layer.alpha, 3)}"`);
    const tail = [...(layer.clip ? [`clip-path="${clip(layer.clip)}"`] : []),
                  ...(layer.cls ? [`class="${layer.cls}"`] : [])];
    /* `under`: the outline is drawn first and the fill covers its inner half, so only half the
       stroke shows and a thin limb keeps all of its colour. Two elements rather than SVG 2's
       `paint-order`, which older sanitisers (and some renderers) drop — dropping that attribute
       would double every outline's apparent width. */
    if (layer.under && layer.fill && layer.stroke) {
      body += `${indent()}<path ${[...a, ...stroke, 'fill="none"', ...tail].join(' ')}/>\n`;
      body += `${indent()}<path ${[...a, ...fill, ...tail].join(' ')}/>\n`;
      continue;
    }
    body += `${indent()}<path ${[...a, ...fill, ...stroke, ...tail].join(' ')}/>\n`;
  }
  while (open.length) {
    const g = open.pop();
    body += `${indent()}</g>\n`;
    if (groupDef(scene, g, lod).clip) body += `${indent()}</g>\n`;
  }
  const box = [vx - pad, vy - pad, vw + 2 * pad, vh + 2 * pad].map(v => num(v)).join(' ');
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${box}"` +
    `${width ? ` width="${width}"` : ''}${height ? ` height="${height}"` : ''} role="img" aria-labelledby="t">\n` +
    `  <title id="t">${esc(title || '')}</title>\n` + (desc ? `  <desc>${esc(desc)}</desc>\n` : '') +
    (css ? `  <style>${css}</style>\n` : '') +
    (defs.size ? `  <defs>\n${[...defs.values()].map(d => `    ${d.body}`).join('\n')}\n  </defs>\n` : '') +
    body + extra + '</svg>\n';
}

/** The box the ink of a scene covers, in user units, strokes included. */
export function bounds(scene, { lod = 'hi', pose = {} } = {}) {
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  for (const layer of scene.layers) {
    if (!visible(layer, { lod, pose }) || (layer.alpha ?? 1) < 0.2) continue;
    const m = groupMatrix(scene, pose, layer.group, lod), h = layer.stroke ? (layer.w || 1) / 2 : 0;
    const box = d => {
      let a = Infinity, b = Infinity, c = -Infinity, e = -Infinity;
      for (const { pts } of flatten(d, 0.1, (x, y) => apply(m, x, y)))
        for (const [x, y] of pts) { a = Math.min(a, x); b = Math.min(b, y); c = Math.max(c, x); e = Math.max(e, y); }
      return [a, b, c, e];
    };
    let [a, b, c, e] = box(layer.d);
    a -= h; b -= h; c += h; e += h;
    if (layer.clip) {                        /* a clipped layer is no bigger than its clip */
      const k = box(layer.clip.d);
      a = Math.max(a, k[0]); b = Math.max(b, k[1]); c = Math.min(c, k[2]); e = Math.min(e, k[3]);
    }
    if (a > c || b > e) continue;
    x0 = Math.min(x0, a); y0 = Math.min(y0, b); x1 = Math.max(x1, c); y1 = Math.max(y1, e);
  }
  return [x0, y0, x1, y1];
}
