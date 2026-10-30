#!/usr/bin/env node
/**
 * KRD · mascot lab — 一个 TUI，把同一份矢量造型画成两种样子：
 *   solid (拟物)  2x 超采样 → 24-bit 真彩半块 ▀
 *   plain (字符)  每格取占多数的材质 → 一个 ASCII 字符
 *
 *   node logo-tui.mjs                    交互（1-4 换 · s 单屏 · q 退出）
 *   node logo-tui.mjs --dump             打到 stdout
 *   node logo-tui.mjs --shot out.html    存成 HTML 截图
 *   node logo-tui.mjs --png out.png      只画蟹，直接写 PNG（README 那张图）
 *
 * 零依赖，Node 18+。
 */
const H = s => [1, 3, 5].map(i => parseInt(s.slice(i, i + 2), 16));
const INK = H('#06080d'), PAPER = H('#080a10'), BLUE = H('#5eb8ff'), SLATE = H('#3d4a68'),
      DIM = H('#232c42'), LIGHT = H('#e8f1ff'), MID = H('#2f6ea8'),
      SHELL_HI = H('#5b7099');
/* 寄居蟹自己的颜色：壳是沙色带棕色螺纹，蟹身是珊瑚色 —— 品牌蓝只剩瞳孔里那一点光 */
const SAND = H('#d9c4a1'), CREAM = H('#f4e7cc'), BROWN = H('#8a6a46'), BROWN_D = H('#5b4530'),
      CORAL = H('#f18a5e'), CORAL_D = H('#c76040');

/* 造型原语：96×96 一个坐标系，四个动物共用 */
const E = (c, x, y, rx, ry) => ({ k: 'e', c, x, y, rx, ry });
const R = (c, x, y, w, h, r = 0) => ({ k: 'r', c, x, y, w, h, r });
const G = (c, pts) => ({ k: 'p', c, pts });
const L = (c, pts, w) => ({ k: 'l', c, pts, w });
const coil = (cx, cy, r0, r1, turns, a0 = 0, n = 80) =>
  Array.from({ length: n + 1 }, (_, i) => {
    const t = i / n, a = a0 + t * turns * 2 * Math.PI, r = r0 + (r1 - r0) * t;
    return [cx + Math.cos(a) * r, cy + Math.sin(a) * r];
  });

