// Capture full page: Chrome's own full-page screenshot (no stitching), handed to the Capture app on this Mac.
// The app saves it in the library and puts it on the clipboard. Nothing leaves the Mac.
const HOST = "com.tylerhagy.capture";
const PART = 512 * 1024; // base64 characters per message; a multiple of 4, so each part decodes on its own

chrome.action.onClicked.addListener((tab) => capture(tab));

async function capture(tab) {
  const target = { tabId: tab.id };
  mark(tab.id, "…", "#6b6b63");
  try {
    await chrome.debugger.attach(target, "1.3");
    const m = await chrome.debugger.sendCommand(target, "Page.getLayoutMetrics");
    const size = m.cssContentSize || m.contentSize;
    const dpr = (await chrome.debugger.sendCommand(target, "Runtime.evaluate", { expression: "window.devicePixelRatio", returnByValue: true })).result.value || 1;
    const width = Math.ceil(size.width), height = Math.min(Math.ceil(size.height), Math.floor(16000 / dpr));
    const shot = await chrome.debugger.sendCommand(target, "Page.captureScreenshot", {
      format: "png", captureBeyondViewport: true, fromSurface: true, clip: { x: 0, y: 0, width, height, scale: 1 },
    });
    await chrome.debugger.detach(target);
    await send(shot.data, tab.title || "");
    mark(tab.id, "✓", "#121212");
  } catch (e) {
    try { await chrome.debugger.detach(target); } catch (_) {}
    console.error("Capture full page:", e);
    mark(tab.id, "!", "#9e1f1a");
  }
  setTimeout(() => chrome.action.setBadgeText({ tabId: tab.id, text: "" }), 2500);
}

function send(b64, title) {
  return new Promise((resolve, reject) => {
    const port = chrome.runtime.connectNative(HOST);
    const id = crypto.randomUUID(), total = Math.ceil(b64.length / PART);
    port.onMessage.addListener((m) => { port.disconnect(); m.ok ? resolve(m) : reject(new Error(m.error || "Capture refused it")); });
    port.onDisconnect.addListener(() => { if (chrome.runtime.lastError) reject(new Error(chrome.runtime.lastError.message)); });
    for (let i = 0; i < total; i++) port.postMessage({ type: "page", id, index: i, total, data: b64.slice(i * PART, (i + 1) * PART), title });
  });
}

function mark(tabId, text, color) {
  chrome.action.setBadgeText({ tabId, text });
  chrome.action.setBadgeBackgroundColor({ tabId, color });
}
