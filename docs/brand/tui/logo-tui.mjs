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
 *   node logo-tui.mjs --test               layout self-test (24..160 columns x 6..40 rows)
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
import { writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import * as V from './vector.mjs';
import * as M from './mascot.mjs';
import { emitSwift } from './swift.mjs';

const argv = process.argv.slice(2);
const arg = (n, d) => { const i = argv.indexOf(n); return i >= 0 ? argv[i + 1] ?? true : d; };
const has = n => argv.includes(n);

/* ------------------------------------------------------------------ renderers */
/** The sprite as dots: a dot is in when at least half of it is (`vector.mjs`'s `pixels`). */
function dots(scene, cols, rows, { pose = {}, lod = 'lo', view = null, aspect = 1 } = {}) {
  return V.pixels(scene, { width: cols, height: rows, pose, lod, ss: 3, view, aspect });
}
/** Dots -> half-block cells: one cell is two dot rows, fg above, bg below. */
export function blocks(scene, cols, rows, opts = {}) {
  const r = dots(scene, cols, rows * 2, opts), px = V.rgba8(r), out = [];
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
export function chars(scene, cols, rows, opts = {}) {
  const r = dots(scene, cols, rows, opts), px = V.rgba8(r), out = [];
  for (let y = 0; y < rows; y++) {
    const line = [];
    for (let x = 0; x < cols; x++) {
      const q = (y * cols + x) * 4;
      if (px[q + 3] < 128) { line.push({ ch: ' ' }); continue; }
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
/* The card is the product's: 36 columns of sprite, 18 rows, then the two captions. It is laid out
   here exactly as `LoadingView` lays it out, so the lab cannot disagree with the binary about what
   the card looks like. */
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
export function card(cols, rows, beat, mode = 'solid') {
  cols = Math.max(8, cols); rows = Math.max(4, rows);
  const pose = M.beat(beat), view = M.spriteView();
  const art = mode === 'plain'
    ? chars(M.scene(), CARD_COLS, CARD_ROWS, { pose, view, aspect: 1.25 })
    : blocks(M.scene(), CARD_COLS, CARD_ROWS, { pose, view, aspect: 1.25 });
  const top = Math.max(0, Math.floor((rows - (CARD_ROWS + 2)) / 2));
  const left = Math.max(0, Math.floor((cols - CARD_COLS) / 2));
  const out = [];
  for (let k = 0; k < top; k++) out.push(fit([], cols));
  const label = 'waiting for first frame' + '.'.repeat(beat % 4);
  for (let y = 0; y < CARD_ROWS; y++) out.push(fit([...blanks(left), ...art[y]], cols));
  out.push(fit([], cols));
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
        }
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
function heroSVG(widthPx = 680, { trim = true, pad = 0.03, bg = null } = {}) {
  const s = M.scene();
  const view = trim ? heroView(pad) : s.view;
  const [, , w, h] = view;
  const extra = bg
    ? `<rect x="${view[0]}" y="${view[1]}" width="${w}" height="${h}" fill="${bg}"/>`
    : '';
  return V.svg(s, {
    width: widthPx, height: Math.round(widthPx * h / w), lod: 'hi', viewBox: view, extra,
    title: "krd's mascot: a hermit crab in a spiral shell",
    desc: 'SSH is secure shell; the crab brings its desktop into the shell you already have open.',
  });
}
function spriteSVG(widthPx = 64) {
  const s = M.scene(), [, , w, h] = M.spriteView();
  return V.svg(s, {
    width: widthPx, height: Math.round(widthPx * h / w), lod: 'lo', viewBox: M.spriteView(),
    title: "krd's mark: the peeking hermit crab",
  });
}
function heroPNG(widthPx = 680, { trim = true, pad = 0.03, bg = null } = {}) {
  const s = M.scene(), view = trim ? heroView(pad) : s.view, [, , w, h] = view;
  const height = Math.round(widthPx * h / w / 2) * 2;
  const r = V.render(s, { width: widthPx, height, ss: 2, lod: 'hi', view });
  return V.png(V.rgba8(r, bg), widthPx, height);
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

if (has('--favicon')) {
  const out = arg('--favicon', null);
  if (typeof out !== 'string') { process.stdout.write('--favicon 要给一个文件名\n'); process.exit(1); }
  const px = Math.round(Number(arg('--px', 16))) || 16;
  /* A tab is 16 dots: the crab is drawn at `px - 2` and sits on the brand's near-black tile, because
     a pale shell on a white tab bar is a smudge and on a dark one it is invisible. One rect per run
     and no antialiasing — a favicon is a bitmap that happens to be an SVG. */
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
  writeFileSync(out, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${px} ${px}" `
    + `shape-rendering="crispEdges" role="img" aria-label="krd">${body}</svg>\n`);
  process.stdout.write(`${out}: ${px}x${px} px art\n`);
  process.exit(0);
}

if (has('--shot')) {
  const out = arg('--shot', null);
  if (typeof out !== 'string') { process.stdout.write('--shot 要给一个文件名\n'); process.exit(1); }
  const cols = Number(arg('--cols', 100)), rows = Number(arg('--rows', 30));
  const cards = [0, 1, 2, 3, 4, 5].map(i => `<figure>${pre(card(cols, rows, i))}`
    + `<figcaption>beat ${i}${i === 4 ? ' · blink' : ''}</figcaption></figure>`).join('');
  const plain = `<figure>${pre(card(cols, rows, 3, 'plain'))}<figcaption>character mode</figcaption></figure>`;
  const small = [80, 60, 40].map(c => `<figure>${pre(card(c, 24, 3))}<figcaption>${c} columns</figcaption></figure>`).join('');
  /* the assets themselves, on the same page: the drawing the README ships, and the two marks */
  const assets = `<figure>${heroSVG(520)}<figcaption>the drawing · hi · the README's SVG</figcaption></figure>`
    + `<figure>${spriteSVG(96)}<figcaption>the mark · lo · 96 px</figcaption></figure>`
    + `<figure class="light">${spriteSVG(96)}<figcaption>the mark · light background</figcaption></figure>`;
  writeFileSync(out, page(assets + cards + plain + small, 'KRD · mascot lab'));
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
  const bad = selfTest();
  process.stdout.write(bad.length ? bad.join('\n') + '\n' : 'ok: every size is exactly cols × rows\n');
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
