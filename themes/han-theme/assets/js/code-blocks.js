(() => {
  function copyWithSelection(text) {
    const active = document.activeElement;
    const selection = window.getSelection();
    const ranges = [];
    for (let i = 0; selection && i < selection.rangeCount; i += 1) {
      ranges.push(selection.getRangeAt(i).cloneRange());
    }
    const input = document.createElement("textarea");
    input.value = text;
    input.setAttribute("readonly", "");
    input.style.cssText = "position:fixed;top:0;left:-9999px;opacity:0";
    document.body.append(input);
    input.select();
    let copied = false;
    try {
      copied = document.execCommand("copy");
    } finally {
      input.remove();
      if (active instanceof HTMLElement) active.focus({ preventScroll: true });
      if (selection) {
        selection.removeAllRanges();
        ranges.forEach((range) => selection.addRange(range));
      }
    }
    if (!copied) throw new Error("Copy failed");
  }

  document.querySelectorAll(".code-copy-button").forEach((button) => {
    const source = button.closest(".code-block").querySelector("[data-code-source]");
    const label = button.querySelector("span");
    let reset;
    button.hidden = false;
    button.addEventListener("click", async () => {
      if (button.disabled) return;
      clearTimeout(reset);
      button.disabled = true;
      try {
        const text = JSON.parse(source.textContent);
        if (navigator.clipboard && window.isSecureContext) {
          try {
            await navigator.clipboard.writeText(text);
          } catch {
            copyWithSelection(text);
          }
        } else {
          copyWithSelection(text);
        }
        label.textContent = "已复制";
        button.dataset.state = "success";
      } catch {
        label.textContent = "请手动选择复制";
        button.dataset.state = "error";
      } finally {
        button.disabled = false;
        reset = setTimeout(() => {
          label.textContent = "复制";
          delete button.dataset.state;
        }, 2200);
      }
    });
  });
})();
