// Adds a link to the same page in the other language to the menu bar. The
// published site serves the English book at its root and the Japanese book
// under ja/.
(function () {
  const bar = document.querySelector(".right-buttons");
  if (!bar || typeof path_to_root === "undefined") {
    return;
  }
  const root = new URL(path_to_root, window.location.href);
  const page = window.location.pathname.slice(root.pathname.length);
  const ja = document.documentElement.lang === "ja";
  const target = new URL((ja ? "../" : "ja/") + page, root);
  const link = document.createElement("a");
  link.href = target.href;
  link.textContent = ja ? "English" : "日本語";
  link.title = ja ? "Read this page in English" : "このページを日本語で読む";
  link.style.marginInlineEnd = "1em";
  bar.prepend(link);
})();
