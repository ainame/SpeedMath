import { qrcode } from "qrcode-generator";
import { init } from "virtual:swift-wasm?js&product=WebApp";

// The Swift app reaches browser APIs through typed BridgeJS bindings. The one thing it cannot reach
// on its own is the bundled QR code library, so it is injected here. No app logic lives here.
await init({
  getImports() {
    return {
      qrCodeDataURL(text) {
        const qr = qrcode(0, "M");
        qr.addData(text);
        qr.make();
        return qr.createDataURL(5, 20);
      },
    };
  },
});
