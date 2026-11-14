import { qrcode } from "qrcode-generator";
import { init } from "virtual:swift-wasm?js&product=WebApp";

// Bridges for the Swift app. Each wraps one browser or library call that can throw, because a JS
// exception inside a JavaScriptKit call would trap the Wasm module. No app logic lives here.
window.speedMathBridge = {
  parse(text) {
    try { return JSON.parse(text); } catch { return null; }
  },
  qr(text) {
    const qr = qrcode(0, "M");
    qr.addData(text);
    qr.make();
    return qr.createDataURL(5, 20);
  },
  sessionLoad(key) {
    try { return sessionStorage.getItem(key); } catch { return null; }
  },
  sessionSave(key, value) {
    try {
      if (value === null) sessionStorage.removeItem(key);
      else sessionStorage.setItem(key, value);
    } catch {}
  },
};

await init();
