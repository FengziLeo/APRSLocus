/* 主题切换（浅 / 深）—— 独立页专用。
 *
 * 首页那套切换写在 js/main.js 里（顺带管导航折叠），而 promo / card / badge /
 * member-card / memorial / terms ×3 这 8 个页面不挂 main.js（也不挂 style.css，
 * 只挂 css/theme.css），所以共用这一份。
 *
 * 初始主题不在这里设：<head> 里的内联脚本已经在首帧前把 data-theme 写到
 * <html> 上了（localStorage 优先，没存过 = dark）。这里只负责按钮与后续切换。
 * 图标是 CSS 换的（细线 SVG：深色下画太阳 = "切到浅色"，浅色下画月亮）。
 */
(function () {
  "use strict";

  var btn = document.getElementById("themeToggle");
  if (!btn) return;

  function sync() {
    var dark = document.documentElement.getAttribute("data-theme") === "dark";
    btn.setAttribute("aria-pressed", String(dark));
    var label = dark
      ? (btn.dataset.labelDark || "切换到浅色模式")
      : (btn.dataset.labelLight || "切换到深色模式");
    btn.setAttribute("aria-label", label);
    btn.setAttribute("title", label);
  }

  sync();

  btn.addEventListener("click", function () {
    var next =
      document.documentElement.getAttribute("data-theme") === "dark" ? "light" : "dark";
    document.documentElement.setAttribute("data-theme", next);
    try { localStorage.setItem("theme", next); } catch (e) {}
    var meta = document.querySelector('meta[name="theme-color"]');
    if (meta) meta.setAttribute("content", next === "dark" ? "#0a0e12" : "#f4f7fc");
    sync();
  });
})();
