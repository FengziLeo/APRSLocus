/* ══════════════════════════════════════════════════════════════════════
   APRSlocus 官网 Hero：3D 星球 + 累计报文遥测
   ──────────────────────────────────────────────────────────────────────
   为什么手写 WebGL 而不是引 three.js：
   官网是零构建、零依赖的静态站（唯一外链资源是 Font Awesome），为一个
   一万多点的星球塞进 900 KB 的渲染库不划算。这里只用原生 WebGL1：
   两个着色器、两个缓冲，几何在加载时一次性生成。

   渲染思路（与 NASA-Punk Observatory 的 three.js 点云同源）：
   · 球面均匀采样 + 薄球壳（半径 1±0.025）→ 星球本体；
   · 颜色按 value noise 在经度方向拉伸取值（noise3(x*1.7, y*4.6, z*1.7)）
     得到纬向环带，再叠 60 个"信标"点（暖色 + 各自呼吸脉冲）代表台站；
   · 环带与卫星轨道放在 XZ 平面，着色器里跳过 yaw（圆环绕自身轴转看不出
     差别），只跟 pitch 与 24° 轴倾角一起走。倾角只进着色器、几何里不预烘，
     否则会被叠加两次；
   · 相机固定在 +Z，靠 uDist 缩放；打开深度测试（加色混合 + 写深度），
     背面点被正面挡住，星球才有实体感，否则只是一团发光的雾。

   降级：没有 WebGL 或着色器编译失败 → 给 .hero-stage 加 .no-3d，用纯 CSS
   的星球顶上；遥测数字照常跳动（它只依赖 DOM）。

   遥测：数值源头是 /stats.json（仓库里的静态快照，由 check_site.py 与页面
   静态值强制一致），页面按"基线 + 速率 × 经过分钟数"每秒本地推算，
   不需要任何后端与定时任务。
   ══════════════════════════════════════════════════════════════════════ */
