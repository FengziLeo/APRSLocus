/* ══════════════════════════════════════════════════════════════════════
   APRSlocus 官网 Hero：3D 星球 + 累计报文遥测
   ──────────────────────────────────────────────────────────────────────
   为什么手写 WebGL 而不是引 three.js：
   官网是零构建、零依赖的静态站（唯一外链资源是 Font Awesome），为一个
   一万七千点的星球塞进 900 KB 的渲染库不划算。这里只用原生 WebGL1：
   两个 program（点云 + 线框球）、三个缓冲，几何在加载时一次性生成。

   星球的模样照参考设计（NASA-Punk Observatory 的海王星）做，只动星球：
   · 本体是一族蓝色的点云，横条带来自纬向拉伸的噪声（y 放大 6 倍），
     再套一层 12 条经线 + 7 条纬线的线框球（gl.LINES）——点云是实体，
     线框是仪表感；
   · 90 颗台站点点在球面上闪（琥珀 / 橙），环带三圈按开普勒比例 ω ∝ r^-1.5
     各转各的，卫星沿轨道跑；
   · 一束左上偏前的光：正面亮、背面暗，球才有体积；
   · 相机固定在 +Z，靠 uDist 缩放；打开深度测试（写深度），背面点被正面
     挡住，星球才有实体感，否则只是一团发光的雾。
   页面皮肤（底色、字体、色标、导航）不在这里 —— hero 还是浅色玻璃那一套，
   所以浅色主题走正常混合（蓝墨点），深色主题走加色混合（霓虹辉光）。

   降级：没有 WebGL 或着色器编译失败 → 给 .hero 加 .no-3d，用纯 CSS
   的星球顶上；遥测数字照常跳动（它只依赖 DOM）。

   遥测：数值源头是 /stats.json（仓库里的静态快照，由 check_site.py 与页面
   静态值强制一致），页面按"基线 + 速率 × 经过分钟数"每秒本地推算，
   不需要任何后端与定时任务。
   入场：一进页面，点云不是一下就摆好——每个点带一个相位，从上方散落着被「拉」下来，错峰聚成一颗球；
   相机同时从更近的机位缓缓退到取景位，线框球比点云慢半步收拢到位。
   滚动：往下拉时星球退得比页面慢半步（视差）并缓缓淡出，文案上浮隐去，滚回顶部一切复原。

   ══════════════════════════════════════════════════════════════════════ */