const ANIMALS = [
  {
    id: 'chameleon', name: '变色龙', en: 'chameleon',
    line: '皮肤就是一格一格的色素细胞：每一格变色，拼出整张画面', flag: '推荐',
    why: '变色=镜像 · 两只眼各转=双屏 · 卷尾巴=@ · 色素细胞=终端格子',
    draw: () => {
      const cells = [];
      for (let r = 0; r < 3; r++) for (let c = 0; c < 5; c++) {
        const x = 29 + c * 8, y = 48 + r * 7.5;
        if (((x + 3 - 48) / 22) ** 2 + ((y + 2.5 - 56) / 13) ** 2 < 0.95)
          cells.push(R(LIGHT, x, y, 5.4, 4.2, 1.4));
      }
      return [
        L(DIM, [[8, 84], [88, 84]], 6),
        L(BLUE, coil(21, 72, 13, 4, 1.35, -1.2), 8),
        E(BLUE, 44, 78, 7, 6), R(BLUE, 62, 32, 24, 23, 8),
        G(BLUE, [[64, 35], [72, 19], [80, 35]]), G(BLUE, [[79, 43], [94, 52], [79, 59]]),
        E(BLUE, 48, 56, 24, 15), ...cells,
        E(MID, 73, 43, 9, 9), E(INK, 73, 43, 5.2, 5.2), E(LIGHT, 75.5, 40, 2, 2),
        L(BLUE, [[36, 70], [34, 80]], 7), L(BLUE, [[56, 70], [58, 80]], 7),
        R(BLUE, 30, 78, 11, 5, 2), R(BLUE, 55, 78, 11, 5, 2),
      ];
    },
  },
  {
    id: 'mouse', name: '老鼠', en: 'mouse',
    line: 'mouse 就是那只要注入到远端 Mac 的鼠标；尾巴的末端是一个光标', flag: '最省解释',
    why: '动物名=输入设备 · 尾巴=终端光标 · 小快、一条端口就钻过去',
    draw: () => [
      E(BLUE, 30, 28, 13.5, 13.5), E(DIM, 30, 28, 6.5, 6.5),
      E(BLUE, 52, 58, 27, 21), E(BLUE, 76, 63, 14, 11),
      R(INK, 56, 49, 6.5, 6.5, 2), R(LIGHT, 86, 59, 5.5, 5.5, 2.5),
      L(INK, [[84, 66], [96, 57]], 1.5), L(INK, [[84, 68], [96, 75]], 1.5),
      L(BLUE, [[28, 64], [13, 72], [15, 84]], 6), R(BLUE, 14, 80, 15, 8, 2),
      R(BLUE, 34, 76, 10, 6, 2), R(BLUE, 60, 76, 10, 6, 2),
    ],
  },
  {
    id: 'hermit', name: '寄居蟹', en: 'hermit crab', k: 0.9,
    fold: () => [
      E(BROWN, 37, 51, 31, 30), E(SAND, 36, 49, 30, 28),
      L(BROWN, coil(36, 49, 23, 9, 1.1, -2.6), 8),
      L(CREAM, coil(36, 49, 26, 3, 1.75, -0.35), 4.5),
      L(CORAL, [[66, 50], [61, 30]], 6), E(CREAM, 60, 27, 9, 9),
      L(CORAL, [[78, 48], [84, 28]], 6), E(CREAM, 85, 25, 9, 9),
      E(INK, 61, 27, 5, 5), E(INK, 86, 25, 5, 5),
    ],
    line: 'SSH 就是 secure shell：桌面住进你的终端壳里，换壳不换人', flag: '选它',
    why: '壳 = shell = SSH 会话 · 换壳 = 断线重连 · 钳子 = 抓一帧',
    draw: () => [
      /* 壳：沙色实体 + 棕色螺纹 + 奶油色脊，五层 */
      E(BROWN_D, 37, 53, 32, 31),
      E(SAND, 36, 50, 30, 28),
      L(BROWN, coil(36, 50, 23, 10, 1.05, -2.6), 9),          // 内侧暗面
      L(CREAM, coil(36, 50, 26, 3, 1.75, -0.35), 4.4),        // 螺旋脊
      L(BROWN, coil(36, 50, 23.5, 2, 1.75, -0.15), 2.2),      // 脊的暗边
      L(CREAM, coil(36, 50, 28.5, 24, 0.42, 2.1), 2.4),       // 外缘高光
      /* 壳口：深棕的洞 + 压在外面的唇 */
      E(BROWN_D, 61, 58, 14, 18),
      L(SAND, [[51, 37], [46, 58], [54, 78]], 7),
      L(CREAM, [[52.5, 39], [48.5, 58], [55, 76]], 1.8),
      /* 小短腿，三只就够，末端一点点尖 */
      L(CORAL, [[47, 71], [40, 78]], 5.6), G(CORAL, [[36, 77], [42, 77], [39, 83]]),
      L(CORAL, [[56, 76], [50, 83]], 5.6), G(CORAL, [[46, 82], [52, 82], [49, 88]]),
      L(CORAL, [[64, 78], [60, 86]], 5), G(CORAL, [[56, 85], [62, 85], [59, 91]]),
      /* 身子：圆一点才可爱 */
      E(CORAL, 71, 60, 13, 14),
      /* 两根短眼柄 + 两只大眼（这是可爱度的全部来源） */
      L(CORAL, [[67, 50], [62, 34]], 6.5), E(CREAM, 60, 31, 9.5, 9.5),
      E(INK, 61.5, 31.5, 5.2, 5.2), E(LIGHT, 63.5, 28, 2.2, 2.2), E(BLUE, 59.5, 34, 1.4, 1.4),
      L(CORAL, [[78, 48], [84, 33]], 6.5), E(CREAM, 85, 30, 9.5, 9.5),
      E(INK, 86.5, 30.5, 5.2, 5.2), E(LIGHT, 88.5, 27, 2.2, 2.2), E(BLUE, 84.5, 33, 1.4, 1.4),
      /* 微笑 + 腮红 */
      L(INK, [[68, 66], [71.5, 69], [75, 66]], 2),
      E(CORAL_D, 62, 63, 3.4, 2.6), E(CORAL_D, 81, 62, 3.4, 2.6),
      /* 小钳子，举在右边 */
      E(BROWN_D, 84, 72, 6.5, 8), E(CORAL, 84, 72, 5.5, 7),
      L(CORAL, [[84, 67], [88, 63]], 4), L(CORAL, [[84, 77], [88, 80]], 4),
      E(CREAM, 88.5, 62.5, 1.6, 1.6), E(CREAM, 88.5, 80.5, 1.6, 1.6),
    ],
  },
  {
    id: 'pangolin', name: '穿山甲', en: 'pangolin',
    line: '一身鳞片就是一张 tile grid：一格一格送过去，拼回整张脸', flag: '最贴编码',
    why: '鳞片=tile（8×4 一块） · 蜷成球=打包压缩 · 只抓脏掉的那几块',
    draw: () => {
      const plates = [];
      for (let r = 0; r < 3; r++) for (let c = 0; c < 4; c++) {
        const x = 22 + c * 12 + (r % 2) * 5, y = 44 + r * 10;
        if (((x + 5 - 44) / 29) ** 2 + ((y + 4 - 56) / 17) ** 2 < 0.9)
          plates.push(R(MID, x, y, 12, 9.5, 4));
      }
      return [
        G(BLUE, [[10, 60], [22, 44], [44, 40], [64, 42], [74, 50], [74, 66], [62, 74], [36, 76], [18, 70]]),
        L(BLUE, [[20, 62], [6, 66]], 14), ...plates,
        E(BLUE, 71, 51, 11, 11), G(BLUE, [[77, 47], [90, 55], [77, 59]]),
        R(LIGHT, 87, 53, 3.6, 3.6, 1.4), R(INK, 70, 46, 4.6, 4.6, 1.6),
        R(BLUE, 34, 74, 11, 7, 2), R(BLUE, 56, 74, 11, 7, 2),
      ];
    },
  },
  {
    id: 'tardigrade', name: '水熊虫', en: 'tardigrade',
    line: '断网、丢包、0.25 倍分辨率——它照样活着，这才是 krd 的自适应缩放', flag: '最能打',
    why: '极端环境存活 = 弱网不冻屏 · 一格一格的体节 = 终端格子 · 谁都没想到用它',
    draw: () => [
      E(BLUE, 48, 52, 33, 22),                                     // 胖身体
      E(BLUE, 76, 47, 15, 14),                                     // 头
      R(BLUE, 85, 42, 8, 10, 4), E(INK, 90, 47, 3.4, 3.4),          // 吻部 + 嘴
      R(INK, 76, 38, 4.6, 4.6, 1.6), R(INK, 84, 40, 3.8, 3.8, 1.4), // 两只眼
      ...[36, 48, 60].map(x => L(DIM, [[x, 36], [x, 64]], 2.4)),    // 体节
      ...[26, 40, 54, 68].flatMap(x => [
        L(BLUE, [[x, 68], [x - 2, 80]], 9),
        R(BLUE, x - 8, 78, 13, 6, 3),
        R(LIGHT, x - 8, 83, 3.4, 2.6, 1), R(LIGHT, x - 1, 83, 3.4, 2.6, 1),  // 爪
      ]),
    ],
  },
];

