import { qrcode } from "qrcode-generator";
import { VERSION, frame, normalizeCode, relayKind, sessionPattern, tokenPattern } from "../worker/protocol.js";

const packet = (type, fields = {}) => ({ v: VERSION, type, ...fields });
const id = () => Array.from(crypto.getRandomValues(new Uint8Array(16)), x => x.toString(16).padStart(2, "0")).join("");
const inviteFromURL = (() => {
  const [path, query] = location.hash.split("?", 2);
  if (path !== "#/remote" || !query) return null;
  const params = new URLSearchParams(query);
  if (!params.has("invite")) return null;
  const secret = params.get("invite").split(".");
  history.replaceState(history.state, "", location.pathname + location.search + "#/remote");
  return secret.length === 3 && sessionPattern.test(secret[0]) && sessionPattern.test(secret[1]) &&
    tokenPattern.test(secret[2]) ? { id: secret[0], generation: secret[1], key: secret[2] } : null;
})();
let qrInvite = inviteFromURL;
const presenterStore = "speedmath.presenter.v1";
let reloadSession = (() => {
  try {
    const stored = sessionStorage.getItem(presenterStore);
    sessionStorage.removeItem(presenterStore);
    return performance.getEntriesByType("navigation")[0]?.type === "reload" && !window.opener ?
      JSON.parse(stored) : null;
  } catch { return null; }
})();
function storePresenter(session) {
  try {
    if (session) sessionStorage.setItem(presenterStore, JSON.stringify({ ...session, route: location.hash }));
    else sessionStorage.removeItem(presenterStore);
  } catch {}
}

async function post(path, value, signal) {
  const result = await fetch("/api/" + path, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(value), signal,
  });
  if (!result.ok) throw new Error(result.status === 429 ? "slow" : "unavailable");
  return result.json();
}

const issueText = "つなげませんでした。コードを たしかめて、もういちど。";
const disconnectedText = "せつぞくが きれました";
const syncedText = "つながりました";

class Link {
  constructor(role, render, presenterEvent) {
    this.role = role;
    this.render = render;
    this.presenterEvent = presenterEvent;
    this.model = { status: "", online: false };
    this.resetTransport();
    this.visible = () => {
      if (document.visibilityState === "hidden" || !this.session) return;
      if (this.socket?.readyState === WebSocket.OPEN && this.authenticated) this.probe();
      else if (!this.inFlight) this.retry();
    };
    this.offline = () => this.socket?.close();
    document.addEventListener("visibilitychange", this.visible);
    window.addEventListener("online", this.visible);
    window.addEventListener("offline", this.offline);
    if (role === 1 && reloadSession?.route === location.hash &&
        sessionPattern.test(reloadSession.id) && tokenPattern.test(reloadSession.key)) {
      this.session = { id: reloadSession.id, key: reloadSession.key };
      reloadSession = null;
      storePresenter(this.session);
      this.update({ started: true, status: "つないでいます…" });
      this.connect();
    }
    if (role === 2 && qrInvite) {
      this.session = qrInvite;
      qrInvite = null;
      this.update({ status: "つないでいます…", joining: true });
      this.connect();
    }
  }

  update(fields) {
    if (this.disposed) return;
    Object.assign(this.model, fields);
    this.render({ ...this.model });
  }

  resetTransport() {
    clearTimeout(this.retryTimer);
    clearTimeout(this.probeTimer);
    clearTimeout(this.commandTimer);
    clearTimeout(this.connectTimer);
    this.socket = null;
    this.authenticated = false;
    this.attempts = 0;
  }

