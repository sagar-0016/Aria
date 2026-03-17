#!/usr/bin/env bash
# ============================================================
#  ARIA — Voice AI Assistant for Linux
#  Engine: Ollama · Model: qwen:1.8b
# ============================================================

set -Eeuo pipefail

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

TARGET_USER="${USER:-}"
TARGET_HOME="${HOME}"
TARGET_GROUP=""
ARIA_DIR=""
BIN_DIR=""
APP_DIR=""
SYSTEMD_DIR=""
INSTALL_LOG=""
MODEL_NAME="qwen:1.8b"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PKG_MANAGER=""
INSTALL_CMD=()
UPDATE_CMD=()
PKG_QUERY_CMD=()
DISTRO_ID="unknown"
DISTRO_LIKE=""
SUDO=""

declare -a BASE_PACKAGES=(
  curl
  wget
  tmux
  git
  python3
  python3-pip
)

declare -a DEBIAN_PACKAGES=(
  espeak-ng
  python3-venv
  lm-sensors
  xterm
  xdg-utils
)

declare -a FEDORA_PACKAGES=(
  espeak-ng
  lm_sensors
  xterm
  xdg-utils
)

log() {
  printf "%b%s%b\n" "${GREEN}" "$1" "${NC}"
}

warn() {
  printf "%b%s%b\n" "${YELLOW}" "$1" "${NC}"
}

error() {
  printf "%b%s%b\n" "${RED}" "$1" "${NC}" >&2
}

die() {
  error "$1"
  exit 1
}

run_logged() {
  "$@" >>"${INSTALL_LOG}" 2>&1
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

configure_target_context() {
  if [[ ${EUID} -eq 0 && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    TARGET_USER="${SUDO_USER}"
    TARGET_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"
  elif [[ -z "${TARGET_USER}" ]]; then
    TARGET_USER="$(id -un)"
    TARGET_HOME="${HOME}"
  fi

  [[ -n "${TARGET_HOME}" ]] || die "Could not determine target home directory."
  TARGET_GROUP="$(id -gn "${TARGET_USER}")"
  ARIA_DIR="${TARGET_HOME}/.aria"
  BIN_DIR="${TARGET_HOME}/.local/bin"
  APP_DIR="${TARGET_HOME}/.local/share/applications"
  SYSTEMD_DIR="${TARGET_HOME}/.config/systemd/user"
  INSTALL_LOG="${ARIA_DIR}/install.log"
}

run_as_target() {
  if [[ ${EUID} -eq 0 && "${TARGET_USER}" != "root" ]]; then
    sudo -u "${TARGET_USER}" HOME="${TARGET_HOME}" "$@"
  else
    "$@"
  fi
}

detect_distro() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    DISTRO_ID="${ID:-unknown}"
    DISTRO_LIKE="${ID_LIKE:-}"
  fi
}

configure_privileges() {
  if [[ ${EUID} -eq 0 ]]; then
    SUDO=""
  elif have_cmd sudo; then
    SUDO="sudo"
  else
    die "This installer needs root privileges through sudo, or it must be run as root."
  fi
}

configure_package_manager() {
  if have_cmd apt-get; then
    PKG_MANAGER="apt"
    INSTALL_CMD=(${SUDO:+$SUDO} apt-get install -y)
    UPDATE_CMD=(${SUDO:+$SUDO} apt-get update)
    PKG_QUERY_CMD=(dpkg -s)
  elif have_cmd dnf; then
    PKG_MANAGER="dnf"
    INSTALL_CMD=(${SUDO:+$SUDO} dnf install -y)
    UPDATE_CMD=(${SUDO:+$SUDO} dnf makecache)
    PKG_QUERY_CMD=(rpm -q)
  else
    die "Unsupported Linux distribution. Only apt-based and dnf-based systems are handled."
  fi
}

package_installed() {
  "${PKG_QUERY_CMD[@]}" "$1" >/dev/null 2>&1
}

apt_enable_common_repos() {
  local repos_added=0

  if have_cmd add-apt-repository && [[ "${DISTRO_ID}" == "ubuntu" || "${DISTRO_LIKE}" == *ubuntu* ]]; then
    if ! grep -RqsE '^[[:space:]]*deb .+ universe' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
      warn "Enabling Ubuntu universe repository."
      run_logged ${SUDO:+$SUDO} add-apt-repository -y universe || true
      repos_added=1
    fi
  fi

  if [[ ${repos_added} -eq 1 ]]; then
    run_logged "${UPDATE_CMD[@]}"
  fi
}

dnf_enable_common_repos() {
  if ! package_installed dnf-plugins-core; then
    warn "Installing dnf-plugins-core for repository management."
    run_logged "${INSTALL_CMD[@]}" dnf-plugins-core || true
  fi

  if ! package_installed rpmfusion-free-release; then
    warn "Attempting to enable RPM Fusion free repository."
    run_logged ${SUDO:+$SUDO} dnf install -y \
      "https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" || true
  fi
}

prepare_repositories() {
  log "[1/8] Preparing package repositories..."
  install -d -m 0755 -o "${TARGET_USER}" -g "${TARGET_GROUP}" "${ARIA_DIR}"
  : >"${INSTALL_LOG}"
  chown "${TARGET_USER}:${TARGET_GROUP}" "${INSTALL_LOG}"

  case "${PKG_MANAGER}" in
    apt)
      run_logged "${UPDATE_CMD[@]}"
      apt_enable_common_repos
      ;;
    dnf)
      run_logged "${UPDATE_CMD[@]}"
      dnf_enable_common_repos
      run_logged "${UPDATE_CMD[@]}"
      ;;
  esac
}