/* ------------------------------------------------------------------ 栅格化 */
const inPoly = (x, y, pts) => {
  let c = false;
  for (let i = 0, j = pts.length - 1; i < pts.length; j = i++) {
    const [xi, yi] = pts[i], [xj, yj] = pts[j];
    if (yi > y !== yj > y && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) c = !c;
  }
  return c;
};
const dSeg = (px, py, [ax, ay], [bx, by]) => {
  const vx = bx - ax, vy = by - ay, t = Math.max(0, Math.min(1, ((px - ax) * vx + (py - ay) * vy) / (vx * vx + vy * vy || 1)));
  return Math.hypot(px - (ax + vx * t), py - (ay + vy * t));
};
function sample(shapes, x, y) {
  let col = null;
  for (const s of shapes) {
    let hit = false;
    if (s.k === 'e') {
      const dx = (x - s.x) / s.rx, dy = (y - s.y) / s.ry; hit = dx * dx + dy * dy <= 1;
    } else if (s.k === 'r') {
      const r = Math.min(s.r, s.w / 2, s.h / 2);
      const nx = Math.max(s.x + r, Math.min(x, s.x + s.w - r)), ny = Math.max(s.y + r, Math.min(y, s.y + s.h - r));
      hit = (x - nx) ** 2 + (y - ny) ** 2 <= r * r && x >= s.x && x <= s.x + s.w && y >= s.y && y <= s.y + s.h;
    } else if (s.k === 'p') hit = inPoly(x, y, s.pts);
    else for (let i = 0; i < s.pts.length - 1 && !hit; i++) hit = dSeg(x, y, s.pts[i], s.pts[i + 1]) <= s.w / 2;
    if (hit) col = s.c;
  }
  return col;
}
/** w×h 的 RGBA，2×2 超采样，背景按覆盖率混到纸色 */
function raster(animal, w, h) {
  const shapes = animal.draw(), px = new Uint8ClampedArray(w * h * 4), SS = 2;
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    let r = 0, g = 0, b = 0, n = 0;
    for (let sy = 0; sy < SS; sy++) for (let sx = 0; sx < SS; sx++) {
      let u = 4 + ((x + (sx + .5) / SS) / w) * 88, v = 4 + ((y + (sy + .5) / SS) / h) * 88;
      if (animal.k) { u = 48 + (u - 48) / animal.k; v = 48 + (v - 48) / animal.k; }
      const c = sample(shapes, u, v);
      if (c) { r += c[0]; g += c[1]; b += c[2]; n++; }
    }
    const i = (y * w + x) * 4, k = n / (SS * SS);
    if (n) {
      px[i] = Math.round((r / n) * k + PAPER[0] * (1 - k));
      px[i + 1] = Math.round((g / n) * k + PAPER[1] * (1 - k));
      px[i + 2] = Math.round((b / n) * k + PAPER[2] * (1 - k));
      px[i + 3] = 255;
    }
  }
  return { w, h, px };
}

