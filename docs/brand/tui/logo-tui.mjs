#!/usr/bin/env node
/**
 * KRD's mascot lab: one drawing, three renderers.
 *
 * The drawing is `mascot.mjs` — a hermit crab in a logarithmic-spiral shell, described as layers of
 * paths, gradients and clips (`vector.mjs`). Everything below is a *view* of that one scene, and
 * that is the point: the README's SVG, the terminal sprite and the loading card krd itself paints
 * cannot be three different crabs if they are three renderers of one scene.
 *
 *   node logo-tui.mjs                      interactive: the card, animated, in this terminal
 *   node logo-tui.mjs --test               layout self-test (8..160 columns x 4..40 rows)
 *   node logo-tui.mjs --frames             the eight beats, as the card draws them
 *   node logo-tui.mjs --art                the 46x23 character crab (docs, ASCII)
 *   node logo-tui.mjs --dump               both drawings, as half blocks
 *   node logo-tui.mjs --banner             the five-line KRD wordmark (for --help)
 *
 * Piped into something that is not a terminal it prints one card instead of animating it
 * (`--beat N`, `--plain` to pick which).
 *
 *   node logo-tui.mjs --svg hero.svg       the drawing, as one SVG, cropped to its ink (README)
 *   node logo-tui.mjs --png hero.png       the same, as PNG; transparent unless --bg is given
 *   node logo-tui.mjs --mark mark.svg      the sprite (lod "lo"), as SVG — the 64 px mark
 *   node logo-tui.mjs --favicon f.svg --px 16   the sprite as pixel art, one rect per run
 *   node logo-tui.mjs --beats strip.png    the four picture beats, side by side
 *   node logo-tui.mjs --shot lab.html      a page with every size, light and dark
 *   node logo-tui.mjs --swift Sources/krd/MascotArt.swift
 *                                          the drawing as Swift, for the loading card
 *
 * Zero dependencies, Node 18+.
 */
import { writeFileSync, readFileSync, existsSync } from 'node:fs';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import * as V from './vector.mjs';
import * as M from './mascot.mjs';
import * as W from './wordmark.mjs';
import { emitSwift } from './swift.mjs';

const argv = process.argv.slice(2);
const arg = (n, d) => { const i = argv.indexOf(n); return i >= 0 ? argv[i + 1] ?? true : d; };
const has = n => argv.includes(n);

/* ------------------------------------------------------------------ renderers */
/**
 * The sprite as dots, the way the *card* computes them: one point sample per dot on the card's own
 * paper, then every dot snapped to a colour the drawing contains.
 *
 * That is `MascotRaster`'s `.mosaic` rule, and it is deliberately not `pixels()`: `pixels()` decides
 * a dot by coverage (half of a 3x3 sample grid), which is the right rule for a 16 px mark and the
 * wrong one at 36, where it washes the pupils out and breaks the shell's groove into dashes. The
 * card in this lab has to be the card the binary paints, or the lab is another opinion.
 */
const PALETTE = new Map();
function palette(scene) {
  if (!PALETTE.has(scene)) {
    const add = p => typeof p === 'string' ? [p] : (p.stops || []).map(([, h]) => h);
    const all = new Set(['#080a10']);
    for (const l of scene.layers) for (const p of [l.fill, l.stroke]) if (p) for (const h of add(p)) all.add(h);
    PALETTE.set(scene, [...all].map(h => [...V.rgb(h), h]));
  }
  return PALETTE.get(scene);
}
function cardDots(scene, cols, rows, { pose = {}, lod = 'lo', view = null, aspect = 1 } = {}) {
  const r = V.render(scene, { width: cols, height: rows, ss: 1, pose, lod, view, aspect });
  const px = V.rgba8(r, '#080a10'), pal = palette(scene);
  for (let i = 0; i < px.length; i += 4) {
    let best = pal[0], bestD = Infinity;
    for (const p of pal) {
      const d = (px[i] - p[0]) ** 2 + (px[i + 1] - p[1]) ** 2 + (px[i + 2] - p[2]) ** 2;
      if (d < bestD) { bestD = d; best = p; }
    }
    px[i] = best[0]; px[i + 1] = best[1]; px[i + 2] = best[2]; px[i + 3] = 255;
  }
  /* `px.map` on a Uint8ClampedArray returns another Uint8ClampedArray, i.e. it `v / 255`s every
     channel back to 0 or 1; a Float32Array is what `rgba8` expects (premultiplied, 0..1) */
  const f = new Float32Array(px.length);
  for (let i = 0; i < px.length; i++) f[i] = i % 4 === 3 ? 1 : px[i] / 255;
  return { width: cols, height: rows, px: f };
}
/** The mark and the ASCII art: coverage, because at 16 px a half-covered dot is a dot. */
function dots(scene, cols, rows, { pose = {}, lod = 'lo', view = null, aspect = 1 } = {}) {
  return V.pixels(scene, { width: cols, height: rows, pose, lod, ss: 3, view, aspect });
}
/** Dots -> half-block cells: one cell is two dot rows, fg above, bg below. */
function blocks(scene, cols, rows, opts = {}) {
  const r = cardDots(scene, cols, rows * 2, opts), px = V.rgba8(r), out = [];
  for (let y = 0; y < rows; y++) {
    const line = [];
    for (let x = 0; x < cols; x++) {
      const t = (y * 2 * cols + x) * 4, b = ((y * 2 + 1) * cols + x) * 4;
      line.push({ ch: '▀', fg: [px[t], px[t + 1], px[t + 2]], bg: [px[b], px[b + 1], px[b + 2]] });
    }
    out.push(line);
  }
  return out;
}
/** Dots -> characters, one per cell, by the dot's own colour (the text version of the sprite). */
const GLYPHS = [
  [[243, 223, 184], '*'], [[255, 250, 242], '#'], [[196, 136, 78], 'o'], [[107, 69, 40], 'O'],
  [[244, 132, 90], 'x'], [[253, 232, 214], '+'], [[34, 15, 8], ' '], [[59, 36, 22], '.'],
  [[94, 184, 255], 'b'], [[28, 20, 32], '@'],
];
function chars(scene, cols, rows, opts = {}) {
  const r = cardDots(scene, cols, rows, opts), px = V.rgba8(r), out = [];
  for (let y = 0; y < rows; y++) {
    const line = [];
    for (let x = 0; x < cols; x++) {
      const q = (y * cols + x) * 4;
      /* the card's paper is not a material: a character version of the card leaves it blank */
      if (px[q + 3] < 128 || (Math.abs(px[q] - 8) + Math.abs(px[q + 1] - 10) + Math.abs(px[q + 2] - 16)) < 12) {
        line.push({ ch: ' ' });
        continue;
      }
      let best = GLYPHS[0], bestD = Infinity;
      for (const [c, ch] of GLYPHS) {
        const d = (px[q] - c[0]) ** 2 + (px[q + 1] - c[1]) ** 2 + (px[q + 2] - c[2]) ** 2;
        if (d < bestD) { bestD = d; best = [c, ch]; }
      }
      line.push({ ch: best[1] });
    }
    out.push(line);
  }
  return out;
}