(function () {
  "use strict";

  var reduce = false;
  try {
    reduce = !!(window.matchMedia && matchMedia("(prefers-reduced-motion: reduce)").matches);
  } catch (e) { reduce = false; }

  /* 星球渲染就绪后会把"闪一下"填进来：读数每跳一次，星面跟着闪一批点 */
  var hooks = { flash: null };

  /* ═════════════ 1. 累计报文遥测 ═════════════ */
  (function telemetry() {
    var root = document.getElementById("heroTelemetry");
    if (!root) return;
    var elVal = document.getElementById("tlPackets");
    if (!elVal) return;
    var elRate = document.getElementById("tlRateNum");

    function digits(s) { return String(s == null ? "" : s).replace(/[^0-9]/g, ""); }
    function fmt(n) { return String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ","); }

    // 首屏先信 HTML 里的静态快照（无 JS / 抓取失败也能看）；stats.json 到手后覆盖。
    var packets = parseInt(digits(root.getAttribute("data-packets") || elVal.textContent), 10);
    var rate = parseInt(digits(root.getAttribute("data-rate") || (elRate ? elRate.textContent : "")), 10);
    var t0 = Date.parse(root.getAttribute("data-updated") || "") || Date.now();
    var src = root.getAttribute("data-stats") || "stats.json";
    if (!isFinite(packets)) packets = 0;
    if (!isFinite(rate)) rate = 0;

    var shown = -1;
    if (elRate) elRate.textContent = "+" + fmt(rate);

    // 外推上限：快照越旧，"基线 + 速率 × 经过时间"离真值越远。超过 12 小时就停止
    // 推算（数字冻结在上限值，LIVE 点变色 + 悬停给解释）—— 宁可保守一点，
    // 也不要让一个月后打开页面的人看到一个凭空多出 15% 的"累计"。
    var MAX_DRIFT_MIN = 720, wasStale = false;

    function tick() {
      var now = Date.now();
      if (now < t0) t0 = now;                       // 快照时间在未来（时钟偏差）→ 不倒退
      var elapsed = (now - t0) / 60000;
      var stale = elapsed > MAX_DRIFT_MIN;
      var mins = stale ? MAX_DRIFT_MIN : elapsed;
      var live = packets + Math.floor(mins * rate);
      if (live !== shown) {
        var grew = shown >= 0 && live > shown;
        elVal.textContent = fmt(live);
        if (grew) {
          elVal.classList.remove("bump");
          void elVal.offsetWidth;                   // 强制回流，重启动画
          elVal.classList.add("bump");
          if (hooks.flash) hooks.flash(live);       // 读数一跳，星面闪一批点
        }
        shown = live;
      }
      if (stale !== wasStale) {
        wasStale = stale;
        root.classList.toggle("stale", stale);
        if (stale) root.title = root.getAttribute("data-stale-title") || "";
      }
    }

    if (window.fetch) {
      try {
        fetch(src, { cache: "no-store" }).then(function (r) {
          return r && r.ok ? r.json() : null;
        }).then(function (d) {
          if (!d) return;
          if (typeof d.packets === "number") packets = d.packets;
          if (typeof d.packetsPerMinute === "number") rate = d.packetsPerMinute;
          var ts = Date.parse(d.updatedIso || "");
          if (ts) t0 = ts;
          if (elRate) elRate.textContent = "+" + fmt(rate);
          shown = -1;
          tick();
        })["catch"](function () {});
      } catch (e) {}
    }
    tick();
    setInterval(tick, 1000);
  })();

  /* ═════════════ 2. 定点随机 & value noise ═════════════
     放在最前面定义：底纹与星球几何共用同一套噪声函数，但各用各的随机流 ——
     共用一条流的话，背景多画一次（比如改窗口大小）就把星球的几何推偏一截，
     同一颗星再也画不出第二遍。 */
  function mulberry32(a) {
    return function () {
      a = a + 0x6D2B79F5 | 0;
      var t = Math.imul(a ^ a >>> 15, 1 | a);
      t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t;
      return ((t ^ t >>> 14) >>> 0) / 4294967296;
    };
  }
  var rnd = mulberry32(0x41505253);   // 'APRS'：星球几何（每次刷新同一颗星）

  /* ── 3D value noise（三线性插值） ── */
  function nodeHash(i, j, k) {
    var n = Math.imul(i, 374761393) ^ Math.imul(j, 668265263) ^ Math.imul(k, 1442695041);
    n = Math.imul(n ^ n >>> 13, 1274126177);
    return ((n ^ n >>> 16) >>> 0) / 4294967296;
  }
  function smooth(t) { return t * t * (3 - 2 * t); }
  function noise3(x, y, z) {
    var xi = Math.floor(x), yi = Math.floor(y), zi = Math.floor(z);
    var u = smooth(x - xi), v = smooth(y - yi), w = smooth(z - zi);
    var c000 = nodeHash(xi, yi, zi), c100 = nodeHash(xi + 1, yi, zi);
    var c010 = nodeHash(xi, yi + 1, zi), c110 = nodeHash(xi + 1, yi + 1, zi);
    var c001 = nodeHash(xi, yi, zi + 1), c101 = nodeHash(xi + 1, yi, zi + 1);
    var c011 = nodeHash(xi, yi + 1, zi + 1), c111 = nodeHash(xi + 1, yi + 1, zi + 1);
    var x00 = c000 + (c100 - c000) * u, x10 = c010 + (c110 - c010) * u;
    var x01 = c001 + (c101 - c001) * u, x11 = c011 + (c111 - c011) * u;
    var y0 = x00 + (x10 - x00) * v, y1 = x01 + (x11 - x01) * v;
    return (y0 + (y1 - y0) * w) * 2 - 1;          // → [-1, 1]
  }

  /* ═════════════ 3. 3D 星球 ═════════════ */
  var canvas = document.getElementById("planetCanvas");
  var hero = document.querySelector(".hero");
  if (!canvas || !hero || !canvas.getContext) return;

  var TILT = 23.4 * Math.PI / 180;    // 轴倾角（与舷窗上 AXIS TILT 标签一致）
  var FOV = 33 * Math.PI / 180;
  var U_PROJ = 1 / Math.tan(FOV / 2);
  var RING_OUT = 1.78;                // 最外圈环半径（决定取景）
  var CLOUD = 13000;
  var DPR = Math.min(window.devicePixelRatio || 1, 2);

  /* 定点随机与噪声函数挪到文件开头（第 2 节）：底纹与星球各用一条随机流。 */

  /* ── 配色：整颗星只有一族蓝（深靛 → 亮天蓝），明暗差全交给噪声带。
        台站点与卫星**不换色相**：由 uStn 按主题给「同族里更亮的一档」——
        深色主题下几乎是白（加色混合，白就是最亮），浅色主题下是更深的靛
        （浅底上深一档才看得见）。整屏没有第二种颜色，也就不存在"花"。 ── */
  var PAL = {
    deep:   [0.055, 0.086, 0.290],   // 深靛
    mid:    [0.145, 0.290, 0.760],   // 中蓝
    bright: [0.420, 0.620, 1.000],   // 亮天蓝
    storm:  [0.030, 0.045, 0.150]    // 风暴带 / 无站区
  };
  function mix3(a, b, t, out) {
    out[0] = a[0] + (b[0] - a[0]) * t;
    out[1] = a[1] + (b[1] - a[1]) * t;
    out[2] = a[2] + (b[2] - a[2]) * t;
    return out;
  }

  var RING_IN = 1.30;                 // 最内圈环半径：开普勒比例以它为准

  /* ── 卫星：几颗小亮点各自绕在倾斜的轨道上**快速划过**。每颗后面拖一小串
        逐渐变暗的点（不是发光线，还是点），看上去就是"嗖"地过去的那一下。
        半径 / 倾角 / 相位 / 快慢 / 方向全部错开 —— 一组卫星，不是一串糖葫芦。
        位置每帧由 JS 按绝对时间算（见 buildSats），所以 aSpin 给 0：它们不跟
        球体自转走，各自在自己的轨道上跑。 ── */
  var SATS = [
    { r: 1.96, tilt: 0.40, ph: 0.00, w: 0.66, sz: 0.0130, tail: 11 },
    { r: 2.16, tilt: -0.26, ph: 2.10, w: -0.80, sz: 0.0112, tail: 9 },
    { r: 2.34, tilt: 0.94, ph: 4.00, w: 0.50, sz: 0.0142, tail: 13 },
    { r: 2.04, tilt: -0.72, ph: 5.35, w: -1.02, sz: 0.0098, tail: 7 }
  ];
  var SAT_STEP = 0.038;               // 尾迹相邻两点的角距（rad）
  var SAT_PTS = 0, si;
  for (si = 0; si < SATS.length; si++) SAT_PTS += 1 + SATS[si].tail;

  /* ── 几何：交错 10 float/点 = pos(3) + col(3) + meta(尺寸, 呼吸频率, 呼吸幅度) + spin
        meta.z > 0 的点会自己呼吸（大小与亮度一起抖）；spin 是自己的角速度，
        0 = 跟着拖动走（星球本体），非 0 = 自己转（环带 / 卫星轨道）。 ── */
  function buildCloud() {
    var arr = [], col = [0, 0, 0], i, j, u, th, s, x, y, z, r, ang, ex, ez, live, fade, band, fine, g, c;

    // 星球本体：纬向拉伸的噪声（y 放大 6 倍）→ 一颗星球该有的横条带
    for (i = 0; i < CLOUD; i++) {
      u = rnd() * 2 - 1;
      th = rnd() * Math.PI * 2;
      s = Math.sqrt(1 - u * u);
      x = s * Math.cos(th); y = u; z = s * Math.sin(th);
      r = 1 + (rnd() - 0.5) * 0.03;
      band = noise3(x * 0.5, y * 3.0, z * 0.5) * 0.5 + 0.5;
      fine = noise3(x * 4.4, y * 4.4, z * 4.4) * 0.5 + 0.5;
      if (band < 0.44) mix3(PAL.deep, PAL.mid, band / 0.44, col);
      else mix3(PAL.mid, PAL.bright, (band - 0.44) / 0.56, col);
      if (fine < 0.32) mix3(col, PAL.storm, (0.32 - fine) * 1.2, col);     // 暗斑
      g = 0.72 + 0.56 * fine;                                              // 逐点亮度抖动
      arr.push(x * r, y * r, z * r, col[0] * g, col[1] * g, col[2] * g,
        0.0105 + rnd() * 0.0062,              // 尺寸：相对星球屏幕半径
        0.35 + rnd() * 1.60,                  // 呼吸频率
        0.06 + 0.22 * fine,                   // 呼吸幅度（本体很轻）
        0);
    }

    // 台站点：同族蓝里最亮的一档，呼吸最明显 —— 会闪的那几粒就是台站在上报
    for (i = 0; i < 90; i++) {
      u = rnd() * 2 - 1;
      th = rnd() * Math.PI * 2;
      s = Math.sqrt(1 - u * u);
      x = s * Math.cos(th); y = u; z = s * Math.sin(th);
      // 不再上色：台站点就是同族蓝里最亮的一档，靠亮度点出来。
      // （抽样次数故意与上一版一致，星球几何因此逐点不变。）
      c = PAL.bright;
      g = 0.62 + rnd() * 0.70;
      arr.push(x, y, z, c[0] * g, c[1] * g, c[2] * g,
        0.0140 + rnd() * 0.0105,
        0.9 + rnd() * 2.4,
        0.80 + rnd() * 0.20,
        0);
    }

    // 环带：XZ 平面三圈，密度按噪声立方取舍 → 亮暗相间的弧段；
    // 角速度取开普勒比例 ω ∝ r^-1.5，三圈快慢不同，转起来才像"有质量的环"。
    var rings = [[RING_IN, 1100, 0.34], [1.52, 1200, 0.46], [1.74, 1300, 0.60]];
    for (i = 0; i < rings.length; i++) {
      var rad = rings[i][0], cnt = rings[i][1], bright = rings[i][2];
      var rate = 0.06 * Math.pow(RING_IN / rad, 1.5);   // 内圈 3.4°/s → 外圈 2.2°/s
      for (j = 0; j < cnt; j++) {
        ang = rnd() * Math.PI * 2;
        ex = Math.cos(ang); ez = Math.sin(ang);
        live = Math.pow((noise3(ex * 2.0, ez * 2.0, 0.5) + 1) * 0.5, 3);
        if (rnd() > live * 1.2) continue;
        r = rad + (rnd() - 0.5) * 0.03;
        fade = 1 - Math.abs(r - rad) / 0.05;
        c = bright > 0.45 ? PAL.bright : PAL.mid;
        g = (0.55 + rnd() * 0.6) * fade * bright;
        arr.push(ex * r, (rnd() - 0.5) * 0.01, ez * r,
          c[0] * g, c[1] * g, c[2] * g,
          0.0058 + rnd() * 0.0036,
          0.6 + rnd() * 1.5,
          0.20 + 0.25 * fade,
          rate);
      }
    }

    return { data: new Float32Array(arr), count: arr.length / 10 };
  }

  /* ── 经纬网：参考实现里星球外面套了一层 6% 不透明度的线框球。手写同一件事：
        12 条经线 + 7 条纬线，半径 1.004，用 gl.LINES 画。点云是"实体"，线框是
        "仪表感" —— 只有一团点的话，看上去还是雾。 ── */
  function buildWire() {
    var v = [], SEG = 48, MER = 12, PAR = 7, R = 1.004, i, k, a, a1, y, rr, p0, p1;
    for (i = 0; i < MER; i++) {
      a = (i / MER) * Math.PI * 2;
      for (k = 0; k < SEG; k++) {
        p0 = (k / SEG) * Math.PI; p1 = ((k + 1) / SEG) * Math.PI;
        v.push(Math.sin(p0) * Math.cos(a) * R, Math.cos(p0) * R, Math.sin(p0) * Math.sin(a) * R,
          Math.sin(p1) * Math.cos(a) * R, Math.cos(p1) * R, Math.sin(p1) * Math.sin(a) * R);
      }
    }
    for (i = 1; i <= PAR; i++) {
      y = -1 + (i / (PAR + 1)) * 2;
      rr = Math.sqrt(Math.max(0, 1 - y * y)) * R;
      for (k = 0; k < SEG; k++) {
        a = (k / SEG) * Math.PI * 2; a1 = ((k + 1) / SEG) * Math.PI * 2;
        v.push(Math.cos(a) * rr, y * R, Math.sin(a) * rr,
          Math.cos(a1) * rr, y * R, Math.sin(a1) * rr);
      }
    }
    return { data: new Float32Array(v), count: v.length / 3 };
  }

  var VS = [
    "attribute vec3 aPos;",
    "attribute vec3 aCol;",
    "attribute vec3 aMeta;",              // 尺寸 / 呼吸频率 / 呼吸幅度
    "attribute float aSpin;",             // 自己的角速度（0 = 跟着拖动走）
    "uniform float uCosY; uniform float uSinY;",
    "uniform float uCosP; uniform float uSinP;",
    "uniform float uSpinT;",
    "uniform float uDist; uniform float uProj; uniform float uAspect;",
    "uniform float uPxScale; uniform float uMaxSize; uniform float uMinPx;",
    "uniform float uTime; uniform float uBurst; uniform float uSeed;",
    "uniform float uGather;",                          // 入场进度 0 → 1
    "uniform vec2 uCenter; uniform vec3 uTint; uniform vec3 uStn;",
    "varying vec3 vCol;",
    "varying float vFade;",
    "void main() {",
    "  float own = aSpin * uSpinT;",                    // 自己转过的角度
    "  float co = cos(own), so = sin(own);",
    // 入场：点云不是一下就摆好，而是从上方散落着被「拉」下来 ——
    // 每点一个 [0,1) 相位，起点是抬高且摊开的一层，逐点错峰落回球面。
    "  float sd = fract(sin(dot(aPos, vec3(12.9898, 78.233, 37.719))) * 43758.5453);",
    "  vec3 src = aPos * (1.05 + 0.75 * sd) + vec3(0.0, 0.35 + 1.70 * sd, 0.0);",
    "  float gp = clamp((uGather - sd * 0.55) / (1.0 - sd * 0.55), 0.0, 1.0);",
    "  gp = gp * gp * (3.0 - 2.0 * gp);",               // 缓入缓出，落点不带刹车感
    "  vec3 loc = mix(src, aPos, gp);",
    "  float cy = uCosY * co - uSinY * so;",            // 拖着走 + 自己转，一次合成
    "  float sy = uSinY * co + uCosY * so;",
    // 明暗用「落定后」的法线算：飞行途中的位置不参与打光，否则一路乱闪
    "  vec3 hn = vec3(aPos.x * cy + aPos.z * sy, aPos.y, aPos.z * cy - aPos.x * sy);",
    "  hn = vec3(hn.x, hn.y * uCosP - hn.z * uSinP, hn.y * uSinP + hn.z * uCosP);",
    "  vec3 p = vec3(loc.x * cy + loc.z * sy, loc.y, loc.z * cy - loc.x * sy);",
    "  p = vec3(p.x, p.y * uCosP - p.z * uSinP, p.y * uSinP + p.z * uCosP);",
    "  float d = uDist - p.z;",
    "  gl_Position = vec4(p.x * uProj / uAspect + uCenter.x, p.y * uProj + uCenter.y, d - uDist, d);",
    "  vec3 L = normalize(vec3(-0.45, 0.42, 0.79));",   // 左上偏前的一束光
    "  float lam = 0.58 + 0.52 * max(dot(normalize(hn), L), 0.0);",
    "  float tw = 0.5 + 0.5 * sin(uTime * aMeta.y + aPos.x * 9.0 + aPos.z * 5.0 + aPos.y * 3.0);",
    "  float k = mix(1.0, 0.34 + 1.20 * tw, aMeta.z) * lam;",
    "  float pick = fract(sin(dot(aPos, vec3(12.9898, 78.233, 37.719)) + uSeed) * 43758.5453);",
    "  float flare = uBurst * step(0.95, pick);",
    "  k *= 1.0 + 1.6 * flare;",
    "  gl_PointSize = clamp(aMeta.x * uPxScale / max(d, 0.35) * k * (0.30 + 0.70 * gp), uMinPx, uMaxSize);",
    "  float isStn = step(0.5, aMeta.z);",              // 台站 / 卫星：比本体亮一大截的那一类
    "  vec3 base = mix(aCol, uStn * (0.72 + 0.62 * aCol.b), isStn);",
    "  vCol = base * uTint * k;",
    "  vFade = ((0.30 + 0.70 * clamp(p.z * 0.85 + 0.62, 0.0, 1.0)) * (0.72 + 0.55 * aMeta.z * tw) + flare * 0.6) * (0.10 + 0.90 * gp);",
    "}"
  ].join("\n");

  var FS = [
    "precision mediump float;",
    "varying vec3 vCol;",
    "varying float vFade;",
    "uniform float uAlpha;",
    "void main() {",
    "  vec2 q = gl_PointCoord - vec2(0.5);",
    "  float r2 = dot(q, q);",
    "  if (r2 > 0.25) discard;",
    "  gl_FragColor = vec4(vCol, clamp(smoothstep(0.25, 0.05, r2) * vFade * uAlpha, 0.0, 1.0));",
    "}"
  ].join("\n");

  /* 线框球：单独的 program（gl_PointCoord 对线段无意义，不能复用上面那支片元着色器） */
  var WVS = [
    "attribute vec3 aPos;",
    "uniform float uAngle; uniform float uCosP; uniform float uSinP;",
    "uniform float uDist; uniform float uProj; uniform float uAspect;",
    "uniform vec2 uCenter;",
    "uniform float uGather;",
    "varying float vFace;",
    "varying float vIn;",
    "void main() {",
    "  vIn = smoothstep(0.0, 1.0, uGather);",           // 线框比点云慢半步落位
    "  vec3 a = aPos * (1.0 + 0.34 * (1.0 - vIn));",
    "  float cy = cos(uAngle), sy = sin(uAngle);",
    "  vec3 p = vec3(a.x * cy + a.z * sy, a.y, a.z * cy - a.x * sy);",
    "  p = vec3(p.x, p.y * uCosP - p.z * uSinP, p.y * uSinP + p.z * uCosP);",
    "  float d = uDist - p.z;",
    "  gl_Position = vec4(p.x * uProj / uAspect + uCenter.x, p.y * uProj + uCenter.y, d - uDist, d);",
    "  vFace = clamp(p.z * 1.1 + 0.5, 0.0, 1.0);",      // 背面的线更淡
    "}"
  ].join("\n");

  var WFS = [
    "precision mediump float;",
    "varying float vFace;",
    "varying float vIn;",
    "uniform vec3 uColor; uniform float uAlpha;",
    "void main() {",
    "  float a = uAlpha * vIn;",
    "  if (a < 0.004) discard;",
    "  gl_FragColor = vec4(uColor * (0.30 + 0.70 * vFace), a);",
    "}"
  ].join("\n");

  function fail(why) {
    hero.classList.add("no-3d");
    hero.setAttribute("data-3d", why);
    if (window.console && console.warn) console.warn("[planet-3d] fallback:", why);
  }

  var gl = null;
  try {
    gl = canvas.getContext("webgl", { alpha: true, premultipliedAlpha: false, antialias: false, depth: true })
      || canvas.getContext("experimental-webgl", { alpha: true, premultipliedAlpha: false });
  } catch (e) { gl = null; }
  if (!gl) { fail("no-webgl"); return; }

  function compile(type, src) {
    var sh = gl.createShader(type);
    gl.shaderSource(sh, src);
    gl.compileShader(sh);
    if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) {
      if (window.console && console.warn) console.warn("[planet-3d]", gl.getShaderInfoLog(sh));
      return null;
    }
    return sh;
  }

  var prog = gl.createProgram();
  var vs = compile(gl.VERTEX_SHADER, VS), fs = compile(gl.FRAGMENT_SHADER, FS);
  if (!vs || !fs) { fail("shader-compile"); return; }
  gl.attachShader(prog, vs);
  gl.attachShader(prog, fs);
  gl.linkProgram(prog);
  if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) { fail("link"); return; }
  gl.useProgram(prog);

  /* 线框球的 program：gl_PointCoord 对线段无意义，所以单独一支片元着色器 */
  var wProg = gl.createProgram();
  var wvs = compile(gl.VERTEX_SHADER, WVS), wfs = compile(gl.FRAGMENT_SHADER, WFS);
  if (!wvs || !wfs) { fail("shader-compile"); return; }
  gl.attachShader(wProg, wvs);
  gl.attachShader(wProg, wfs);
  gl.linkProgram(wProg);
  if (!gl.getProgramParameter(wProg, gl.LINK_STATUS)) { fail("link"); return; }
  var WA = { pos: gl.getAttribLocation(wProg, "aPos") };
  var WU = {};
  ["uAngle", "uCosP", "uSinP", "uDist", "uProj", "uAspect", "uCenter", "uColor", "uAlpha", "uGather"
  ].forEach(function (k) { WU[k] = gl.getUniformLocation(wProg, k); });
  var wire = buildWire();
  var wBuf = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, wBuf);
  gl.bufferData(gl.ARRAY_BUFFER, wire.data, gl.STATIC_DRAW);
  gl.useProgram(prog);

  var cloud = buildCloud();
  var STRIDE = 10 * 4;
  var buf = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, buf);
  gl.bufferData(gl.ARRAY_BUFFER, cloud.data, gl.STATIC_DRAW);

  var satArr = new Float32Array(SAT_PTS * 10);
  var satBuf = gl.createBuffer();

  var A = {
    pos: gl.getAttribLocation(prog, "aPos"),
    col: gl.getAttribLocation(prog, "aCol"),
    meta: gl.getAttribLocation(prog, "aMeta"),
    spin: gl.getAttribLocation(prog, "aSpin")
  };
  var U = {};
  ["uCosY", "uSinY", "uCosP", "uSinP", "uSpinT", "uDist", "uProj", "uAspect", "uPxScale",
    "uMaxSize", "uMinPx", "uTime", "uCenter", "uTint", "uStn", "uAlpha", "uBurst", "uSeed", "uGather"
  ].forEach(function (k) { U[k] = gl.getUniformLocation(prog, k); });

  function bindPointers() {
    gl.vertexAttribPointer(A.pos, 3, gl.FLOAT, false, STRIDE, 0);
    gl.vertexAttribPointer(A.col, 3, gl.FLOAT, false, STRIDE, 12);
    gl.vertexAttribPointer(A.meta, 3, gl.FLOAT, false, STRIDE, 24);
    gl.vertexAttribPointer(A.spin, 1, gl.FLOAT, false, STRIDE, 36);
    gl.enableVertexAttribArray(A.pos);
    gl.enableVertexAttribArray(A.col);
    gl.enableVertexAttribArray(A.meta);
    gl.enableVertexAttribArray(A.spin);
  }

  gl.disable(gl.CULL_FACE);
  gl.enable(gl.BLEND);
  gl.enable(gl.DEPTH_TEST);
  gl.depthFunc(gl.LESS);
  gl.depthMask(true);
  gl.clearColor(0, 0, 0, 0);                       // 画布全透明：点之外什么都不画，所以没有"面板"

  /* 深浅主题共用同一份几何，只换混合函数、色调与线框：
     浅底用正常混合（蓝墨点压在浅底上），深底用加色混合（同样的点变霓虹辉光）。
     线框在浅底上要更实一点才看得见，颜色也往靛蓝收一档。 */
  var MODES = {
    light: {
      add: false, tint: [1.00, 1.00, 1.00], alpha: 1.00,
      wire: 0.42, wireCol: [0.05, 0.36, 0.60],          // 站点本来就有的那支靛蓝
      stn: [0.075, 0.165, 0.520]                        // 台站 / 卫星：同族里更深一档
    },
    dark: {
      add: true, tint: [1.08, 1.12, 1.26], alpha: 0.88,
      wire: 0.55, wireCol: [0.42, 0.62, 1.00],
      stn: [0.930, 0.980, 1.000]                        // 加色混合下就是"最亮"
    }
  };
  var dark = false;
  function syncMode() {
    var t = document.documentElement.getAttribute("data-theme");
    dark = (t === "dark");
  }
  syncMode();

  /* ── 相机 / 交互状态 ── */
  var yaw = 0.55, pitch = -0.10, tYaw = yaw, tPitch = pitch;
  var spin = reduce ? 0 : 0.055;                   // rad/s 自转
  var dragging = false, lastX = 0, lastY = 0;
  var running = false, paused = false, raf = 0, last = 0;

  /* 入场（聚成球）：gather 从 0 → 1，顶点着色器用 uGather 把点从「散开的一层」
     拉回球面；相机同时从更近的机位退到取景位（先是一颗大地球，再落定）。
     降级动效下直接到位，不动。 */
  var GATHER_MS = 2400;
  var gather = reduce ? 1 : 0, gatherT0 = 0, gateAt = 0;
  function easeOutCubic(t) { return 1 - Math.pow(1 - t, 3); }
  function nowMs() { return window.performance && performance.now ? performance.now() : Date.now(); }
  /* 入场的发令枪：等启动遮罩走开（body.loaded）再开演 —— 遮罩还在就开演的话，
     整段动画在遮罩后面自己演完，用户什么都没看到。但遮罩要是因为任何原因不
     消失（main.js 的外链资源卡住），最多等 3.6s 就直接开场：宁可早一步，
     也不要 hero 一直停在"还没聚拢"的状态。（main.js 自己 3.2s 有兜底。） */
  function gatherGate() {
    if (!gateAt) gateAt = nowMs() + 3600;
    if (document.body && document.body.classList.contains("loaded")) return true;
    return nowMs() >= gateAt;
  }

  /* ── 取景：view.r 是星球本体的屏幕半径，view.cx/cy 是它在 hero 里的相对位置。
        相机距离由 r 反推，所以换屏不会"忽大忽小"，环带始终切出右缘。 ── */
  var view = { cx: 0.715, cy: 0.475, r: 1 };
  function frame(w, h) {
    var aspect = w / Math.max(1, h);
    if (aspect > 1.25) { view.cx = 0.715; view.cy = 0.475; view.r = 0.325 * h; }     // 桌面：偏右
    else if (aspect > 0.95) { view.cx = 0.60; view.cy = 0.42; view.r = 0.27 * h; }   // 横屏平板
    else { view.cx = 0.50; view.cy = 0.30; view.r = 0.34 * w; }                      // 窄屏：上三分之一居中
    return view;
  }
  function camDist(h) { return U_PROJ * h / (2 * Math.max(1, view.r)); }

  /* 每来一条报文就挑一批点窜一下：读数一跳，星面跟着亮一片（uBurst 从 1 衰减） */
  var burstAt = -1e9, burstSeed = 0, BURST_MS = 900;
  function flash(seed) { burstAt = Date.now(); burstSeed = (seed || 0) * 0.618 % 1; if (!running) start(); }

  function draw(now) {
    var w = canvas.width, h = canvas.height;
    if (!w || !h) return;
    var f = frame(w, h);
    var m = MODES[dark ? "dark" : "light"];
    var zoom = reduce ? 1 : 1 + 0.20 * (1 - gather);   // 入场：从更近的机位缓缓退回
    var dist = camDist(h) / zoom;
    var cp = Math.cos(TILT + pitch), sp = Math.sin(TILT + pitch);
    var age = reduce ? 1 : (Date.now() - burstAt) / BURST_MS;
    var burst = (age < 0 || age > 1) ? 0 : Math.pow(1 - age, 2);
    gl.viewport(0, 0, w, h);
    gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
    gl.useProgram(prog);
    gl.blendFunc(gl.SRC_ALPHA, m.add ? gl.ONE : gl.ONE_MINUS_SRC_ALPHA);
    gl.uniform3f(U.uTint, m.tint[0], m.tint[1], m.tint[2]);
    gl.uniform3f(U.uStn, m.stn[0], m.stn[1], m.stn[2]);
    gl.uniform1f(U.uAlpha, m.alpha);
    gl.uniform2f(U.uCenter, f.cx * 2 - 1, 1 - f.cy * 2);
    gl.uniform1f(U.uCosY, Math.cos(yaw));
    gl.uniform1f(U.uSinY, Math.sin(yaw));
    gl.uniform1f(U.uCosP, cp);
    gl.uniform1f(U.uSinP, sp);
    gl.uniform1f(U.uSpinT, reduce ? 0 : now);
    gl.uniform1f(U.uDist, dist);
    gl.uniform1f(U.uProj, U_PROJ);
    gl.uniform1f(U.uAspect, w / h);
    gl.uniform1f(U.uPxScale, (h / 2) * U_PROJ);
    gl.uniform1f(U.uMaxSize, Math.max(14, 15 * DPR));
    gl.uniform1f(U.uMinPx, Math.max(1, 2.0 * DPR));
    gl.uniform1f(U.uTime, reduce ? 0 : now);
    gl.uniform1f(U.uBurst, burst);
    gl.uniform1f(U.uSeed, burstSeed);
    gl.uniform1f(U.uGather, gather);

    // 线框球先画：点云自己写深度，正面那一半自然把线压住
    gl.useProgram(wProg);
    gl.uniform1f(WU.uAngle, yaw);
    gl.uniform1f(WU.uCosP, cp);
    gl.uniform1f(WU.uSinP, sp);
    gl.uniform1f(WU.uDist, dist);
    gl.uniform1f(WU.uProj, U_PROJ);
    gl.uniform1f(WU.uAspect, w / h);
    gl.uniform2f(WU.uCenter, f.cx * 2 - 1, 1 - f.cy * 2);
    gl.uniform3f(WU.uColor, m.wireCol[0], m.wireCol[1], m.wireCol[2]);
    var wireIn = reduce ? 1 : Math.max(0, Math.min(1, (gather - 0.40) / 0.60));
    gl.uniform1f(WU.uGather, wireIn);
    gl.uniform1f(WU.uAlpha, m.wire);
    gl.bindBuffer(gl.ARRAY_BUFFER, wBuf);
    gl.vertexAttribPointer(WA.pos, 3, gl.FLOAT, false, 0, 0);
    gl.enableVertexAttribArray(WA.pos);
    gl.drawArrays(gl.LINES, 0, wire.count);
    gl.disableVertexAttribArray(WA.pos);          // 免得下一趟点到线框的缓冲上去

    gl.useProgram(prog);
    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    bindPointers();
    gl.drawArrays(gl.POINTS, 0, cloud.count);

    // 卫星：几颗小亮点带着尾迹，各在自己的倾斜轨道上快速划过
    if (!reduce) buildSats(now);
    gl.bindBuffer(gl.ARRAY_BUFFER, satBuf);
    gl.bufferData(gl.ARRAY_BUFFER, satArr, gl.DYNAMIC_DRAW);
    bindPointers();
    gl.drawArrays(gl.POINTS, 0, SAT_PTS);
  }

  /* 把每颗卫星（含尾迹）的位置算进 satArr：head 在最前，后面一串点按角距往回
     排、越往后越暗越小。角距 = SAT_STEP，尾点排在**运动方向的反面**，所以谁
     快谁尾巴长都对得上。位置每帧重算，不需要 aSpin（顶点着色器里给 0）。 */
  function buildSats(t) {
    var o = 0, k, j, s2, ct, st, base, dir, a, x, y, z, f, g, sz;
    for (k = 0; k < SATS.length; k++) {
      s2 = SATS[k];
      base = s2.ph + s2.w * t;
      dir = s2.w >= 0 ? 1 : -1;
      ct = Math.cos(s2.tilt); st = Math.sin(s2.tilt);
      for (j = 0; j <= s2.tail; j++) {
        a = base - dir * j * SAT_STEP;
        x = Math.cos(a) * s2.r; z = Math.sin(a) * s2.r;
        y = -z * st; z = z * ct;                 // 轨道面绕 X 轴倾斜 tilt
        f = j === 0 ? 1 : 1 - j / (s2.tail + 1);
        g = j === 0 ? 1 : 0.16 + 0.84 * f * f;   // 头最亮，尾点快速衰减
        sz = s2.sz * (j === 0 ? 1 : 0.34 + 0.66 * f);
        satArr[o++] = x; satArr[o++] = y; satArr[o++] = z;
        satArr[o++] = g; satArr[o++] = g; satArr[o++] = g;   // 亮度：色相由 uStn 按主题给
        satArr[o++] = sz;
        satArr[o++] = 0.35 + 0.20 * k;           // 呼吸频率：卫星也轻轻喘，很慢
        satArr[o++] = 0.55;                      // 幅度 > 0.5 → 着色器当成"台站 / 卫星"那一类
        satArr[o++] = 0;                         // aSpin = 0：位置自己算
      }
    }
  }

  function loop(now) {
    var dt = Math.min(0.05, (now - last) / 1000) || 0;
    last = now;
    if (!gatherT0) {                                // 入场：先等发令枪
      if (gatherGate()) gatherT0 = now;
    } else if (gather < 1) {                        // 聚成球 + 机位退定
      gather = easeOutCubic(Math.min(1, (now - gatherT0) / GATHER_MS));
      if (gather > 0.999) gather = 1;
    }
    var k = Math.min(1, dt * 9);                   // 阻尼跟随（参考实现是每帧 0.1）
    yaw += (tYaw - yaw) * k;
    pitch += (tPitch - pitch) * k;
    if (!dragging && spin) { tYaw += spin * dt; yaw += spin * dt; }
    draw(now / 1000);
    // 降级动效（prefers-reduced-motion）：静止后停掉循环，只保留可拖动
    if (reduce && !dragging && Math.abs(tYaw - yaw) < 0.002 && Math.abs(tPitch - pitch) < 0.002) {
      running = false;
      return;
    }
    raf = requestAnimationFrame(loop);
  }

  function start() {
    if (running || paused) return;
    running = true;
    last = nowMs();
    raf = requestAnimationFrame(loop);               // 入场起点由 loop 里的发令枪定
  }

  function resize() {
    var dpr = Math.min(window.devicePixelRatio || 1, 2);
    var rect = canvas.getBoundingClientRect();
    var w = Math.round(rect.width * dpr), h = Math.round(rect.height * dpr);
    if (w < 2 || h < 2) return;
    if (w === canvas.width && h === canvas.height) return;
    canvas.width = w;
    canvas.height = h;
    draw(reduce ? 0 : (window.performance && performance.now ? performance.now() / 1000 : 0));
    applyScroll();
    start();
  }

  /* ── 拖动 / 键盘 ── */
  canvas.addEventListener("pointerdown", function (e) {
    dragging = true;
    lastX = e.clientX; lastY = e.clientY;
    hero.classList.add("grabbing");
    if (canvas.setPointerCapture) { try { canvas.setPointerCapture(e.pointerId); } catch (err) {} }
    start();
  });
  canvas.addEventListener("pointermove", function (e) {
    if (!dragging) return;
    tYaw += (e.clientX - lastX) * 0.0065;
    tPitch = Math.max(-0.95, Math.min(0.95, tPitch + (e.clientY - lastY) * 0.005));
    lastX = e.clientX; lastY = e.clientY;
  });
  function endDrag() {
    if (!dragging) return;
    dragging = false;
    hero.classList.remove("grabbing");
    start();
  }
  canvas.addEventListener("pointerup", endDrag);
  canvas.addEventListener("pointercancel", endDrag);
  canvas.addEventListener("pointerleave", endDrag);

  canvas.addEventListener("keydown", function (e) {
    var step = 0.22, used = true;
    if (e.key === "ArrowLeft") tYaw -= step;
    else if (e.key === "ArrowRight") tYaw += step;
    else if (e.key === "ArrowUp") tPitch = Math.max(-0.95, tPitch - step * 0.6);
    else if (e.key === "ArrowDown") tPitch = Math.min(0.95, tPitch + step * 0.6);
    else if (e.key === "Home") { tYaw = 0.55; tPitch = -0.10; }
    else used = false;
    if (used) { e.preventDefault(); start(); }
  });

  /* ── 视口内才画（省电，也让长页面滚动不卡） ── */
  if (window.IntersectionObserver) {
    new IntersectionObserver(function (es) {
      es.forEach(function (en) {
        if (en.isIntersecting) { paused = false; start(); }
        else {
          paused = true;
          running = false;
          if (raf) cancelAnimationFrame(raf);
        }
      });
    }, { threshold: 0 }).observe(hero);
  }
  document.addEventListener("visibilitychange", function () {
    if (document.hidden) {
      paused = true; running = false;
      if (raf) cancelAnimationFrame(raf);
    } else { paused = false; start(); }
  });

  if (window.ResizeObserver) {
    new ResizeObserver(resize).observe(canvas);
  } else {
    window.addEventListener("resize", resize, { passive: true });
  }

  resize();
  if (!canvas.width) resize();
  start();
  hooks.flash = flash;                             // 遥测那边每跳一次就调它

  /* ── 滚动：往下拉时星球退得比页面慢半步（视差）并缓缓淡出，文案上浮隐去；
        滚回顶部一切复原。变量写在 .hero 上，位移 / 透明度全交给 hero-3d.css。
        降级动效（prefers-reduced-motion）下不接这个监听，CSS 保持原样。 ── */
  var scrollP = 0, scrollQueued = false;
  function applyScroll() {
    scrollQueued = false;
    if (reduce) return;
    var h = window.innerHeight || hero.offsetHeight || 1;   // 以"一屏"为准
    var y = window.pageYOffset || document.documentElement.scrollTop || 0;
    var p = Math.max(0, Math.min(1, y / (h * 0.8)));
    if (p === scrollP) return;
    scrollP = p;
    var e = p * p * (3 - 2 * p);                    // 缓入缓出：起手不出戏，收尾不突兀
    hero.style.setProperty("--hero-3d-y", (e * 30).toFixed(2) + "px");
    hero.style.setProperty("--hero-3d-scale", (1 + e * 0.06).toFixed(4));
    hero.style.setProperty("--hero-3d-fade", (1 - e * 0.62).toFixed(3));
    hero.style.setProperty("--hero-3d-copy", (-e * 34).toFixed(2) + "px");
    hero.style.setProperty("--hero-3d-copy-fade", (1 - e * 0.88).toFixed(3));
  }
  function onScroll() {
    if (scrollQueued) return;
    scrollQueued = true;
    requestAnimationFrame(applyScroll);
  }
  if (!reduce) {
    window.addEventListener("scroll", onScroll, { passive: true });
    applyScroll();
  }

  /* 主题切换（站点的 toggle 改的是 <html data-theme>）：只换混合模式与 tint，重画一帧 */
  if (window.MutationObserver) {
    new MutationObserver(function () {
      var was = dark;
      syncMode();
      if (was !== dark) {
        draw(reduce ? 0 : (window.performance ? performance.now() / 1000 : 0));
        start();
      }
    }).observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
  }

  /* ── 调试/自检钩子：给脚本一个同步的"渲染 + 回读"入口，静态检查与
        CI 截图都靠它读像素，不需要目测（draw + readPixels 必须同一任务内）。 ── */
  window.__planet3d = {
    pixelStats: function () {
      draw(reduce ? 0 : (window.performance ? performance.now() / 1000 : 0));
      var w = canvas.width, h = canvas.height;
      var px = new Uint8Array(w * h * 4);
      gl.readPixels(0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, px);
      var lit = 0, sum = 0, q = [0, 0, 0, 0], n = w * h, i;
      // 4×4 网格均值：覆盖率这类宏观统计是**旋转不变**的，抓不到「拖了没反应」，
      // 所以自检要比对网格指纹而不是只看 litRatio。
      var cell = [], grid = [];
      for (i = 0; i < 16; i++) cell.push([0, 0]);
      for (i = 0; i < n; i++) {
        var l = (px[i * 4] + px[i * 4 + 1] + px[i * 4 + 2]) / 3;
        sum += l;
        var gx = Math.min(3, (i % w) * 4 / w | 0), gy = Math.min(3, ((i / w) | 0) * 4 / h | 0);
        cell[gy * 4 + gx][0] += l;
        cell[gy * 4 + gx][1]++;
        if (l > 24) {
          lit++;
          q[(gy < 2 ? 0 : 2) + (gx < 2 ? 0 : 1)]++;
        }
      }
      for (i = 0; i < 16; i++) grid.push(+(cell[i][0] / Math.max(1, cell[i][1])).toFixed(1));
      return { w: w, h: h, mean: +(sum / n).toFixed(2), litRatio: +(lit / n).toFixed(4),
               quadrants: q, grid: grid };
    },
    state: function () {
      return {
        ok: !hero.classList.contains("no-3d"),
        glError: gl.getError(),
        points: cloud.count,
        wire: wire.count,
        dist: +camDist(canvas.height).toFixed(3),
        frame: { cx: +view.cx.toFixed(3), cy: +view.cy.toFixed(3), r: Math.round(view.r) },
        mode: dark ? "dark" : "light",
        yaw: +yaw.toFixed(3),
        pitch: +pitch.toFixed(3),
        reduce: reduce,
        gate: gatherT0 > 0,
        gather: +gather.toFixed(3),
        scroll: +scrollP.toFixed(3),
        running: running
      };
    },
    flash: function () { flash(0); }
  };
})();