/* 拟物：一格 = 上下两个像素 */
function solid(animal, cols, rows, reveal = 1) {
  const r = raster(animal, cols, rows * 2), out = [];
  for (let y = 0; y < rows; y++) {
    const line = [];
    const shown = y / rows <= reveal;
    for (let x = 0; x < cols; x++) {
      if (!shown) { line.push({ ch: '▀', fg: PAPER, bg: PAPER }); continue; }
      const t = (y * 2 * cols + x) * 4, b = ((y * 2 + 1) * cols + x) * 4;
      line.push({ ch: '▀', fg: [r.px[t], r.px[t + 1], r.px[t + 2]], bg: [r.px[b], r.px[b + 1], r.px[b + 2]] });
    }
    out.push(line);
  }
  return out;
}
/* 字符：一格 = 一个字符，按格内占多数的材质选字形 */
const GLYPHS = [[LIGHT, '@'], [BLUE, '#'], [MID, '+'], [SLATE, ':'], [DIM, '.'], [INK, ',']];
const glyph = c => GLYPHS.reduce((best, [ref, ch]) => {
  const d = (c[0] - ref[0]) ** 2 + (c[1] - ref[1]) ** 2 + (c[2] - ref[2]) ** 2;
  return d < best.d ? { d, ch } : best;
}, { d: Infinity, ch: '#' }).ch;
function plain(animal, cols, rows) {
  const shapes = animal.draw(), out = [];
  for (let y = 0; y < rows; y++) {
    const line = [];
    for (let x = 0; x < cols; x++) {
      const vote = new Map(); let n = 0;
      for (let sy = 0; sy < 3; sy++) for (let sx = 0; sx < 3; sx++) {
        let u = 4 + ((x + (sx + .5) / 3) / cols) * 88, v = 4 + ((y + (sy + .5) / 3) / rows) * 88;
      if (animal.k) { u = 48 + (u - 48) / animal.k; v = 48 + (v - 48) / animal.k; }
      const c = sample(shapes, u, v);
        if (!c) continue;
        n++; const k = c.join(','); vote.set(k, (vote.get(k) || 0) + 1);
      }
      if (n < 3) { line.push({ ch: ' ' }); continue; }
      let best = null, bn = 0;
      for (const [k, v] of vote) if (v > bn) { bn = v; best = k; }
      line.push({ ch: glyph(best.split(',').map(Number)) });
    }
    out.push(line);
  }
  return out;
}

/* ---------------------------------------------------------------- 全屏 TUI -- */
/* 一屏 = rows 行 × cols 个终端列。宽字符占两列，所以宽度一律按显示列算，
   每一行都被裁到恰好 cols，行尾补齐 —— 这样终端永远不会折行、边框不会断。 */
const WALL = [66, 74, 94], TITLE = [122, 132, 152], NUM = [62, 72, 96],
      CAP = [94, 184, 255], NOTE = [140, 150, 170], DIMTXT = [88, 98, 118];
const BLANK = { ch: ' ' };
const wide = ch => /[\u1100-\u115f\u2e80-\ua4cf\uac00-\ud7a3\uf900-\ufaff\ufe30-\ufe4f\uff00-\uff60]/.test(ch) ? 2 : 1;
const w = s => [...s].reduce((n, ch) => n + wide(ch), 0);
const txt = (s, fg = null) => [...s].map(ch => ({ ch, fg }));
const blanks = n => Array.from({ length: Math.max(0, n) }, () => BLANK);

/** 裁到恰好 width 个显示列：宽字符跨过边界就整块丢掉，末尾补空格 */
function fit(row, width) {
  const out = [];
  let used = 0;
  for (const c of row) {
    const cw = wide(c.ch);
    if (used + cw > width) break;
    out.push(c); used += cw;
  }
  while (used < width) { out.push(BLANK); used++; }
  return out;
}
const centre = (s, fg, width) => fit([...blanks(Math.floor((width - w(s)) / 2)), ...txt(s, fg)], width);
const dashed = n => Array.from({ length: Math.max(0, n) }, () => ({ ch: '─', fg: WALL }));

/** 按显示宽度折行，最多 max 行，最后一行加省略号 */
function wrap(s, width, max) {
  const out = [];
  let line = '', used = 0;
  for (const ch of s) {
    const cw = wide(ch);
    if (used + cw > width) { out.push(line); line = ''; used = 0; if (out.length === max) break; }
    line += ch; used += cw;
  }
  if (out.length < max) out.push(line);
  if (out.length === max && w(s) > max * width) {
    const last = out[max - 1];
    out[max - 1] = [...last].slice(0, Math.max(0, width - 1)).join('') + '…';
  }
  return out;
}

/* ------------------------------------------------------------ loading 动画 -- */
/* 首图还没到的时候，蟹在壳里探头：出来 → 眨眼 → 缩回去，8 帧 110ms。
   只有壳 + 两只眼，形状少到可以直接搬到 Swift 里画。 */
const SHELL_SHAPES = () => [
  E(BROWN_D, 37, 53, 32, 31), E(SAND, 36, 50, 30, 28),
  L(BROWN, coil(36, 50, 23, 10, 1.05, -2.6), 9),
  L(CREAM, coil(36, 50, 26, 3, 1.75, -0.35), 4.4),
  L(BROWN, coil(36, 50, 23.5, 2, 1.75, -0.15), 2.2),
];
const PEEK = [0.05, 0.45, 0.8, 1, 1, 1, 0.8, 0.45];