const SGR = row => {
  let s = '', last = '|';
  for (const c of row) {
    const k = (c.fg || '') + '' + (c.bg || '');
    if (k !== last) {
      const parts = [];
      if (c.fg) parts.push(`38;2;${c.fg[0]};${c.fg[1]};${c.fg[2]}`);
      if (c.bg) parts.push(`48;2;${c.bg[0]};${c.bg[1]};${c.bg[2]}`);
      s += `\x1b[${parts.length ? '0;' + parts.join(';') : '0'}m`;
      last = k;
    }
    s += c.ch;
  }
  return s + '\x1b[0m';
};

/* ------------------------------------------------------------------- the card */
/* The card is the product's: 36 columns of sprite, 18 rows, then the two captions — 20 rows, no
   blank row between them (`LoadingView.labels()` starts at `originRow + cellRows + 1`). The sprite
   starts one column right of the card's own left edge, exactly as `originCol` does, so a screenshot
   of the lab and a screenshot of the binary line up. Where the terminal is narrower than the card
   the product *wraps* (its row is a fixed 37 columns whatever the pane) and this truncates: a lab
   that showed a wrapped row would be showing a bug as if it were the design. */
const CARD_COLS = 36, CARD_ROWS = 18;
const BLANK = { ch: ' ' };
const wide = ch => /[\u1100-\u115f\u2e80-\ua4cf\uac00-\ud7a3\uf900-\ufaff\ufe30-\ufe4f\uff00-\uff60]/.test(ch) ? 2 : 1;
const width = s => [...s].reduce((n, ch) => n + wide(ch), 0);
const txt = (s, fg = null) => [...s].map(ch => ({ ch, fg }));
const blanks = n => Array.from({ length: Math.max(0, n) }, () => BLANK);
const fit = (row, w) => {
  const out = [];
  let used = 0;
  for (const c of row) {
    const cw = wide(c.ch);
    if (used + cw > w) break;
    out.push(c); used += cw;
  }
  while (used < w) { out.push(BLANK); used++; }
  return out;
};
const centre = (s, fg, w) => fit([...blanks(Math.floor((w - width(s)) / 2)), ...txt(s, fg)], w);
const NOTE = [140, 150, 170], DIMTXT = [88, 98, 118];

/** The card at `beat`, in `cols` x `rows` cells: the sprite, centred, then the two captions. */
function card(cols, rows, beat, mode = 'solid') {
  cols = Math.max(8, cols); rows = Math.max(4, rows);
  const pose = M.beat(beat), view = M.spriteView();
  const art = mode === 'plain'
    ? chars(M.scene(), CARD_COLS, CARD_ROWS, { pose, view, aspect: 1.25 })
    : blocks(M.scene(), CARD_COLS, CARD_ROWS, { pose, view, aspect: 1.25 });
  const top = Math.max(0, Math.floor((rows - (CARD_ROWS + 2)) / 2));
  /* the product's `originCol` is `(cols - 36) / 2 + 1`: the sprite is indented one column, so the
     mosaic's 36 dots start there and the picture is placed on the same column */
  const left = Math.max(0, Math.floor((cols - CARD_COLS) / 2)) + 1;
  const out = [];
  for (let k = 0; k < top; k++) out.push(fit([], cols));
  const label = 'waiting for first frame' + '.'.repeat(beat % 4);
  for (let y = 0; y < CARD_ROWS; y++) out.push(fit([...blanks(left), ...art[y]], cols));
  out.push(fit([...blanks(left), ...centre(label, NOTE, CARD_COLS)], cols));
  out.push(fit([...blanks(left), ...centre('krd · connecting', DIMTXT, CARD_COLS)], cols));
  while (out.length < rows) out.push(fit([], cols));
  return out.slice(0, rows);
}
const ansi = f => f.map(SGR).join('\n') + '\n';

/* ------------------------------------------------- the four beats, as one strip */
/* What the loading picture is: four frames of the same drawing, side by side, so a document can
   show the animation without shipping a GIF. */
