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
   · 机位固定为「侧看、画面轻 roll 到左上」（VIEW_ELEV + VIEW_ROLL）——
     星球是只看不摸的，机位就是唯一的机位，不接指针也不接键盘。
   页面皮肤（底色、字体、色标、导航）不在这里 —— hero 还是浅色玻璃那一套，
   所以浅色主题走正常混合（蓝墨点），深色主题走加色混合（霓虹辉光）。

   降级：没有 WebGL 或着色器编译失败 → 给 .hero 加 .no-3d，用纯 CSS
   的星球顶上；遥测数字照常跳动（它只依赖 DOM）。

   遥测：数值源头是 /stats.json（仓库里的静态快照，由 check_site.py 与页面
   静态值强制一致），页面按"基线 + 速率 × 经过分钟数"每秒本地推算，
   不需要任何后端与定时任务。
   入场：一进页面，点云不是一下就摆好——每个点带一个相位，从上方散落着被「拉」下来，错峰聚成一颗球；
   相机同时从更近的机位缓缓退到取景位，线框球比点云慢半步收拢到位。
   动感：星面有三层不同方向的浪在跑（波峰亮一档，所以浪看得见），小流星从外面
   斜插进球面、落点荡开一圈冲击波；读数每跳一次星面再闪一批点。
   滚动：往下拉时星球退得比页面慢半步（视差）并缓缓淡出，文案轻缩上浮隐去，
   折线之下那一屏淡淡地追上——滚动量在 JS 里被缓动过（每帧向目标靠近一档），
   所以是滑上去的，不是跟着滚轮一格一格跳。滚回顶部一切复原。

   ══════════════════════════════════════════════════════════════════════ */