/** peek: 0 缩回壳里 → 1 全伸出来；blink 那一帧眼睛压成一条缝 */
function loadingShapes(i) {
  const peek = PEEK[i % PEEK.length], blink = i % PEEK.length === 4;
  const out = [...SHELL_SHAPES()];
  // 壳口 + 蟹身，随探头一起往外挪一点点
  out.push(E(BROWN_D, 61, 58, 14, 18), L(SAND, [[51, 37], [46, 58], [54, 78]], 7));
  out.push(E(CORAL, 70, 60 + (1 - peek) * 2, 13, 14));
  const eyeY = 44 + (1 - peek) * 14, eyeY2 = eyeY - 3;   // 缩回时眼睛沉到壳口里
  out.push(L(CORAL, [[67, 52], [63, eyeY]], 6.5), L(CORAL, [[78, 50], [84, eyeY2]], 6.5));
  if (blink) {
    out.push(E(CREAM, 61, eyeY, 9.5, 2.2), E(CREAM, 85, eyeY2, 9.5, 2.2),
             E(INK, 61, eyeY, 9.5, 0.9), E(INK, 85, eyeY2, 9.5, 0.9));
  } else {
    out.push(E(CREAM, 61, eyeY, 9.5, 9.5), E(INK, 62.5, eyeY + 0.5, 5.2, 5.2),
             E(LIGHT, 64.5, eyeY - 3, 2.2, 2.2), E(BLUE, 60.5, eyeY + 3, 1.4, 1.4),
             E(CREAM, 85, eyeY2, 9.5, 9.5), E(INK, 86.5, eyeY2 + 0.5, 5.2, 5.2),
             E(LIGHT, 88.5, eyeY2 - 3, 2.2, 2.2), E(BLUE, 84.5, eyeY2 + 3, 1.4, 1.4));
  }
  return out;
}

/** 启动等待那一屏：一行字 + 一只在探头的蟹 */
function loadingScreen(cols, rows, i) {
  const art = solid({ draw: () => loadingShapes(i), k: 0.72 }, 36, 18);
  const n = i % PEEK.length;
  const label = 'waiting for first frame';
  const dots = '.'.repeat(n % 4);
  const out = [];
  const top = Math.max(0, Math.floor((rows - 20) / 2));
  for (let k = 0; k < top; k++) out.push(blankRow(cols));
  const left = Math.max(0, Math.floor((cols - 34) / 2));
  for (const line of art) out.push(padRow([...blanks(left), ...line], cols));
  out.push(blankRow(cols));
  out.push(centre(label + dots, NOTE, cols));
  out.push(centre('krd · connecting', DIMTXT, cols));
  while (out.length < rows) out.push(blankRow(cols));
  return out.slice(0, rows).map(l => fit(l, cols));
}
const blankRow = n => Array.from({ length: n }, () => BLANK);
const padRow = (row, n) => fit(row, n);