function beatsPNG(cellW = 256, gap = 12) {
  const s = M.scene(), view = M.spriteView();
  const w = cellW, h = Math.round(cellW * view[3] / view[2]);
  const W = w * 4 + gap * 3, H = h;
  const out = new Uint8ClampedArray(W * H * 4);
  [0, 2, 4, 6].forEach((beat, n) => {
    const r = V.render(s, { width: w, height: h, ss: 2, pose: M.beat(beat), lod: 'lo', view });
    const px = V.rgba8(r);
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        const q = (y * w + x) * 4, d = (y * W + x + n * (w + gap)) * 4;
        out[d] = px[q]; out[d + 1] = px[q + 1]; out[d + 2] = px[q + 2]; out[d + 3] = px[q + 3];
      }
    }
  });
  return V.png(out, W, H);
}

/* ------------------------------------------------------- the wordmark & lockup -- */
/* The letters are paths in `wordmark.mjs`, laid out by their own ink; the lockup places the crab
   and the wordmark in one scene, so every output below is the same two drawings at different
   sizes and backgrounds. */
function wordmarkSVG(widthPx = 960, id = '') {
  const s = W.wordmark();
  return V.svg(s, {
    width: widthPx, height: Math.round(widthPx * s.view[3] / s.view[2]), lod: 'hi', viewBox: s.view, id,
    title: 'KRD', desc: 'The krd wordmark: three letters drawn with the mascot\'s own stroke.',
  });
}
function lockupSVG(widthPx = 960, stacked = false, id = '') {
  const s = W.lockup(M.scene(), { stacked });
  return V.svg(s, {
    width: widthPx, height: Math.round(widthPx * s.view[3] / s.view[2]), lod: 'hi', viewBox: s.view, id,
    title: 'krd', desc: "The krd lockup: a hermit crab and the wordmark, ink aligned.",
  });
}
/* The social card is 2:1, so the lockup's own view is widened to that ratio around the ink and
   the margin becomes part of the view: no crop, and the whole card is the drawing. */
function socialScene(clear = 0.06) {
  const l = W.lockup(M.scene(), { clear });
  const [x, y, w, h] = l.view;
  const w2 = w * 1.1, h2 = w2 / 2;
  const cx = x + w / 2, cy = y + h / 2;
  return { ...l, view: [cx - w2 / 2, cy - h2 / 2, w2, h2] };
}
function socialPNG(widthPx = 1280) {
  const scene = socialScene(), height = Math.round(widthPx / 2);
  const r = V.render(scene, { width: widthPx, height, ss: 2, lod: 'hi', view: scene.view });
  return V.png(V.rgba8(r, '#080a10'), widthPx, height);
}

/* ------------------------------------------------------------------ the GIF -- */
/* The loading picture is 36 x 45 dots that the terminal scales 8x, so the GIF is rendered at the
   card's own resolution and then repeated by whole pixels: a smooth 288-wide render would be a
   picture the terminal never shows. */
function loadingFrames(cell = 8) {
  const w = 36, h = 45, W2 = w * cell, H2 = h * cell;
  return [0, 2, 4, 6].map(beat => {
    const r = V.render(M.scene(), { width: w, height: h, ss: 2, pose: M.beat(beat), lod: 'lo', view: M.spriteView() });
    const px = V.rgba8(r, '#080a10'), out = new Uint8ClampedArray(W2 * H2 * 4);
    for (let y = 0; y < H2; y++) {
      const sy = (y / cell) | 0;
      for (let x = 0; x < W2; x++) {
        const q = (sy * w + ((x / cell) | 0)) * 4, d = (y * W2 + x) * 4;
        out[d] = px[q]; out[d + 1] = px[q + 1]; out[d + 2] = px[q + 2]; out[d + 3] = 255;
      }
    }
    return { px: out };
  });
}
function loadingGIF(cell = 8, delay = 22) {
  const frames = loadingFrames(cell);
  return V.gif(frames, { width: 36 * cell, height: 45 * cell, delay, loop: 0 });
}

/* ---------------------------------------------------------------- the lab page */
const page = (body, title) => `<!doctype html><meta charset="utf-8"><title>${title}</title>
<style>html,body{margin:0;background:#05070c;color:#c9d2e2}
body{padding:18px;display:flex;flex-wrap:wrap;gap:16px;align-items:flex-start;
font:13px/1.4 ui-monospace,SFMono-Regular,Menlo,monospace}
pre{margin:0;padding:14px 16px;background:#07090f;border:1px solid #1e2330;border-radius:9px;
font:13px/1.12 ui-monospace,SFMono-Regular,Menlo,monospace;white-space:pre}
figure{margin:0;padding:10px;background:#07090f;border:1px solid #1e2330;border-radius:9px}
figure.light{background:#fff;border-color:#d8dce6}
figcaption{margin-top:8px;font-size:11px;color:#8b95a8}
figure.light figcaption{color:#5a6373}
</style>${body}`;
/* One span per run of identically styled cells: a card is a few hundred runs, not a few thousand
   spans, and the page stays small enough to commit. */
const styleOf = c => (c.fg ? `color:rgb(${c.fg.join(',')});` : '')
  + (c.bg ? `background:rgb(${c.bg.join(',')});` : '');
const escape = ch => ch.replace(/&/g, '&amp;').replace(/</g, '&lt;');
const pre = f => `<pre>${f.map(row => {
  let out = '', run = null;
  for (const c of row) {
    const st = styleOf(c);
    if (run && run.st === st) { run.text += escape(c.ch); continue; }
    if (run) out += run.st ? `<span style="${run.st}">${run.text}</span>` : run.text;
    run = { st, text: escape(c.ch) };
  }
  if (run) out += run.st ? `<span style="${run.st}">${run.text}</span>` : run.text;
  return out;
}).join('\n')}</pre>`;

