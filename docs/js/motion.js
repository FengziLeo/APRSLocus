/* ═══════════ 首页动效：同层的一排 .reveal 依次涌上来 ═══════════
   只算延迟，不做显现 —— 把元素"显出来"仍旧交给 main.js 里那套 IntersectionObserver
   （两套观察器抢着加 .in 迟早出事，这里不重复造）。

   时序：本文件跟在 main.js 后面**同步**执行，而 IntersectionObserver 的回调要到
   下一帧才跑 —— 所以 --fx-d 一定在第一次加 .in 之前就写好了，第一批卡片不会
   先亮一下再跳。

   延迟按「行 % 3」循环，不是按行号一路累加：更新日志有 100+ 条 .cl-version，
   累加的话滚到后段每一行都要等上半秒，越滚越迟钝；取模之后不管滚到哪一屏，
   那一屏自己就有 0 / .13 / .26 秒的行差 —— 波浪一直在，但不拖。 */
(function () {
  "use strict";
  if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;

  var COL = 0.055, ROW = 0.13, ROWS = 3, MIN_KIDS = 3;
  var groups = [], index = [], els, i;

  els = document.querySelectorAll(".reveal:not(.section-head)");
  for (i = 0; i < els.length; i++) {
    var el = els[i];
    // hero 里的入场有自己的时钟（planet-3d.js 的 animT），别掺和；
    // 章节标题单独走 data-fx1（见 motion.css 第 3 节），不参与网格成排。
    if (el.closest(".hero")) continue;
    var p = el.parentNode;
    if (!p || p.nodeType !== 1) continue;
    var at = index.indexOf(p);
    if (at < 0) { at = index.push(p) - 1; groups.push({ p: p, kids: [] }); }
    groups[at].kids.push(el);
  }

  for (i = 0; i < groups.length; i++) {
    var g = groups[i], kids = g.kids;
    if (kids.length < MIN_KIDS) continue;              // 单张卡片不需要波浪

    // 用 rect 而不是 offsetTop：跟 offsetParent 是谁无关，跨定位上下文也不会串行
    var boxes = kids.map(function (k) { return { el: k, r: k.getBoundingClientRect() }; });
    boxes.sort(function (a, b) {
      return (a.r.top - b.r.top) || (a.r.left - b.r.left);
    });

    var row = -1, top = null, col = 0;
    for (var j = 0; j < boxes.length; j++) {
      var b = boxes[j];
      if (top === null || Math.abs(b.r.top - top) > 6) { top = b.r.top; row++; col = 0; }
      else col++;
      b.el.style.setProperty("--fx-d", ((row % ROWS) * ROW + col * COL).toFixed(3) + "s");
    }
    g.p.setAttribute("data-fx", "");                   // CSS 只认这个属性才动手
  }

  var heads = document.querySelectorAll(".section-head.reveal");
  for (i = 0; i < heads.length; i++) heads[i].setAttribute("data-fx1", "");
})();