  async begin(input) {
    if (this.disposed || this.session || this.inFlight) return;
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 8000);
    this.inFlight = controller;
    this.update({ status: "つないでいます…", joining: true });
    try {
      if (this.role === 1) {
        const session = await post("session", packet("create"), controller.signal);
        if (this.disposed) return;
        this.session = session;
        storePresenter(session);
        this.wantInvite = true;
        this.update({ started: true, open: true });
      } else {
        const code = normalizeCode(input);
        if (!code) throw new Error("unavailable");
        const found = await post("lookup", packet("lookup", { code }), controller.signal);
        if (this.disposed) return;
        this.session = { ...found, code };
      }
      this.connect();
    } catch (error) {
      this.update({ joining: false, status: error.message === "slow" ? "すこし まってから ためしてね" : issueText });
    } finally {
      clearTimeout(timeout);
      this.inFlight = null;
    }
  }

  show() {
    this.update({ open: !this.model.open });
    if (!this.model.open) return;
    if (!this.session) this.begin();
    else if (!this.authenticated) this.retry();
    else if (!this.model.code && !this.model.paired && !this.model.request) this.newInvite();
  }

  newInvite() {
    if (this.model.paired) return;
    if (this.send("invite")) this.update({ code: null, qr: null, request: null, check: null, status: "コードを つくっています…" });
  }

  decide(approved, request) {
    if (request === this.model.request) this.send(approved ? "approve" : "reject", { request });
  }

  revoke() { this.send("revoke"); }

  send(type, fields) {
    if (!this.authenticated || this.socket?.readyState !== WebSocket.OPEN) return false;
    this.socket.send(JSON.stringify(packet(type, fields)));
    return true;
  }

  connect() {
    if (this.disposed || !this.session || this.socket) return;
    const session = this.session;
    const url = new URL("/api/socket/" + session.id, location.origin);
    url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
    const ws = new WebSocket(url);
    this.socket = ws;
    this.connectTimer = setTimeout(() => ws.close(), 8000);
    ws.onopen = () => {
      if (this.socket !== ws) return;
      const joining = !!session.generation;
      ws.send(JSON.stringify(joining ? packet(session.code ? "joinCode" : "joinQR", {
        generation: session.generation, key: session.code ?? session.key,
      }) : packet("auth", { role: this.role, key: session.key })));
    };
    ws.onmessage = event => {
      if (this.socket !== ws) return;
      const value = frame(event.data);
      if (value) this.message(value);
    };
    ws.onclose = event => {
      if (this.socket !== ws || this.disposed) return;
      this.resetConnection();
      const definitive = event.code === 4001 && ["unavailable", "invite-ended", "revoked", "ended", "replaced"].includes(event.reason);
      const wasJoining = !!this.session?.generation;
      if (wasJoining || definitive) {
        this.session = null;
        this.inFlightCommand = null;
        this.snapshot = null;
        this.oldEpochs?.clear();
        if (this.role === 1) storePresenter(null);
        this.update({ started: false, paired: false, joining: false, retry: false, request: null, code: null, qr: null,
          check: null, busy: false, status: wasJoining ? issueText : "せつぞくが おわりました" });
        return;
      }
      this.update({ retry: true, status: disconnectedText });
      if (navigator.onLine && this.attempts < 6) {
        this.retryTimer = setTimeout(() => this.connect(), Math.min(8000, 250 * 2 ** this.attempts++));
      }
    };
  }

  resetConnection() {
    this.socket = null;
    this.authenticated = false;
    clearTimeout(this.connectTimer);
    clearTimeout(this.probeTimer);
    clearTimeout(this.commandTimer);
    this.commandTimer = null;
    this.update({ online: false });
  }

  retry() {
    if (!this.session || this.disposed) return;
    this.attempts = 0;
    clearTimeout(this.retryTimer);
    if (!this.socket) this.connect();
    else if (this.authenticated) this.probe();
  }

  probe() {
    clearTimeout(this.probeTimer);
    // On background restore, pause controls until the server answers and the Presenter resyncs.
    if (this.role === 2) this.update({ online: false });
    if (this.send("ping")) this.probeTimer = setTimeout(() => this.socket?.close(), 3500);
  }

  message(value) {
    switch (value.type) {
      case "connected":
      case "approved":
        if (value.type === "approved") {
          if (this.role !== 2 || !tokenPattern.test(value.key)) return;
          this.session = { id: this.session.id, key: value.key };
          this.snapshot = null;
          this.oldEpochs?.clear();
        }
        this.authenticated = true;
        this.attempts = 0;
        clearTimeout(this.connectTimer);
        this.update({ joining: false, retry: false, check: null, paired: this.role === 2 || value.paired,
          status: this.role === 1 ? (value.peer ? syncedText : "") : "どうきしています…" });
        if (this.role === 1) {
          if (value.peer) this.presenterEvent(null);
          if (this.wantInvite) { this.wantInvite = false; this.newInvite(); }
        } else this.send("requestSync");
        break;
      case "waiting":
        clearTimeout(this.connectTimer);
        this.update({ check: value.check, status: "しょうにんを まっています" });
        break;
      case "pending":
        this.update({ request: value.request, check: value.check, open: true });
        break;
      case "pendingGone":
        this.update({ request: null, check: null });
        break;
      case "invite":
        this.showInvite(value);
        break;
      case "inviteMissing":
        this.update({ request: null, check: null, code: null, qr: null, status: "あたらしい コードを だしてね" });
        break;
      case "reset":
        this.update({ online: false, paired: false, request: null, check: null, code: null, qr: null, status: "" });
        break;
      case "peerUp":
        if (this.role === 1) {
          this.update({ paired: true, request: null, check: null, code: null, qr: null, status: syncedText });
          this.presenterEvent(null);
        } else { this.update({ status: "どうきしています…" }); this.send("requestSync"); }
        break;
      case "peerDown":
        clearTimeout(this.commandTimer);
        this.commandTimer = null;
        this.update({ online: false, status: this.role === 2 ? "こどもの がめんを まっています" : "リモコンを まっています" });
        break;
      case "pong":
        clearTimeout(this.probeTimer);
        if (this.role === 2) this.send("requestSync");
        break;
      default:
        if (!this.authenticated || !relayKind(value)) break;
        if (this.role === 1) {
          if (value.type === "command") this.presenterEvent(value);
          if (value.type === "requestSync") this.presenterEvent(null);
        } else {
          if (value.type === "sync") this.sync(value);
          if (value.type === "ack") this.ack(value);
        }
    }
  }

  showInvite(value) {
    const link = new URL(location.href);
    link.hash = "/remote?invite=" + [this.session.id, value.generation, value.key].join(".");
    const qr = qrcode(0, "M");
    qr.addData(link.href);
    qr.make();
    this.update({ code: value.code.match(/.{4}/g).join("-"), qr: qr.createDataURL(5, 20), status: "" });
  }

  publish(state) { this.send("sync", state); }
  receipt(epoch, commandId, result) { this.send("ack", { epoch, id: commandId, result }); }

  sync(state) {
    const previous = this.snapshot;
    if (previous?.epoch === state.epoch && (state.version < previous.version ||
      state.deckVersion !== previous.deckVersion)) return;
    this.oldEpochs ??= new Set();
    if (this.oldEpochs.has(state.epoch)) return;
    if (previous && previous.epoch !== state.epoch) this.oldEpochs.add(previous.epoch);
    this.snapshot = state;
    const card = state.phase === 1 ? state.cards[state.index] : null;
    const command = this.inFlightCommand;
    if (command && command.epoch !== state.epoch) this.uncertain();
    this.update({ online: true, status: state.phase === 0 ? "はじまるのを まっています" : syncedText,
      phase: state.phase, index: state.index + 1, count: state.cards.length, elapsed: state.elapsed,
      question: card ? `${card[0]} ${card[1] === 1 ? "+" : "−"} ${card[2]}` : "",
      answer: card ? String(card[0] + card[1] * card[2]) : "" });
    if (this.inFlightCommand && !this.commandTimer) this.transmit();
  }

  move(direction) {
    if (this.inFlightCommand || !this.model.online || this.snapshot?.phase !== 1) return;
    this.inFlightCommand = {
      id: id(), epoch: this.snapshot.epoch, baseVersion: this.snapshot.version, direction,
    };
    this.retries = 0;
    this.commandStarted = performance.now();
    this.update({ busy: true, notice: "" });
    this.transmit();
  }

  transmit() {
    clearTimeout(this.commandTimer);
    this.commandTimer = null;
    if (!this.inFlightCommand || !this.model.online) return;
    if (this.retries++ >= 4 || performance.now() - this.commandStarted >= 20_000) return this.uncertain();
    if (!this.send("command", this.inFlightCommand)) return;
    this.commandTimer = setTimeout(() => this.transmit(), 900);
  }

  ack(message) {
    if (this.inFlightCommand?.id !== message.id || this.inFlightCommand.epoch !== message.epoch) return;
    if (message.result >= 3) return this.uncertain();
    clearTimeout(this.commandTimer);
    this.commandTimer = null;
    this.inFlightCommand = null;
    this.update({ busy: false });
  }

  uncertain() {
    clearTimeout(this.commandTimer);
    this.commandTimer = null;
    this.inFlightCommand = null;
    this.update({ busy: false, notice: "まえの そうさは かくにんできませんでした" });
    this.send("requestSync");
  }

  dispose() {
    this.disposed = true;
    if (this.role === 1) {
      this.send("end");
      storePresenter(null);
    }
    const socket = this.socket;
    this.resetTransport();
    socket?.close();
    this.inFlight?.abort();
    document.removeEventListener("visibilitychange", this.visible);
    window.removeEventListener("online", this.visible);
    window.removeEventListener("offline", this.offline);
    this.presenterEvent = null;
    this.render = null;
  }
}

window.speedMathRemote = { id, mount: (role, render, presenterEvent) => new Link(role, render, presenterEvent) };