/* --------------------------------------------------------------- self-test -- */
/* Every size the card can meet, and the two invariants that break a TUI: a row that is not exactly
   `cols` display cells (the terminal wraps and the card's rows shift) and a card taller than the
   pane (the captions fall off the bottom). */
function selfTest() {
  const bad = [];
  for (const cols of [8, 20, 24, 36, 40, 60, 80, 100, 137, 160])
    for (const rows of [4, 6, 9, 14, 20, 22, 40])
      for (const mode of ['solid', 'plain'])
        for (const beat of [0, 3, 4]) {
          const f = card(cols, rows, beat, mode);
          if (f.length !== rows) bad.push(`${cols}x${rows} ${mode} beat ${beat}: ${f.length} rows`);
          f.forEach((l, i) => {
            const w = l.reduce((n, c) => n + wide(c.ch), 0);
            if (w !== cols) bad.push(`${cols}x${rows} ${mode} beat ${beat} row ${i}: width ${w}`);
          });
          /* the two rows that are the card and not the sprite: a card sized as if it were one row
             shorter drops `krd · connecting` off the bottom, which is invisible to the checks above */
          const text = f.map(l => l.map(c => c.ch).join('')).join('\n');
          /* only where the card can fit at all: below 36 columns the product's row wraps and
             the lab truncates on purpose, so a missing caption there is the terminal's size
             rather than the card's arithmetic */
          if (rows >= CARD_ROWS + 2 && cols >= CARD_COLS) {
            if (!text.includes('waiting for first frame'))
              bad.push(`${cols}x${rows} ${mode} beat ${beat}: no first caption`);
            if (!text.includes('krd · connecting'))
              bad.push(`${cols}x${rows} ${mode} beat ${beat}: no second caption`);
          }
        }
  return bad;
}

/* ------------------------------------------- the wordmark, the lockup, the assets -- */
/* A GIF read back the way a viewer reads it: the header, the global table, the Netscape loop, and
   every frame's LZW. A test that only checks the magic bytes would not notice a palette index that
   decodes to the wrong pixel, which is the one way this encoder can be wrong and still look like a
   GIF. */
function readGIF(buf) {
  if (buf.toString('latin1', 0, 6) !== 'GIF89a') throw new Error('not GIF89a');
  const width = buf.readUInt16LE(6), height = buf.readUInt16LE(8);
  const gct = 2 << (buf[10] & 7);
  let p = 13;
  const palette = [];
  for (let i = 0; i < gct; i++, p += 3) palette.push([buf[p], buf[p + 1], buf[p + 2]]);
  const out = { width, height, palette, loop: null, delay: [], frames: [], transparent: [] };
  const blocks = () => {
    const parts = [];
    while (buf[p] !== 0) { const n = buf[p++]; parts.push(buf.subarray(p, p + n)); p += n; }
    p++;
    return parts;
  };
  while (p < buf.length) {
    const b = buf[p++];
    if (b === 0x3b) break;
    if (b === 0x21) {
      const label = buf[p++], parts = blocks();
      if (label === 0xf9) { out.delay.push(parts[0].readUInt16LE(1)); out.transparent.push(parts[0][0] & 1); }
      else if (label === 0xff && parts[0].toString('latin1') === 'NETSCAPE2.0') out.loop = parts[1].readUInt16LE(1);
    } else if (b === 0x2c) {
      const x = buf.readUInt16LE(p), y = buf.readUInt16LE(p + 2);
      const w = buf.readUInt16LE(p + 4), h = buf.readUInt16LE(p + 6), packed = buf[p + 8];
      p += 9;
      let local = null;
      if (packed & 0x80) { const n = 2 << (packed & 7); local = []; for (let i = 0; i < n; i++, p += 3) local.push([buf[p], buf[p + 1], buf[p + 2]]); }
      const min = buf[p++], data = Buffer.concat(blocks());
      out.frames.push({ x, y, width: w, height: h, min, data, local });
    } else throw new Error(`unknown GIF block 0x${b.toString(16)}`);
  }
  return out;
}
/** GIF's LZW, decoder side: the same table rules the encoder above follows. */
function lzwDecode(data, min) {
  const clear = 1 << min, eoi = clear + 1;
  let size = min + 1, dict, next, prev;
  const reset = () => {
    dict = []; for (let i = 0; i < clear; i++) dict[i] = [i];
    dict[clear] = []; dict[eoi] = [];
    next = eoi + 1; size = min + 1; prev = -1;
  };
  reset();
  const out = [];
  let acc = 0, bits = 0, pos = 0;
  const code = () => {
    while (bits < size) { acc |= (data[pos++] || 0) << bits; bits += 8; }
    const v = acc & ((1 << size) - 1); acc >>>= size; bits -= size; return v;
  };
  for (;;) {
    const c = code();
    if (c === eoi) break;
    if (c === clear) { reset(); continue; }
    const entry = c < next ? dict[c] : [...dict[prev], dict[prev][0]];
    if (!entry) throw new Error(`bad LZW code ${c}`);
    for (const v of entry) out.push(v);
    if (prev >= 0 && next < 4096) {
      dict[next++] = [...dict[prev], entry[0]];
      if (next === (1 << size) && size < 12) size++;
    }
    prev = c;
  }
  return out;
}
/* How much air the view leaves around the ink, on each side. A negative number is a crop. */
function margins(scene, lod = 'hi') {
  const [vx, vy, vw, vh] = scene.view, [x0, y0, x1, y1] = V.bounds(scene, { lod });
  return [x0 - vx, y0 - vy, vx + vw - x1, vy + vh - y1];
}
const close = (a, b, eps = 0.01) => Math.abs(a - b) <= eps;