(function () {
  "use strict";

  var reduce = false;
  try {
    reduce = !!(window.matchMedia && matchMedia("(prefers-reduced-motion: reduce)").matches);
  } catch (e) { reduce = false; }

  /* 星球渲染就绪后会把"闪一下"填进来：读数每跳一次，星面跟着闪一批点 */
  var hooks = { flash: null };

  /* ── 页面级的节奏覆盖 ──
     页面可以在**引入本脚本之前**先写一份：
       window.__planet3dPage = { gatherMs: 4400, scrollEase: 0.085 };
     不写（首页三语页）就全走下面的默认值，画面与以前一模一样。
     只有彩蛋页 docs/hero.html 写它：同一段画面，开场慢慢聚成球、滚动缓动
     调软一档 —— 那页是让人走进去读故事的，不是扫一眼就走。
     只放两个数，外加一个布尔 `deck`（那页的装饰层是页面级固定层、点云会换形状），
     以及一个整数 `symbols`（那页的名单有多少个名字 → 星野里要补多少粒可点的
     符号点，见第 3d 节）；不做主题/颜色的覆盖：那是设计，不是节奏。 */
  var PAGE = window.__planet3dPage || {};

  /* 彩蛋页还要多做一件事：点云会**换形状**（见第 3b 节）。它把 deck: true 写进
     __planet3dPage，连带着两处按它开关：降级标记挂在哪一层、"在不在画面里"
     按哪一层看。三语首页没有这个键。 */
  var DECK = !!PAGE.deck;

  /* ═════════════ 1. 累计报文遥测 ═════════════ */
  (function telemetry() {
    var root = document.getElementById("heroTelemetry");
    if (!root) return;
    var elVal = document.getElementById("tlPackets");
    if (!elVal) return;

    function digits(s) { return String(s == null ? "" : s).replace(/[^0-9]/g, ""); }
    function fmt(n) { return String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ","); }

    // 首屏先信 HTML 里的静态快照（无 JS / 抓取失败也能看）；stats.json 到手后覆盖。
    var packets = parseInt(digits(root.getAttribute("data-packets") || elVal.textContent), 10);
    var rate = parseInt(digits(root.getAttribute("data-rate")), 10);
    var t0 = Date.parse(root.getAttribute("data-updated") || "") || Date.now();
    var src = root.getAttribute("data-stats") || "stats.json";
    if (!isFinite(packets)) packets = 0;
    if (!isFinite(rate)) rate = 0;

    var shown = -1;

    // 不做上限：这个数字就该一直往上走（维护者的要求）。代价说清楚 —— 快照越旧，
    // "基线 + 速率 × 经过的分钟数"离真值越远，估算就是估算；换来的是一直在动的
    // 读数，而不是一个到点就冻住、还压暗一档的数。想让它准，就更新 stats.json。
    function tick() {
      var now = Date.now();
      if (now < t0) t0 = now;                       // 快照时间在未来（时钟偏差）→ 不倒退
      var live = packets + Math.floor(((now - t0) / 60000) * rate);
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

  /* 降级标记与"在不在画面里"都挂在**画布所在的那一层**上：首页那一层是 .hero
     里的装饰层，彩蛋页那一层是页面级天空层（固定铺满视口，翻到哪一屏都在）。
     挂错层的表现很具体：降级时 .no-3d 加在看不见的元素上 → 纯 CSS 星球不出现；
     或者按"某一屏在不在视口里"停掉渲染 → 翻到别的屏时点云死在半路。 */
  var host = (DECK && canvas.parentNode) ? canvas.parentNode : hero;

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
    deep:   [0.078, 0.141, 0.235],   // 深空蓝（#14243C）
    mid:    [0.184, 0.435, 0.745],   // 冷蓝偏深（#2F6FBE，贴 --cyan-deep）
    bright: [0.302, 0.639, 1.000],   // 冷蓝（#4DA3FF = --cyan）
    storm:  [0.043, 0.071, 0.125]    // 风暴带 / 无站区（#0B1220）
  };
  function mix3(a, b, t, out) {
    out[0] = a[0] + (b[0] - a[0]) * t;
    out[1] = a[1] + (b[1] - a[1]) * t;
    out[2] = a[2] + (b[2] - a[2]) * t;
    return out;
  }

  var RING_IN = 1.30;                 // 最内圈环半径：开普勒比例以它为准

  /* ── 卫星：一组小亮点各自绕在倾斜的轨道上**快速划过**，一颗都不重样。
        每颗分两截尾迹：
        · tail：紧跟在头后面的亮点串（越远越暗越小）—— 就是"嗖"的那一下；
        · wake：再接一段更淡更疏的弧（arc 弧度），把划过的那条**轨迹**留在天上，
          慢慢化掉。只有头 + 尾巴是看不出轨迹的，看上去像凭空冒出来的光点。
        半径 / 倾角 / 相位 / 快慢 / 方向 / 尾长全部错开，避免排成一串糖葫芦。
        位置每帧由 JS 按 animT 算（见 buildSats），aSpin 给 0：它们不跟球体自转。 ── */
  var SATS = [
    { r: 1.96, tilt: 0.40, ph: 0.00, w: 0.66, sz: 0.0130, tail: 14, wake: 22, arc: 1.90 },
    { r: 2.16, tilt: -0.26, ph: 2.10, w: -0.80, sz: 0.0112, tail: 12, wake: 20, arc: 1.70 },
    { r: 2.40, tilt: 0.94, ph: 4.00, w: 0.50, sz: 0.0142, tail: 16, wake: 24, arc: 2.10 },
    { r: 2.04, tilt: -0.72, ph: 5.35, w: -1.02, sz: 0.0098, tail: 10, wake: 16, arc: 1.45 },
    { r: 1.84, tilt: 0.18, ph: 1.25, w: 0.92, sz: 0.0106, tail: 12, wake: 18, arc: 1.60 },
    { r: 2.30, tilt: -1.05, ph: 3.30, w: -0.42, sz: 0.0122, tail: 15, wake: 21, arc: 1.35 },
    { r: 1.74, tilt: 0.62, ph: 5.95, w: 1.12, sz: 0.0092, tail: 9, wake: 14, arc: 1.25 }
  ];
  var SAT_STEP = 0.038;               // 尾迹相邻两点的角距（rad，实际按速度缩放）
  var SAT_PTS = 0, si;
  for (si = 0; si < SATS.length; si++) SAT_PTS += 1 + SATS[si].tail + SATS[si].wake;

  /* ── 几何：交错 10 float/点 = pos(3) + col(3) + meta(尺寸, 呼吸频率, 呼吸幅度) + spin
        meta.z > 0 的点会自己呼吸（大小与亮度一起抖）；spin 是自己的角速度，
        0 = 跟着星球整体走（星球本体），非 0 = 自己转（环带 / 卫星轨道）。 ── */
  /* 符号点的下标表：buildCloud 里排出来的台站式点（第 90 粒之后那些是彩蛋页
     补的），序号 = 数组里的位置。彩蛋页把名单按同一个顺序铺下来，于是
     「第 n 个名字」永远对应「第 n 粒符号」。三语首页不碰这张表（PAGE.symbols
     不传 → 一粒都不补），几何逐点不变。 */
  var SYM = [];

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
      SYM.push(i);                    // 这一粒是符号点：下标 = 它在这张表里的位置
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
      var rate = 0.085 * Math.pow(RING_IN / rad, 1.5);  // 内圈 4.9°/s → 外圈 3.2°/s
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

    /* 彩蛋页的星野：名单上的每一个人都得有自己那一粒可点的符号。前 90 粒就是
       上面那批台站点，这里按 PAGE.symbols 补满（补到与名单人数一样多）。
       ⚠ 只补在**所有既有采样之后**，而且只在 DECK 时补 —— 三语首页的点、
       环、台站一个字节都没动，同一颗星还是每次刷新都一样。 */
    if (DECK) {
      var extra = Math.max(0, (PAGE.symbols | 0) - SYM.length);
      for (i = 0; i < extra; i++) {
        u = rnd() * 2 - 1;
        th = rnd() * Math.PI * 2;
        s = Math.sqrt(1 - u * u);
        x = s * Math.cos(th); y = u; z = s * Math.sin(th);
        c = PAL.bright;
        g = 0.62 + rnd() * 0.70;
        SYM.push(arr.length / 10);    // 下标 = 补进来这一粒的位置
        arr.push(x, y, z, c[0] * g, c[1] * g, c[2] * g,
          0.0140 + rnd() * 0.0105,
          0.9 + rnd() * 2.4,
          0.80 + rnd() * 0.20,
          0);
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
    "attribute float aSpin;",             // 自己的角速度（0 = 只跟着星球整体自转）
    "attribute vec3 aFrom; attribute vec3 aTo;",   // 换形状的两只纯位置缓冲（乒乓）
    "uniform float uCosY; uniform float uSinY;",
    "uniform float uCosP; uniform float uSinP;",
    "uniform float uSpinT;",
    "uniform float uDist; uniform float uProj; uniform float uAspect;",
    "uniform float uCosR; uniform float uSinR;",        // 画面 roll（机位斜着摆）
    "uniform float uPxScale; uniform float uMaxSize; uniform float uMinPx; uniform float uPxGain;",
    "uniform float uTime; uniform float uBurst; uniform float uSeed;",
    "uniform float uGather;",                          // 入场进度 0 → 1
    "uniform float uWave;",                            // 星面海浪（0 = 关 / 已经不是星球了）
    "uniform float uMorph;",                           // 换形状的进度 0 → 1
    "uniform float uScatter;",                         // 中途甩出去的幅度
    "uniform float uShape;",                           // 1 = 形状参与（首页给 0：整段退回 aPos）
    "uniform float uForm;",                            // 1 = 已经不是星球了（环带 / 仪表退场）
    "uniform vec3 uImpDir0; uniform float uImpAge0;",  // 撞击落点 + 命中后经过的秒数
    "uniform vec3 uImpDir1; uniform float uImpAge1;",  //   （负数 = 这一槽在等下一颗）
    "uniform vec3 uImpDir2; uniform float uImpAge2;",
    "uniform vec2 uCenter; uniform vec3 uTint; uniform vec3 uStn;",
    "uniform vec3 uSpot; uniform float uSpotK;",       // 点名：被点到的那一粒（模型空间）+ 点名强度 0→1
    "uniform vec3 uHot;",                             // 点名那一粒换个颜色（暖金）
    "varying vec3 vCol;",
    "varying float vFade;",
    "void main() {",
    "  float own = aSpin * uSpinT;",                    // 自己转过的角度
    "  float co = cos(own), so = sin(own);",
    // 入场：点云不是一下就摆好，而是从上方散落着被「拉」下来 ——
    // 每点一个 [0,1) 相位，起点是抬高且摊开的一层，逐点错峰落回球面。
    "  float sd = fract(sin(dot(aPos, vec3(12.9898, 78.233, 37.719))) * 43758.5453);",
    // 换形状：位置 = mix(aFrom, aTo) 再加一记"甩出去又收回来"的包络
    // （sin(π·进度)，峰值在中途）——所以是散开、再聚拢成另一个形状，
    // 不是两点之间直线插值。uShape = 0（三语首页）时 home 逐位等于 aPos。
    "  float mot = uMorph * uMorph * (3.0 - 2.0 * uMorph);",
    "  vec3 unit = normalize(aPos + vec3(0.0001, 0.0002, 0.0003));",
    "  vec3 tan3 = normalize(cross(unit, vec3(0.0, 1.0, 0.0)) + vec3(0.0001, 0.0, 0.0));",
    "  float burst = uScatter * sin(3.14159265 * mot) * (0.35 + 0.85 * sd);",
    "  vec3 goal = mix(aFrom, aTo, mot) + (unit + tan3 * 0.42) * burst;",
    "  vec3 home = mix(aPos, goal, uShape);",
    "  vec3 src = home * (1.05 + 0.75 * sd) + vec3(0.0, 0.35 + 1.70 * sd, 0.0);",
    "  float gp = clamp((uGather - sd * 0.55) / (1.0 - sd * 0.55), 0.0, 1.0);",
    "  gp = gp * gp * (3.0 - 2.0 * gp);",               // 缓入缓出，落点不带刹车感
    "  vec3 loc = mix(src, home, gp);",
    "  float cy = uCosY * co - uSinY * so;",            // 拖着走 + 自己转，一次合成
    "  float sy = uSinY * co + uCosY * so;",
    // 明暗用「落定后」的法线算：飞行途中的位置不参与打光，否则一路乱闪
    "  vec3 hn = vec3(aPos.x * cy + aPos.z * sy, aPos.y, aPos.z * cy - aPos.x * sy);",
    "  hn = vec3(hn.x, hn.y * uCosP - hn.z * uSinP, hn.y * uSinP + hn.z * uCosP);",
    "  vec3 p = vec3(loc.x * cy + loc.z * sy, loc.y, loc.z * cy - loc.x * sy);",
    "  p = vec3(p.x, p.y * uCosP - p.z * uSinP, p.y * uSinP + p.z * uCosP);",
    // 星面上的浪：三层不同方向、不同快慢的波叠起来；只有本体跟着起伏
    // （|aPos| ≈ 1），环带在外圈不动，线框球也不动 —— 浪只在这颗"海"上跑。
    "  float body = 1.0 - smoothstep(1.02, 1.14, length(aPos));",
    "  float wv = sin(hn.y * 8.0 + uTime * 0.95) * 0.45",
    "           + sin(hn.x * 6.5 - uTime * 1.35) * 0.34",
    "           + sin(hn.z * 5.5 + uTime * 0.75) * 0.28;",
    // 撞击：从落点往外扩一圈环。收尾是这里最要紧的一件事 ——
    //   · 环半径不是匀速线性扩，而是 1.55·(1-e^(-1.5t))：越走越慢，最后停在整个
    //     可见半球上；匀速环到点被闸门切掉，看起来就是"啪"地断了。
    //   · 环还会随着时间变宽（3.4 → 2.4），于是它是化开的，不是消失的。
    //   · 亮度用 smoothstep 起手 + 长尾指数衰减（0.8）收到 1.9s 处正好为 0，
    //     脚本到那一刻才把这一槽清空 —— 两边对上，切换处就没有跳。
    // age < 0 表示这一槽空着：先 max 到 0，起手的 smoothstep 自然把它乘没。
    // 注意用 q*q 而不是 pow(q, 2.0)：GLSL 里 pow() 的底数为负是"未定义"，
    // q 在环内外都会取负，写得顺手就出一片 NaN（整片点凭空消失）。
    "  float a0 = max(uImpAge0, 0.0);",
    "  float a1 = max(uImpAge1, 0.0);",
    "  float a2 = max(uImpAge2, 0.0);",
    "  float ra0 = 1.55 * (1.0 - exp(-a0 * 1.5));",
    "  float ra1 = 1.55 * (1.0 - exp(-a1 * 1.5));",
    "  float ra2 = 1.55 * (1.0 - exp(-a2 * 1.5));",
    "  float qa = (distance(hn, uImpDir0) - ra0) * (4.4 - 1.9 * min(a0, 1.2));",
    "  float qb = (distance(hn, uImpDir1) - ra1) * (4.4 - 1.9 * min(a1, 1.2));",
    "  float qc = (distance(hn, uImpDir2) - ra2) * (4.4 - 1.9 * min(a2, 1.2));",
    "  float rip = 0.0;",
    "  rip += smoothstep(0.0, 0.06, a0) * (1.0 - smoothstep(0.6, 1.9, a0)) * exp(-qa * qa) * exp(-a0 * 0.8);",
    "  rip += smoothstep(0.0, 0.06, a1) * (1.0 - smoothstep(0.6, 1.9, a1)) * exp(-qb * qb) * exp(-a1 * 0.8);",
    "  rip += smoothstep(0.0, 0.06, a2) * (1.0 - smoothstep(0.6, 1.9, a2)) * exp(-qc * qc) * exp(-a2 * 0.8);",
    "  rip = min(rip, 1.5) * (1.0 - uForm);",       // 换了形状就别再荡冲击环了
    "  p += hn * body * uWave * (wv * 0.021 + rip * 0.070);",
    "  float d = uDist - p.z;",
    // 画面 roll 是**绕视轴的旋转**，所以要在物体屏幕平面 (x,y) 上转，转完再除
    // aspect 投到 NDC。反过来（先除 aspect、再在 NDC 里转）不是旋转：x 已经被
    // 压过 1/aspect，转完等价于给整颗星做一次剪切 —— 16:9 屏在像素空间里会长出
    // 一条 16% 的椭圆，21:9 时 20%，屏越宽星越扁。这就是"星球变鸡蛋"的真身。
    "  vec2 rp = vec2(p.x * uCosR - p.y * uSinR, p.x * uSinR + p.y * uCosR);",
    "  vec2 sc = vec2(rp.x * uProj / uAspect, rp.y * uProj);",
    "  gl_Position = vec4(sc.x + uCenter.x, sc.y + uCenter.y, d - uDist, d);",
    "  vec3 L = normalize(vec3(-0.45, 0.42, 0.79));",   // 左上偏前的一束光
    "  float lam = 0.58 + 0.52 * max(dot(normalize(hn), L), 0.0);",
    "  float tw = 0.5 + 0.5 * sin(uTime * aMeta.y + aPos.x * 9.0 + aPos.z * 5.0 + aPos.y * 3.0);",
    "  float k = mix(1.0, 0.34 + 1.20 * tw, aMeta.z) * lam;",
    "  k *= 1.0 + body * uWave * (max(wv, 0.0) * 0.75 + rip * 3.0);",    // 波峰亮、撞击那圈最亮
    "  k *= 1.0 - uForm * smoothstep(1.20, 1.30, length(aPos));",       // 环带：换形状就退场
    // 点名（彩蛋页的星野）：那一粒换成暖金、大一圈，其余只压一档（不是抹掉）。
    // 距离用 home 算、uSpot 也传那一粒在**当前形状**里的位置（uShape = 1 时
    // 着色器里的 home 就是它）—— 两边同一个坐标系，落定与途中都对得上。
    "  float dsp = distance(home, uSpot);",
    "  float hot = exp(-dsp * dsp * 110.0) * uSpotK;",   // 它自己 ≈ 1，越远越接近 0
    "  k *= mix(1.0, 0.52 + 1.50 * hot, uSpotK);",
    "  float pick = fract(sin(dot(aPos, vec3(12.9898, 78.233, 37.719)) + uSeed) * 43758.5453);",
    "  float flare = uBurst * step(0.95, pick);",
    "  k *= 1.0 + 1.6 * flare;",
    "  gl_PointSize = clamp(aMeta.x * uPxScale * uPxGain / max(d, 0.35) * k * (0.30 + 0.70 * gp) * (1.0 + 0.85 * hot), uMinPx * uPxGain, uMaxSize * uPxGain);",
    "  float isStn = step(0.5, aMeta.z);",              // 台站 / 卫星：比本体亮一大截的那一类
    "  vec3 base = mix(aCol, uStn * (0.72 + 0.62 * aCol.b), isStn);",
    "  vCol = base * uTint * k;",
    "  vCol = mix(vCol, uHot * (0.50 + 0.85 * k), hot);",   // 点名的那一粒：暖金（其余粒子一个都不动色）
    "  vFade = ((0.30 + 0.70 * clamp(p.z * 0.85 + 0.62, 0.0, 1.0)) * (0.72 + 0.55 * aMeta.z * tw) + flare * 0.6 + rip * 0.9 * uWave) * (0.10 + 0.90 * gp) * (1.0 - uForm * smoothstep(1.20, 1.30, length(aPos))) * mix(1.0, 0.62 + 0.95 * hot, uSpotK);",
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
    "uniform float uCosR; uniform float uSinR;",        // 同点云：画面 roll
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
    // 与点云同一套 roll：先绕视轴转 (x,y)，再除 aspect
    "  vec2 rp = vec2(p.x * uCosR - p.y * uSinR, p.x * uSinR + p.y * uCosR);",
    "  vec2 sc = vec2(rp.x * uProj / uAspect, rp.y * uProj);",
    "  gl_Position = vec4(sc.x + uCenter.x, sc.y + uCenter.y, d - uDist, d);",
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
    host.classList.add("no-3d");
    host.setAttribute("data-3d", why);
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
  ["uAngle", "uCosP", "uSinP", "uDist", "uProj", "uAspect", "uCosR", "uSinR",
    "uCenter", "uColor", "uAlpha", "uGather"
  ].forEach(function (k) { WU[k] = gl.getUniformLocation(wProg, k); });
  var wire = buildWire();
  var wBuf = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, wBuf);
  gl.bufferData(gl.ARRAY_BUFFER, wire.data, gl.STATIC_DRAW);
  gl.useProgram(prog);

  var cloud = buildCloud();
  /* 点 → 符号序号（-1 = 寻常粒子）。换形状时按它把符号点摆到各自的格子上，
     点击时按它把名字对回符号。 */
  var symOrd = new Int32Array(cloud.count);
  (function () {
    var i;
    for (i = 0; i < symOrd.length; i++) symOrd[i] = -1;
    for (i = 0; i < SYM.length; i++) if (SYM[i] < cloud.count) symOrd[SYM[i]] = i;
  })();
  var STRIDE = 10 * 4;
  var buf = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, buf);
  gl.bufferData(gl.ARRAY_BUFFER, cloud.data, gl.STATIC_DRAW);

  var satArr = new Float32Array(SAT_PTS * 10);
  var satBuf = gl.createBuffer();

  /* ── 撞击：小流星从外面斜插进球面，落点荡开一圈冲击波（上面顶点着色器那三段）。 ──
     三个槽轮转：等一会儿 → 飞进来（带尾迹）→ 命中（环在星面上扩开、1.2s 收干净）。
     方向与等待时间来自**另一条**随机流 rnd2 —— 星球几何那条流一点没动，
     所以同一颗星还是每次刷新都一模一样。 ── */
  var rnd2 = mulberry32(0x41505254);
  var IMP_SLOTS = 3, IMP_TAIL = 9, IMP_FLY = 1.40, IMP_AGE = 1.90;
  var IMP_WAIT_MIN = 1.5, IMP_WAIT_VAR = 2.4;
  var IMP_R0 = 3.30, IMP_R1 = 1.015, IMP_PTS = 0;
  var imps = [], iq;
  for (iq = 0; iq < IMP_SLOTS; iq++) {
    imps.push({ phase: "wait", t: 0, wait: 0.9 + iq * 1.9, dir: [0, 0, 1], age: -1 });
    IMP_PTS += 1 + IMP_TAIL;
  }
  var impArr = new Float32Array(IMP_PTS * 10);
  var impBuf = gl.createBuffer();
  var impCount = 0;

  var A = {
    pos: gl.getAttribLocation(prog, "aPos"),
    col: gl.getAttribLocation(prog, "aCol"),
    meta: gl.getAttribLocation(prog, "aMeta"),
    spin: gl.getAttribLocation(prog, "aSpin")
  };
  var U = {};
  ["uCosY", "uSinY", "uCosP", "uSinP", "uSpinT", "uDist", "uProj", "uAspect", "uCosR", "uSinR",
    "uPxScale",
    "uMaxSize", "uMinPx", "uPxGain", "uTime", "uCenter", "uTint", "uStn", "uAlpha", "uBurst", "uSeed", "uGather",
    "uWave", "uImpDir0", "uImpAge0", "uImpDir1", "uImpAge1", "uImpDir2", "uImpAge2",
    "uMorph", "uScatter", "uShape", "uForm", "uSpot", "uSpotK", "uHot"
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

  /* ═════════════ 3b. 换形状（只有彩蛋页用） ═════════════
     一屏一件事的那页里，点云不该只属于"地图那一屏"：翻过去时它们先摊开、
     再拢成**另一种形状**，屏与屏之间才是同一团东西在变。

     怎么做到不重写几何：
       · aPos（原有那份交错缓冲）依旧是"星球身份" —— 打光的法线、呼吸相位、
         哪一批点是环带，全都拿它算；所以形状换了，明暗体系没换。
       · 另加两只**纯位置**缓冲（aFrom / aTo）乒乓：静止时点站在 aTo 上；
         换形状就把新形状写进空着的那只、swap 一下、进度归零 —— 起点恰好是
         "上一刻那个形状"，所以画面不会跳。
       · 进度 uMorph 0 → 1，配上顶点着色器里那个 sin(π·进度) 包络，就成了
         "散开 → 聚成新形状"。
     环带 / 线框 / 卫星 / 流星是"球体仪表"，成不了别的形状：uForm 随进度升起，
     它们整体退场，聚回球时再一起回来。 */

  var pArr = [new Float32Array(cloud.count * 3), new Float32Array(cloud.count * 3)];
  /* "家"（球面）那份位置另存一只**只读**的：两只乒乓缓冲翻几次就被形状写花了，
     而"换回球"要的恰恰是开场那一份原样的坐标。以前 shapeFill("sphere") 读的是
     pArr[0] —— 它只在开场时等于家，第一次换形状就被写成了别的形状，于是从那
     一屏起"换回球"换回来的是上一个形状（实测：第 17 屏声明 sphere，球的像素
     指纹离 beacon 2.7、离家 8.4 —— 屏幕上一直是那根塔）。 */
  var homePos = new Float32Array(cloud.count * 3);
  (function () {
    var i, o;
    for (i = 0; i < cloud.count; i++) {
      o = i * 10;
      homePos[i * 3] = cloud.data[o];
      homePos[i * 3 + 1] = cloud.data[o + 1];
      homePos[i * 3 + 2] = cloud.data[o + 2];
    }
    pArr[0].set(homePos);
    pArr[1].set(homePos);                       // 两只都从"家"（球面）出发
  })();
  var pBuf = [gl.createBuffer(), gl.createBuffer()];
  (function () {
    for (var i = 0; i < 2; i++) {
      gl.bindBuffer(gl.ARRAY_BUFFER, pBuf[i]);
      gl.bufferData(gl.ARRAY_BUFFER, pArr[i], gl.DYNAMIC_DRAW);
    }
  })();
  var SA = {
    from: gl.getAttribLocation(prog, "aFrom"),
    to: gl.getAttribLocation(prog, "aTo")
  };
  var bi = 1;                                   // 现在这一只（= 家）
  var morphP = 1;                               // 进度：1 = 已经站定
  var shapeName = "sphere";
  var form = 0, formTarget = 0;                 // 0 = 球（仪表全在），1 = 别的形状
  var MORPH_S = PAGE.morphMs ? PAGE.morphMs / 1000 : 1.25;

  function bindShape() {
    gl.bindBuffer(gl.ARRAY_BUFFER, pBuf[1 - bi]);          // aFrom = 上一刻那只
    gl.vertexAttribPointer(SA.from, 3, gl.FLOAT, false, 0, 0);
    gl.enableVertexAttribArray(SA.from);
    gl.bindBuffer(gl.ARRAY_BUFFER, pBuf[bi]);              // aTo = 现在这只
    gl.vertexAttribPointer(SA.to, 3, gl.FLOAT, false, 0, 0);
    gl.enableVertexAttribArray(SA.to);
  }

  /* 形状采样：给每个点一个目标位置。坐标与星球同一套（半径 1 的球、+Z 朝观众），
     体量可以直接跟取景半径 view.r 比。随机数走**另一条**流 —— 星球几何那条流
     一点没动，同一颗星还是每次刷新都一模一样。
     ⚠ 逐点消耗随机数、不写 while 式的拒绝采样：同一个形状每次生成要一模一样，
       点数也必须正好是 cloud.count。 */
  var rnd3 = mulberry32(0x41505255);
  var glyphs = {};

  /* 文字点阵：离屏画一次字，把"亮着的像素"收成点集，再按最长边归一化到半宽 1。
     字重 800 的粗体 —— 点云要靠笔画宽才看得清。拿不到像素（没有 2D 上下文、
     字体量不出笔画）就返回 null，调用方退回球面：宁可少一个形状，不要散乱一片。 */
  function glyph(text) {
    if (Object.prototype.hasOwnProperty.call(glyphs, text)) return glyphs[text];
    var pts = null, i, x, y, d, g, max = 1;
    try {
      var c = document.createElement("canvas");
      c.width = 512; c.height = 256;
      g = c.getContext("2d");
      if (g) {
        g.fillStyle = "#fff";
        g.textAlign = "center";
        g.textBaseline = "middle";
        g.font = "800 190px system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif";
        g.fillText(text, 256, 132);
        d = g.getImageData(0, 0, 512, 256).data;
        pts = [];
        for (y = 0; y < 256; y += 2) {
          for (x = 0; x < 512; x += 2) {
            if (d[(y * 512 + x) * 4 + 3] > 120) pts.push(x - 256, 128 - y);
          }
        }
      }
    } catch (e) { pts = null; }
    if (!pts || pts.length < 40) { glyphs[text] = null; return null; }
    for (i = 0; i < pts.length; i += 2) {
      max = Math.max(max, Math.abs(pts[i]), Math.abs(pts[i + 1]));
    }
    for (i = 0; i < pts.length; i++) pts[i] /= max;
    glyphs[text] = pts;
    return pts;
  }

  /* 把形状写进 out（长度 = 点数 × 3）。 */
  function shapeFill(name, out) {
    var n = cloud.count, i, o, u, th, r, t, q, w, sp, gp, m, half, k2, s, rr;
    if (name === "sphere") {                   // 家：原样那层球面
      out.set(homePos);
      return;
    }
    if (name === "heart") {
      /* 心形参数曲线（16sin³t / 13cos t − 5cos2 t − 2cos3t − cos4t）。
         q 往 1 偏 → 边缘密、中间疏：轮廓才看得出是"一颗心"，不是一团雾。
         另给一点厚度（z）—— 它仍然是个有体积的东西，不是一张纸。 */
      for (i = 0; i < n; i++) {
        o = i * 3;
        t = rnd3() * Math.PI * 2;
        q = Math.pow(rnd3(), 0.34);
        u = Math.sin(t);
        out[o] = 16 * u * u * u * 0.0469 * q;
        out[o + 1] = (13 * Math.cos(t) - 5 * Math.cos(2 * t) - 2 * Math.cos(3 * t)
          - Math.cos(4 * t)) * 0.0449 * q + 0.114;   // x 半宽 0.75、y 半高 0.65（量过包围盒）
        out[o + 2] = (rnd3() - 0.5) * 0.16 * (1 - q * 0.6);
      }
      return;
    }
    if (name === "beacon") {
      /* 天线塔 + 一圈圈荡开的波纹。"电波从哪来" —— 它先是从**一个点**发出来的。
         这里原来是"地图针"（上半一颗球头、下半一支往下的锥）：屏幕上看就是
         一支麦克风（维护者第一眼就认成了麦克风，问"那个麦克风是什么意思"）。
         换个认不错的：一根细塔，塔顶往外荡三圈波。 */
      for (i = 0; i < n; i++) {
        o = i * 3;
        u = rnd3();
        if (u < 0.20) {                        // 塔身：一根细柱，塔底略宽
          t = rnd3();
          w = 0.014 + 0.032 * t;
          out[o] = (rnd3() - 0.5) * w;
          out[o + 1] = 0.28 - t * 1.13;
          out[o + 2] = (rnd3() - 0.5) * w;
        } else if (u < 0.32) {                 // 塔顶那颗灯
          u = rnd3() * 2 - 1;
          th = rnd3() * Math.PI * 2;
          r = 0.12 * Math.pow(rnd3(), 0.4);
          sp = Math.sqrt(1 - u * u);
          out[o] = sp * Math.cos(th) * r;
          out[o + 1] = 0.34 + u * r;
          out[o + 2] = sp * Math.sin(th) * r;
        } else {                               // 三圈波纹：以塔顶为心，一圈比一圈远
          t = rnd3();
          r = t < 0.33 ? 0.38 : (t < 0.66 ? 0.66 : 0.94);
          r += (rnd3() - 0.5) * 0.024;
          th = rnd3() * Math.PI * 2;
          out[o] = Math.cos(th) * r;
          out[o + 1] = 0.28 + Math.sin(th) * r;
          out[o + 2] = (rnd3() - 0.5) * 0.06;     // 一点厚度：它仍然是个有体积的东西
        }
      }
      return;
    }
    if (name === "scatter") {
      /* 结尾名单那几屏：名字落在**球面上**（维护者的原话：不要散开了，就在球的
         表面）。球还是那颗球 —— 本体、环带、经纬线都在原位，只有名单上的
         每一个人从球里升到球面外薄薄一层：
         · 纬度按序号等分（y 均匀 = 球面上等面积），经度按黄金角错开 ——
           等分却不排队，每一粒占着自己那一格，谁也压不住谁。序号就是第几格，
           页面按同一个顺序铺名字，于是「第 n 个名字」永远落在同一个位置上；
         · 半径 1.030 → 1.085：贴着球面一点点。压在球面上（r = 1）会与本体搅在
           一起分不出谁是谁，离远了又不叫「在球上」了。
         ⚠ 这一支用**自己**的随机流：翻回去再散一次还是同一片名单（位置不动），
           否则每回到这一屏，名单上的人就会换一个位置站。 */
      var rs = mulberry32(0x4150525a);
      out.set(homePos);                          // 其余一切照旧：球体与环带都还在原位
      for (i = 0; i < n; i++) {
        if (symOrd[i] < 0) continue;             // 只有符号点（名单上的名字）动
        o = i * 3;
        k2 = (symOrd[i] + 0.5) / Math.max(1, SYM.length);
        u = 1 - 2 * k2;                          // 纬度：球面上等面积
        th = symOrd[i] * 2.39996323;             // 经度：黄金角错开（rad）
        s = Math.sqrt(Math.max(0, 1 - u * u));
        rr = 1.030 + rs() * 0.055;
        out[o] = s * Math.cos(th) * rr;
        out[o + 1] = u * rr;
        out[o + 2] = s * Math.sin(th) * rr;
      }
      return;
    }
    /* 其余一律按**文字**处理：比如 `73`（火腿收尾那句话）。 */
    gp = glyph(name);
    if (!gp) { out.set(homePos); return; }
    m = gp.length / 2;
    half = 1.02;                                // 半宽：与星球半径同量级
    for (i = 0; i < n; i++) {
      o = i * 3;
      u = (rnd3() * m) | 0;
      if (u >= m) u = m - 1;
      out[o] = gp[u * 2] * half + (rnd3() - 0.5) * 0.012;
      out[o + 1] = gp[u * 2 + 1] * half + (rnd3() - 0.5) * 0.012;
      out[o + 2] = (rnd3() - 0.5) * 0.09;
    }
  }

  var _tmp = new Float32Array(cloud.count * 3);

  /* 换形状：新目标写进**空着**的那只缓冲，swap，进度归零。
     同一个形状再来一次就直接返回（翻屏时会被反复调用，别白甩一遍）。
     降级动效下不甩不聚，直接站定 —— 与入场、自转同一套规矩。 */
  function shapeTo(name) {
    if (!DECK || typeof name !== "string" || name === shapeName) return;
    if (!/^[A-Za-z0-9]{1,8}$/.test(name)) return;
    shapeName = name;
    if (name !== "scatter") focusAt(-1);       // 离开星野：把点名收回
    /* "仪表"（环带 / 线框 / 卫星 / 海浪）什么时候退场：只有那几种"不是球"的
       形状才要它们让位。scatter 现在是「球 + 球面上一层名字」——球还是球，
       环带与经纬线照旧在，所以它也按 0 算。 */
    formTarget = (name === "sphere" || name === "scatter") ? 0 : 1;
    shapeFill(name, _tmp);
    pArr[1 - bi].set(_tmp);
    gl.bindBuffer(gl.ARRAY_BUFFER, pBuf[1 - bi]);
    gl.bufferData(gl.ARRAY_BUFFER, pArr[1 - bi], gl.DYNAMIC_DRAW);
    bi = 1 - bi;
    if (reduce) {
      morphP = 1;
      form = formTarget;
      draw(animT);
      return;
    }
    morphP = 0;
    start();
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
      wire: 0.42, wireCol: [0.012, 0.412, 0.631],       // #0369A1（--cyan-deep）
      stn: [0.114, 0.435, 0.816],                       // #1D6FD0（--cyan 白天档）
      hot: [0.78, 0.50, 0.04]                           // 点名那一粒：暖金（白天档的琥珀那一档）
    },
    dark: {
      add: true, tint: [1.00, 1.08, 1.24], alpha: 0.88,
      wire: 0.55, wireCol: [0.302, 0.639, 1.000],       // #4DA3FF（--cyan）
      stn: [0.847, 0.867, 0.890],                       // #D8DDE3：铝白，加色下最亮
      hot: [1.00, 0.72, 0.14]                           // 点名那一粒：暖金（同 --grad-text 的 #ffb000 那一档）
    }
  };
  var dark = false;
  function syncMode() {
    var t = document.documentElement.getAttribute("data-theme");
    dark = (t === "dark");
  }
  syncMode();

  /* ── 3c. 天色：整片点云跟着翻屏换色（只有故事页用）──
     名字与页面上壁纸的色阶**同名** —— 页面那边一处声明，天光与粒子一起换。
     这里只给“倍数”，不给绝对颜色：深浅两套主题各自的原色照旧算，乘完再进
     着色器，于是夜间是霓虹、白天是墨蓝，两套主题里都不会有哪个色阶发飘。
     值都在 1 上下：>1 是把那个通道拉亮（也能把整片往暖里拉），<1 是压暗。 */
  var MOODS = {
    bloom: [1.00, 1.02, 1.08],     // 星球与那个数字：还是本来的冷蓝，略提一点
    wave: [0.92, 1.00, 1.16],      // 电波那一章：更冷、更蓝
    night: [0.74, 0.84, 1.00],     // 夜里那几屏：整体压暗一档
    spark: [0.98, 1.06, 1.14],     // 等你自己那一格：亮起来
    warm: [1.30, 1.02, 0.72],      // 名单那几屏：暖过来（站内的安全橙那一族）
    roster: [1.10, 1.02, 1.00]     // 三百多个呼号那屏：偏中性，别抢正文
  };
  var mTint = [1, 1, 1], mTintTo = [1, 1, 1], mName = "";
  function setMood(name) {
    if (!DECK || typeof name !== "string" || name === mName) return;
    if (!Object.prototype.hasOwnProperty.call(MOODS, name)) return;
    mName = name;
    mTintTo = MOODS[name];
  }

  /* ── 机位摆位 ──
     星球是只看不摸的：不能拖动，机位就是唯一的机位。两个常量各管一件事：
     · VIEW_ROLL：画面自己转一点点（**正数 = 极轴往左上倒**）——「从左上往下看」
       这层意思就靠它 + 左上那束光给出来；0 = 极轴笔直向上。
     · VIEW_ELEV：机位相对赤道平面的仰角。这个数比看上去敏感：它同时决定三圈
       环带被压成多扁的椭圆。环半径是 1.30 / 1.52 / 1.74（星球半径 = 1），
       仰角 15° 时最外圈就是 1.74 宽 × 0.45 高的一片椭圆，比星球本体还大一圈 ——
       整张图看上去就变成一个椭圆（用户的原话：星球怎么变成椭圆形了）。
       所以只给 0.10（约 6°）：环带是一道薄透镜，不再是那条横线，也不大口吃掉
       那颗球。真想要「从上往下看」，得同时把环带半径收进去 —— 那是改设计，
       先说一声再做。
     两者都只做整体摆位，不参与自转：yaw 只管星球自己转。roll 是绕视轴的旋转，
     写在**物体屏幕平面 (x,y)、除 aspect 之前**（见顶点着色器里那段注）——
     「先除 aspect、再在 NDC 里转」会把旋转变成剪切，屏越宽星越扁。 ── */
  var VIEW_ELEV = 0.10;                            // 0 = 正侧视；越大环带越扁、越像椭圆
  var VIEW_ROLL = 0.12;                            // 0 = 极轴向上，正数 = 往左上倒
  var yaw = 0.55, tYaw = yaw;                      // yaw 只在自转里往前走
  var pitch = VIEW_ELEV - TILT;                    // 着色器吃的是 TILT + pitch
  var ROLL_C = Math.cos(VIEW_ROLL), ROLL_S = Math.sin(VIEW_ROLL);
  var spin = reduce ? 0 : 0.075;                   // rad/s 自转：比上一版快一档，闲不住
  var running = false, paused = false, raf = 0, last = 0;

  /* 入场（聚成球）：gather 从 0 → 1，顶点着色器用 uGather 把点从「散开的一层」
     拉回球面；相机同时从更近的机位退到取景位（先是一颗大地球，再落定）。
     降级动效下直接到位，不动。 */
  var GATHER_MS = PAGE.gatherMs || 2400;          // 聚成球用掉的时间（页面可放慢）
  var gather = reduce ? 1 : 0, gatherT0 = 0, gateAt = 0;
  function easeOutCubic(t) { return 1 - Math.pow(1 - t, 3); }
  function nowMs() { return window.performance && performance.now ? performance.now() : Date.now(); }
  /* 入场的发令枪：等启动遮罩走开（body.loaded）再开演 —— 遮罩还在就开演的话，
     整段动画在遮罩后面自己演完，用户什么都没看到。但遮罩要是因为任何原因不
     消失（main.js 的外链资源卡住），最多等 3.6s 就直接开场：宁可早一步，
     也不要 hero 一直停在"还没聚拢"的状态。（main.js 自己 3.2s 有兜底。）

     发令枪的第二道门（只有彩蛋页会用上）：那页在星球上面还有一屏开场白，
     人还在读招呼的时候，星球已经在后台把"聚成球"整段演完了 —— 等他翻下来，
     只剩一颗早就在转的球，入场那一下白演了。所以这里再等一手：这一屏真的
     进过画面才开演。首页上 hero 本来就在最顶上，这道门第一帧就开着，
     行为与以前一个字不差。 */
  var heroSeen = reduce || !window.IntersectionObserver || DECK;
  if (!heroSeen) {
    new IntersectionObserver(function (entries, ob) {
      for (var i = 0; i < entries.length; i++) {
        if (entries[i].isIntersecting) { heroSeen = true; ob.disconnect(); }
      }
    }, { threshold: 0.15 }).observe(hero);
  }
  function gatherGate() {
    if (!gateAt) gateAt = nowMs() + 3600;
    if (!heroSeen) return false;
    if (document.body && document.body.classList.contains("loaded")) return true;
    return nowMs() >= gateAt;
  }

  /* ── 取景：view.r 是星球本体的屏幕半径，view.cx/cy 是它在 hero 里的相对位置。
        相机距离由 r 反推，所以换屏不会"忽大忽小"，环带始终切出右缘。
        VIEW_ZOOM / PX_GAIN 两个倍数只有故事页给（__planet3dPage）：那页的星球
        是主角，要大一圆；它的粒子（台站符号也在其中）要粗一档才看得清。
        三语首页不传这两个键 → 逐一等于上一版，没动。 ── */
  var view = { cx: 0.715, cy: 0.475, r: 1 };
  var VIEW_ZOOM = PAGE.zoom || 1;
  var PX_GAIN = PAGE.pxSize || 1;
  function frame(w, h) {
    var aspect = w / Math.max(1, h);
    if (aspect > 1.25) { view.cx = 0.715; view.cy = 0.475; view.r = 0.325 * h * VIEW_ZOOM; }   // 桌面：偏右
    else if (aspect > 0.95) { view.cx = 0.60; view.cy = 0.42; view.r = 0.27 * h * VIEW_ZOOM; } // 横屏平板
    else { view.cx = 0.50; view.cy = 0.30; view.r = 0.34 * w * VIEW_ZOOM; }                    // 窄屏：上三分之一居中
    return view;
  }
  function camDist(h) { return U_PROJ * h / (2 * Math.max(1, view.r)); }

  /* ── 3d. 点名：镜头飞到某一粒星上（只有彩蛋页用）──
     结尾名单那几屏里，点一粒星、或点名单上的一个名字，都是同一件事：
     镜头飞过去停在它上面，其余压暗，左下角报出这是谁、编号多少。

     镜头那一半分两件事：
       · 中心偏移 —— **解析**算出来，不是“朝画面里它现在的位置一点点挪”：
         后者是个反馈环，星球还在转，追不稳。投影里中心是加在 sc 上的偏移，
         取它的相反数，那一粒就正好落在画面正中（与机位远近无关）。
       · 机位收近到 0.62 倍 —— 星野从“铺满画面”变成“一颗星占住画面”。
     着色器那一半只认两件事：那一粒在哪（模型空间，与 home 同一套）、点名到几分。
     位置读**目标形状缓冲**（pArr[bi]），换形状时也就是它现在待的地方。 */
  var focusOrd = -1;                     // 名单里第几个人的那一粒（-1 = 没点谁）
  var focusK = 0;                        // 点名强度 0 → 1（镜头、收近、压暗一起吃它）
  var ctrX = 0, ctrY = 0;                // 中心偏移（投影中心那一套，见 draw 里的 uCenter）
  var gDist = 1;                         // 这一帧的机位距离（draw / 投影 / 点击 都读它）
  var _sp = [0, 0, 0];
  function pointOf(idx) {
    var i = SYM[idx] * 3;
    _sp[0] = pArr[bi][i]; _sp[1] = pArr[bi][i + 1]; _sp[2] = pArr[bi][i + 2];
    return _sp;
  }
  function spotPoint() {
    if (focusOrd < 0 || focusOrd >= SYM.length) { _sp[0] = 0; _sp[1] = 0; _sp[2] = 0; return _sp; }
    return pointOf(focusOrd);
  }
  /* 模型空间的一点 → 投影里的中间量（照抄顶点着色器那几行：自转 → 俯仰 →
     绕视轴 roll → 除 aspect。x / y 是加进 gl_Position 之前的 sc，d 是深度）。 */
  var _pj = { x: 0, y: 0, d: 1 };
  function projPoint(p) {
    var cy = Math.cos(yaw), sy = Math.sin(yaw);
    var x = p[0] * cy + p[2] * sy, y = p[1], z = p[2] * cy - p[0] * sy;
    var cp2 = Math.cos(TILT + pitch + pitchOff), sp2 = Math.sin(TILT + pitch + pitchOff);
    var y2 = y * cp2 - z * sp2, z2 = y * sp2 + z * cp2;
    var aspect = canvas.width / Math.max(1, canvas.height);
    _pj.x = (x * ROLL_C - y2 * ROLL_S) * U_PROJ / aspect;
    _pj.y = (x * ROLL_S + y2 * ROLL_C) * U_PROJ;
    _pj.d = Math.max(0.35, gDist - z2);
    return _pj;
  }
  function chaseSpot(dt) {
    var fk = reduce ? 1 : Math.min(1, dt * 3.4);
    focusK += ((focusOrd >= 0 ? 1 : 0) - focusK) * fk;
    var tx = 0, ty = 0, pj;
    if (focusOrd >= 0 && !lookFree) {
      pj = projPoint(pointOf(focusOrd));
      tx = -(pj.x + view.cx * 2 - 1);     // 取反正好抵消：见 draw 里 uCenter 那一行
      ty = -(pj.y + 1 - view.cy * 2);
    }
    /* 人自己拖过之后（lookFree）：这一层**冻在原地** —— 拖就只有转动，画面里别的
       东西一个都不动。要是继续往 0 放，他一抚画面就自己滑一段；继续往那一粒上
       追，又会和手指抢。收回时 lookFree 落下，这一层再自己滑回标准取景。 */
    var ck = lookFree ? 0 : fk;
    ctrX += (tx - ctrX) * ck;
    ctrY += (ty - ctrY) * ck;
  }
  /* 球要转到哪个角度，那一粒才正对镜头：着色器里 x' = r·cos(θ−yaw)、
     z' = r·sin(θ−yaw)（θ = 那一粒在球面上的经度，z' > 0 的那一半朝观众）。
     取 x' = 0、z' > 0 —— yaw = θ − π/2。半径多少都一样，所以名字层不论在
     球面内外都适用。 */
  function spotYaw() {
    var p = pointOf(focusOrd);
    return Math.atan2(p[2], p[0]) - Math.PI / 2;
  }

  /* ── 3d-b. 自己转视角（只有彩蛋页在「点着谁」的时候会喂它）──
     上面那一套是**自动**的：点一粒星，镜头把它转到正对镜头、再摆到画面正中。
     人一旦自己按住拖动，自动的那一半就得让位 —— 两边抢同一个角度，画面会一抖
     一抖地往回跳（用户的原话：跳来跳去）。
     拖的只有两个角：
       · 左右 = 绕极轴的 yaw，直接改 tYaw —— 与自转、追星用的是同一个数：松手就
         停在转到的位置（不弹回），收回之后自转从这个角度接着走，也不跳。
       · 上下 = 叠在 pitch 上的一个小偏移，夹在 ±PITCH_MAX 里。球还是那颗球，
         只是机位抬高 / 压低一点，不会把环带转成一条别的曲线。
     两个角都走「每帧朝目标挪一档」的阻尼跟随（见 loop），拖得再快也不跳。
     这里只管「能转」；什么时候允许转由页面说了算（见 hero.html 的 0b 段）。 */
  var lookFree = false;                  // 人自己动过视角：自动追星让位
  var pitchOff = 0, pitchOffTo = 0;      // 上下偏移（弧度）与它的目标
  var PITCH_MAX = 0.40;                  // ±23°：够看出立体，又不会把环带转散
  var YAW_PER_PX = 0.0034, PITCH_PER_PX = 0.0022;
  function look(dx, dy) {
    lookFree = true;
    tYaw -= dx * YAW_PER_PX;             // 往右拖：球面跟着往右走（yaw 增大是往左）
    pitchOffTo = Math.max(-PITCH_MAX, Math.min(PITCH_MAX, pitchOffTo + dy * PITCH_PER_PX));
    start();
  }
  /* 那一粒现在在屏幕的哪儿（CSS 像素，已经把画布的偏移算进去）—— 每帧报给页面，
     页面把“他是谁 / 编号多少”那一行贴在那里：镜头飞的整段里它跟着那一粒走。
     只有彩蛋页会接这个回调（__planet3dPage.onSpot）；三语首页不接 → 什么都不发生。 */
  function reportSpot(f) {
    if (typeof PAGE.onSpot !== "function") return;
    if (!DECK || focusOrd < 0 || focusOrd >= SYM.length) { PAGE.onSpot(null); return; }
    var pj = projPoint(pointOf(focusOrd));
    var bx = f.cx * 2 - 1 + ctrX * focusK, by = 1 - f.cy * 2 + ctrY * focusK;
    var rct = canvas.getBoundingClientRect();
    if (!rct.width) return;
    var nx = (pj.x + bx) / pj.d, ny = (pj.y + by) / pj.d;
    /* k 不只是「点名到几分」：那一粒被自己转出画面之后，这一行字也跟着淡掉 ——
       别把它按在视口边上假装那一粒还在（页面拿 k 写 opacity）。 */
    var edge = Math.max(Math.abs(nx), Math.abs(ny));
    PAGE.onSpot({
      x: rct.left + (0.5 + 0.5 * nx) * rct.width,
      y: rct.top + (0.5 - 0.5 * ny) * rct.height,
      k: focusK * Math.max(0, Math.min(1, (1.05 - edge) / 0.25))
    });
  }
  function focusAt(ord) {
    var n2 = (ord === null || ord === undefined || ord < 0) ? -1 : ord | 0;
    if (n2 >= SYM.length) n2 = -1;
    focusOrd = n2;
    /* 换一个目标（或收回）＝把「自动」那一半拿回来：球重新转到那一粒正对镜头，
       上下也摆平 —— 人上一次拖出来的角度不算到下一个人头上。 */
    lookFree = false;
    pitchOffTo = 0;
    if (n2 >= 0) start();                 // 镜头要动起来（降级动效下它直接到位）
    return focusOrd;
  }
  /* 点到星野里的哪一粒了？传点击事件的 CSS 坐标，返回那一粒的序号（没点到 -1）。
     坐标先按画布自己的矩形折回画布内 —— 天空层有时被 CSS 缩放过
     （.deck[data-sky="soft"]），只按视口坐标算会整体偏掉。命中按**屏幕上的距离**
     （近的赢），只认星野那一种形状：别的形状上这些序号没有意义。
     ⚠ 命中半径故意紧跟粒子的自己大小（桌面 13px / 触屏 20px）：星野里“点一下”
       是翻屏的手势，圈开大了就会把它整片吃掉（整片星野都变成“点中某个人”）。 */
  var COARSE = !!(window.matchMedia && window.matchMedia("(pointer: coarse)").matches);
  function symbolAt(cssX, cssY) {
    if (!DECK || shapeName !== "scatter" || !SYM.length) return -1;
    var r = canvas.getBoundingClientRect();
    if (!r.width || !r.height) return -1;
    var ox = cssX - r.left, oy = cssY - r.top;
    var bx = view.cx * 2 - 1 + ctrX * focusK, by = 1 - view.cy * 2 + ctrY * focusK;
    var lim = COARSE ? 20 : 13;
    var best = lim * lim, pick = -1, i, pj, nx, ny, ex, ey, dd;
    for (i = 0; i < SYM.length; i++) {
      pj = projPoint(pointOf(i));
      nx = (pj.x + bx) / pj.d;
      ny = (pj.y + by) / pj.d;
      if (nx < -1.05 || nx > 1.05 || ny < -1.05 || ny > 1.05) continue;
      ex = (0.5 + 0.5 * nx) * r.width - ox;
      ey = (0.5 - 0.5 * ny) * r.height - oy;
      dd = ex * ex + ey * ey;
      if (dd < best) { best = dd; pick = i; }
    }
    return pick;
  }

  /* ── 动画时钟 animT ──
     所有"看时间"的效果（浪、撞击、自转、卫星、读数闪点）都吃这一刻钟，它只在
     真正画帧的时候往前走。用绝对的 performance.now() 的话，页面滚出视口暂停
     再滚回来、或者切走标签页回来，时间一下子跳过去 —— 浪会闪一下位置、卫星会
     瞬移。animT 没这个问题：回来时从离开的那一秒接着演。 ── */
  var animT = 0;

  /* 每来一条报文就挑一批点窜一下：读数一跳，星面跟着亮一片（uBurst 从 1 衰减） */
  var burstAtT = -1e9, burstSeed = 0, BURST_S = 0.9;
  function flash(seed) { burstAtT = animT; burstSeed = (seed || 0) * 0.618 % 1; if (!running) start(); }

  function draw(now) {
    var w = canvas.width, h = canvas.height;
    if (!w || !h) return;
    var f = frame(w, h);
    var m = MODES[dark ? "dark" : "light"];
    var zoom = reduce ? 1 : 1 + 0.20 * (1 - gather);   // 入场：从更近的机位缓缓退回
    /* 点名：镜头一边往那一粒上靠（见 chaseSpot），一边把机位收近到 0.62 倍；
       gDist 也是投影 / 点击命中读的同一个数，所以放在模块级上。 */
    gDist = camDist(h) / zoom / (1 + 0.62 * focusK);
    var pv = TILT + pitch + pitchOff;            // 俯仰：自己拖出来的那点偏移也算进来
    var cp = Math.cos(pv), sp = Math.sin(pv);
    var age = reduce ? 1 : (animT - burstAtT) / BURST_S;
    var burst = (age < 0 || age > 1) ? 0 : Math.pow(1 - age, 2);
    gl.viewport(0, 0, w, h);
    gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
    gl.useProgram(prog);
    gl.blendFunc(gl.SRC_ALPHA, m.add ? gl.ONE : gl.ONE_MINUS_SRC_ALPHA);
    gl.uniform3f(U.uTint, m.tint[0] * mTint[0], m.tint[1] * mTint[1], m.tint[2] * mTint[2]);
    gl.uniform3f(U.uStn, m.stn[0], m.stn[1], m.stn[2]);
    var sp3 = spotPoint();                        // 点名：被点到的那一粒（当前形状里的位置）
    gl.uniform3f(U.uSpot, sp3[0], sp3[1], sp3[2]);
    gl.uniform1f(U.uSpotK, focusK);
    gl.uniform3f(U.uHot, m.hot[0], m.hot[1], m.hot[2]);
    reportSpot(f);                                // 那一行字贴到那一粒旁边（第 3d 节）
    gl.uniform1f(U.uAlpha, m.alpha);
    gl.uniform2f(U.uCenter, f.cx * 2 - 1 + ctrX * focusK, 1 - f.cy * 2 + ctrY * focusK);
    gl.uniform1f(U.uCosY, Math.cos(yaw));
    gl.uniform1f(U.uSinY, Math.sin(yaw));
    gl.uniform1f(U.uCosP, cp);
    gl.uniform1f(U.uSinP, sp);
    gl.uniform1f(U.uCosR, ROLL_C);
    gl.uniform1f(U.uSinR, ROLL_S);
    gl.uniform1f(U.uSpinT, reduce ? 0 : now);
    gl.uniform1f(U.uDist, gDist);
    gl.uniform1f(U.uProj, U_PROJ);
    gl.uniform1f(U.uAspect, w / h);
    gl.uniform1f(U.uPxScale, (h / 2) * U_PROJ);
    gl.uniform1f(U.uMaxSize, Math.max(14, 15 * DPR));
    gl.uniform1f(U.uMinPx, Math.max(1, 2.0 * DPR));
    gl.uniform1f(U.uPxGain, PX_GAIN);
    gl.uniform1f(U.uTime, reduce ? 0 : now);
    gl.uniform1f(U.uBurst, burst);
    gl.uniform1f(U.uSeed, burstSeed);
    gl.uniform1f(U.uGather, gather);
    // 换形状：进度 / 中途甩出的幅度 / 形状是否参与（首页恒为 0 → 与上一版一致）
    gl.uniform1f(U.uMorph, reduce ? 1 : easeOutCubic(morphP));
    gl.uniform1f(U.uScatter, reduce ? 0 : (PAGE.scatter == null ? 0.95 : PAGE.scatter));
    gl.uniform1f(U.uShape, DECK ? 1 : 0);
    gl.uniform1f(U.uForm, reduce ? formTarget : form);
    gl.uniform1f(U.uWave, reduce ? 0 : (1 - form));   // 星面海浪（降级动效 / 已换形状都关掉）
    // 撞击落点：物体空间的单位向量，按当前的 yaw / pitch 转成与顶点同一套坐标系
    // （顶点着色器里的 hn 就是转过的）—— 两边不是同一套的话，球自转时冲击环
    // 会从落点上滑走。
    var cyv = Math.cos(yaw), syv = Math.sin(yaw);
    for (var ic = 0; ic < IMP_SLOTS; ic++) {
      var im = imps[ic];
      var dx = im.dir[0] * cyv + im.dir[2] * syv;
      var dz = im.dir[2] * cyv - im.dir[0] * syv;
      gl.uniform3f(U["uImpDir" + ic], dx, im.dir[1] * cp - dz * sp, im.dir[1] * sp + dz * cp);
      gl.uniform1f(U["uImpAge" + ic], reduce ? -1 : im.age);
    }

    // 线框球先画：点云自己写深度，正面那一半自然把线压住
    gl.useProgram(wProg);
    gl.uniform1f(WU.uAngle, yaw);
    gl.uniform1f(WU.uCosP, cp);
    gl.uniform1f(WU.uSinP, sp);
    gl.uniform1f(WU.uCosR, ROLL_C);
    gl.uniform1f(WU.uSinR, ROLL_S);
    gl.uniform1f(WU.uDist, gDist);
    gl.uniform1f(WU.uProj, U_PROJ);
    gl.uniform1f(WU.uAspect, w / h);
    gl.uniform2f(WU.uCenter, f.cx * 2 - 1 + ctrX * focusK, 1 - f.cy * 2 + ctrY * focusK);
    gl.uniform3f(WU.uColor, m.wireCol[0], m.wireCol[1], m.wireCol[2]);
    var wireIn = reduce ? 1 : Math.max(0, Math.min(1, (gather - 0.40) / 0.60));
    gl.uniform1f(WU.uGather, wireIn);
    gl.uniform1f(WU.uAlpha, m.wire * (1 - (reduce ? formTarget : form)));   // 换形状 → 线框退场
    gl.bindBuffer(gl.ARRAY_BUFFER, wBuf);
    gl.vertexAttribPointer(WA.pos, 3, gl.FLOAT, false, 0, 0);
    gl.enableVertexAttribArray(WA.pos);
    gl.drawArrays(gl.LINES, 0, wire.count);
    gl.disableVertexAttribArray(WA.pos);          // 免得下一趟点到线框的缓冲上去

    gl.useProgram(prog);
    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    bindPointers();
    bindShape();                                   // aFrom / aTo：换形状那两只位置缓冲
    gl.drawArrays(gl.POINTS, 0, cloud.count);

    // 卫星与流星的位置是每帧自己算的，不吃形状那一套：uShape 归零让着色器直接
    // 退回 aPos（否则它们会去读形状缓冲，落到画面正中变成一坨）
    gl.uniform1f(U.uShape, 0);

    // 卫星：一组小亮点带着尾迹与淡淡轨迹，各在自己的倾斜轨道上快速划过
    if (!reduce) buildSats(now);
    gl.bindBuffer(gl.ARRAY_BUFFER, satBuf);
    gl.bufferData(gl.ARRAY_BUFFER, satArr, gl.DYNAMIC_DRAW);
    bindPointers();
    gl.drawArrays(gl.POINTS, 0, SAT_PTS);

    // 撞进来的小流星（命中那一刻它已经飞完了，剩下的交给星面上的冲击环）
    impCount = reduce ? 0 : buildImpacts();
    if (impCount) {
      gl.bindBuffer(gl.ARRAY_BUFFER, impBuf);
      gl.bufferData(gl.ARRAY_BUFFER, impArr, gl.DYNAMIC_DRAW);
      bindPointers();
      gl.drawArrays(gl.POINTS, 0, impCount);
    }
  }

  /* 落点方向：球面上随机取一个，再往正面（+Z）偏一点 —— 撞在背面观众是看不到的。
     单位向量，且是**物体空间**的：着色器会按当前的 yaw / pitch 一起转过去。 */
  function pickImpactDir() {
    var u = rnd2() * 2 - 1, th = rnd2() * Math.PI * 2, s2 = Math.sqrt(1 - u * u);
    var x = s2 * Math.cos(th), y = u * 0.7 + 0.26, z = s2 * Math.sin(th);
    var n = Math.sqrt(x * x + y * y + z * z) || 1;
    x = x / n; y = y / n; z = z / n;
    z = z * 0.72 + 0.46;
    z = Math.max(-1, Math.min(1, z));
    n = Math.sqrt(x * x + y * y + z * z) || 1;
    return [x / n, y / n, z / n];
  }

  /* 槽的状态机：wait → fly → hit → wait。age < 0 就是"这一槽空着"。 */
  function stepImpacts(dt) {
    for (var i = 0; i < imps.length; i++) {
      var o = imps[i];
      o.t += dt;
      if (o.phase === "wait") {
        if (o.t >= o.wait) {
          if (form > 0.5) o.t = 0;                      // 换形状途中别再放流星进来
          else { o.phase = "fly"; o.t = 0; o.dir = pickImpactDir(); }
        }
      } else if (o.phase === "fly") {
        if (o.t >= IMP_FLY) { o.phase = "hit"; o.t = 0; }
      } else if (o.t >= IMP_AGE) {
        o.phase = "wait"; o.t = 0;
        o.wait = IMP_WAIT_MIN + rnd2() * IMP_WAIT_VAR;
      }
      o.age = o.phase === "hit" ? o.t : -1;
    }
  }

  /* 流星本体 + 尾迹：头在最里（最接近球面），尾点拖着往外排、越远越暗越小。
     跟卫星一样每帧现算，aSpin 给 0（位置不受球体自转影响）。
     衔接：进场淡入、**到达前淡掉**（最后那一下交给星面上的冲击环），
     尾迹随俯冲被拉长（0.26 → 0.88）—— 于是"命中"是一个交接，不是一次切换。 */
  function smooth01(a, b, x) {
    var t = Math.max(0, Math.min(1, (x - a) / (b - a)));
    return t * t * (3 - 2 * t);
  }
  function buildImpacts() {
    var o = 0, k, j, s2, d, f, rr, t2, rj, g, sz, env, span;
    for (k = 0; k < imps.length; k++) {
      s2 = imps[k];
      if (s2.phase !== "fly") continue;
      f = Math.min(1, s2.t / IMP_FLY);
      f = f * f * (3 - 2 * f);
      env = smooth01(0.0, 0.14, f) * (1.0 - smooth01(0.70, 1.0, f));
      span = 0.26 + 0.62 * f;
      rr = IMP_R0 + (IMP_R1 - IMP_R0) * f;
      d = s2.dir;
      for (j = 0; j <= IMP_TAIL; j++) {
        t2 = j / (IMP_TAIL + 1);
        rj = rr + t2 * span;
        g = (j === 0 ? 1 : Math.max(0, 1 - t2 * 1.3) * Math.max(0, 1 - t2 * 1.3)) * env;
        sz = 0.0165 * env * (j === 0 ? 1 : 0.30 + 0.70 * g);
        impArr[o++] = d[0] * rj; impArr[o++] = d[1] * rj; impArr[o++] = d[2] * rj;
        impArr[o++] = g; impArr[o++] = g; impArr[o++] = g;
        impArr[o++] = Math.max(0.0001, sz);
        impArr[o++] = 0.4 + 0.2 * k;         // 呼吸频率
        impArr[o++] = 0.55;                  // 幅度 > 0.5 → 着色器当成"台站 / 卫星"那一类
        impArr[o++] = 0;
      }
    }
    return o / 10;
  }

  /* 把每颗卫星（头 + 尾迹 + 轨迹）的位置算进 satArr：head 在最前，后面一串点按
     角距往回排、越往后越暗越小。角距随速度走（快的拖得更长），尾点排在**运动
     方向的反面**；轨迹接着尾迹往后再铺一段弧，亮度压到两成多、越远越虚 ——
     划过之后天上还剩一道淡淡的痕。位置每帧重算，不需要 aSpin（着色器里给 0）。 */
  function buildSats(t) {
    var o = 0, k, j, s2, ct, st, base, dir, a, x, y, z, f, g, sz, step, tf, off;
    var cut = 1 - form;                    // 换形状时卫星跟着退场（它们只在球上有意义）
    for (k = 0; k < SATS.length; k++) {
      s2 = SATS[k];
      base = s2.ph + s2.w * t;
      dir = s2.w >= 0 ? 1 : -1;
      ct = Math.cos(s2.tilt); st = Math.sin(s2.tilt);
      step = SAT_STEP * (0.62 + Math.abs(s2.w) * 0.85);   // 速度越快，尾迹点距得越开
      for (j = 0; j <= s2.tail; j++) {
        a = base - dir * j * step;
        x = Math.cos(a) * s2.r; z = Math.sin(a) * s2.r;
        y = -z * st; z = z * ct;                 // 轨道面绕 X 轴倾斜 tilt
        f = j === 0 ? 1 : 1 - j / (s2.tail + 1);
        g = (j === 0 ? 1 : 0.16 + 0.84 * f * f) * cut;   // 头最亮，尾点快速衰减
        sz = s2.sz * (j === 0 ? 1 : 0.34 + 0.66 * f);
        satArr[o++] = x; satArr[o++] = y; satArr[o++] = z;
        satArr[o++] = g; satArr[o++] = g; satArr[o++] = g;   // 亮度：色相由 uStn 按主题给
        satArr[o++] = sz;
        satArr[o++] = 0.35 + 0.20 * k;           // 呼吸频率：卫星也轻轻喘，很慢
        satArr[o++] = 0.55;                      // 幅度 > 0.5 → 着色器当成"台站 / 卫星"那一类
        satArr[o++] = 0;                         // aSpin = 0：位置自己算
      }
      for (j = 0; j < s2.wake; j++) {                     // 正好 s2.wake 个点（与 SAT_PTS 对齐）
        tf = j / (s2.wake + 1);
        off = (s2.tail + 1) * step + tf * s2.arc;        // 从尾迹末端再往后的角距
        a = base - dir * off;
        x = Math.cos(a) * s2.r; z = Math.sin(a) * s2.r;
        y = -z * st; z = z * ct;
        g = Math.pow(1 - tf, 2.2) * 0.26 * cut;          // 极淡，越远越虚
        sz = s2.sz * (0.20 + 0.46 * (1 - tf));
        satArr[o++] = x; satArr[o++] = y; satArr[o++] = z;
        satArr[o++] = g; satArr[o++] = g; satArr[o++] = g;
        satArr[o++] = sz;
        satArr[o++] = 0.30 + 0.16 * k;
        satArr[o++] = 0.55;
        satArr[o++] = 0;
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
    // 换形状：进度往前走；仪表（环带 / 线框 / 卫星 / 流星）按 form 退场或回来
    if (morphP < 1) morphP = Math.min(1, morphP + dt / MORPH_S);
    form += (formTarget - form) * Math.min(1, dt * 2.6);
    // 天色：色温比形状慢半拍换（指数趋近）—— 翻屏时粒子是"游"过去的，不是跳色
    var mk = Math.min(1, dt * 1.6);
    for (var mi = 0; mi < 3; mi++) mTint[mi] += (mTintTo[mi] - mTint[mi]) * mk;
    var k = Math.min(1, dt * 9);                   // 阻尼跟随（参考实现是每帧 0.1）
    /* 点名：自转先停住（点着谁，谁就该停在原地），球再转到那一粒正对镜头 ——
       这样背面的人也看得到，而且它最后就落在画面正中。收回时自转自己转回来。
       人自己拖过之后（lookFree）：角度归他，这一半不再出手。 */
    var spinNow = spin * (1 - focusK);
    if (spinNow) tYaw += spinNow * dt;
    if (focusOrd >= 0 && !lookFree) {
      var da = Math.atan2(Math.sin(spotYaw() - tYaw), Math.cos(spotYaw() - tYaw));
      tYaw += da * (reduce ? 1 : Math.min(1, dt * 2.2));   // 走近的那一边（不绕远路）
    }
    yaw += (tYaw - yaw) * k;
    pitchOff += (pitchOffTo - pitchOff) * Math.min(1, dt * 8);   // 上下偏移：与 yaw 同一条阻尼
    animT += dt;                                   // 动画时钟：只在这里走
    chaseSpot(dt);                                 // 点名：镜头往那一粒上追（第 3d 节）
    stepImpacts(dt);                               // 撞击槽：wait → fly → hit
    draw(animT);
    // 降级动效（prefers-reduced-motion）：自转本来就是 0，摆到位就停掉循环
    if (reduce && Math.abs(tYaw - yaw) < 0.002 && Math.abs(pitchOffTo - pitchOff) < 0.002) {
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
    /* 量**布局尺寸**（clientWidth/Height），不是 getBoundingClientRect：彩蛋页会把这
       块画布用 CSS 缩放（有正文的屏上它退到右上角），而 rect 量到的是缩放后的尺寸。
       拿缩放后的尺寸当分辨率，则缩放一变（CSS transform 不触发 resize 事件）
       画面就会整体放大、发糊。布局尺寸不受 transform 影响：画布始终按满屏
       分辨率渲染，缩放交给 CSS。 */
    var w = Math.round(canvas.clientWidth * dpr), h = Math.round(canvas.clientHeight * dpr);
    if (w < 2 || h < 2) return;
    if (w === canvas.width && h === canvas.height) return;
    canvas.width = w;
    canvas.height = h;
    draw(animT);
    applyScroll();
    start();
  }

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
    }, { threshold: 0 }).observe(host);
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

  /* ── 滚动：往下拉时星球退得比页面慢半步（视差）并缓缓淡出，数字轻缩着上浮
        隐去、折线之下那一屏淡淡追上来；滚回顶部一切复原。变量写在 .hero 上，
        位移 / 缩放 / 透明度全交给 hero-3d.css。
        这里的"丝滑"靠缓动：滚动量不直接写进样式，而是每帧朝目标挪一档
        （约 200ms 到位）—— 滚轮一格一格地跳、触摸屏的甩动，都被抹成一段滑行，
        而且 JS 里只缓一道、CSS 那边不写 transition，免得两套缓动叠在一起发涩。
        降级动效（prefers-reduced-motion）下不接这个监听，CSS 保持原样。 ── */
  var scrollP = 0, scrollTarget = 0, scrollRaf = 0;
  var SCROLL_EASE = PAGE.scrollEase || 0.17;        // 每帧向目标靠近的比例（页面可调软）
  function writeScroll(e) {
    hero.style.setProperty("--hero-3d-y", (e * 30).toFixed(2) + "px");
    hero.style.setProperty("--hero-3d-scale", (1 + e * 0.06).toFixed(4));
    hero.style.setProperty("--hero-3d-fade", (1 - e * 0.62).toFixed(3));
    hero.style.setProperty("--hero-3d-copy", (-e * 46).toFixed(2) + "px");
    hero.style.setProperty("--hero-3d-copy-scale", (1 - e * 0.06).toFixed(4));
    hero.style.setProperty("--hero-3d-copy-fade", (1 - e * 0.94).toFixed(3));
    hero.style.setProperty("--hero-3d-next", (-e * 20).toFixed(2) + "px");
  }
  function readScroll() {
    var h = window.innerHeight || hero.offsetHeight || 1;   // 以"一屏"为准
    var y = window.pageYOffset || document.documentElement.scrollTop || 0;
    /* 进度按"这一屏离视口顶多远"算，不是整页滚了多少：彩蛋页在它上面还有一屏
       开场白，拿整页滚动量当进度的话，人还没翻到星球，它就已经按"滚过一屏"
       淡掉一半了。首页上两者算出来一模一样（hero 就在最顶上），行为没变。 */
    var passed = y - (hero.getBoundingClientRect().top + y);
    scrollTarget = Math.max(0, Math.min(1, passed / (h * 0.8)));
    return scrollTarget;
  }
  function easeScroll(p) { return p * p * (3 - 2 * p); }    // 缓入缓出：起手不出戏、收尾不突兀
  function applyScroll() {                          // 立刻对齐（首屏 / 尺寸变化后用）
    scrollRaf = 0;
    scrollP = readScroll();
    writeScroll(easeScroll(scrollP));
  }
  function glide() {                                // 每帧朝目标挪一档
    scrollRaf = 0;
    var d = scrollTarget - scrollP;
    if (Math.abs(d) < 0.0006) scrollP = scrollTarget;
    else scrollP += d * SCROLL_EASE;
    writeScroll(easeScroll(scrollP));
    if (scrollP !== scrollTarget) scrollRaf = requestAnimationFrame(glide);
  }
  function onScroll() {
    if (reduce) return;
    readScroll();
    if (!scrollRaf) scrollRaf = requestAnimationFrame(glide);
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
        draw(animT);
        start();
      }
    }).observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
  }

  /* ── 调试/自检钩子：给脚本一个同步的"渲染 + 回读"入口，静态检查与
        CI 截图都靠它读像素，不需要目测（draw + readPixels 必须同一任务内）。 ── */
  window.__planet3d = {
    pixelStats: function () {
      draw(animT);
      var w = canvas.width, h = canvas.height;
      var px = new Uint8Array(w * h * 4);
      gl.readPixels(0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, px);
      var lit = 0, sum = 0, q = [0, 0, 0, 0], n = w * h, i;
      // 4×4 网格均值：覆盖率这类宏观统计是**旋转不变**的，抓不到「转了个角度但画面没变」，
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
        pitch: +(pitch + pitchOff).toFixed(3),
        reduce: reduce,
        gate: gatherT0 > 0,
        gather: +gather.toFixed(3),
        scroll: +scrollP.toFixed(3),
        animT: +animT.toFixed(2),
        shape: shapeName,
        mood: mName || "deep",
        sym: SYM.length,                           // 星野里可点的符号有几粒
        spot: focusOrd,                            // 现在点到第几个名字（-1 = 没点）
        focus: +focusK.toFixed(3),
        look: lookFree,                            // 视角是自己拖的（自动追星已让位）
        morph: +morphP.toFixed(3),
        form: +form.toFixed(3),
        impacts: imps.filter(function (o) { return o.age >= 0; }).length,
        impCount: impCount,
        running: running
      };
    },
    flash: function () { flash(0); },
    shape: function (name) { shapeTo(name); },        // 彩蛋页翻屏时换形状（见第 3b 节）
    mood: function (name) { setMood(name); },         // 同一个名字也顺便换粒子的色温（第 3c 节）
    symbolAt: function (x, y) { return symbolAt(x, y); },   // 屏幕坐标 → 星野里的第几粒（第 3d 节）
    focusSymbol: function (ord) { return focusAt(ord); },   // 镜头飞到那一粒上（其余压暗）
    unfocus: function () { return focusAt(-1); },           // 收回：回到星野全景
    look: function (dx, dy) { look(dx, dy); }               // 聚焦时自己转视角（像素位移）
  };
})();