/** 一整屏：上下边框 + 画面 + 说明。cols/rows 一定被填满，不靠终端自己补 */
function screen(a, mode, cols, rows, reveal = 1) {
  cols = Math.max(20, cols); rows = Math.max(6, rows);
  const inner = cols - 2;
  const wall = row => [{ ch: '│', fg: WALL }, ...fit(row, inner), { ch: '│', fg: WALL }];
  const title = ` KRD · ${a.name} ${a.en} `, num = ` ${ANIMALS.indexOf(a) + 1}/${ANIMALS.length} `;
  const dash = cols - 2 - w(title) - w(num);
  const top = [{ ch: '┌', fg: WALL }, ...dashed(1), ...txt(title, TITLE), ...dashed(dash),
               ...txt(num, NUM), { ch: '┐', fg: WALL }];
  const bottom = [{ ch: '└', fg: WALL }, ...dashed(cols - 2), { ch: '┘', fg: WALL }];

  /* 说明放右边还是下面：右边放得下就让画面尽量大 */
  const textW = Math.min(40, Math.max(24, Math.floor(inner * 0.34)));
  const stacked = Math.min(rows - 12, Math.floor(inner / 2), 48);
  const beside = Math.min(rows - 5, Math.floor((inner - textW - 4) / 2), 48);
  const side = beside > stacked + 2;
  const artH = Math.max(0, side ? beside : stacked);
  const artW = artH * 2;

  const out = [fit(top, cols), wall([])];
  if (artH < 5) {
    out.push(wall(centre('窗口太小了', DIMTXT, inner)), wall([]),
             wall(centre('放大一点，或者按 q 退出', DIMTXT, inner)));
  } else if (side) {
    const art = mode === 'solid' ? solid(a, artW, artH, reveal) : plain(a, artW, artH);
    const left = 1;
    const texts = [
      ...wrap(`[${a.flag}]`, textW, 1),
      ...wrap(a.line, textW, 3),
      '',
      ...wrap(a.why, textW, 3),
      '',
      ...wrap(mode === 'solid' ? '拟物 solid · 24-bit half blocks' : '字符 plain · 一字符一格', textW, 2),
    ];
    const pad = Math.max(0, Math.floor((artH - texts.length) / 2));
    for (let y = 0; y < artH; y++) {
      const line = [...blanks(left), ...art[y], ...blanks(2)];
      const t = y - pad;
      const cap = t >= 0 && t < texts.length ? texts[t] : '';
      const fg = t >= 0 && t < texts.length ? (cap.startsWith('[') ? CAP : t < 4 ? NOTE : DIMTXT) : null;
      out.push(wall([...line, ...txt(cap, fg)]));
    }
  } else {
    const art = mode === 'solid' ? solid(a, artW, artH, reveal) : plain(a, artW, artH);
    const left = Math.floor((inner - artW) / 2);
    for (const line of art) out.push(wall([...blanks(left), ...line]));
    out.push(wall([]));
    out.push(wall(centre(mode === 'solid' ? '拟物 solid · 24-bit half blocks' : '字符 plain · one char per cell', CAP, inner)));
    for (const l of wrap(a.line, inner, 2)) out.push(wall(centre(l, NOTE, inner)));
    for (const l of wrap(`[${a.flag}] ${a.why}`, inner, 2)) out.push(wall(centre(l, DIMTXT, inner)));
  }
  if (artH >= 5) {
    out.push(wall([]));
    out.push(wall(centre('1-5 换动物 · s 拟物/字符 · a 抓屏 · q 退出', DIMTXT, inner)));
  }
  /* 底边框永远在最后一行：先收内容，再补空行，最后画边 */
  const frame = out.slice(0, Math.max(1, rows - 1));
  while (frame.length < rows - 1) frame.push(wall([]));
  frame.push(fit(bottom, cols));
  return frame.slice(0, rows).map(l => fit(l, cols));
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
const ansi = f => f.map(SGR).join('\n') + '\n';

const page = (body, title) => `<!doctype html><meta charset="utf-8"><title>${title}</title>
<style>html,body{margin:0;background:#05070c}
body{padding:18px;display:flex;flex-wrap:wrap;gap:16px;align-items:flex-start}
pre{margin:0;padding:14px 16px;background:#07090f;border:1px solid #1e2330;border-radius:9px;
font:13px/1.12 ui-monospace,SFMono-Regular,Menlo,monospace;white-space:pre;color:#c9d2e2}
</style>${body}`;
const pre = f => `<pre>${f.map(l => l.map(c => {
  const ch = c.ch.replace(/&/g, '&amp;').replace(/</g, '&lt;');
  const st = (c.fg ? `color:rgb(${c.fg.join(',')});` : '') + (c.bg ? `background:rgb(${c.bg.join(',')});` : '');
  return st ? `<span style="${st}">${ch}</span>` : ch;
}).join('')).join('\n')}</pre>`;

/* ------------------------------------------------------------------- CLI -- */
const argv = process.argv.slice(2);
const arg = (n, d) => { const i = argv.indexOf(n); return i >= 0 ? argv[i + 1] ?? true : d; };
const hermit = ANIMALS.findIndex(a => a.id === 'hermit');
let idx = Math.max(0, hermit), mode = arg('--mode', argv.includes('--anim') ? 'loading' : 'solid');
const pick = arg('--animal', null);
if (pick) { const i = ANIMALS.findIndex(a => a.id === pick || a.name === pick); if (i >= 0) idx = i; }

if (argv.includes('--dump')) {
  for (const a of ANIMALS) for (const m of ['solid', 'plain'])
    process.stdout.write(`\n${a.name} · ${a.en} · ${m}\n` +
      ansi(m === 'solid' ? solid(a, 64, 32) : plain(a, 64, 32)));
  process.exit(0);
}

/* ---------------------------------------------------------------- 自检 -- */
function selfTest() {
  const bad = [];
  for (const cols of [24, 40, 60, 80, 100, 118, 160])
    for (const rows of [6, 9, 14, 20, 40])
      for (const m of ['solid', 'plain']) {
        const f = screen(ANIMALS[0], m, cols, rows);
        if (f.length !== rows) bad.push(`${cols}x${rows} ${m}: ${f.length} rows`);
        if (f[0][0].ch !== '┌' || f[rows - 1][0].ch !== '└')
          bad.push(`${cols}x${rows} ${m}: 边框被切掉了（${f[0][0].ch}…${f[rows - 1][0].ch}）`);
        f.forEach((l, i) => {
          const width = l.reduce((n, c) => n + wide(c.ch), 0);
          if (width !== cols) bad.push(`${cols}x${rows} ${m} row ${i}: width ${width}`);
        });
      }
  return bad;
}

/* ------------------------------------------------------------ --help 版 -- */
const WORD = [
  '  ██    ██  ██████    ██████  ',
  '  ██  ██    ██    ██  ██    ██',
  '  ████      ██████    ██    ██',
  '  ██  ██    ██  ██    ██    ██',
  '  ██    ██  ██    ██  ██████  ',
];
function banner() {
  return [...WORD, '', "  your mac's desktop, inside a terminal",
          '  SSH shell · kitty graphics · no codec'].join('\n');
}
function art() {
  return plain(ANIMALS[hermit], 46, 23).map(l => l.map(c => c.ch).join('').replace(/\s+$/, '')).join('\n');
}
if (argv.includes('--banner')) { process.stdout.write(banner() + '\n'); process.exit(0); }
if (argv.includes('--art')) { process.stdout.write(art() + '\n'); process.exit(0); }
const fav = arg('--favicon', null);
if (fav) {
  const { writeFileSync } = await import('node:fs');
  const px = Number(arg('--px', 16));
  const a = ANIMALS[hermit];
  /* 小尺寸折叠成壳 + 眼柄，大尺寸用整只 */
  const r = raster({ draw: px <= 24 && a.fold ? a.fold : a.draw, k: a.k }, px, px);
  const pal = [PAPER, CREAM, SAND, BROWN, BROWN_D, CORAL, CORAL_D, LIGHT, BLUE, INK];
  const hex = c => '#' + c.map(v => v.toString(16).padStart(2, '0')).join('');
  const near = c => pal.reduce((b, p) => {
    const d = (c[0] - p[0]) ** 2 + (c[1] - p[1]) ** 2 + (c[2] - p[2]) ** 2;
    return d < b.d ? { d, p } : b;
  }, { d: Infinity, p: PAPER }).p;
  const rows = [];
  for (let y = 0; y < px; y++) {
    const line = [];
    for (let x = 0; x < px; x++) {
      const i = (y * px + x) * 4;
      line.push(near([r.px[i], r.px[i + 1], r.px[i + 2]]));
    }
    rows.push(line);
  }
  let body = '';
  for (let y = 0; y < px; y++) {
    for (let x = 0; x < px;) {
      const c = rows[y][x];
      let w = 1;
      while (x + w < px && rows[y][x + w].join() === c.join()) w++;
      if (c.join() !== PAPER.join()) body += `<rect x="${x}" y="${y}" width="${w}" height="1" fill="${hex(c)}"/>`;
      x += w;
    }
  }
  writeFileSync(fav, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${px} ${px}" shape-rendering="crispEdges">` +
    `<rect width="${px}" height="${px}" fill="${hex(PAPER)}"/>${body}</svg>\n`);
  process.exit(0);
}
if (argv.includes('--test')) {
  const bad = selfTest();
  process.stdout.write(bad.length ? bad.join('\n') + '\n' : 'ok: 70 屏都是严格的 cols × rows\n');
  process.exit(bad.length ? 1 : 0);
}

if (argv.includes('--frames')) {
  for (let i = 0; i < 8; i++) {
    process.stdout.write(`\nframe ${i}  peek=${PEEK[i]}\n`);
    for (const line of loadingScreen(64, 22, i))
      process.stdout.write(line.map(c => c.ch).join('').replace(/\s+$/, '') + '\n');
  }
  process.exit(0);
}
const shot = arg('--shot', null);
if (shot) {
  const { writeFileSync } = await import('node:fs');
  const cols = Number(arg('--cols', 118)), rows = Number(arg('--rows', 42));
  const only = pick ? [ANIMALS[idx]] : ANIMALS;
  const frames = argv.includes('--anim')
    ? PEEK.map((_, i) => loadingScreen(cols, rows, i))          // 整份分镜
    : only.flatMap(a => [screen(a, 'solid', cols, rows), screen(a, 'plain', cols, rows)]);
  writeFileSync(shot, page(frames.map(pre).join(''), 'KRD · mascot lab'));
  process.exit(0);
}

/* ------------------------------------------------- 只画蟹，不出卡片 --png -- */
/* README 里那张图要的是**蟹本身**，不是卡片：标题、右边那段说明、底下那行快捷键都是卡片的
   排版（宽了就左右排、窄了就上下排），不属于吉祥物。所以这里只画画面框里的那只蟹。
   画面框本来就是 `raster()` 的正方形点阵（solid() 一格 = 上下两点），这里把它按 --scale
   展开成实心方块直接写 PNG —— 用 node:zlib，仍然零依赖。
   为什么不用 --shot 再截屏：截图会带上字体、窗口边距和屏幕 DPR，换台机器就是另一张图，
   而一张没法复现的二进制没法 review。这条命令在哪台机器上都出同一张图：
     node docs/brand/tui/logo-tui.mjs --png docs/media/mascot.png --animal hermit --trim
   --dots 72 就是卡片画面框画蟹用的那个点阵边长；--scale 20 在 width="680" 的图里一个点
   正好 10 个 CSS 像素（680 / 68 个点）—— 2 倍屏上一个点 20×20 个设备像素，不用重采样。
   --trim 裁到蟹自己的墨边（四周留 1 个点）：造型在 96×96 里留了头高，画面框顶部 20% 是空的，
   在白底 README 里就是一条黑边；裁掉留白才是「只有蟹」。 */
if (argv.includes('--png')) {
  const { writeFileSync } = await import('node:fs');
  const { deflateSync } = await import('node:zlib');
  const out = arg('--png', null);
  if (typeof out !== 'string') { process.stdout.write('--png 要给一个文件名\n'); process.exit(1); }
  const int = (name, def, lo) => { const n = Math.round(Number(arg(name, def))); return Number.isFinite(n) && n >= lo ? n : def; };
  const dots = int('--dots', 72, 8), scale = int('--scale', 20, 1);   // NaN 会让 Buffer.alloc 抛栈
  const r = raster(ANIMALS[idx], dots, dots);
  /* --trim：裁到蟹的墨边，四周留 1 个点（贴边的造型留不出，理由见上面的块注释） */
  let x0 = 0, y0 = 0, w = dots, h = dots;
  const trimmed = argv.includes('--trim');
  if (trimmed) {
    let minx = dots, miny = dots, maxx = -1, maxy = -1;
    for (let y = 0; y < dots; y++) for (let x = 0; x < dots; x++) {
      const i = (y * dots + x) * 4;
      if (r.px[i] || r.px[i + 1] || r.px[i + 2]) {
        if (x < minx) minx = x; if (x > maxx) maxx = x;
        if (y < miny) miny = y; if (y > maxy) maxy = y;
      }
    }
    x0 = Math.max(0, minx - 1); y0 = Math.max(0, miny - 1);
    w = Math.min(dots, maxx + 2) - x0; h = Math.min(dots, maxy + 2) - y0;
    if (maxx < 0) { x0 = 0; y0 = 0; w = dots; h = dots; }     // 一点造型都没有：别裁成负数
  }
  const W = w * scale, H = h * scale;
  const crc = (() => {
    const t = Array.from({ length: 256 }, (_, n) => {
      let c = n;
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      return c >>> 0;
    });
    return buf => { let c = 0xffffffff; for (const b of buf) c = t[(c ^ b) & 0xff] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
  })();
  const chunk = (type, body) => {
    const head = Buffer.alloc(4); head.writeUInt32BE(body.length);
    const name = Buffer.from(type, 'latin1'), tail = Buffer.alloc(4);
    tail.writeUInt32BE(crc(Buffer.concat([name, body])));
    return Buffer.concat([head, name, body, tail]);
  };
  /* 没有形状覆盖的点在 raster() 里还是 0,0,0 —— 画面框的底色因此是纯黑，跟卡片里一致 */
  const raw = Buffer.alloc((W * 3 + 1) * H);
  let p = 0;
  for (let y = y0; y < y0 + h; y++) {
    const line = Buffer.alloc(W * 3);
    for (let x = x0; x < x0 + w; x++) {
      const i = (y * dots + x) * 4, o = (x - x0) * scale * 3;
      for (let k = 0; k < scale; k++) {
        line[o + k * 3] = r.px[i]; line[o + k * 3 + 1] = r.px[i + 1]; line[o + k * 3 + 2] = r.px[i + 2];
      }
    }
    for (let k = 0; k < scale; k++) { raw[p++] = 0; line.copy(raw, p); p += W * 3; }
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(W, 0); ihdr.writeUInt32BE(H, 4); ihdr[8] = 8; ihdr[9] = 2;   // 8-bit RGB，无 alpha
  writeFileSync(out, Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr), chunk('IDAT', deflateSync(raw, { level: 9 })), chunk('IEND', Buffer.alloc(0))]));
  process.stdout.write(`${out}: ${W}×${H} px = ${w}×${h} dots × ${scale} px · ${ANIMALS[idx].en} only` +
    `${trimmed ? ` · dots ${x0}..${x0 + w - 1} × ${y0}..${y0 + h - 1} of ${dots}` : ''}\n`);
  process.exit(0);
}