function brandTest() {
  const bad = [];
  const note = (m) => bad.push(m);

  /* the wordmark: three letters, one cap height, the documented spacing between their ink */
  const word = W.wordmark();
  const names = Object.keys(word.boxes);
  if (names.join('') !== 'KRD') note(`wordmark: letters are ${names.join('')}, not KRD`);
  const boxes = names.map(n => word.boxes[n]);
  for (let i = 1; i < boxes.length; i++) {
    const gap = boxes[i][0] - boxes[i - 1][1];
    if (!close(gap, W.GAP, 0.5)) note(`wordmark: ${names[i - 1]}-${names[i]} ink gap ${gap.toFixed(2)}, want ${W.GAP}`);
  }
  const [wx0, wy0, wx1, wy1] = V.bounds(word, { lod: 'hi' });
  if (!close(wy1 - wy0, W.CAP + W.OUTLINE, 0.5)) note(`wordmark: ink height ${(wy1 - wy0).toFixed(2)}, want ${W.CAP + W.OUTLINE}`);
  const wm = margins(word);
  if (Math.min(...wm) < -0.01) note(`wordmark: the view crops its ink (margins ${wm.map(v => v.toFixed(1)).join(', ')})`);
  if (word.layers.length !== 3) note(`wordmark: ${word.layers.length} layers, want one per letter`);

  /* the lockup: the crab's ink and the wordmark's are LEAD apart (side by side) or STACK apart
     (stacked), the baseline is one line, and no ink falls outside the view */
  const crabLayers = M.scene().layers.length;
  const side = W.lockup(M.scene(), {});
  if (side.layers.length !== crabLayers + 3) note('lockup: a layer went missing between the crab and the wordmark');
  const crab = side.parts.crab, wpart = side.parts.word;
  const between = wpart[0] - crab[2];
  if (!close(between, W.LEAD, 0.5)) note(`lockup: crab-to-word ink gap ${between.toFixed(2)}, want ${W.LEAD}`);
  if (!close(crab[3], wpart[3], 0.3)) note(`lockup: baselines differ (${crab[3].toFixed(2)} vs ${wpart[3].toFixed(2)})`);
  for (const s of [side, W.lockup(M.scene(), { stacked: true })]) {
    const ms = margins(s);
    const want = 0.14 * W.CAP;
    if (Math.min(...ms) < want - 0.5) note(`lockup: clear space ${ms.map(v => v.toFixed(1)).join(', ')}, want >= ${want}`);
  }
  const stacked = W.lockup(M.scene(), { stacked: true });
  const sc = stacked.parts.crab, sw = stacked.parts.word;
  if (!close((sc[0] + sc[2]) / 2, (sw[0] + sw[2]) / 2, 0.5)) note('lockup (stacked): not centred on one axis');
  if (!close(sw[1] - sc[3], W.STACK, 0.5)) note(`lockup (stacked): ink gap ${(sw[1] - sc[3]).toFixed(2)}, want ${W.STACK}`);

  /* the GIF: the right size, four frames, the card's delay, forever, and the pixels come back */
  const cell = 8, gif = readGIF(loadingGIF(cell));
  if (gif.width !== 36 * cell || gif.height !== 45 * cell) note(`gif: ${gif.width}x${gif.height}, want ${36 * cell}x${45 * cell}`);
  if (gif.loop !== 0) note(`gif: loop=${gif.loop}, want 0 (forever)`);
  if (gif.frames.length !== 4) note(`gif: ${gif.frames.length} frames, want 4`);
  if (gif.delay.length !== 4 || gif.delay.some(d => d !== 22)) note(`gif: delays ${gif.delay.join(',')}, want four 220 ms`);
  if (gif.palette.length > 256) note(`gif: palette ${gif.palette.length} > 256`);
  const frames = loadingFrames(cell), decoded = gif.frames.map(f => lzwDecode(f.data, f.min));
  const n = 36 * cell * 45 * cell;
  let worst = 0, same = 0;
  decoded.forEach((idx, k) => {
    if (idx.length !== n) { note(`gif: frame ${k} decodes to ${idx.length} pixels, want ${n}`); return; }
    const src = frames[k].px;
    for (let i = 0; i < n; i++) {
      const c = gif.palette[idx[i]], q = i * 4;
      worst = Math.max(worst, Math.abs(c[0] - src[q]), Math.abs(c[1] - src[q + 1]), Math.abs(c[2] - src[q + 2]));
    }
    if (k && idx.every((v, i) => v === decoded[k - 1][i])) same++;
  });
  if (worst > 2) note(`gif: decoded colour is off by ${worst}/255 (want <= 2)`);
  if (same) note(`gif: ${same} frame(s) identical to the frame before; the four beats must differ`);

  /* the social card: 2:1, 1280x640, a real PNG */
  const social = socialScene(), [, , sw2, sh2] = social.view;
  if (!close(sw2 / sh2, 2, 1e-6)) note(`social: view ${sw2.toFixed(1)}x${sh2.toFixed(1)} is not 2:1`);
  const png = socialPNG(1280);
  if (png.toString('latin1', 1, 4) !== 'PNG') note('social: not a PNG');
  if (png.readUInt32BE(16) !== 1280 || png.readUInt32BE(20) !== 640) note(`social: ${png.readUInt32BE(16)}x${png.readUInt32BE(20)}, want 1280x640`);
  return bad;
}

/* --------------------------------------------------------------------- SVG -- */
/* The picture as an asset: cropped to what is actually drawn, transparent, so it reads on a light
   and a dark page alike — a card with a background burned into it is what issue #85 complained
   about. `--trim` is the default for the hero; `--pad` is how much air to leave around the ink. */