install_missing_packages() {
  local -a wanted=("${BASE_PACKAGES[@]}")
  local -a missing=()
  local pkg

  case "${PKG_MANAGER}" in
    apt)
      wanted+=("${DEBIAN_PACKAGES[@]}")
      ;;
    dnf)
      wanted+=("${FEDORA_PACKAGES[@]}")
      ;;
  esac

  log "[2/8] Checking system dependencies..."
  for pkg in "${wanted[@]}"; do
    if ! package_installed "${pkg}"; then
      missing+=("${pkg}")
    fi
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    printf "  All system packages are already installed.\n"
    return
  fi

  printf "  Installing missing packages: %s\n" "${missing[*]}"
  if ! run_logged "${INSTALL_CMD[@]}" "${missing[@]}"; then
    warn "Initial package install failed. Refreshing repositories and retrying once."
    run_logged "${UPDATE_CMD[@]}"
    run_logged "${INSTALL_CMD[@]}" "${missing[@]}" || die "Package installation failed. See ${INSTALL_LOG}."
  fi
}

ensure_pip_module() {
  local venv_python=$1
  local import_name=$2
  local package_name=$3

  if ! run_as_target "${venv_python}" -c "import ${import_name}" >/dev/null 2>&1; then
    run_logged run_as_target "${venv_python}" -m pip install --upgrade "${package_name}" || die "Failed to install Python package ${package_name}."
  fi
}

install_ollama() {
  log "[3/8] Ensuring Ollama is installed..."

  if have_cmd ollama; then
    printf "  Ollama already available at %s\n" "$(command -v ollama)"
    return
  fi

  run_logged bash -c 'curl -fsSL https://ollama.com/install.sh | sh' || die "Ollama installation failed."

  if ! have_cmd ollama; then
    die "Ollama was installed but is still not on PATH."
  fi
}

ensure_model() {
  log "[4/8] Ensuring model ${MODEL_NAME} is available..."
  ollama pull "${MODEL_NAME}" >>"${INSTALL_LOG}" 2>&1 || die "Failed to pull ${MODEL_NAME}."
}

setup_python_env() {
  log "[5/8] Preparing Python environment..."

  install -d -m 0755 -o "${TARGET_USER}" -g "${TARGET_GROUP}" "${ARIA_DIR}" "${BIN_DIR}" "${APP_DIR}" "${SYSTEMD_DIR}"

  if [[ ! -x "${ARIA_DIR}/venv/bin/python3" ]]; then
    run_as_target python3 -m venv "${ARIA_DIR}/venv"
  fi

  run_logged run_as_target "${ARIA_DIR}/venv/bin/python3" -m pip install --upgrade pip
  ensure_pip_module "${ARIA_DIR}/venv/bin/python3" requests requests
}

