(() => {
  const tree = document.querySelector(".home-sidebar-left .category-tree");
  if (!tree) return;

  const storageKey = "han-theme:category-tree:v1";
  const nodes = Array.from(tree.querySelectorAll("details[data-category-path]"));
  let saved;
  try {
    saved = JSON.parse(sessionStorage.getItem(storageKey));
  } catch {
    // Navigation must still work when storage is unavailable or invalid.
  }

  let restoring = true;
  let timer;
  const scrollTop = saved && Number.isFinite(saved.scrollTop)
    ? Math.max(0, saved.scrollTop)
    : 0;

  if (saved && Array.isArray(saved.categories)) {
    const states = new Map(
      saved.categories
        .filter((item) => item && typeof item.path === "string" && typeof item.open === "boolean")
        .map((item) => [item.path, item.open])
    );
    nodes.forEach((node) => {
      if (states.has(node.dataset.categoryPath)) {
        node.open = states.get(node.dataset.categoryPath);
      }
    });
  }

  function save() {
    if (restoring) return;
    clearTimeout(timer);
    try {
      sessionStorage.setItem(storageKey, JSON.stringify({
        scrollTop: tree.scrollTop,
        categories: nodes.map((node) => ({
          path: node.dataset.categoryPath,
          open: node.open,
        })),
      }));
    } catch {
      // Disabled storage must not interfere with links or category controls.
    }
  }

  // Restore the expansion first, then the scroll offset after the grid is laid out.
  tree.scrollTop = scrollTop;
  requestAnimationFrame(() => {
    tree.scrollTop = scrollTop;
    restoring = false;
  });

  tree.addEventListener("scroll", () => {
    if (!restoring) {
      clearTimeout(timer);
      timer = setTimeout(save, 100);
    }
  }, { passive: true });
  nodes.forEach((node) => node.addEventListener("toggle", save));

  // Save synchronously before navigation, including series links outside the tree.
  document.addEventListener("click", (event) => {
    if (event.target instanceof Element && event.target.closest("a[href]")) save();
  }, { capture: true });
  window.addEventListener("pagehide", save);
})();