function heroView(pad = 0.03) {
  const [x, y, w, h] = V.bounds(M.scene(), { lod: 'hi' });
  const m = Math.max(w, h) * pad;
  return [x - m, y - m, w + 2 * m, h + 2 * m];
}
function heroSVG(widthPx = 680, { trim = true, pad = 0.03, bg = null, id = '' } = {}) {
  const s = M.scene();
  const view = trim ? heroView(pad) : s.view;
  const [, , w, h] = view;
  const extra = bg
    ? `<rect x="${view[0]}" y="${view[1]}" width="${w}" height="${h}" fill="${bg}"/>`
    : '';
  return V.svg(s, {
    width: widthPx, height: Math.round(widthPx * h / w), lod: 'hi', viewBox: view, extra, id,
    title: "krd's mascot: a hermit crab in a spiral shell",
    desc: 'SSH is secure shell; the crab brings its desktop into the shell you already have open.',
  });
}
function spriteSVG(widthPx = 64, id = '') {
  const s = M.scene(), [, , w, h] = M.spriteView();
  return V.svg(s, {
    width: widthPx, height: Math.round(widthPx * h / w), lod: 'lo', viewBox: M.spriteView(), id,
    title: "krd's mark: the peeking hermit crab",
  });
}
function heroPNG(widthPx = 680, { trim = true, pad = 0.03, bg = null } = {}) {
  const s = M.scene(), view = trim ? heroView(pad) : s.view, [, , w, h] = view;
  const height = Math.round(widthPx * h / w / 2) * 2;
  const r = V.render(s, { width: widthPx, height, ss: 2, lod: 'hi', view });
  return V.png(V.rgba8(r, bg), widthPx, height);
}

function shotHTML(cols = 100, rows = 30) {
  const cards = [0, 1, 2, 3, 4, 5].map(i => `<figure>${pre(card(cols, rows, i))}`
    + `<figcaption>beat ${i}${i === 4 ? ' · blink' : ''}</figcaption></figure>`).join('');
  const plain = `<figure>${pre(card(cols, rows, 3, 'plain'))}<figcaption>character mode</figcaption></figure>`;
  const small = [80, 60, 40].map(c => `<figure>${pre(card(c, 24, 3))}<figcaption>${c} columns</figcaption></figure>`).join('');
  /* the assets themselves, on the same page: the drawing the README ships, the two marks, the
     lockup and the wordmark — one page to see whether any of them drifted apart */
  const assets = `<figure>${heroSVG(520, { id: 'hero' })}<figcaption>the drawing · hi · the README's SVG</figcaption></figure>`
    + `<figure>${spriteSVG(96, 'mark')}<figcaption>the mark · lo · 96 px</figcaption></figure>`
    + `<figure class="light">${spriteSVG(96, 'mark2')}<figcaption>the mark · light background</figcaption></figure>`
    + `<figure>${lockupSVG(520, false, 'lock')}<figcaption>the lockup · hi · 520 px</figcaption></figure>`
    + `<figure>${wordmarkSVG(520, 'word')}<figcaption>the wordmark · 520 px</figcaption></figure>`;
  return page(assets + cards + plain + small, 'KRD · mascot lab');
}