(function () {
  "use strict";

  var reduce = false;
  try {
    reduce = !!(window.matchMedia && matchMedia("(prefers-reduced-motion: reduce)").matches);
  } catch (e) { reduce = false; }

  /* ═════════════ 1. 累计报文遥测 ═════════════ */
  (function telemetry() {
    var root = document.getElementById("heroTelemetry");
    if (!root) return;
    var elVal = document.getElementById("tlPackets");
    if (!elVal) return;
    var elRate = document.getElementById("tlRateNum");
    var elStamp = document.getElementById("tlStamp");
    var elInc = document.getElementById("tlInc");
    var elNext = document.getElementById("tlNext");
    var elBar = document.getElementById("tlBar");

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
    if (elInc) elInc.textContent = "+0";

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
        }
        if (elInc) elInc.textContent = "+" + fmt(live - packets);
        shown = live;
      }
      if (elBar) elBar.style.width = stale ? "100%" : ((elapsed % 1) * 100).toFixed(1) + "%";
      if (elNext) elNext.textContent = stale ? "—" : String(60 - Math.floor((now / 1000) % 60));
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
          if (d.updated && elStamp) elStamp.textContent = d.updated;
          if (elRate) elRate.textContent = "+" + fmt(rate);
          shown = -1;
          tick();
        })["catch"](function () {});
      } catch (e) {}
    }
    tick();
    setInterval(tick, 1000);
  })();

  /* ═════════════ 2. 3D 星球 ═════════════ */
  var canvas = document.getElementById("planetCanvas");
  var stage = document.querySelector(".hero-stage");
  if (!canvas || !stage || !canvas.getContext) return;

  var TILT = 23.4 * Math.PI / 180;    // 轴倾角（与舷窗上 AXIS TILT 标签一致）
  var FOV = 33 * Math.PI / 180;
  var U_PROJ = 1 / Math.tan(FOV / 2);
  var RING_OUT = 1.78;                // 最外圈环半径（决定取景）
  var ORBIT = 2.05;                   // 卫星轨道半径
  var CLOUD = 13000;

  /* ── 定点随机：固定种子 → 每次刷新都是同一颗星球（也方便截图对比） ── */
  function mulberry32(a) {
    return function () {
      a = a + 0x6D2B79F5 | 0;
      var t = Math.imul(a ^ a >>> 15, 1 | a);
      t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t;
      return ((t ^ t >>> 14) >>> 0) / 4294967296;
    };
  }
  var rnd = mulberry32(0x41505253);   // 'APRS'

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

  /* ── 色带：深海 → 冰蓝（深色面板上取色，浅色主题也读得清） ── */
  var RAMP = [
    [0.00, 0.043, 0.129, 0.243],   // #0b2136
    [0.42, 0.043, 0.278, 0.463],   // #0b4776
    [0.72, 0.090, 0.588, 0.847],   // #1796d8
    [1.00, 0.545, 0.882, 1.000]    // #8be1ff
  ];
  function ramp(t, out) {
    t = t < 0 ? 0 : t > 1 ? 1 : t;
    var i = 0;
    while (i < RAMP.length - 2 && t > RAMP[i + 1][0]) i++;
    var a = RAMP[i], b = RAMP[i + 1];
    var f = (t - a[0]) / ((b[0] - a[0]) || 1);
    out[0] = a[1] + (b[1] - a[1]) * f;
    out[1] = a[2] + (b[2] - a[2]) * f;
    out[2] = a[3] + (b[3] - a[3]) * f;
  }

  /* ── 几何：交错 9 float/点 = pos(3) + col(3) + meta(尺寸, 脉冲) + spin ── */
  function buildCloud() {
    var arr = [], col = [0, 0, 0], i, u, th, s, x, y, z, r, t, n, ang, ex, ez, live, fade;

    // 星球本体
    for (i = 0; i < CLOUD; i++) {
      u = rnd() * 2 - 1;
      th = rnd() * Math.PI * 2;
      s = Math.sqrt(1 - u * u);
      x = s * Math.cos(th); y = u; z = s * Math.sin(th);
      r = 1 + (rnd() - 0.5) * 0.05;
      n = noise3(x * 1.7, y * 4.6, z * 1.7) * 0.72 + noise3(x * 5.1, y * 5.1, z * 5.1) * 0.28;
      t = Math.pow((n + 1) * 0.5, 0.85);
      ramp(0.16 + t * 0.84, col);
      arr.push(x * r, y * r, z * r, col[0], col[1], col[2],
        0.022 + rnd() * 0.010, 0, 0);
    }

    // 信标点（台站）：暖色 + 呼吸脉冲
    for (i = 0; i < 60; i++) {
      u = rnd() * 2 - 1;
      th = rnd() * Math.PI * 2;
      s = Math.sqrt(1 - u * u);
      x = s * Math.cos(th); y = u; z = s * Math.sin(th);
      var hot = rnd() < 0.3;
      arr.push(x, y, z,
        1.0, hot ? 0.60 : 0.86, hot ? 0.20 : 0.40,
        0.030 + rnd() * 0.018, 0.9 + rnd() * 2.2, 0);
    }

    // 环带：XZ 平面三圈，密度按 noise 立方取舍 → 亮暗相间的弧段
    var rings = [[1.30, 900], [1.52, 1000], [1.74, 1100]];
    for (i = 0; i < rings.length; i++) {
      var rad = rings[i][0], cnt = rings[i][1];
      for (var j = 0; j < cnt; j++) {
        ang = rnd() * Math.PI * 2;
        ex = Math.cos(ang); ez = Math.sin(ang);
        live = Math.pow((noise3(ex * 2.2, ez * 2.2, 0) + 1) * 0.5, 3);
        if (rnd() > live * 1.15) continue;
        r = rad + (rnd() - 0.5) * 0.035;
        fade = 1 - Math.abs(r - rad) / 0.05;
        arr.push(ex * r, (rnd() - 0.5) * 0.012, ez * r,
          0.31 * fade, 0.72 * fade, 0.95 * fade,
          0.013 + rnd() * 0.006, 0, 1);
      }
    }

    // 卫星轨道：一圈细点
    var ON = 280;
    for (i = 0; i < ON; i++) {
      ang = (i / ON) * Math.PI * 2;
      arr.push(Math.cos(ang) * ORBIT, 0, Math.sin(ang) * ORBIT, 0.30, 0.52, 0.70, 0.011, 0, 1);
    }
    return { data: new Float32Array(arr), count: arr.length / 9 };
  }

  var VS = [
    "attribute vec3 aPos;",
    "attribute vec3 aCol;",
    "attribute vec2 aMeta;",
    "attribute float aSpin;",
    "uniform float uCosY; uniform float uSinY;",
    "uniform float uCosP; uniform float uSinP;",
    "uniform float uDist; uniform float uProj; uniform float uAspect;",
    "uniform float uPxScale; uniform float uMaxSize; uniform float uTime;",
    "varying vec3 vCol;",
    "varying float vFade;",
    "void main() {",
    "  float cy = mix(uCosY, 1.0, aSpin);",
    "  float sy = mix(uSinY, 0.0, aSpin);",
    "  vec3 p = vec3(aPos.x * cy + aPos.z * sy, aPos.y, aPos.z * cy - aPos.x * sy);",
    "  p = vec3(p.x, p.y * uCosP - p.z * uSinP, p.y * uSinP + p.z * uCosP);",
    "  float d = uDist - p.z;",
    "  gl_Position = vec4(p.x * uProj / uAspect, p.y * uProj, d - uDist, d);",
    "  gl_PointSize = clamp(aMeta.x * uPxScale / d, 1.0, uMaxSize);",
    "  float pulse = aMeta.y > 0.0",
    "    ? 0.30 + 0.70 * pow(0.5 + 0.5 * sin(uTime * aMeta.y + aPos.x * 9.0), 2.0)",
    "    : 1.0;",
    "  vCol = aCol * pulse;",
    "  vFade = 0.45 + 0.55 * clamp(p.z * 0.9 + 0.55, 0.0, 1.0);",
    "}"
  ].join("\n");

  var FS = [
    "precision mediump float;",
    "varying vec3 vCol;",
    "varying float vFade;",
    "void main() {",
    "  vec2 q = gl_PointCoord - vec2(0.5);",
    "  float r2 = dot(q, q);",
    "  if (r2 > 0.25) discard;",
    "  gl_FragColor = vec4(vCol, smoothstep(0.25, 0.04, r2) * vFade);",
    "}"
  ].join("\n");

  function fail(why) {
    stage.classList.add("no-3d");
    stage.setAttribute("data-3d", why);
    if (window.console && console.warn) console.warn("[planet-3d] fallback:", why);
  }

  var gl = null;
  try {
    gl = canvas.getContext("webgl", { alpha: false, antialias: false, depth: true })
      || canvas.getContext("experimental-webgl", { alpha: false });
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

  var cloud = buildCloud();
  var STRIDE = 9 * 4;
  var buf = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, buf);
  gl.bufferData(gl.ARRAY_BUFFER, cloud.data, gl.STATIC_DRAW);

  var marker = new Float32Array(9);
  var mBuf = gl.createBuffer();

  var A = {
    pos: gl.getAttribLocation(prog, "aPos"),
    col: gl.getAttribLocation(prog, "aCol"),
    meta: gl.getAttribLocation(prog, "aMeta"),
    spin: gl.getAttribLocation(prog, "aSpin")
  };
  var U = {};
  ["uCosY", "uSinY", "uCosP", "uSinP", "uDist", "uProj", "uAspect",
    "uPxScale", "uMaxSize", "uTime"].forEach(function (k) { U[k] = gl.getUniformLocation(prog, k); });

  function bindPointers() {
    gl.vertexAttribPointer(A.pos, 3, gl.FLOAT, false, STRIDE, 0);
    gl.vertexAttribPointer(A.col, 3, gl.FLOAT, false, STRIDE, 12);
    gl.vertexAttribPointer(A.meta, 2, gl.FLOAT, false, STRIDE, 24);
    gl.vertexAttribPointer(A.spin, 1, gl.FLOAT, false, STRIDE, 32);
    gl.enableVertexAttribArray(A.pos);
    gl.enableVertexAttribArray(A.col);
    gl.enableVertexAttribArray(A.meta);
    gl.enableVertexAttribArray(A.spin);
  }

  gl.disable(gl.CULL_FACE);
  gl.enable(gl.BLEND);
  gl.blendFunc(gl.SRC_ALPHA, gl.ONE);              // 加色混合：点重叠处更亮
  gl.enable(gl.DEPTH_TEST);
  gl.depthFunc(gl.LESS);
  gl.depthMask(true);
  gl.clearColor(0.024, 0.043, 0.086, 1);           // #060b16（面板底色，与 CSS 一致）

  /* ── 相机 / 交互状态 ── */
  var yaw = 0.55, pitch = -0.10, tYaw = yaw, tPitch = pitch;
  var spin = reduce ? 0 : 0.055;                   // rad/s 自转
  var dragging = false, lastX = 0, lastY = 0;
  var running = false, paused = false, raf = 0, last = 0;

  function camDist() {
    var w = canvas.width, h = canvas.height;
    var aspect = w / Math.max(1, h);
    var fit = aspect < 1 ? 1.30 : 0.92;            // 竖版面板允许环带略微出框
    var d = RING_OUT * U_PROJ / (fit * aspect);    // 横向最宽，按它取景
    var dMax = U_PROJ / 0.34;                      // 星球半径不小于画面高度的 17%
    return Math.max(Math.min(d, dMax), 3.4);
  }

  function draw(now) {
    var w = canvas.width, h = canvas.height;
    if (!w || !h) return;
    var dist = camDist();
    var cp = Math.cos(TILT + pitch), sp = Math.sin(TILT + pitch);
    gl.viewport(0, 0, w, h);
    gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
    gl.useProgram(prog);
    gl.uniform1f(U.uCosY, Math.cos(yaw));
    gl.uniform1f(U.uSinY, Math.sin(yaw));
    gl.uniform1f(U.uCosP, cp);
    gl.uniform1f(U.uSinP, sp);
    gl.uniform1f(U.uDist, dist);
    gl.uniform1f(U.uProj, U_PROJ);
    gl.uniform1f(U.uAspect, w / h);
    gl.uniform1f(U.uPxScale, (h / 2) * U_PROJ);
    gl.uniform1f(U.uMaxSize, 26);
    gl.uniform1f(U.uTime, reduce ? 0 : now);

    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    bindPointers();
    gl.drawArrays(gl.POINTS, 0, cloud.count);

    // 卫星：沿轨道移动的单点
    var ang = (reduce ? 0 : now) * 0.26;
    marker[0] = Math.cos(ang) * ORBIT;
    marker[1] = 0;
    marker[2] = Math.sin(ang) * ORBIT;
    marker[3] = 0.72; marker[4] = 0.95; marker[5] = 1.0;
    marker[6] = 0.046; marker[7] = 1.6; marker[8] = 1;
    gl.bindBuffer(gl.ARRAY_BUFFER, mBuf);
    gl.bufferData(gl.ARRAY_BUFFER, marker, gl.DYNAMIC_DRAW);
    bindPointers();
    gl.drawArrays(gl.POINTS, 0, 1);
  }

  function loop(now) {
    var dt = Math.min(0.05, (now - last) / 1000) || 0;
    last = now;
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
    last = (window.performance && performance.now ? performance.now() : Date.now());
    raf = requestAnimationFrame(loop);
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
    start();
  }

  /* ── 拖动 / 键盘 ── */
  canvas.addEventListener("pointerdown", function (e) {
    dragging = true;
    lastX = e.clientX; lastY = e.clientY;
    stage.classList.add("grabbing");
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
    stage.classList.remove("grabbing");
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
    }, { threshold: 0 }).observe(stage);
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
        ok: !stage.classList.contains("no-3d"),
        glError: gl.getError(),
        points: cloud.count,
        dist: +camDist().toFixed(3),
        yaw: +yaw.toFixed(3),
        pitch: +pitch.toFixed(3),
        reduce: reduce,
        running: running
      };
    }
  };
})();