write_runtime_files() {
  local ollama_bin
  ollama_bin="$(command -v ollama)"

  log "[6/8] Writing ARIA runtime files..."

  cat >"${ARIA_DIR}/aria.py" <<'PYEOF'
#!/usr/bin/env python3
"""
ARIA — Browser Voice Assistant · Ollama + qwen:1.8b
"""
import json
import os
import signal
import threading
import webbrowser
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import requests

HOME = Path.home()
OLLAMA = os.getenv("OLLAMA_HOST", "http://127.0.0.1:11434")
MODEL = "qwen:1.8b"
API = f"{OLLAMA}/api/chat"
GENERATE_API = f"{OLLAMA}/api/generate"
WEB_ROOT = HOME / ".aria" / "web"
INDEX_HTML = WEB_ROOT / "index.html"
HOST = "127.0.0.1"
PORT = int(os.getenv("ARIA_PORT", "8765"))
history = []

SYSTEM = """You are ARIA, a Linux voice assistant.
Reply in 2-3 short sentences. Be practical and concise.
Do not output shell commands unless the user explicitly asks for them."""


def warm_model() -> None:
    try:
        requests.post(
            GENERATE_API,
            json={"model": MODEL, "prompt": "Ready.", "stream": False, "keep_alive": "15m"},
            timeout=60,
        ).raise_for_status()
    except Exception:
        pass


def ask(text):
    global history
    history.append({"role": "user", "content": text})
    payload = {
        "model": MODEL,
        "messages": [{"role": "system", "content": SYSTEM}] + history[-10:],
        "stream": False,
    }
    try:
        response = requests.post(API, json=payload, timeout=30)
        response.raise_for_status()
        reply = response.json()["message"]["content"]
        history.append({"role": "assistant", "content": reply})
        return reply
    except requests.ConnectionError:
        return "Ollama is not reachable. Start it with `ollama serve`."
    except Exception as exc:
        return f"Model error: {exc}"


class AriaHandler(BaseHTTPRequestHandler):
    def _send_json(self, payload, status=HTTPStatus.OK):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_html(self):
        body = INDEX_HTML.read_bytes()
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        return

    def do_GET(self):
        if self.path in {"/", "/index.html"}:
            self._send_html()
            return
        if self.path == "/health":
            self._send_json({"ok": True})
            return
        self._send_json({"error": "Not found"}, status=HTTPStatus.NOT_FOUND)

    def do_POST(self):
        global history
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            payload = json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError:
            self._send_json({"error": "Invalid JSON"}, status=HTTPStatus.BAD_REQUEST)
            return

        if self.path == "/api/warm":
            warm_model()
            self._send_json({"ok": True})
            return

        if self.path == "/api/reset":
            history = []
            self._send_json({"ok": True})
            return

        if self.path == "/api/chat":
            text = (payload.get("text") or "").strip()
            if not text:
                self._send_json({"error": "Text is required"}, status=HTTPStatus.BAD_REQUEST)
                return
            reply = ask(text)
            self._send_json({"reply": reply})
            return

        self._send_json({"error": "Not found"}, status=HTTPStatus.NOT_FOUND)


def shutdown(*_args):
    raise KeyboardInterrupt


def maybe_open_browser(url):
    if os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"):
        threading.Timer(1.0, lambda: webbrowser.open(url)).start()


def main():
    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    print("\n  ARIA — Browser Voice Assistant")
    print(f"  Host : {OLLAMA}")
    print(f"  Web  : http://{HOST}:{PORT}")
    print("  Ctrl+C to quit\n")

    try:
        requests.get(f"{OLLAMA}/api/tags", timeout=3).raise_for_status()
        print("  Ollama: online")
    except Exception:
        print("  WARNING: Ollama not running. Start with: ollama serve")

    warm_model()
    url = f"http://{HOST}:{PORT}"
    maybe_open_browser(url)

    server = ThreadingHTTPServer((HOST, PORT), AriaHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        print("\n  Goodbye.")


if __name__ == "__main__":
    main()
PYEOF
  chmod +x "${ARIA_DIR}/aria.py"

  install -d -m 0755 -o "${TARGET_USER}" -g "${TARGET_GROUP}" "${ARIA_DIR}/web"
  cat >"${ARIA_DIR}/web/index.html" <<'HTMLEOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>ARIA</title>
  <style>
    :root {
      --bg: #08111f;
      --panel: rgba(12, 18, 34, 0.9);
      --panel-2: rgba(15, 23, 42, 0.96);
      --text: #edf2f7;
      --muted: #9aa7ba;
      --accent: #2dd4bf;
      --accent-2: #f59e0b;
      --border: rgba(148, 163, 184, 0.2);
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      min-height: 100vh;
      padding: 24px;
      display: grid;
      place-items: center;
      color: var(--text);
      font-family: "IBM Plex Sans", "Segoe UI", sans-serif;
      background:
        radial-gradient(circle at top left, rgba(45, 212, 191, 0.16), transparent 36%),
        radial-gradient(circle at bottom right, rgba(245, 158, 11, 0.18), transparent 32%),
        linear-gradient(160deg, #020617, #0f172a 55%, #111827);
    }
    .app {
      width: min(920px, 100%);
      padding: 24px;
      border-radius: 28px;
      background: var(--panel);
      border: 1px solid var(--border);
      backdrop-filter: blur(18px);
      box-shadow: 0 28px 80px rgba(2, 6, 23, 0.5);
    }
    .hero {
      display: flex;
      justify-content: space-between;
      gap: 16px;
      align-items: start;
      margin-bottom: 18px;
    }
    .brand {
      display: flex;
      gap: 18px;
      align-items: center;
    }
    .orb-wrap {
      display: grid;
      place-items: center;
      width: 92px;
      height: 92px;
      border-radius: 50%;
      background: radial-gradient(circle, rgba(45, 212, 191, 0.24), rgba(15, 23, 42, 0.14) 68%, transparent 72%);
    }
    .orb {
      width: 56px;
      height: 56px;
      border-radius: 50%;
      background: radial-gradient(circle at 35% 35%, #a7f3d0, #14b8a6 55%, #0f172a 100%);
      box-shadow: 0 0 0 0 rgba(45, 212, 191, 0.4);
      transition: transform 180ms ease, box-shadow 180ms ease, filter 180ms ease;
    }
    .orb.armed {
      animation: pulse 2.2s infinite;
    }
    .orb.listening {
      transform: scale(1.08);
      animation: pulse 0.9s infinite;
      filter: saturate(1.2);
    }
    .orb.thinking {
      background: radial-gradient(circle at 35% 35%, #fde68a, #f59e0b 55%, #0f172a 100%);
      animation: pulse 1.1s infinite;
    }
    .orb.speaking {
      background: radial-gradient(circle at 35% 35%, #bfdbfe, #3b82f6 55%, #0f172a 100%);
      animation: pulse 0.7s infinite;
    }
    .orb.error {
      background: radial-gradient(circle at 35% 35%, #fca5a5, #ef4444 55%, #0f172a 100%);
      animation: pulse 1.4s infinite;
    }
    @keyframes pulse {
      0% { box-shadow: 0 0 0 0 rgba(45, 212, 191, 0.48); }
      70% { box-shadow: 0 0 0 18px rgba(45, 212, 191, 0); }
      100% { box-shadow: 0 0 0 0 rgba(45, 212, 191, 0); }
    }
    h1 {
      margin: 0;
      font-size: clamp(2rem, 5vw, 3.7rem);
      line-height: 0.95;
      letter-spacing: -0.05em;
    }
    .subtitle {
      margin: 10px 0 0;
      color: var(--muted);
      max-width: 42rem;
    }
    .status {
      border-radius: 999px;
      border: 1px solid var(--border);
      padding: 10px 14px;
      background: var(--panel-2);
      color: var(--accent);
      white-space: nowrap;
    }
    .controls, .composer {
      display: flex;
      gap: 12px;
      flex-wrap: wrap;
      margin-bottom: 16px;
    }
    button, input {
      border: 1px solid var(--border);
      border-radius: 16px;
      font: inherit;
    }
    button {
      cursor: pointer;
      padding: 14px 18px;
      color: var(--text);
      background: linear-gradient(135deg, rgba(45, 212, 191, 0.14), rgba(15, 23, 42, 0.95));
    }
    button.primary {
      background: linear-gradient(135deg, #14b8a6, #0f766e);
    }
    button.warn {
      background: linear-gradient(135deg, #f59e0b, #b45309);
    }
    input {
      flex: 1 1 320px;
      padding: 14px 16px;
      background: rgba(15, 23, 42, 0.92);
      color: var(--text);
    }
    .chat {
      display: grid;
      gap: 12px;
      max-height: 56vh;
      overflow: auto;
      padding-right: 4px;
    }
    .msg {
      padding: 14px 16px;
      border-radius: 18px;
      border: 1px solid var(--border);
      background: rgba(15, 23, 42, 0.92);
    }
    .msg.user {
      background: rgba(8, 47, 73, 0.92);
    }
    .role {
      margin-bottom: 6px;
      color: var(--muted);
      font-size: 0.82rem;
      text-transform: uppercase;
      letter-spacing: 0.08em;
    }
    .hint {
      margin-top: 12px;
      color: var(--muted);
      font-size: 0.92rem;
    }
    .signal {
      display: flex;
      gap: 10px;
      align-items: center;
      margin: 0 0 18px;
      color: var(--muted);
      font-size: 0.95rem;
    }
    .signal-dot {
      width: 10px;
      height: 10px;
      border-radius: 50%;
      background: var(--accent);
      box-shadow: 0 0 12px rgba(45, 212, 191, 0.8);
    }
    .transcript {
      min-height: 54px;
      margin: 0 0 16px;
      padding: 14px 16px;
      border-radius: 18px;
      border: 1px solid var(--border);
      background: rgba(15, 23, 42, 0.7);
      color: var(--muted);
      font-size: 0.98rem;
    }
    .transcript strong {
      color: var(--text);
    }
    @media (max-width: 720px) {
      .brand {
        align-items: start;
      }
      .orb-wrap {
        width: 72px;
        height: 72px;
      }
      .orb {
        width: 46px;
        height: 46px;
      }
    }
  </style>
</head>
<body>
  <main class="app">
    <section class="hero">
      <div class="brand">
        <div class="orb-wrap">
          <div id="orb" class="orb"></div>
        </div>
        <div>
          <h1>ARIA</h1>
          <p class="subtitle">A local voice interface for your models.</p>
        </div>
      </div>
      <div id="status" class="status">Starting…</div>
    </section>

    <div class="signal">
      <span class="signal-dot"></span>
      <span id="signalText">Initializing microphone access</span>
    </div>

    <section class="controls">
      <button id="listenBtn" class="primary">Start Listening</button>
      <button id="stopBtn">Stop Listening</button>
      <button id="wakeBtn">Wake Word: On</button>
      <button id="resetBtn" class="warn">Reset Chat</button>
      <button id="speakBtn">Speak Replies: On</button>
    </section>

    <section class="composer">
      <input id="textInput" placeholder="Type here if browser speech recognition is unavailable">
      <button id="sendBtn">Send</button>
    </section>

    <section id="transcript" class="transcript"><strong>Live signal:</strong> Waiting for the first microphone permission.</section>
    <section id="chat" class="chat"></section>
    <p class="hint">Designed for browser voice control, with typed fallback when speech APIs are unavailable.</p>
  </main>

  <script>
    const chat = document.getElementById("chat");
    const orb = document.getElementById("orb");
    const statusEl = document.getElementById("status");
    const signalText = document.getElementById("signalText");
    const transcriptEl = document.getElementById("transcript");
    const input = document.getElementById("textInput");
    const listenBtn = document.getElementById("listenBtn");
    const stopBtn = document.getElementById("stopBtn");
    const wakeBtn = document.getElementById("wakeBtn");
    const sendBtn = document.getElementById("sendBtn");
    const resetBtn = document.getElementById("resetBtn");
    const speakBtn = document.getElementById("speakBtn");
    const SpeechRecognition = window.SpeechRecognition || window.webkitSpeechRecognition;
    let wakeRecognition = null;
    let commandRecognition = null;
    let speakReplies = true;
    let wakeWordEnabled = true;
    let micReady = false;
    let commandCaptureActive = false;
    let wakeRestartTimer = null;
    let currentState = "idle";
    const wakeRegex = /\b(aria|area|arya)\b/i;

    function setStatus(text, state = currentState) {
      currentState = state;
      statusEl.textContent = text;
      signalText.textContent = text;
      orb.className = `orb ${state === "idle" ? "" : state}`.trim();
    }

    function setTranscript(text) {
      transcriptEl.innerHTML = `<strong>Live signal:</strong> ${escapeHtml(text)}`;
    }

    function escapeHtml(text) {
      return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    }

    function addMessage(role, text) {
      const item = document.createElement("article");
      item.className = `msg ${role}`;
      item.innerHTML = `<div class="role">${role}</div><div>${escapeHtml(text)}</div>`;
      chat.appendChild(item);
      chat.scrollTop = chat.scrollHeight;
    }

    async function postJSON(url, payload = {}) {
      const response = await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload)
      });
      const data = await response.json().catch(() => ({}));
      if (!response.ok) {
        throw new Error(data.error || response.statusText);
      }
      return data;
    }

    async function sendText(text) {
      const trimmed = text.trim();
      if (!trimmed) return;
      addMessage("user", trimmed);
      input.value = "";
      setTranscript(trimmed);
      setStatus("Thinking…", "thinking");
      try {
        const data = await postJSON("/api/chat", { text: trimmed });
        addMessage("aria", data.reply);
        setStatus(speakReplies ? "Speaking response" : (wakeWordEnabled ? "Wake word armed" : "Ready"), speakReplies ? "speaking" : (wakeWordEnabled ? "armed" : "idle"));
        if (speakReplies && "speechSynthesis" in window) {
          window.speechSynthesis.cancel();
          const utterance = new SpeechSynthesisUtterance(data.reply);
          utterance.onend = () => {
            setStatus(wakeWordEnabled ? "Wake word armed" : "Ready", wakeWordEnabled ? "armed" : "idle");
          };
          window.speechSynthesis.speak(utterance);
        }
      } catch (error) {
        addMessage("aria", `Error: ${error.message}`);
        setStatus("Error", "error");
      }
    }

    async function ensureMic() {
      if (micReady) return true;
      try {
        await navigator.mediaDevices.getUserMedia({ audio: true });
        micReady = true;
        setStatus(wakeWordEnabled ? "Wake word armed" : "Ready", wakeWordEnabled ? "armed" : "idle");
        return true;
      } catch (error) {
        setStatus(`Mic error: ${error.message}`, "error");
        setTranscript("Microphone access is blocked or unavailable.");
        return false;
      }
    }

    function scheduleWakeRestart() {
      if (!wakeWordEnabled || commandCaptureActive) return;
      clearTimeout(wakeRestartTimer);
      wakeRestartTimer = setTimeout(() => {
        if (!wakeWordEnabled || commandCaptureActive) return;
        startWakeRecognition();
      }, 400);
    }

    function startWakeRecognition() {
      if (!wakeRecognition) return;
      try {
        wakeRecognition.start();
      } catch (error) {
        setStatus("Voice arming needs browser permission or focus", "error");
      }
    }

    async function startCommandCapture() {
      if (!commandRecognition) return;
      if (!(await ensureMic())) return;
      commandCaptureActive = true;
      setStatus("Listening for command…", "listening");
      try {
        commandRecognition.start();
      } catch (error) {
        commandCaptureActive = false;
        setStatus("Could not start command capture", "error");
      }
    }

    function stopAllRecognition() {
      commandCaptureActive = false;
      if (wakeRecognition) {
        try { wakeRecognition.stop(); } catch (_) {}
      }
      if (commandRecognition) {
        try { commandRecognition.stop(); } catch (_) {}
      }
      clearTimeout(wakeRestartTimer);
    }

    function initRecognition() {
      if (!SpeechRecognition) {
        listenBtn.disabled = true;
        stopBtn.disabled = true;
        wakeBtn.disabled = true;
        setStatus("Browser speech recognition unavailable", "error");
        setTranscript("Use typed input because this browser does not expose speech recognition.");
        return;
      }

      wakeRecognition = new SpeechRecognition();
      wakeRecognition.lang = "en-US";
      wakeRecognition.interimResults = false;
      wakeRecognition.continuous = true;
      wakeRecognition.maxAlternatives = 3;

      wakeRecognition.onstart = () => {
        if (!commandCaptureActive) setStatus("Wake word armed", "armed");
      };
      wakeRecognition.onend = () => {
        if (wakeWordEnabled && !commandCaptureActive) scheduleWakeRestart();
      };
      wakeRecognition.onerror = (event) => {
        if (event.error !== "aborted") setStatus(`Wake error: ${event.error}`, "error");
        if (wakeWordEnabled && !commandCaptureActive) scheduleWakeRestart();
      };
      wakeRecognition.onresult = (event) => {
        const chunks = [];
        for (let i = event.resultIndex; i < event.results.length; i += 1) {
          chunks.push(event.results[i][0].transcript);
        }
        const text = chunks.join(" ").trim();
        setTranscript(text || "Heard audio while waiting for wake word.");
        if (!wakeRegex.test(text)) return;

        const afterWake = text.replace(wakeRegex, "").trim();
        commandCaptureActive = true;
        try { wakeRecognition.stop(); } catch (_) {}

        if (afterWake) {
          sendText(afterWake).finally(() => {
            commandCaptureActive = false;
            scheduleWakeRestart();
          });
          return;
        }

        setStatus("Wake word detected", "listening");
        setTranscript("Wake word accepted. Say your command now.");
        startCommandCapture();
      };

      listenBtn.onclick = async () => {
        wakeWordEnabled = false;
        wakeBtn.textContent = "Wake Word: Off";
        stopAllRecognition();
        setTranscript("Manual capture started.");
        setStatus("Manual listening…", "listening");
        startCommandCapture();
      };

      commandRecognition = new SpeechRecognition();
      commandRecognition.lang = "en-US";
      commandRecognition.interimResults = false;
      commandRecognition.continuous = false;
      commandRecognition.maxAlternatives = 1;
      commandRecognition.onstart = () => setStatus("Listening for command…", "listening");
      commandRecognition.onend = () => {
        commandCaptureActive = false;
        if (wakeWordEnabled) {
          scheduleWakeRestart();
        } else {
          setStatus("Ready", "idle");
        }
      };
      commandRecognition.onerror = (event) => {
        commandCaptureActive = false;
        if (event.error !== "aborted") setStatus(`Speech error: ${event.error}`, "error");
        if (wakeWordEnabled) scheduleWakeRestart();
      };
      commandRecognition.onresult = (event) => {
        const text = event.results[event.resultIndex][0].transcript;
        setTranscript(text);
        sendText(text);
      };

      stopBtn.onclick = () => {
        wakeWordEnabled = false;
        wakeBtn.textContent = "Wake Word: Off";
        stopAllRecognition();
        setTranscript("Voice capture paused.");
        setStatus("Listening stopped", "idle");
      };

      wakeBtn.onclick = async () => {
        wakeWordEnabled = !wakeWordEnabled;
        wakeBtn.textContent = `Wake Word: ${wakeWordEnabled ? "On" : "Off"}`;
        stopAllRecognition();
        if (wakeWordEnabled) {
          if (!(await ensureMic())) return;
          setTranscript("Wake-word listening resumed.");
          scheduleWakeRestart();
        } else {
          setTranscript("Wake-word listening disabled.");
          setStatus("Wake word disabled", "idle");
        }
      };
    }

    sendBtn.onclick = () => sendText(input.value);
    input.addEventListener("keydown", (event) => {
      if (event.key === "Enter") sendText(input.value);
    });

    resetBtn.onclick = async () => {
      await postJSON("/api/reset");
      chat.innerHTML = "";
      addMessage("aria", "Conversation reset.");
      setTranscript("Conversation reset.");
      setStatus("Ready", "idle");
    };

    speakBtn.onclick = () => {
      speakReplies = !speakReplies;
      speakBtn.textContent = `Speak Replies: ${speakReplies ? "On" : "Off"}`;
      if (!speakReplies && "speechSynthesis" in window) {
        window.speechSynthesis.cancel();
      }
    };

    (async () => {
      try {
        await fetch("/health");
        await postJSON("/api/warm");
        addMessage("aria", "ARIA is ready. Say 'aria' to wake it, or type a message.");
        setTranscript("Say 'aria' to wake the assistant.");
        setStatus("Preparing microphone…", "armed");
      } catch (error) {
        addMessage("aria", `Startup error: ${error.message}`);
        setStatus("Startup error", "error");
      }
      initRecognition();
      if (SpeechRecognition) {
        const ok = await ensureMic();
        if (ok && wakeWordEnabled) {
          scheduleWakeRestart();
        }
      }
    })();
  </script>
</body>
</html>
HTMLEOF

  cat >"${BIN_DIR}/aria-ollama-serve" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
exec "${ollama_bin}" serve
EOF
  chmod +x "${BIN_DIR}/aria-ollama-serve"

  cat >"${BIN_DIR}/aria" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

ARIA_DIR="${HOME}/.aria"
OLLAMA_HOST="${OLLAMA_HOST:-http://127.0.0.1:11434}"

mkdir -p "${ARIA_DIR}"
source "${ARIA_DIR}/venv/bin/activate"
python3 "${ARIA_DIR}/aria.py" "$@"
EOF
  chmod +x "${BIN_DIR}/aria"

  cat >"${APP_DIR}/aria.desktop" <<'EOF'
[Desktop Entry]
Name=ARIA Voice Assistant
Comment=Browser voice assistant for Ollama
Exec=/bin/bash -lc "$HOME/.local/bin/aria"
Icon=audio-input-microphone
Terminal=true
Type=Application
Categories=Utility;
EOF

  cat >"${SYSTEMD_DIR}/ollama.service" <<EOF
[Unit]
Description=Ollama AI Server
After=network.target

[Service]
ExecStart=${BIN_DIR}/aria-ollama-serve
Restart=always
Environment=OLLAMA_HOST=127.0.0.1:11434

[Install]
WantedBy=default.target
EOF

  chown "${TARGET_USER}:${TARGET_GROUP}" \
    "${ARIA_DIR}/aria.py" \
    "${ARIA_DIR}/web/index.html" \
    "${BIN_DIR}/aria-ollama-serve" \
    "${BIN_DIR}/aria" \
    "${APP_DIR}/aria.desktop" \
    "${SYSTEMD_DIR}/ollama.service"

  rm -f "${BIN_DIR}/aria-model-runner" "${ARIA_DIR}/model_terminal.pid"
}

enable_service() {
  log "[7/8] Configuring Ollama user service..."

  if ! have_cmd systemctl; then
    warn "systemctl is not installed. Skipping service setup."
    return
  fi

  run_logged run_as_target systemctl --user daemon-reload || true
  run_logged run_as_target systemctl --user enable ollama.service || true
  run_logged run_as_target systemctl --user restart ollama.service || true
}

configure_shell_path() {
  local zshrc="${TARGET_HOME}/.zshrc"
  local path_line='export PATH="$HOME/.local/bin:$PATH"'
  local target_path=""

  log "[8/9] Ensuring ~/.local/bin is on PATH for zsh..."

  target_path="$(run_as_target env | awk -F= '$1=="PATH"{print $2}')"

  if [[ ":${target_path}:" == *":${TARGET_HOME}/.local/bin:"* ]]; then
    run_logged run_as_target zsh -lc "source ~/.zshrc" || true
    return
  fi

  if [[ ! -f "${zshrc}" ]]; then
    install -m 0644 -o "${TARGET_USER}" -g "${TARGET_GROUP}" /dev/null "${zshrc}"
  fi

  if ! grep -Fqx "${path_line}" "${zshrc}"; then
    printf '\n%s\n' "${path_line}" >>"${zshrc}"
    chown "${TARGET_USER}:${TARGET_GROUP}" "${zshrc}"
  fi

  run_logged run_as_target zsh -lc "source ~/.zshrc" || true
}

print_summary() {
  log "[9/9] Installation complete."
  printf "\n"
  printf "%b━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n" "${YELLOW}" "${NC}"
  printf "%bARIA is ready.%b\n" "${GREEN}" "${NC}"
  printf "  Installed for    : %s\n" "${TARGET_USER}"
  printf "  Installer location: %s\n" "${SCRIPT_DIR}"
  printf "  Runtime directory : %s\n" "${ARIA_DIR}"
  printf "  Start ARIA        : %baria%b\n" "${CYAN}" "${NC}"
  printf "  Test Ollama       : %bollama run %s%b\n" "${CYAN}" "${MODEL_NAME}" "${NC}"
  printf "  Install log       : %s\n" "${INSTALL_LOG}"
  printf "%b━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n" "${YELLOW}" "${NC}"
}

main() {
  printf "%b" "${CYAN}"
  printf "  ╔══════════════════════════════════════════════╗\n"
  printf "  ║   ARIA — Ollama Voice Assistant              ║\n"
  printf "  ║   Linux installer · apt/dnf aware            ║\n"
  printf "  ╚══════════════════════════════════════════════╝\n"
  printf "%b" "${NC}"

  configure_target_context
  detect_distro
  configure_privileges
  configure_package_manager
  prepare_repositories
  install_missing_packages
  install_ollama
  ensure_model
  setup_python_env
  write_runtime_files
  enable_service
  configure_shell_path
  print_summary
}

main "$@"