/* ---------------------------------------------------------------- the CLI -- */
/* Wrapped so the file can be imported (the card's layout is worth testing without a terminal). */
export function main() {
if (has('--swift')) {
  const out = arg('--swift', null);
  const beats = Array.from({ length: M.PEEK.length }, (_, i) => M.beat(i));
  const src = emitSwift(M.scene(), { lod: 'lo', beats, view: M.spriteView() });
  if (typeof out === 'string') { writeFileSync(out, src); process.stdout.write(`${out}: ${src.split('\n').length} lines\n`); }
  else process.stdout.write(src);
  process.exit(0);
}

if (has('--svg')) {
  const out = arg('--svg', null);
  if (typeof out !== 'string') { process.stdout.write('--svg 要给一个文件名\n'); process.exit(1); }
  const px = Number(arg('--px', 680));
  writeFileSync(out, heroSVG(px, { trim: !has('--no-trim'), pad: Number(arg('--pad', 0.03)),
                                  bg: arg('--bg', null) }));
  process.stdout.write(`${out}: ${px} px wide\n`);
  process.exit(0);
}

if (has('--mark')) {
  const out = arg('--mark', null);
  if (typeof out !== 'string') { process.stdout.write('--mark 要给一个文件名\n'); process.exit(1); }
  writeFileSync(out, spriteSVG(Number(arg('--px', 64))));
  process.stdout.write(`${out}: ${arg('--px', 64)} px wide\n`);
  process.exit(0);
}

if (has('--png')) {
  const out = arg('--png', null);
  if (typeof out !== 'string') { process.stdout.write('--png 要给一个文件名\n'); process.exit(1); }
  writeFileSync(out, heroPNG(Number(arg('--px', 680)), {
    trim: !has('--no-trim'), pad: Number(arg('--pad', 0.03)), bg: arg('--bg', null),
  }));
  process.stdout.write(`${out}: ${arg('--px', 680)} px wide`
    + `${arg('--bg', null) ? `, on ${arg('--bg', null)}` : ', transparent'}\n`);
  process.exit(0);
}

if (has('--beats')) {
  const out = arg('--beats', null);
  if (typeof out !== 'string') { process.stdout.write('--beats 要给一个文件名\n'); process.exit(1); }
  writeFileSync(out, beatsPNG(Number(arg('--px', 256))));
  process.stdout.write(`${out}: four beats\n`);
  process.exit(0);
}

if (has('--wordmark')) {
  const out = arg('--wordmark', null);
  if (typeof out !== 'string') { process.stdout.write('--wordmark 要给一个文件名\n'); process.exit(1); }
  writeFileSync(out, wordmarkSVG(Number(arg('--px', 960))));
  process.stdout.write(`${out}: ${arg('--px', 960)} px wide\n`);
  process.exit(0);
}

if (has('--lockup')) {
  const out = arg('--lockup', null);
  if (typeof out !== 'string') { process.stdout.write('--lockup 要给一个文件名\n'); process.exit(1); }
  writeFileSync(out, lockupSVG(Number(arg('--px', 960)), has('--stacked')));
  process.stdout.write(`${out}: ${arg('--px', 960)} px wide${has('--stacked') ? ', stacked' : ''}\n`);
  process.exit(0);
}

if (has('--social')) {
  const out = arg('--social', null);
  if (typeof out !== 'string') { process.stdout.write('--social 要给一个文件名\n'); process.exit(1); }
  const px = Number(arg('--px', 1280));
  writeFileSync(out, socialPNG(px));
  process.stdout.write(`${out}: ${px}x${Math.round(px / 2)} on #080a10\n`);
  process.exit(0);
}

if (has('--gif')) {
  const out = arg('--gif', null);
  if (typeof out !== 'string') { process.stdout.write('--gif 要给一个文件名\n'); process.exit(1); }
  const cell = Math.max(1, Math.round(Number(arg('--cell', 8))));
  writeFileSync(out, loadingGIF(cell));
  process.stdout.write(`${out}: 36x45 dots at ${cell}x, four frames, 880 ms loop\n`);
  process.exit(0);
}

/* A tab is 16 dots: the crab is drawn at `px - 2` and sits on the brand's near-black tile, because
   a pale shell on a white tab bar is a smudge and on a dark one it is invisible. One rect per run
   and no antialiasing — a favicon is a bitmap that happens to be an SVG. */
function faviconSVG(px = 16) {
  const art = dots(M.scene(), px - 2, px - 2, { pose: M.beat(3), view: M.spriteView() });
  const rgba = V.rgba8(art);
  const tile = [];
  for (let y = 0; y < px; y++) tile.push(new Array(px).fill(null));
  for (let y = 0; y < px; y++) {
    for (let x = 0; x < px; x++) {
      const corner = (x === 0 || x === px - 1) && (y === 0 || y === px - 1);
      if (!corner) tile[y][x] = [8, 10, 16];
    }
  }
  for (let y = 0; y < px - 2; y++) {
    for (let x = 0; x < px - 2; x++) {
      const q = (y * (px - 2) + x) * 4;
      if (rgba[q + 3] < 128) continue;
      tile[y + 1][x + 1] = [rgba[q], rgba[q + 1], rgba[q + 2]];
    }
  }
  let body = '';
  for (let y = 0; y < px; y++) {
    for (let x = 0; x < px;) {
      const c = tile[y][x];
      if (!c) { x++; continue; }
      let w = 1;
      while (x + w < px && tile[y][x + w] && tile[y][x + w].join() === c.join()) w++;
      body += `<rect x="${x}" y="${y}" width="${w}" height="1" fill="${V.hex(c)}"/>`;
      x += w;
    }
  }
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${px} ${px}" `
    + `shape-rendering="crispEdges" role="img" aria-label="krd">${body}</svg>\n`;
}

/* ------------------------------------------------------------------ the assets -- */
/* Every file this generator owns. `--write` rewrites them, `--verify` regenerates in memory and
   compares — the drift alarm, so a hand-edited generated file cannot land. The root is resolved
   from this file, so the two modes work from any directory. */
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '../../..');
const swift = () => emitSwift(M.scene(), {
  lod: 'lo', beats: Array.from({ length: M.PEEK.length }, (_, i) => M.beat(i)), view: M.spriteView(),
});
const ASSETS = [
  ['Sources/krd/MascotArt.swift', swift],
  ['docs/media/mascot.svg', () => heroSVG(680)],
  ['docs/media/mascot.png', () => heroPNG(680)],
  ['docs/media/mascot-loading.png', () => beatsPNG(256)],
  ['docs/media/mascot-loading.gif', () => loadingGIF(8)],
  ['docs/media/krd-social.png', () => socialPNG(1280)],
  ['docs/brand/tui/krd-mark.svg', () => spriteSVG(64)],
  ['docs/brand/tui/krd-favicon.svg', () => faviconSVG(16)],
  ['docs/brand/tui/krd-wordmark.svg', () => wordmarkSVG(960)],
  ['docs/brand/tui/krd-lockup.svg', () => lockupSVG(960)],
  ['docs/brand/tui/krd-lockup-stacked.svg', () => lockupSVG(640, true)],
  ['docs/brand/tui/shot.html', () => shotHTML(96, 26)],
];

if (has('--write')) {
  for (const [file, make] of ASSETS) {
    writeFileSync(join(ROOT, file), make());
    process.stdout.write(`${file}\n`);
  }
  process.exit(0);
}
if (has('--verify')) {
  const stale = [];
  for (const [file, make] of ASSETS) {
    const path = join(ROOT, file), data = make();
    const want = Buffer.isBuffer(data) ? data : Buffer.from(data);
    if (!existsSync(path) || !readFileSync(path).equals(want)) stale.push(file);
  }
  if (stale.length) {
    process.stdout.write(stale.map(f => `stale: ${f}`).join('\n') + '\nrun make mascot\n');
    process.exit(1);
  }
  process.stdout.write(`ok: all ${ASSETS.length} generated files match their source\n`);
  process.exit(0);
}

if (has('--favicon')) {
  const out = arg('--favicon', null);
  if (typeof out !== 'string') { process.stdout.write('--favicon 要给一个文件名\n'); process.exit(1); }
  const px = Math.round(Number(arg('--px', 16))) || 16;
  writeFileSync(out, faviconSVG(px));
  process.stdout.write(`${out}: ${px}x${px} px art\n`);
  process.exit(0);
}