const stdin = process.stdin, stdout = process.stdout;
const size = () => ({ cols: stdout.columns || 100, rows: stdout.rows || 34 });
let reveal = 1, anim = argv.includes('--anim'), loadFrame = 0;
const paint = () => {
  const { cols, rows } = size();
  const f = anim && mode === 'loading'
    ? loadingScreen(cols, rows, loadFrame)
    : screen(ANIMALS[idx], mode, cols, rows, mode === 'solid' ? reveal : 1);
  let s = '';
  for (let i = 0; i < f.length; i++) s += `\x1b[${i + 1};1H\x1b[2K` + SGR(f[i]);
  stdout.write(s);
};
if (!stdin.isTTY) {
  const { cols, rows } = size();
  stdout.write(ansi(screen(ANIMALS[idx], mode, cols, rows)));
  process.exit(0);
}
stdout.write('\x1b[?1049h\x1b[?25l\x1b[2J');
const quit = () => { stdout.write('\x1b[0m\x1b[?25h\x1b[?1049l'); process.exit(0); };
const repaint = () => { stdout.write('\x1b[2J'); paint(); };
stdin.setRawMode(true); stdin.resume(); repaint();
stdin.on('data', b => {
  const s = b.toString();
  if (s === 'q' || s === '\x03') quit();
  else if (s === 's' || s === '\t') { mode = mode === 'solid' ? 'plain' : 'solid'; paint(); }
  else if (s === 'a') { anim = !anim; reveal = anim ? 0 : 1; paint(); }
  else if (s === 'l') { mode = mode === 'loading' ? 'solid' : 'loading'; paint(); }
  else if (/^[1-9]$/.test(s) && ANIMALS[+s - 1]) { idx = +s - 1; repaint(); }
  else if (s === 'j' || s === '\x1b[B') { idx = (idx + 1) % ANIMALS.length; repaint(); }
  else if (s === 'k' || s === '\x1b[A') { idx = (idx + ANIMALS.length - 1) % ANIMALS.length; repaint(); }
});
process.on('SIGWINCH', repaint);
setInterval(() => {
  if (mode === 'loading') { loadFrame++; paint(); return; }
  if (!anim) return;
  reveal += 0.02;
  if (reveal > 1.6) reveal = 0;         // 画满之后停一下再重来
  paint();
}, 45);
process.on('exit', () => stdout.write('\x1b[0m\x1b[?25h\x1b[?1049l'));
