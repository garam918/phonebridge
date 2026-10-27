// Copy buttons for install commands. The page works without this script.
document.querySelectorAll(".code").forEach((block) => {
  const code = block.querySelector("code");
  if (!code || !navigator.clipboard) return;
  const label = document.documentElement.lang === "ko" ? ["복사", "복사됨"] : ["Copy", "Copied"];
  const button = document.createElement("button");
  button.type = "button";
  button.className = "copy";
  button.textContent = label[0];
  button.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(code.textContent.trim());
      button.textContent = label[1];
      setTimeout(() => { button.textContent = label[0]; }, 1500);
    } catch {
      // Clipboard denied: the command stays selectable.
    }
  });
  block.appendChild(button);
});