if (has('--shot')) {
  const out = arg('--shot', null);
  if (typeof out !== 'string') { process.stdout.write('--shot 要给一个文件名\n'); process.exit(1); }
  writeFileSync(out, shotHTML(Number(arg('--cols', 100)), Number(arg('--rows', 30))));
  process.stdout.write(`${out}\n`);
  process.exit(0);
}

/* ------------------------------------------------------------ --help 版 -- */
const WORD = [
  '  ██    ██  ██████    ██████  ',
  '  ██  ██    ██    ██  ██    ██',
  '  ████      ██████    ██    ██',
  '  ██  ██    ██  ██    ██    ██',
  '  ██    ██  ██    ██  ██████  ',
];
const banner = () => [...WORD, '', "  your mac's desktop, inside a terminal",
  '  SSH shell · kitty graphics · no codec'].join('\n');
if (has('--banner')) { process.stdout.write(banner() + '\n'); process.exit(0); }

if (has('--art')) {
  const f = chars(M.scene(), 46, 23, { pose: M.beat(3), view: M.spriteView() });
  process.stdout.write(f.map(l => l.map(c => c.ch).join('').replace(/\s+$/, '')).join('\n') + '\n');
  process.exit(0);
}
if (has('--dump')) {
  for (const lod of ['lo', 'hi']) {
    const view = lod === 'lo' ? M.spriteView() : null;
    process.stdout.write(`\n${lod}\n` + ansi(blocks(M.scene(), 64, 28, { lod, view })));
  }
  process.exit(0);
}
if (has('--test')) {
  const bad = [...selfTest(), ...brandTest()];
  process.stdout.write(bad.length ? bad.join('\n') + '\n'
    : 'ok: every card size is exactly cols × rows; the wordmark, the lockup, the GIF and the social card hold\n');
  process.exit(bad.length ? 1 : 0);
}
if (has('--frames')) {
  for (let i = 0; i < M.PEEK.length; i++) {
    process.stdout.write(`\nbeat ${i}  peek=${M.PEEK[i]}${i === 4 ? '  blink' : ''}\n`);
    for (const line of card(64, 22, i, 'plain'))
      process.stdout.write(line.map(c => c.ch).join('').replace(/\s+$/, '') + '\n');
  }
  process.exit(0);
}

/* ---------------------------------------------------------------- the TUI -- */
const stdin = process.stdin, stdout = process.stdout;
const size = () => ({ cols: stdout.columns || 100, rows: stdout.rows || 34 });
let beat = 0, paused = false, mode = 'solid', clock = null, blocked = false;
const paint = () => {
  const { cols, rows } = size();
  const f = card(cols, rows, beat, mode);
  let s = '';
  for (let i = 0; i < f.length; i++) s += `\x1b[${i + 1};1H\x1b[2K` + SGR(f[i]);
  /* A terminal slower than the card (a serial line, a recording pty) is not something to fight:
     drop frames rather than queue them, so a keystroke never waits behind a backlog of paints. */
  if (blocked) return;
  if (!stdout.write(s)) blocked = true;
};
const draw = () => { try { paint(); } catch (e) { stdout.write(`\r\nmascot: ${e.message}\r\n`); } };
if (!stdin.isTTY) {
  const { cols, rows } = size();
  stdout.write(ansi(card(cols, rows, Number(arg('--beat', 0)) || 0, has('--plain') ? 'plain' : 'solid')));
  process.exit(0);
}
stdout.write('\x1b[?1049h\x1b[?25l\x1b[2J');
/* Restoring the screen is the one write that must not be lost, so it goes out and *then* the
   process ends: on a pty `stdout` is asynchronous, and `process.exit()` on the same tick would drop
   the `?1049l` and leave the terminal in the alternate screen. */
const quit = () => {
  if (clock) clearInterval(clock);
  clock = null;
  stdin.setRawMode(false);
  const restore = '\x1b[0m\x1b[?25h\x1b[?1049l';
  stdout.write(restore, () => process.exit(0));
  setTimeout(() => process.exit(0), 250);
};
const repaint = () => { stdout.write('\x1b[2J'); draw(); };
stdout.on('drain', () => { blocked = false; });
stdin.setRawMode(true); stdin.resume(); repaint();
/* A chunk can carry more than one keypress (a paste, or a pty that delivered two sends at once), so
   they are split rather than compared whole: `"sq"` is two commands, not an unknown one. */
const keys = chunk => chunk.startsWith('\x1b[') ? [chunk.slice(0, 3), ...keys(chunk.slice(3))]
                                               : [...chunk];
stdin.on('data', b => {
  for (const s of keys(b.toString())) handle(s);
});
const handle = s => {
  if (s === 'q' || s === '\x03') return quit();
  if (s === ' ') paused = !paused;
  else if (s === 's' || s === '\t') mode = mode === 'solid' ? 'plain' : 'solid';
  else if (/^[1-8]$/.test(s)) beat = +s - 1;
  else if (s === 'j' || s === '\x1b[B') beat = (beat + 1) % 8;
  else if (s === 'k' || s === '\x1b[A') beat = (beat + 7) % 8;
  else return;
  draw();
};
process.on('SIGWINCH', repaint);
process.on('SIGHUP', quit);
process.on('SIGTERM', quit);
clock = setInterval(() => { if (paused) return; beat = (beat + 1) % 8; draw(); }, 110);
process.on('exit', () => stdout.write('\x1b[0m\x1b[?25h\x1b[?1049l'));
}

/* run as a program, not as a library */
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main();
