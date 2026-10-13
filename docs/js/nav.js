/* ═══════════ 首页导航：「更多」面板的开合 ═══════════
   只挂首页（三语 index.html 各一行 <script>），子页导航本来就只有 5 个链接。

   三件事：
   1) 开合：点按钮开、点别处关、Esc 关并把焦点还回按钮、点条目后关（同页锚点跳过去
      面板还杵着会挡视线）。
   2) 窄屏（≤720px）：抽屉里的面板是摊平的（见 nav.css 的 media 查询），
      按钮被隐藏 —— 这时不开合，只把 aria-expanded 设成 true，别让读屏软件以为
      里面还有一层没展开。
   3) 高亮接力：main.js 的 scrollspy 会给 .nav-links a[href^="#"] 加 .active。
      面板一收起来，里面哪一条高亮外面都看不见 —— 所以把「面板里有 .active」
      接力到「更多」按钮上，用 MutationObserver 盯着 class 变化，不重写 scrollspy。 */
(function () {
  "use strict";

  var more = document.getElementById("navMore");
  var btn = document.getElementById("navMoreBtn");
  var list = document.getElementById("navMoreList");
  if (!more || !btn || !list) return;

  var drawer = window.matchMedia("(max-width: 720px)");
  function isDrawer() { return drawer.matches; }

  function setOpen(open) {
    more.classList.toggle("open", open);
    btn.setAttribute("aria-expanded", String(open));
  }

  function sync() {
    // 抽屉里面板本来就是摊开的，aria 跟着走；桌面端一律先收起来
    setOpen(isDrawer());
  }

  btn.addEventListener("click", function () {
    if (isDrawer()) return;
    setOpen(!more.classList.contains("open"));
  });

  document.addEventListener("click", function (e) {
    if (isDrawer() || more.contains(e.target)) return;
    setOpen(false);
  });

  document.addEventListener("keydown", function (e) {
    if (e.key !== "Escape" && e.key !== "Esc") return;
    if (!more.classList.contains("open")) return;
    setOpen(false);
    btn.focus();
  });

  list.addEventListener("click", function (e) {
    if (isDrawer()) return;
    var t = e.target;
    while (t && t !== list && t.tagName !== "A") t = t.parentNode;
    if (t && t.tagName === "A") setOpen(false);
  });

  if (drawer.addEventListener) drawer.addEventListener("change", sync);
  else if (drawer.addListener) drawer.addListener(sync);

  var anchors = [].slice.call(list.querySelectorAll('a[href^="#"]'));
  if (anchors.length && window.MutationObserver) {
    var mo = new MutationObserver(function () {
      var on = anchors.some(function (a) { return a.classList.contains("active"); });
      btn.classList.toggle("active", on);
    });
    anchors.forEach(function (a) {
      mo.observe(a, { attributes: true, attributeFilter: ["class"] });
    });
  }

  sync();
})();
