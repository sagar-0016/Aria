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
  log "[1/9] Preparing ARIA foundations..."
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

  log "[2/9] Preparing ARIA intelligence modules..."
  for pkg in "${wanted[@]}"; do
    if ! package_installed "${pkg}"; then
      missing+=("${pkg}")
    fi
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    printf "  System essentials are already in place.\n"
    return
  fi

  printf "  Adding missing system pieces: %s\n" "${missing[*]}"
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
  log "[3/9] Checking local AI engine..."

  if have_cmd ollama; then
    printf "  Local AI engine found at %s\n" "$(command -v ollama)"
    return
  fi

  run_logged bash -c 'curl -fsSL https://ollama.com/install.sh | sh' || die "Ollama installation failed."

  if ! have_cmd ollama; then
    die "Ollama was installed but is still not on PATH."
  fi
}

ensure_model() {
  log "[4/9] Downloading local AI brain..."
  ollama pull "${MODEL_NAME}" >>"${INSTALL_LOG}" 2>&1 || die "Failed to pull ${MODEL_NAME}."
}

setup_python_env() {
  log "[5/9] Activating ARIA runtime core..."

  install -d -m 0755 -o "${TARGET_USER}" -g "${TARGET_GROUP}" "${ARIA_DIR}" "${BIN_DIR}" "${APP_DIR}" "${SYSTEMD_DIR}"

  if [[ ! -x "${ARIA_DIR}/venv/bin/python3" ]]; then
    run_as_target python3 -m venv "${ARIA_DIR}/venv"
  fi

  run_logged run_as_target "${ARIA_DIR}/venv/bin/python3" -m pip install --upgrade pip
  ensure_pip_module "${ARIA_DIR}/venv/bin/python3" requests requests
  ensure_pip_module "${ARIA_DIR}/venv/bin/python3" openai openai
  ensure_pip_module "${ARIA_DIR}/venv/bin/python3" google.generativeai google-generativeai
  ensure_pip_module "${ARIA_DIR}/venv/bin/python3" anthropic anthropic
}

write_runtime_files() {
  local ollama_bin
  ollama_bin="$(command -v ollama)"

  log "[6/9] Building ARIA experience layer..."

  install -d -m 0755 -o "${TARGET_USER}" -g "${TARGET_GROUP}" \
    "${ARIA_DIR}/models" \
    "${ARIA_DIR}/tools" \
    "${ARIA_DIR}/web"

  if ! run_logged curl -fsSL "https://github.com/sagar-0016/AI_Assistant/raw/refs/heads/main/listening.mp3" -o "${ARIA_DIR}/web/listening.mp3"; then
    warn "Could not download the listening sound."
  fi
  if ! run_logged curl -fsSL "https://github.com/sagar-0016/AI_Assistant/raw/refs/heads/main/processing_command.mp3" -o "${ARIA_DIR}/web/processing_command.mp3"; then
    warn "Could not download the processing sound."
  fi
  if ! run_logged curl -fsSL "https://github.com/sagar-0016/AI_Assistant/raw/3e304abd5a657e3c465e5b3de00498966e1e32e1/i_am_your_assistant_.mp3" -o "${ARIA_DIR}/web/complete.mp3"; then
    warn "Could not download the completion sound."
  fi
  : > "${ARIA_DIR}/conversation.log"

  cat >"${ARIA_DIR}/config.py" <<'PYEOF'
from pathlib import Path

ARIA_DIR = Path.home() / ".aria"
SETTINGS_PATH = ARIA_DIR / "settings.json"
WEB_ROOT = ARIA_DIR / "web"
INDEX_HTML = WEB_ROOT / "index.html"
HOST = "127.0.0.1"
PORT = 8765
OLLAMA_HOST = "http://127.0.0.1:11434"

DEFAULT_SETTINGS = {
    "selected_model": "auto",
    "wake_word": "aria",
    "speech_replies": True,
    "theme": "light",
    "auto_route": True,
    "api_keys": {
        "openai": "",
        "gemini": "",
        "anthropic": "",
    },
}

SUPPORTED_MODELS = {
    "qwen:1.8b": {
        "label": "Qwen 1.8B",
        "provider": "ollama",
        "module": "ollama_model.py",
        "type": "local",
        "badge": ["LOCAL", "FREE"],
        "pricing": "FREE",
    },
    "qwen2:3b": {
        "label": "Qwen2 3B",
        "provider": "ollama",
        "module": "ollama_model.py",
        "type": "local",
        "badge": ["LOCAL", "FREE"],
        "pricing": "FREE",
    },
    "llama3": {
        "label": "Llama 3",
        "provider": "ollama",
        "module": "ollama_model.py",
        "type": "local",
        "badge": ["LOCAL", "FREE"],
        "pricing": "FREE",
    },
    "phi3": {
        "label": "Phi-3",
        "provider": "ollama",
        "module": "ollama_model.py",
        "type": "local",
        "badge": ["LOCAL", "FREE"],
        "pricing": "FREE",
    },
    "gemma": {
        "label": "Gemma",
        "provider": "ollama",
        "module": "ollama_model.py",
        "type": "local",
        "badge": ["LOCAL", "FREE"],
        "pricing": "FREE",
    },
    "gpt-4o-mini": {
        "label": "GPT-4o mini",
        "provider": "openai",
        "module": "openai_model.py",
        "type": "cloud",
        "badge": ["LOW COST"],
        "pricing": "LOW COST",
        "key_name": "openai",
        "connect_label": "OpenAI API key",
        "connect_url": "https://platform.openai.com/api-keys",
    },
    "gemini-1.5-flash": {
        "label": "Gemini 1.5 Flash",
        "provider": "gemini",
        "module": "gemini_model.py",
        "type": "cloud",
        "badge": ["FREE"],
        "pricing": "FREE tier available",
        "key_name": "gemini",
        "connect_label": "Gemini API key",
        "connect_url": "https://makersuite.google.com/app/apikey",
    },
    "gemini-1.5-flash-8b": {
        "label": "Gemini 1.5 Flash 8B",
        "provider": "gemini",
        "module": "gemini_model.py",
        "type": "cloud",
        "badge": ["FREE"],
        "pricing": "FREE tier available",
        "key_name": "gemini",
        "connect_label": "Gemini API key",
        "connect_url": "https://makersuite.google.com/app/apikey",
    },
    "claude-haiku": {
        "label": "Claude Haiku",
        "provider": "anthropic",
        "module": "claude_model.py",
        "type": "cloud",
        "badge": ["LOW COST"],
        "pricing": "LOW COST",
        "key_name": "anthropic",
        "connect_label": "Anthropic API key",
        "connect_url": "https://console.anthropic.com/",
        "api_name": "claude-3-haiku-20240307",
    },
}
PYEOF

  cat >"${ARIA_DIR}/models.py" <<'PYEOF'
class BaseModel:
    name = ""
    provider = ""
    type = "local"

    def __init__(self, model_config, settings_manager):
        self.config = model_config
        self.settings_manager = settings_manager
        self.name = model_config["id"]
        self.provider = model_config["provider"]
        self.type = model_config["type"]

    def is_available(self):
        raise NotImplementedError

    def setup(self):
        raise NotImplementedError

    def chat(self, messages):
        raise NotImplementedError

    def validate(self, key=None):
        return False, "Validation not implemented"
PYEOF

  cat >"${ARIA_DIR}/settings_manager.py" <<'PYEOF'
import json
from pathlib import Path

from config import DEFAULT_SETTINGS, SETTINGS_PATH


class SettingsManager:
    def __init__(self):
        self.path = Path(SETTINGS_PATH)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._settings = self._load()

    def _load(self):
        if not self.path.exists():
            self.save(DEFAULT_SETTINGS.copy())
        try:
            with self.path.open("r", encoding="utf-8") as handle:
                data = json.load(handle)
        except Exception:
            data = {}
        merged = DEFAULT_SETTINGS.copy()
        merged["api_keys"] = DEFAULT_SETTINGS["api_keys"].copy()
        merged["api_keys"].update(data.get("api_keys", {}))
        for key, value in data.items():
            if key != "api_keys":
                merged[key] = value
        return merged

    def save(self, settings):
        with self.path.open("w", encoding="utf-8") as handle:
            json.dump(settings, handle, indent=2)
        self._settings = settings
        return self._settings

    def get(self):
        return self._settings

    def update(self, patch):
        current = self.get().copy()
        current["api_keys"] = current["api_keys"].copy()
        if "api_keys" in patch:
            current["api_keys"].update(patch["api_keys"])
        for key, value in patch.items():
            if key != "api_keys":
                current[key] = value
        return self.save(current)

    def api_key(self, provider):
        return self._settings.get("api_keys", {}).get(provider, "")
PYEOF

  cat >"${ARIA_DIR}/models/ollama_model.py" <<'PYEOF'
import re
import subprocess

import requests

from config import OLLAMA_HOST
from models import BaseModel


class OllamaModel(BaseModel):
    type = "local"
    provider = "ollama"

    def is_available(self):
        try:
            requests.get(f"{OLLAMA_HOST}/api/tags", timeout=2).raise_for_status()
            return self.name in self.installed_models()
        except Exception:
            return False

    def setup(self):
        subprocess.run(["ollama", "pull", self.name], check=True)

    def chat(self, messages):
        payload = {"model": self.name, "messages": messages, "stream": False, "options": {"temperature": 0.3}}
        response = requests.post(f"{OLLAMA_HOST}/api/chat", json=payload, timeout=90)
        response.raise_for_status()
        return response.json()["message"]["content"]

    def validate(self, key=None):
        try:
            requests.get(f"{OLLAMA_HOST}/api/tags", timeout=2).raise_for_status()
            return True, "Connected"
        except Exception as exc:
            return False, str(exc)

    @staticmethod
    def installed_models():
        try:
            output = subprocess.check_output(["ollama", "list"], text=True, stderr=subprocess.STDOUT)
        except Exception:
            return []
        models = []
        for line in output.splitlines()[1:]:
            match = re.split(r"\s{2,}", line.strip())
            if match and match[0]:
                models.append(match[0])
        return models
PYEOF

  cat >"${ARIA_DIR}/models/openai_model.py" <<'PYEOF'
from openai import OpenAI

from models import BaseModel


class OpenAIModel(BaseModel):
    type = "cloud"
    provider = "openai"

    def _client(self, key=None):
        api_key = key or self.settings_manager.api_key("openai")
        return OpenAI(api_key=api_key)

    def is_available(self):
        return bool(self.settings_manager.api_key("openai"))

    def setup(self):
        return True

    def chat(self, messages):
        client = self._client()
        response = client.chat.completions.create(model=self.name, messages=messages)
        return response.choices[0].message.content

    def validate(self, key=None):
        try:
            self._client(key).models.list()
            return True, "Connected"
        except Exception as exc:
            return False, str(exc)
PYEOF

  cat >"${ARIA_DIR}/models/gemini_model.py" <<'PYEOF'
import google.generativeai as genai

from models import BaseModel


class GeminiModel(BaseModel):
    type = "cloud"
    provider = "gemini"

    def _configure(self, key=None):
        api_key = key or self.settings_manager.api_key("gemini")
        genai.configure(api_key=api_key)
        return genai.GenerativeModel(self.name)

    def is_available(self):
        return bool(self.settings_manager.api_key("gemini"))

    def setup(self):
        return True

    def chat(self, messages):
        model = self._configure()
        prompt = "\n".join(f"{item['role'].upper()}: {item['content']}" for item in messages)
        response = model.generate_content(prompt)
        return response.text

    def validate(self, key=None):
        try:
            genai.configure(api_key=key or self.settings_manager.api_key("gemini"))
            list(genai.list_models())
            return True, "Connected"
        except Exception as exc:
            return False, str(exc)
PYEOF

  cat >"${ARIA_DIR}/models/claude_model.py" <<'PYEOF'
from anthropic import Anthropic

from models import BaseModel


class ClaudeModel(BaseModel):
    type = "cloud"
    provider = "anthropic"

    def _client(self, key=None):
        api_key = key or self.settings_manager.api_key("anthropic")
        return Anthropic(api_key=api_key)

    def is_available(self):
        return bool(self.settings_manager.api_key("anthropic"))

    def setup(self):
        return True

    def chat(self, messages):
        client = self._client()
        model_name = self.config.get("api_name", self.name)
        system = next((item["content"] for item in messages if item["role"] == "system"), "")
        user_messages = [item for item in messages if item["role"] != "system"]
        response = client.messages.create(
            model=model_name,
            max_tokens=1024,
            system=system,
            messages=user_messages,
        )
        return "".join(block.text for block in response.content if getattr(block, "type", "") == "text")

    def validate(self, key=None):
        try:
            model_name = self.config.get("api_name", self.name)
            self._client(key).messages.create(
                model=model_name,
                max_tokens=16,
                messages=[{"role": "user", "content": "ping"}],
            )
            return True, "Connected"
        except Exception as exc:
            return False, str(exc)
PYEOF

  cat >"${ARIA_DIR}/router.py" <<'PYEOF'
import importlib.util
import socket
from pathlib import Path

from config import SUPPORTED_MODELS


def internet_available():
    try:
        socket.create_connection(("8.8.8.8", 53), timeout=2)
        return True
    except Exception:
        return False


class ModelRouter:
    def __init__(self, settings_manager, local_model_detector):
        self.settings_manager = settings_manager
        self.local_model_detector = local_model_detector
        self.root = Path.home() / ".aria"

    def _load_provider_class(self, module_filename):
        module_path = self.root / "models" / module_filename
        module_name = module_filename.replace(".py", "")
        spec = importlib.util.spec_from_file_location(module_name, module_path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        for attr in dir(module):
            if attr.endswith("Model"):
                candidate = getattr(module, attr)
                if attr != "BaseModel":
                    return candidate
        raise RuntimeError(f"No model class found in {module_filename}")

    def available_models(self):
        models = {}
        for model_id, meta in SUPPORTED_MODELS.items():
            config = meta.copy()
            config["id"] = model_id
            cls = self._load_provider_class(meta["module"])
            models[model_id] = cls(config, self.settings_manager)
        return models

    def _is_complex(self, text):
        text = text.lower()
        keywords = [
            "write code",
            "summarize",
            "article",
            "physics",
            "compare",
            "analyze",
            "design",
            "architecture",
            "explain in detail",
            "research",
        ]
        return any(keyword in text for keyword in keywords) or len(text.split()) > 18

    def select(self, text):
        online = internet_available()
        settings = self.settings_manager.get()
        models = self.available_models()
        selected = settings.get("selected_model", "auto")
        installed = set(self.local_model_detector())

        if not online:
            for candidate in ["qwen:1.8b", "qwen2:3b", "phi3", "llama3", "gemma"]:
                if candidate in installed:
                    return models[candidate], True

        if selected != "auto" and selected in models:
            return models[selected], False

        complex_request = self._is_complex(text)
        if online and complex_request:
            for candidate in ["gpt-4o-mini", "gemini-1.5-flash", "claude-haiku", "gemini-1.5-flash-8b"]:
                model = models[candidate]
                if model.is_available():
                    return model, False

        for candidate in ["qwen:1.8b", "qwen2:3b", "phi3", "llama3", "gemma"]:
            if candidate in installed:
                return models[candidate], False

        if online:
            for candidate in ["gemini-1.5-flash", "gpt-4o-mini", "claude-haiku"]:
                model = models[candidate]
                if model.is_available():
                    return model, False

        return models["qwen:1.8b"], not online

    def chat(self, messages, text):
        model, offline = self.select(text)
        try:
            reply = model.chat(messages)
            return reply, model, offline
        except Exception:
            fallback = self.available_models()["qwen:1.8b"]
            reply = fallback.chat(messages)
            return reply, fallback, True
PYEOF

  cat >"${ARIA_DIR}/tools/__init__.py" <<'PYEOF'
"""ARIA tool execution layer."""
PYEOF

  cat >"${ARIA_DIR}/tools/browser_tools.py" <<'PYEOF'
import shutil
import subprocess
import webbrowser
from pathlib import Path


class BrowserTools:
    APP_MAP = {
        "browser": ["xdg-open", "https://www.google.com"],
        "youtube": ["xdg-open", "https://www.youtube.com"],
        "github": ["xdg-open", "https://github.com"],
        "chatgpt": ["xdg-open", "https://chatgpt.com"],
        "google": ["xdg-open", "https://www.google.com"],
        "settings": ["gnome-control-center"],
        "files": ["xdg-open", "."],
        "terminal": ["x-terminal-emulator"],
        "documents": ["xdg-open", "~/Documents"],
        "downloads": ["xdg-open", "~/Downloads"],
    }

    def available(self):
        return True

    def open_target(self, target):
        command = self.APP_MAP.get(target)
        if command and shutil.which(command[0]):
            expanded = [str(Path(part).expanduser()) if part.startswith("~") else part for part in command]
            subprocess.Popen(expanded)
            return {"ok": True, "message": f"Opened {target}.", "items": [], "execution": {"kind": "command", "value": expanded}}
        if target.startswith("http"):
            webbrowser.open(target)
            return {"ok": True, "message": f"Opened {target}.", "items": [], "execution": {"kind": "url", "value": target}}
        return {"ok": False, "message": f"I could not open {target} on this system.", "items": [], "execution": {"kind": "target", "value": target}}

    def search_url(self, query):
        url = f"https://www.google.com/search?q={query.replace(' ', '+')}"
        webbrowser.open(url)
        return {"ok": True, "message": f"Opened a browser search for {query}.", "items": [{"title": query, "url": url, "snippet": "Opened in your browser."}], "execution": {"kind": "url", "value": url}}
PYEOF

  cat >"${ARIA_DIR}/tools/system_tools.py" <<'PYEOF'
import datetime
import platform
import shutil
import socket
import subprocess


class SystemTools:
    SAFE_COMMANDS = {
        "disk": ["df", "-h"],
        "memory": ["free", "-h"],
        "uptime": ["uptime"],
        "whoami": ["whoami"],
        "pwd": ["pwd"],
    }

    def info(self, topic):
        if topic == "time":
            return {"ok": True, "message": datetime.datetime.now().strftime("Current time: %I:%M %p"), "items": [], "execution": {"kind": "builtin", "value": "datetime.now().strftime('%I:%M %p')"}}
        if topic == "date":
            return {"ok": True, "message": datetime.datetime.now().strftime("Today is %A, %B %d, %Y"), "items": [], "execution": {"kind": "builtin", "value": "datetime.now().strftime('%A, %B %d, %Y')"}}
        if topic == "system":
            return {"ok": True, "message": f"{platform.system()} {platform.release()} on {socket.gethostname()}", "items": [], "execution": {"kind": "builtin", "value": "platform.system()/platform.release()/socket.gethostname()"}}
        command = self.SAFE_COMMANDS.get(topic)
        if not command:
            return {"ok": False, "message": "That system action is not available.", "items": [], "execution": {"kind": "topic", "value": topic}}
        if not shutil.which(command[0]):
            return {"ok": False, "message": f"{command[0]} is not installed.", "items": [], "execution": {"kind": "command", "value": command}}
        result = subprocess.run(command, capture_output=True, text=True, timeout=8)
        text = (result.stdout or result.stderr).strip()
        return {"ok": result.returncode == 0, "message": text[:1200] or "Done.", "items": [], "execution": {"kind": "command", "value": command}}
PYEOF

  cat >"${ARIA_DIR}/tools/file_tools.py" <<'PYEOF'
from pathlib import Path


class FileTools:
    def __init__(self):
        self.root = Path.home()

    def _resolve(self, raw_path):
        candidate = (self.root / raw_path).expanduser().resolve() if not raw_path.startswith("/") else Path(raw_path).expanduser().resolve()
        if self.root not in candidate.parents and candidate != self.root:
            raise ValueError("Access outside the home directory is blocked.")
        return candidate

    def list_dir(self, raw_path="."):
        target = self._resolve(raw_path)
        if not target.exists() or not target.is_dir():
            return {"ok": False, "message": "That folder does not exist.", "items": [], "execution": {"kind": "path", "value": str(target)}}
        items = sorted(child.name + ("/" if child.is_dir() else "") for child in target.iterdir())
        return {"ok": True, "message": "\n".join(items[:200]) or "Folder is empty.", "items": [{"title": item, "url": "", "snippet": "Folder entry"} for item in items[:25]], "execution": {"kind": "path", "value": str(target)}}

    def read_file(self, raw_path):
        target = self._resolve(raw_path)
        if not target.exists() or not target.is_file():
            return {"ok": False, "message": "That file does not exist.", "items": [], "execution": {"kind": "path", "value": str(target)}}
        return {"ok": True, "message": target.read_text(encoding="utf-8", errors="replace")[:4000], "items": [{"title": target.name, "url": str(target), "snippet": "Read from local file"}], "execution": {"kind": "path", "value": str(target)}}

    def file_info(self, raw_path):
        target = self._resolve(raw_path)
        if not target.exists():
            return {"ok": False, "message": "That path does not exist.", "items": [], "execution": {"kind": "path", "value": str(target)}}
        kind = "directory" if target.is_dir() else "file"
        return {"ok": True, "message": f"{target.name} is a {kind} at {target}", "items": [{"title": target.name, "url": str(target), "snippet": kind}], "execution": {"kind": "path", "value": str(target)}}

    def make_dir(self, raw_path):
        target = self._resolve(raw_path)
        target.mkdir(parents=True, exist_ok=True)
        return {"ok": True, "message": f"Created folder {target}.", "items": [{"title": target.name, "url": str(target), "snippet": "Folder created"}], "execution": {"kind": "path", "value": str(target)}}
PYEOF

  cat >"${ARIA_DIR}/tools/search_tools.py" <<'PYEOF'
import requests

from router import internet_available


class SearchTools:
    def search(self, query):
        if not internet_available():
            return {"ok": False, "message": "Offline Mode. Using local AI brain.", "items": [], "execution": {"kind": "request", "value": "offline"}}
        try:
            request_url = "https://api.duckduckgo.com/"
            response = requests.get(
                request_url,
                params={"q": query, "format": "json", "no_html": 1, "skip_disambig": 1},
                timeout=8,
            )
            response.raise_for_status()
            payload = response.json()
            parts = []
            if payload.get("AbstractText"):
                parts.append(payload["AbstractText"])
            if payload.get("Answer"):
                parts.append(payload["Answer"])
            related = payload.get("RelatedTopics", [])
            for item in related[:3]:
                if isinstance(item, dict) and item.get("Text"):
                    parts.append(item["Text"])
            cards = []
            for item in related[:5]:
                if isinstance(item, dict) and item.get("Text"):
                    cards.append({"title": item["Text"].split(" - ")[0], "url": item.get("FirstURL", ""), "snippet": item["Text"]})
            return {"ok": True, "message": "\n".join(parts[:4])[:1600] or "No search result summary was returned.", "items": cards, "execution": {"kind": "request", "value": f"{request_url}?q={query}"}}
        except Exception as exc:
            return {"ok": False, "message": f"Search failed: {exc}", "items": [], "execution": {"kind": "request", "value": f"duckduckgo:{query}"}}
PYEOF

  cat >"${ARIA_DIR}/tool_executor.py" <<'PYEOF'
import json
import re

from tools.browser_tools import BrowserTools
from tools.file_tools import FileTools
from tools.search_tools import SearchTools
from tools.system_tools import SystemTools


class ToolExecutor:
    def __init__(self):
        self.browser = BrowserTools()
        self.files = FileTools()
        self.search = SearchTools()
        self.system = SystemTools()

    def available_tools(self):
        return {
            "browser": "Open websites, desktop apps, or browser searches.",
            "system": "Read safe system information like time, date, memory, disk usage, or working directory.",
            "files": "List folders, inspect files, read text files, and create folders inside the home directory.",
            "search": "Run internet searches when online.",
        }

    def schema(self):
        return {
            "browser": {
                "actions": {
                    "open_target": {"target": "browser|youtube|github|chatgpt|google|settings|files|terminal|documents|downloads"},
                    "search_url": {"query": "search query string"},
                }
            },
            "system": {
                "actions": {
                    "info": {"topic": "time|date|disk|memory|uptime|whoami|pwd|system"},
                }
            },
            "files": {
                "actions": {
                    "list_dir": {"path": "relative or home-absolute path"},
                    "read_file": {"path": "relative or home-absolute path"},
                    "file_info": {"path": "relative or home-absolute path"},
                    "make_dir": {"path": "relative or home-absolute path"},
                }
            },
            "search": {
                "actions": {
                    "search": {"query": "internet search query"},
                }
            },
        }

    def prompt_block(self):
        return (
            "Available tools are described as JSON. "
            "Only request a tool when it materially helps and stays within the allowed action names.\n"
            f"{json.dumps(self.schema(), indent=2)}\n"
            "For open requests, always use tool='browser'. "
            "Use action='open_target' for known destinations like youtube, github, chatgpt, google, settings, files, terminal, documents, or downloads. "
            "Use action='search_url' for unknown sites, raw domains, or web searches. "
            "Never invent tool names like 'open' or action names like 'open'.\n"
            "If you need tools, respond with JSON only in this exact format:\n"
            '{"tool_calls":[{"tool":"search","action":"search","query":"latest fedora release"}]}\n'
            "If no tool is needed, answer normally in plain text."
        )

    def _normalize_browser_target(self, value):
        target = (value or "").strip().lower()
        compact = target.replace(" ", "")
        aliases = {
            "youtube": "youtube",
            "github": "github",
            "chatgpt": "chatgpt",
            "chat gpt": "chatgpt",
            "google": "google",
            "google.com": "google",
            "settings": "settings",
            "files": "files",
            "file manager": "files",
            "terminal": "terminal",
            "documents": "documents",
            "downloads": "downloads",
            "browser": "browser",
        }
        if target in aliases:
            return aliases[target], None
        if compact in aliases:
            return aliases[compact], None
        if "." in compact:
            cleaned = compact
            if not cleaned.startswith(("http://", "https://")):
                cleaned = f"https://{cleaned}"
            return None, cleaned
        return None, target

    def _normalize_call(self, call):
        tool_name = str(call.get("tool", "")).strip().lower()
        action = str(call.get("action", "")).strip().lower()
        payload = dict(call)

        if tool_name in {"open", "browser_open", "site"}:
            target = str(payload.get("target") or payload.get("url") or payload.get("site") or payload.get("query") or "").strip()
            normalized_target, fallback_url = self._normalize_browser_target(target)
            payload["tool"] = "browser"
            if normalized_target:
                payload["action"] = "open_target"
                payload["target"] = normalized_target
                payload.pop("url", None)
                payload.pop("query", None)
            else:
                payload["action"] = "search_url"
                payload["query"] = fallback_url or target
                payload.pop("url", None)
                payload.pop("target", None)
            return payload

        if tool_name == "browser" and action == "open_target":
            target = str(payload.get("target", "")).strip()
            normalized_target, fallback_url = self._normalize_browser_target(target)
            if normalized_target:
                payload["target"] = normalized_target
            elif fallback_url:
                payload["action"] = "search_url"
                payload["query"] = fallback_url
                payload.pop("target", None)
            return payload

        if tool_name == "browser" and action in {"open", "go", "visit"}:
            target = str(payload.get("target") or payload.get("url") or payload.get("query") or "").strip()
            normalized_target, fallback_url = self._normalize_browser_target(target)
            payload["action"] = "open_target" if normalized_target else "search_url"
            if normalized_target:
                payload["target"] = normalized_target
                payload.pop("url", None)
                payload.pop("query", None)
            else:
                payload["query"] = fallback_url or target
                payload.pop("url", None)
                payload.pop("target", None)
            return payload

        return payload

    def execute_call(self, call):
        call = self._normalize_call(call)
        tool_name = str(call.get("tool", "")).strip()
        action = str(call.get("action", "")).strip()
        payload = dict(call)
        payload.pop("tool", None)
        payload.pop("action", None)

        try:
            if tool_name == "browser":
                if action == "open_target":
                    result = self.browser.open_target(str(payload.get("target", "")).strip())
                elif action == "search_url":
                    result = self.browser.search_url(str(payload.get("query", "")).strip())
                else:
                    result = {"ok": False, "message": "That browser action is not available.", "items": []}
            elif tool_name == "system":
                if action == "info":
                    result = self.system.info(str(payload.get("topic", "")).strip())
                else:
                    result = {"ok": False, "message": "That system action is not available.", "items": []}
            elif tool_name == "files":
                path = str(payload.get("path", "")).strip()
                if action == "list_dir":
                    result = self.files.list_dir(path or ".")
                elif action == "read_file":
                    result = self.files.read_file(path)
                elif action == "file_info":
                    result = self.files.file_info(path)
                elif action == "make_dir":
                    result = self.files.make_dir(path)
                else:
                    result = {"ok": False, "message": "That file action is not available.", "items": []}
            elif tool_name == "search":
                if action == "search":
                    result = self.search.search(str(payload.get("query", "")).strip())
                else:
                    result = {"ok": False, "message": "That search action is not available.", "items": []}
            else:
                result = {"ok": False, "message": "Unknown tool requested.", "items": []}
        except Exception as exc:
            result = {"ok": False, "message": str(exc), "items": []}

        return {
            "used": True,
            "tool": tool_name or "unknown",
            "action": action or "unknown",
            "input": payload,
            "result": result,
        }

    def execute_plan(self, tool_calls):
        events = []
        for call in tool_calls[:4]:
            if not isinstance(call, dict):
                continue
            events.append(self.execute_call(call))
        return events

    def route(self, text):
        lowered = text.lower().strip()

        if any(phrase in lowered for phrase in ["what time", "current time", "time now"]):
            return self.execute_call({"tool": "system", "action": "info", "topic": "time"})
        if any(phrase in lowered for phrase in ["what date", "today's date", "today date"]):
            return self.execute_call({"tool": "system", "action": "info", "topic": "date"})
        if "disk usage" in lowered or "storage" in lowered:
            return self.execute_call({"tool": "system", "action": "info", "topic": "disk"})
        if "memory usage" in lowered or "ram" in lowered:
            return self.execute_call({"tool": "system", "action": "info", "topic": "memory"})
        if "system info" in lowered:
            return self.execute_call({"tool": "system", "action": "info", "topic": "system"})

        if any(phrase in lowered for phrase in ["open browser", "open chrome", "open firefox"]):
            return self.execute_call({"tool": "browser", "action": "open_target", "target": "browser"})
        if "open youtube" in lowered:
            return self.execute_call({"tool": "browser", "action": "open_target", "target": "youtube"})
        if "open github" in lowered:
            return self.execute_call({"tool": "browser", "action": "open_target", "target": "github"})
        if "open chatgpt" in lowered or "open chat gpt" in lowered:
            return self.execute_call({"tool": "browser", "action": "open_target", "target": "chatgpt"})
        if "open google" in lowered:
            return self.execute_call({"tool": "browser", "action": "open_target", "target": "google"})
        if "open settings" in lowered:
            return self.execute_call({"tool": "browser", "action": "open_target", "target": "settings"})
        if "open files" in lowered or "open file manager" in lowered:
            return self.execute_call({"tool": "browser", "action": "open_target", "target": "files"})
        if "open terminal" in lowered:
            return self.execute_call({"tool": "browser", "action": "open_target", "target": "terminal"})
        if "open documents" in lowered:
            return self.execute_call({"tool": "browser", "action": "open_target", "target": "documents"})
        if "open downloads" in lowered:
            return self.execute_call({"tool": "browser", "action": "open_target", "target": "downloads"})
        match = re.search(r"open\s+([a-z0-9][a-z0-9\.\-]+\.[a-z]{2,})(?:\s|$)", lowered)
        if match:
            return self.execute_call({"tool": "browser", "action": "search_url", "query": match.group(1).strip()})

        match = re.search(r"(?:search|look up|find)\s+(.+)", lowered)
        if match:
            query = match.group(1).strip()
            if any(word in lowered for word in ["browser", "web", "online"]) or lowered.startswith("search "):
                return self.execute_call({"tool": "search", "action": "search", "query": query})

        match = re.search(r"(?:list files in|list folder|show files in)\s+(.+)", lowered)
        if match:
            return self.execute_call({"tool": "files", "action": "list_dir", "path": match.group(1).strip()})
        match = re.search(r"(?:read file|open file|show file)\s+(.+)", lowered)
        if match:
            return self.execute_call({"tool": "files", "action": "read_file", "path": match.group(1).strip()})
        match = re.search(r"(?:details for|file info for|inspect)\s+(.+)", lowered)
        if match:
            return self.execute_call({"tool": "files", "action": "file_info", "path": match.group(1).strip()})
        match = re.search(r"(?:create folder|make folder|create directory|make directory)\s+(.+)", lowered)
        if match:
            return self.execute_call({"tool": "files", "action": "make_dir", "path": match.group(1).strip()})

        return {"used": False}
PYEOF

  cat >"${ARIA_DIR}/aria.py" <<'PYEOF'
#!/usr/bin/env python3
import json
import mimetypes
import os
import re
import signal
import shutil
import subprocess
import threading
import webbrowser
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import requests

from config import HOST, INDEX_HTML, OLLAMA_HOST, PORT, SUPPORTED_MODELS
from router import ModelRouter, internet_available
from settings_manager import SettingsManager
from tool_executor import ToolExecutor

ARIA_DIR = Path.home() / ".aria"
CONVERSATION_LOG = ARIA_DIR / "conversation.log"
SYSTEM_PROMPT = (
    "You are ARIA, a polished multi-model assistant. "
    "Answer clearly, stay concise unless depth is requested, and keep responses useful. "
    "When tool output is present, rely on it directly instead of inventing details. "
    "Never claim an action succeeded unless the tool result says it did. "
    "If something is missing, such as an API key, internet access, a local model install, or a safe permission boundary, say exactly what is missing and what the user should do next. "
    "If the user input is incomplete or ambiguous, ask one short clarifying question instead of guessing."
)
TOOL_SYSTEM_PROMPT = (
    "You are deciding whether ARIA should use tools before answering. "
    "Prefer tools for internet lookups, opening desktop targets, safe system questions, and home-directory file tasks. "
    "Do not invent tool names or actions. "
    "Return plain text if no tool is needed. "
)
SETTINGS = SettingsManager()
ROUTER = ModelRouter(SETTINGS, lambda: detect_installed_local_models())
TOOLS = ToolExecutor()
CHAT_HISTORY = []
INSTALL_STATUS = {"running": False, "model": "", "progress": "", "percent": 0, "done": False, "error": ""}
STATUS_LOCK = threading.Lock()


def detect_installed_local_models():
    try:
        output = subprocess.check_output(["ollama", "list"], text=True, stderr=subprocess.STDOUT)
    except Exception:
        return []
    models = []
    for line in output.splitlines()[1:]:
        parts = re.split(r"\s{2,}", line.strip())
        if parts and parts[0]:
            models.append(parts[0])
    return models


def ollama_available():
    return bool(shutil.which("ollama"))


def update_install_status(**patch):
    with STATUS_LOCK:
        INSTALL_STATUS.update(patch)


def current_install_status():
    with STATUS_LOCK:
        return INSTALL_STATUS.copy()


def install_local_model(model_name):
    update_install_status(running=True, model=model_name, progress="Starting download…", percent=0, done=False, error="")
    try:
        process = subprocess.Popen(
            ["ollama", "pull", model_name],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        for raw_line in process.stdout:
            line = raw_line.strip()
            percent_match = re.search(r"(\d+)%", line)
            percent = int(percent_match.group(1)) if percent_match else current_install_status()["percent"]
            update_install_status(progress=line or "Downloading local AI brain…", percent=percent)
        code = process.wait()
        if code != 0:
            raise RuntimeError(f"ollama pull exited with code {code}")
        update_install_status(running=False, done=True, progress="Local model is ready.", percent=100)
    except Exception as exc:
        update_install_status(running=False, done=False, error=str(exc), progress="Model install failed.")


def validate_provider_connection(provider, api_key=None):
    for model_id, meta in SUPPORTED_MODELS.items():
        if meta["provider"] == provider:
            model = ROUTER.available_models()[model_id]
            return model.validate(api_key)
    return False, "Provider not found"


def build_messages(text):
    messages = [{"role": "system", "content": SYSTEM_PROMPT}] + CHAT_HISTORY[-10:]
    messages.append({"role": "user", "content": text})
    return messages


def build_messages_with_tool(text, tool_name, tool_result):
    messages = build_messages(text)
    messages.append(
        {
            "role": "system",
            "content": f"Tool `{tool_name}` result:\n{tool_result}",
        }
    )
    return messages


def build_tool_selection_messages(text):
    return [
        {"role": "system", "content": TOOL_SYSTEM_PROMPT},
        {"role": "system", "content": TOOLS.prompt_block()},
        {"role": "user", "content": text},
    ]


def build_messages_with_tool_events(text, tool_events):
    messages = build_messages(text)
    for event in tool_events:
        summary = json.dumps(
            {
                "tool": event.get("tool"),
                "action": event.get("action"),
                "ok": event.get("result", {}).get("ok"),
                "message": event.get("result", {}).get("message"),
            },
            ensure_ascii=True,
        )
        messages.append({"role": "system", "content": f"Tool result: {summary}"})
    return messages


def extract_tool_plan(reply_text):
    if not reply_text:
        return []
    candidate = reply_text.strip()
    fenced = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", candidate, re.DOTALL)
    if fenced:
        candidate = fenced.group(1)
    try:
        parsed = json.loads(candidate)
    except Exception:
        return []
    tool_calls = parsed.get("tool_calls", [])
    return tool_calls if isinstance(tool_calls, list) else []


def flatten_tool_cards(tool_events):
    cards = []
    for event in tool_events:
        result = event.get("result", {})
        for item in result.get("items", [])[:8]:
            if not isinstance(item, dict):
                continue
            cards.append(
                {
                    "tool": event.get("tool", ""),
                    "action": event.get("action", ""),
                    "title": str(item.get("title", "")),
                    "url": str(item.get("url", "")),
                    "snippet": str(item.get("snippet", "")),
                }
            )
    return cards[:12]


def log_interaction(user_text, reply_text, model_name, tool_events):
    try:
        execution = []
        for event in tool_events:
            result = event.get("result", {})
            execution.append(
                {
                    "tool": event.get("tool"),
                    "action": event.get("action"),
                    "input": event.get("input", {}),
                    "execution": result.get("execution", {}),
                    "ok": result.get("ok"),
                }
            )
        entry = {
            "user": user_text,
            "reply": reply_text,
            "model": model_name,
            "tool_events": tool_events,
            "execution_details": execution,
        }
        with CONVERSATION_LOG.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(entry, ensure_ascii=True) + "\n")
    except Exception:
        pass


def active_model_snapshot():
    selected = SETTINGS.get().get("selected_model", "auto")
    resolved, offline = ROUTER.select("status ping")
    meta = SUPPORTED_MODELS[resolved.name]
    if selected != "auto" and selected in SUPPORTED_MODELS:
        chosen = SUPPORTED_MODELS[selected]
    else:
        chosen = meta
    return {
        "selected_model": selected,
        "active_model": resolved.name,
        "label": meta["label"],
        "provider": meta["provider"],
        "type": meta["type"],
        "status": "Running" if meta["type"] == "local" else ("Connected" if resolved.is_available() else "Not Connected"),
        "offline_mode": offline or not internet_available(),
        "display_selected_label": "Smart" if selected == "auto" else chosen["label"],
    }


def serializable_models():
    installed = set(detect_installed_local_models())
    items = []
    providers = ROUTER.available_models()
    for model_id, meta in SUPPORTED_MODELS.items():
        provider = providers[model_id]
        items.append(
            {
                "id": model_id,
                "label": meta["label"],
                "provider": meta["provider"],
                "type": meta["type"],
                "pricing": meta["pricing"],
                "badge": meta["badge"],
                "installed": model_id in installed if meta["type"] == "local" else provider.is_available(),
                "connected": provider.is_available(),
                "connect_label": meta.get("connect_label", ""),
                "connect_url": meta.get("connect_url", ""),
            }
        )
    items.insert(
        0,
        {
            "id": "auto",
            "label": "Smart Router",
            "provider": "router",
            "type": "hybrid",
            "pricing": "AUTO",
            "badge": ["AUTO"],
            "installed": True,
            "connected": True,
            "connect_label": "",
            "connect_url": "",
        },
    )
    return items


def status_payload():
    settings = SETTINGS.get()
    active = active_model_snapshot()
    installed = detect_installed_local_models()
    provider_status = {}
    for provider in ["openai", "gemini", "anthropic"]:
        ok, _ = validate_provider_connection(provider, settings["api_keys"].get(provider, ""))
        provider_status[provider] = ok
    return {
        "settings": settings,
        "active": active,
        "models": serializable_models(),
        "installed_local_models": installed,
        "internet": internet_available(),
        "provider_status": provider_status,
        "install_status": current_install_status(),
        "ollama_available": ollama_available(),
        "tools": TOOLS.available_tools(),
    }


def warm_local_model():
    active = active_model_snapshot()
    if active["type"] != "local":
        return
    try:
        requests.post(
            f"{OLLAMA_HOST}/api/generate",
            json={"model": active["active_model"], "prompt": "Ready.", "stream": False, "keep_alive": "30m"},
            timeout=30,
        ).raise_for_status()
    except Exception:
        pass


class AriaHandler(BaseHTTPRequestHandler):
    def _send_json(self, payload, status=HTTPStatus.OK):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            return

    def _send_html(self):
        body = INDEX_HTML.read_bytes()
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            return

    def log_message(self, fmt, *args):
        return

    def do_GET(self):
        if self.path in {"/", "/index.html"}:
            self._send_html()
            return
        if self.path.startswith("/") and ".." not in self.path:
            candidate = (INDEX_HTML.parent / self.path.lstrip("/")).resolve()
            if candidate.exists() and candidate.is_file() and candidate.parent == INDEX_HTML.parent.resolve():
                body = candidate.read_bytes()
                self.send_response(HTTPStatus.OK)
                self.send_header("Content-Type", mimetypes.guess_type(candidate.name)[0] or "application/octet-stream")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                try:
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    return
                return
        if self.path == "/health":
            self._send_json({"ok": True})
            return
        if self.path == "/api/status":
            self._send_json(status_payload())
            return
        if self.path == "/api/settings":
            self._send_json(status_payload())
            return
        self._send_json({"error": "Not found"}, status=HTTPStatus.NOT_FOUND)

    def do_POST(self):
        global CHAT_HISTORY
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            payload = json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError:
            self._send_json({"error": "Invalid JSON"}, status=HTTPStatus.BAD_REQUEST)
            return

        if self.path == "/api/warm":
            warm_local_model()
            self._send_json({"ok": True})
            return

        if self.path == "/api/reset":
            CHAT_HISTORY = []
            self._send_json({"ok": True})
            return

        if self.path == "/api/settings":
            updated = SETTINGS.update(payload)
            self._send_json({"ok": True, "settings": updated, "status": status_payload()})
            return

        if self.path == "/api/test-connection":
            provider = payload.get("provider", "")
            api_key = payload.get("api_key", "")
            ok, detail = validate_provider_connection(provider, api_key)
            self._send_json({"ok": ok, "detail": detail})
            return

        if self.path == "/api/install-model":
            model_name = payload.get("model", "")
            if not model_name or model_name not in SUPPORTED_MODELS or SUPPORTED_MODELS[model_name]["type"] != "local":
                self._send_json({"error": "Unknown local model"}, status=HTTPStatus.BAD_REQUEST)
                return
            if current_install_status()["running"]:
                self._send_json({"error": "Another model install is already running"}, status=HTTPStatus.CONFLICT)
                return
            thread = threading.Thread(target=install_local_model, args=(model_name,), daemon=True)
            thread.start()
            self._send_json({"ok": True})
            return

        if self.path == "/api/chat":
            text = (payload.get("text") or "").strip()
            if not text:
                self._send_json({"error": "Text is required"}, status=HTTPStatus.BAD_REQUEST)
                return
            tool_events = []
            heuristic_event = TOOLS.route(text)
            if heuristic_event.get("used"):
                tool_events.append(heuristic_event)
            else:
                planner_reply, planner_model, _ = ROUTER.chat(build_tool_selection_messages(text), text)
                planned_calls = extract_tool_plan(planner_reply)
                if planned_calls:
                    tool_events = TOOLS.execute_plan(planned_calls)
                    model = planner_model
                    offline = not internet_available()
                else:
                    model = None
                    offline = not internet_available()

            if tool_events:
                messages = build_messages_with_tool_events(text, tool_events)
                if any(not event["result"]["ok"] for event in tool_events):
                    reply = "\n".join(event["result"]["message"] for event in tool_events if not event["result"]["ok"])
                    if all(not event["result"]["ok"] for event in tool_events):
                        selected_model, selected_offline = ROUTER.select(text)
                        model = selected_model
                        offline = selected_offline
                else:
                    reply, model, offline = ROUTER.chat(messages, text)
            else:
                messages = build_messages(text)
                reply, model, offline = ROUTER.chat(messages, text)

            if tool_events and len(tool_events) == 1 and tool_events[0]["result"]["ok"] and len(tool_events[0]["result"]["message"]) < 220 and any(
                phrase in text.lower() for phrase in ["open ", "what time", "what date", "memory", "disk", "system info", "search "]
            ):
                reply = tool_events[0]["result"]["message"]
            CHAT_HISTORY.extend(
                [
                    {"role": "user", "content": text},
                    {"role": "assistant", "content": reply},
                ]
            )
            log_interaction(text, reply, model.name, tool_events)
            self._send_json(
                {
                    "reply": reply,
                    "active_model": model.name,
                    "active_label": SUPPORTED_MODELS[model.name]["label"],
                    "active_source": SUPPORTED_MODELS[model.name]["type"],
                    "offline_mode": offline or not internet_available(),
                    "tool_events": tool_events,
                    "result_cards": flatten_tool_cards(tool_events),
                    "status": status_payload(),
                }
            )
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
    print("\n  ARIA — Multi-Model Voice Assistant")
    print(f"  Local AI engine : {OLLAMA_HOST}")
    print(f"  Web interface   : http://{HOST}:{PORT}")
    print("  Ctrl+C to quit\n")
    warm_local_model()
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

  cat >"${ARIA_DIR}/web/index.html" <<'HTMLEOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>ARIA</title>
  <style>
    :root {
      --bg: #f4f7fb;
      --bg-2: #e7edf6;
      --panel: rgba(255,255,255,0.72);
      --panel-strong: rgba(255,255,255,0.9);
      --text: #102033;
      --muted: #6c7f93;
      --line: rgba(16,32,51,0.08);
      --accent: #008F11;
      --glow: rgba(0, 143, 17, 0.18);
      --user: #eef5ff;
      --aria: rgba(255,255,255,0.78);
      --shadow: 0 24px 80px rgba(67,89,122,0.16);
      --state-a: rgba(14,165,161,0.14);
      --state-b: rgba(59,130,246,0.12);
      --state-c: transparent;
      --badge-free: rgba(15, 118, 110, 0.12);
      --badge-cost: rgba(245, 158, 11, 0.14);
      --badge-local: rgba(59, 130, 246, 0.12);
      --surface-soft: rgba(248, 250, 252, 0.84);
      --transcript-surface: rgba(255,255,255,0.42);
    }
    body[data-theme="dark"] {
      --bg: #07111d;
      --bg-2: #0c1725;
      --panel: rgba(11,19,33,0.74);
      --panel-strong: rgba(10,19,32,0.92);
      --text: #edf4ff;
      --muted: #95a6bb;
      --line: rgba(226,232,240,0.1);
      --accent: #008F11;
      --glow: rgba(0, 143, 17, 0.22);
      --user: rgba(18,43,74,0.7);
      --aria: rgba(255,255,255,0.05);
      --shadow: 0 24px 80px rgba(2,8,18,0.48);
      --badge-free: rgba(45, 212, 191, 0.15);
      --badge-cost: rgba(251, 191, 36, 0.16);
      --badge-local: rgba(96, 165, 250, 0.15);
      --surface-soft: rgba(255,255,255,0.06);
      --transcript-surface: rgba(255,255,255,0.06);
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      min-height: 100vh;
      padding: 28px;
      color: var(--text);
      font-family: "Sora", "Segoe UI", sans-serif;
      background:
        radial-gradient(circle at 10% 10%, var(--state-a), transparent 28%),
        radial-gradient(circle at 90% 20%, var(--state-b), transparent 26%),
        radial-gradient(circle at 50% 100%, var(--state-c), transparent 38%),
        linear-gradient(180deg, var(--bg), var(--bg-2));
      transition: background 100ms ease, color 100ms ease;
    }
    body[data-state="armed"] {
      --state-a: transparent;
      --state-b: transparent;
      --state-c: transparent;
    }
    body[data-state="listening"] {
      --state-a: rgba(14, 165, 161, 0.34);
      --state-b: rgba(34, 197, 94, 0.18);
      --state-c: rgba(16, 185, 129, 0.12);
    }
    body[data-state="thinking"] {
      --state-a: rgba(245, 158, 11, 0.24);
      --state-b: rgba(251, 191, 36, 0.16);
      --state-c: rgba(251, 191, 36, 0.09);
    }
    body[data-state="speaking"] {
      --state-a: rgba(59, 130, 246, 0.24);
      --state-b: rgba(96, 165, 250, 0.16);
      --state-c: rgba(96, 165, 250, 0.08);
    }
    body[data-state="error"] {
      --state-a: rgba(239, 68, 68, 0.2);
      --state-b: rgba(248, 113, 113, 0.08);
      --state-c: rgba(248, 113, 113, 0.06);
    }
    body[data-state="idle"] {
      --state-a: rgba(38, 38, 38, 0.18);
      --state-b: rgba(24, 24, 27, 0.14);
      --state-c: rgba(63, 63, 70, 0.08);
    }
    .shell {
      width: min(1040px, 100%);
      margin: 0 auto;
      position: relative;
    }
    .app {
      min-height: calc(100vh - 56px);
      padding: 22px;
      border-radius: 32px;
      background: var(--panel);
      border: 1px solid var(--line);
      backdrop-filter: blur(22px);
      box-shadow: var(--shadow);
      display: flex;
      flex-direction: column;
      gap: 16px;
      transition: transform 180ms ease, width 180ms ease;
    }
    .workspace {
      position: relative;
      display: flex;
      align-items: stretch;
      min-height: calc(100vh - 56px);
      gap: 0;
    }
    .main-stage {
      flex: 1 1 auto;
      min-width: 0;
      transition: transform 220ms ease, flex-basis 220ms ease, width 220ms ease;
    }
    .workspace.chat-open .main-stage .app {
      transform: translateX(-24px);
    }
    .chat-drawer {
      position: relative;
      flex: 0 0 0;
      width: 0;
      min-width: 0;
      max-width: 0;
      height: auto;
      overflow: hidden;
      opacity: 1;
      pointer-events: none;
      transition: width 220ms ease, max-width 220ms ease, flex-basis 220ms ease, padding-left 220ms ease;
    }
    .workspace.chat-open .chat-drawer {
      width: min(400px, calc(100vw - 40px));
      max-width: min(400px, calc(100vw - 40px));
      flex-basis: min(400px, calc(100vw - 40px));
      padding-left: 18px;
      pointer-events: auto;
    }
    .chat-drawer::before {
      content: "";
      position: absolute;
      inset: 18px 0 18px 18px;
      border-radius: 28px;
      background:
        linear-gradient(110deg,
          rgba(255,255,255,0) 0%,
          rgba(255,255,255,0.22) 35%,
          rgba(255,255,255,0.08) 50%,
          rgba(255,255,255,0) 70%);
      background-size: 220% 100%;
      opacity: 0;
      pointer-events: none;
      z-index: 2;
      transition: opacity 180ms ease;
    }
    .workspace.chat-opening .chat-drawer::before {
      opacity: 1;
      animation: drawer-shimmer 700ms linear infinite;
    }
    @keyframes drawer-shimmer {
      from { background-position: 200% 0; }
      to { background-position: -40% 0; }
    }
    .chat-shell {
      height: 100%;
      padding: 18px;
      border-radius: 28px;
      background: var(--panel);
      border: 1px solid var(--line);
      backdrop-filter: blur(22px);
      box-shadow: var(--shadow);
      display: flex;
      flex-direction: column;
      gap: 14px;
      overflow: hidden;
      opacity: 0;
      transform: translateX(22px);
      transition: opacity 220ms ease, transform 220ms ease;
      position: relative;
      z-index: 1;
    }
    .workspace.chat-open .chat-shell {
      opacity: 1;
      transform: translateX(0);
    }
    .chat-messages,
    .insights-panel-body,
    .modal,
    .modal {
      scrollbar-width: thin;
      scrollbar-color: transparent transparent;
    }
    .chat-messages:hover,
    .chat-messages:focus-within,
    .insights-panel-body:hover,
    .insights-panel-body:focus-within,
    .modal:hover,
    .modal:focus-within {
      scrollbar-color: rgba(14, 165, 161, 0.42) rgba(148, 163, 184, 0.12);
    }
    .chat-messages::-webkit-scrollbar,
    .insights-panel-body::-webkit-scrollbar,
    .modal::-webkit-scrollbar {
      width: 0;
      transition: width 120ms ease;
    }
    .chat-messages:hover::-webkit-scrollbar,
    .chat-messages:focus-within::-webkit-scrollbar,
    .insights-panel-body:hover::-webkit-scrollbar,
    .insights-panel-body:focus-within::-webkit-scrollbar,
    .modal:hover::-webkit-scrollbar,
    .modal:focus-within::-webkit-scrollbar {
      width: 12px;
    }
    .chat-messages::-webkit-scrollbar-track,
    .insights-panel-body::-webkit-scrollbar-track,
    .modal::-webkit-scrollbar-track {
      background: rgba(148, 163, 184, 0.08);
      border-radius: 999px;
    }
    .chat-messages::-webkit-scrollbar-thumb,
    .insights-panel-body::-webkit-scrollbar-thumb,
    .modal::-webkit-scrollbar-thumb {
      background: linear-gradient(180deg, rgba(14, 165, 161, 0.55), rgba(96, 165, 250, 0.55));
      border: 3px solid transparent;
      border-radius: 999px;
      background-clip: padding-box;
    }
    .chat-messages::-webkit-scrollbar-thumb:hover,
    .insights-panel-body::-webkit-scrollbar-thumb:hover,
    .modal::-webkit-scrollbar-thumb:hover {
      background: linear-gradient(180deg, rgba(14, 165, 161, 0.72), rgba(96, 165, 250, 0.72));
      background-clip: padding-box;
    }
    .chat-shell-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 12px;
    }
    .chat-shell-title {
      margin: 0;
      font-size: 0.82rem;
      color: var(--muted);
      letter-spacing: 0.14em;
      text-transform: uppercase;
    }
    .chat-shell-actions {
      display: flex;
      align-items: center;
      gap: 8px;
    }
    .insights-panel {
      display: grid;
      grid-template-rows: 0fr;
      transition: grid-template-rows 180ms ease, opacity 180ms ease, margin-bottom 180ms ease;
      opacity: 0;
      margin-bottom: 0;
      min-height: 0;
    }
    .insights-panel.open {
      grid-template-rows: 1fr;
      opacity: 1;
      margin-bottom: 6px;
    }
    .insights-panel-body {
      min-height: 0;
      overflow-y: auto;
      display: grid;
      gap: 12px;
      padding-right: 2px;
    }
    .drawer-panel {
      padding: 14px 16px;
      border-radius: 20px;
      border: 1px solid var(--line);
      background: var(--surface-soft);
      display: grid;
      gap: 12px;
    }
    .drawer-panel .section-title {
      margin-bottom: 0;
    }
    .chat-messages {
      flex: 1 1 auto;
      min-height: 0;
      overflow-y: auto;
      display: grid;
      gap: 10px;
      padding-right: 2px;
    }
    .chat-toggle {
      position: fixed;
      right: 26px;
      bottom: 26px;
      z-index: 20;
      width: 58px;
      height: 58px;
      border-radius: 999px;
      background: var(--text);
      color: var(--panel-strong);
      border-color: transparent;
      box-shadow: 0 18px 40px rgba(16, 32, 51, 0.18);
    }
    .chat-toggle:hover {
      box-shadow: 0 20px 44px rgba(16, 32, 51, 0.24);
    }
    .hero {
      display: grid;
      grid-template-columns: 1.5fr 1fr;
      gap: 16px;
      align-items: stretch;
    }
    .hero-card, .panel {
      border-radius: 28px;
      border: 1px solid var(--line);
      background: var(--panel-strong);
      transition: background 100ms ease, border-color 100ms ease, box-shadow 100ms ease;
    }
    .hero-card {
      padding: 28px;
    }
    .panel {
      display: grid;
      align-content: start;
      gap: 14px;
    }
    .hero-top {
      display: flex;
      justify-content: space-between;
      gap: 18px;
      align-items: center;
    }
    .eyebrow {
      margin: 0 0 10px;
      color: var(--muted);
      font-size: 0.82rem;
      letter-spacing: 0.18em;
      text-transform: uppercase;
    }
    .eyebrow span {
      display: block;
    }
    h1 {
      margin: 0;
      font-size: clamp(2.2rem, 6vw, 4.3rem);
      line-height: 0.92;
      letter-spacing: -0.06em;
    }
    .subtitle {
      max-width: 26rem;
      margin: 14px 0 0;
      color: var(--muted);
      font-size: 1rem;
      line-height: 1.5;
    }
    .core {
      position: relative;
      flex: none;
      width: 110px;
      height: 110px;
      border-radius: 50%;
      background: radial-gradient(circle at 35% 35%, #ffffff, #b2f5ea 36%, #14b8a6 64%, rgba(16, 32, 51, 0.18) 100%);
      box-shadow: 0 16px 50px var(--glow);
      transition: transform 100ms ease, box-shadow 100ms ease, filter 100ms ease, background 100ms ease;
    }
    .core::before,
    .core::after {
      content: "";
      position: absolute;
      inset: -10px;
      border-radius: 50%;
      border: 1px solid rgba(14, 165, 161, 0.16);
      opacity: 0;
    }
    .core.armed::before {
      opacity: 0;
      animation: none;
    }
    .core.armed {
      transform: scale(1);
      filter: saturate(0.95);
      background: radial-gradient(circle at 35% 35%, #f3fff8, #9fd9b4 28%, #2f6f49 62%, rgba(16, 32, 51, 0.22) 100%);
      box-shadow: 0 10px 24px rgba(47, 111, 73, 0.18);
    }
    .core.listening {
      transform: scale(1.06);
      filter: saturate(1.2);
      background: radial-gradient(circle at 35% 35%, #ffffff, #c8fff3 28%, #10b981 58%, rgba(16, 32, 51, 0.18) 100%);
    }
    .core.listening::before,
    .core.listening::after {
      opacity: 1;
      animation: ring-fast 1s infinite;
    }
    .core.thinking {
      background: radial-gradient(circle at 35% 35%, #fff9eb, #fde68a 32%, #f59e0b 62%, rgba(16, 32, 51, 0.18) 100%);
    }
    .core.speaking {
      background: radial-gradient(circle at 35% 35%, #ffffff, #dbeafe 28%, #3b82f6 62%, rgba(16, 32, 51, 0.18) 100%);
    }
    .core.error {
      background: radial-gradient(circle at 35% 35%, #fff1f1, #fecaca 28%, #ef4444 62%, rgba(16, 32, 51, 0.18) 100%);
    }
    .core.idle {
      transform: scale(0.98);
      filter: saturate(0.72);
      background: radial-gradient(circle at 35% 35%, #f3f4f6, #9ca3af 26%, #3f3f46 62%, rgba(16, 32, 51, 0.26) 100%);
      box-shadow: 0 10px 26px rgba(24, 24, 27, 0.22);
    }
    @keyframes ring {
      0% { transform: scale(0.92); opacity: 0.42; }
      100% { transform: scale(1.22); opacity: 0; }
    }
    @keyframes ring-fast {
      0% { transform: scale(0.92); opacity: 0.56; }
      100% { transform: scale(1.28); opacity: 0; }
    }
    .stat-value {
      font-size: 1.03rem;
      font-weight: 600;
    }
    .voice-state {
      display: inline-flex;
      align-items: center;
      gap: 10px;
      margin-top: 24px;
      min-height: 46px;
      padding: 10px 16px;
      border-radius: 999px;
      background: var(--panel-strong);
      border: 1px solid var(--line);
      color: var(--muted);
      line-height: 1.2;
      white-space: nowrap;
    }
    .voice-state-dot {
      width: 10px;
      height: 10px;
      border-radius: 50%;
      background: #3f3f46;
      box-shadow: 0 0 0 rgba(63, 63, 70, 0);
      transition: background 100ms ease, box-shadow 100ms ease;
      flex: none;
    }
    .voice-state-text {
      display: inline-block;
    }
    body[data-state="armed"] .voice-state-dot {
      background: var(--accent);
      box-shadow: 0 0 18px rgba(0, 143, 17, 0.36), 0 0 30px rgba(0, 143, 17, 0.18);
    }
    body[data-state="listening"] .voice-state-dot {
      background: #10b981;
      box-shadow: 0 0 20px rgba(16, 185, 129, 0.54), 0 0 38px rgba(16, 185, 129, 0.24);
    }
    body[data-state="thinking"] .voice-state-dot {
      background: #f59e0b;
      box-shadow: 0 0 20px rgba(245, 158, 11, 0.4), 0 0 34px rgba(245, 158, 11, 0.16);
    }
    body[data-state="speaking"] .voice-state-dot {
      background: #3b82f6;
      box-shadow: 0 0 20px rgba(59, 130, 246, 0.4), 0 0 34px rgba(59, 130, 246, 0.16);
    }
    body[data-state="error"] .voice-state-dot {
      background: #ef4444;
      box-shadow: 0 0 20px rgba(239, 68, 68, 0.4), 0 0 34px rgba(239, 68, 68, 0.16);
    }
    body[data-state="idle"] .voice-state-dot {
      background: #3f3f46;
      box-shadow: 0 0 0 rgba(63, 63, 70, 0);
    }
    .command-bar {
      display: flex;
      gap: 12px;
      flex-wrap: wrap;
      margin-bottom: 0;
      justify-content: space-between;
    }
    .command-group { display:flex; gap:10px; flex-wrap: wrap; }
    button {
      cursor: pointer;
      padding: 12px 15px;
      color: var(--text);
      background: var(--panel-strong);
      border: 1px solid var(--line);
      border-radius: 999px;
      font: inherit;
      letter-spacing: 0.01em;
      transition: transform 160ms ease, border-color 160ms ease, box-shadow 160ms ease;
      box-shadow: 0 1px 0 rgba(255, 255, 255, 0.06) inset;
    }
    button:hover {
      transform: translateY(-1px);
      box-shadow: 0 10px 24px rgba(16, 32, 51, 0.08);
    }
    button.primary {
      background: var(--text);
      color: var(--panel-strong);
      border-color: transparent;
    }
    button.warn {
      color: var(--muted);
    }
    .pill {
      display: inline-flex;
      align-items: center;
      gap: 10px;
      justify-self: start;
      min-height: 46px;
      padding: 10px 16px;
      border-radius: 999px;
      background: var(--panel-strong);
      border: 1px solid var(--line);
      color: var(--muted);
      line-height: 1.2;
      white-space: nowrap;
    }
    .pill-dot {
      width: 10px;
      height: 10px;
      border-radius: 50%;
      background: var(--accent);
      box-shadow: 0 0 18px rgba(14, 165, 161, 0.55);
    }
    .composer {
      display: grid;
      grid-template-columns: 1fr auto;
      gap: 12px;
    }
    input {
      min-width: 0;
      padding: 16px 18px;
      background: var(--panel-strong);
      color: var(--text);
      border: 1px solid var(--line);
      border-radius: 18px;
      font: inherit;
    }
    .transcript {
      min-height: 68px;
      margin-bottom: 18px;
      padding: 18px 20px;
      border-radius: 22px;
      border: 1px solid var(--line);
      background: var(--transcript-surface);
      color: var(--muted);
      font-size: 0.98rem;
      line-height: 1.5;
    }
    .chat {
      display: grid;
      gap: 10px;
      flex: 0 0 auto;
    }
    .tool-hub {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 14px;
    }
    .tool-panel {
      padding: 18px;
      border-radius: 24px;
      border: 1px solid var(--line);
      background: var(--panel-strong);
    }
    .section-title {
      margin: 0 0 14px;
      font-size: 0.8rem;
      color: var(--muted);
      letter-spacing: 0.14em;
      text-transform: uppercase;
    }
    .timeline {
      display: grid;
      gap: 10px;
    }
    .timeline-item {
      display: grid;
      gap: 6px;
      padding: 14px 16px;
      border-radius: 18px;
      border: 1px solid var(--line);
      background: var(--surface-soft);
    }
    .timeline-meta {
      display: flex;
      align-items: center;
      gap: 10px;
      color: var(--muted);
      font-size: 0.8rem;
      letter-spacing: 0.06em;
      text-transform: uppercase;
    }
    .timeline-dot {
      width: 9px;
      height: 9px;
      border-radius: 50%;
      background: #ef4444;
      box-shadow: 0 0 0 6px rgba(239, 68, 68, 0.08);
    }
    .timeline-item.ok .timeline-dot {
      background: #10b981;
      box-shadow: 0 0 0 6px rgba(16, 185, 129, 0.08);
    }
    .timeline-text {
      line-height: 1.5;
    }
    .result-grid {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 10px;
    }
    .result-card {
      padding: 16px;
      border-radius: 18px;
      border: 1px solid var(--line);
      background: var(--surface-soft);
      display: grid;
      gap: 8px;
    }
    .result-card a {
      color: var(--text);
      text-decoration: none;
      font-weight: 600;
    }
    .result-card a:hover {
      text-decoration: underline;
    }
    .result-kicker {
      color: var(--muted);
      font-size: 0.74rem;
      letter-spacing: 0.1em;
      text-transform: uppercase;
    }
    .msg {
      padding: 15px 16px;
      border-radius: 20px;
      border: 1px solid var(--line);
      background: var(--aria);
    }
    .msg.user {
      background: var(--user);
    }
    .msg.tool {
      background: rgba(14, 165, 161, 0.08);
    }
    .role {
      margin-bottom: 6px;
      color: var(--muted);
      font-size: 0.72rem;
      text-transform: uppercase;
      letter-spacing: 0.14em;
    }
    .hint {
      margin-top: 14px;
      color: var(--muted);
      font-size: 0.9rem;
    }
    .theme-toggle {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      align-self: start;
      justify-self: start;
      padding: 4px;
      border-radius: 999px;
      border: 1px solid var(--line);
      background: var(--panel-strong);
    }
    .theme-chip {
      border: 0;
      background: transparent;
      color: var(--muted);
      padding: 9px 12px;
      border-radius: 999px;
      box-shadow: none;
      width: 42px;
      height: 42px;
      min-width: 42px;
    }
    .theme-chip.active {
      background: var(--text);
      color: var(--panel-strong);
    }
    .badge-row {
      display: flex;
      gap: 8px;
      flex-wrap: wrap;
      margin-top: 8px;
    }
    .badge {
      display: inline-flex;
      align-items: center;
      padding: 6px 10px;
      border-radius: 999px;
      font-size: 0.74rem;
      letter-spacing: 0.08em;
      text-transform: uppercase;
      color: var(--muted);
    }
    .badge.free { background: var(--badge-free); }
    .badge.lowcost { background: var(--badge-cost); }
    .badge.local { background: var(--badge-local); }
    .settings-button {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      width: 46px;
      height: 46px;
      padding: 0;
      font-size: 1.05rem;
      line-height: 1;
    }
    .icon-button {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      width: 46px;
      height: 46px;
      padding: 0;
    }
    .icon-button svg,
    .settings-button svg {
      width: 18px;
      height: 18px;
      stroke-width: 2.1;
    }
    .overlay {
      position: fixed;
      inset: 0;
      z-index: 40;
      background: rgba(5, 12, 24, 0.34);
      backdrop-filter: blur(10px);
      display: none;
      align-items: center;
      justify-content: center;
      padding: 20px;
    }
    .overlay.open { display: flex; }
    .modal {
      width: min(980px, 100%);
      max-height: calc(100vh - 40px);
      overflow-y: auto;
      position: relative;
      z-index: 41;
      border-radius: 28px;
      background: var(--panel-strong);
      border: 1px solid var(--line);
      box-shadow: var(--shadow);
      padding: 24px;
    }
    body[data-theme="dark"] .chat-messages:hover,
    body[data-theme="dark"] .chat-messages:focus-within,
    body[data-theme="dark"] .insights-panel-body:hover,
    body[data-theme="dark"] .insights-panel-body:focus-within,
    body[data-theme="dark"] .modal:hover,
    body[data-theme="dark"] .modal:focus-within {
      scrollbar-color: rgba(45, 212, 191, 0.5) rgba(255, 255, 255, 0.06);
    }
    body[data-theme="dark"] .chat-messages::-webkit-scrollbar-track,
    body[data-theme="dark"] .insights-panel-body::-webkit-scrollbar-track,
    body[data-theme="dark"] .modal::-webkit-scrollbar-track {
      background: rgba(255, 255, 255, 0.05);
    }
    body[data-theme="dark"] .chat-messages::-webkit-scrollbar-thumb,
    body[data-theme="dark"] .insights-panel-body::-webkit-scrollbar-thumb,
    body[data-theme="dark"] .modal::-webkit-scrollbar-thumb {
      background: linear-gradient(180deg, rgba(45, 212, 191, 0.62), rgba(96, 165, 250, 0.58));
      background-clip: padding-box;
    }
    body[data-theme="dark"] .chat-messages::-webkit-scrollbar-thumb:hover,
    body[data-theme="dark"] .insights-panel-body::-webkit-scrollbar-thumb:hover,
    body[data-theme="dark"] .modal::-webkit-scrollbar-thumb:hover {
      background: linear-gradient(180deg, rgba(94, 234, 212, 0.82), rgba(125, 211, 252, 0.76));
      background-clip: padding-box;
    }
    .modal-grid {
      display: grid;
      grid-template-columns: 1.2fr 1fr;
      gap: 18px;
    }
    .modal-card {
      padding: 18px;
      border-radius: 22px;
      border: 1px solid var(--line);
      background: var(--panel);
    }
    .model-list {
      display: grid;
      gap: 10px;
    }
    .model-option {
      padding: 16px;
      border-radius: 18px;
      border: 1px solid var(--line);
      background: rgba(255,255,255,0.55);
      cursor: pointer;
    }
    body[data-theme="dark"] .model-option {
      background: rgba(255,255,255,0.03);
    }
    .model-option.active { border-color: var(--accent); box-shadow: 0 0 0 1px var(--accent) inset; }
    .model-meta { display:flex; justify-content: space-between; gap: 12px; align-items: start; }
    .stack { display:grid; gap:12px; }
    .label { font-size: 0.82rem; color: var(--muted); text-transform: uppercase; letter-spacing: 0.12em; }
    .api-field {
      display:grid;
      gap: 8px;
    }
    .api-field input { width: 100%; }
    .api-field a {
      color: color-mix(in srgb, var(--text) 72%, white 28%);
      text-decoration: none;
      font-size: 0.92rem;
    }
    .api-field a:hover {
      text-decoration: underline;
    }
    .status-pill {
      display:inline-flex;
      align-items:center;
      gap:8px;
      padding: 8px 12px;
      border-radius: 999px;
      border:1px solid var(--line);
      color: var(--muted);
    }
    .plain-list-row {
      padding: 10px 0 12px;
      color: var(--text);
      line-height: 1.5;
      border-bottom: 1px solid var(--line);
    }
    .stack > .plain-list-row:first-child,
    #currentBrainCard > .plain-list-row:first-child,
    #connectionStatus > .plain-list-row:first-child,
    #localModels > .plain-list-row:first-child {
      margin-top: 6px;
    }
    .stack > .plain-list-row:last-child,
    #currentBrainCard > .plain-list-row:last-child,
    #connectionStatus > .plain-list-row:last-child,
    #localModels > .plain-list-row:last-child {
      padding-bottom: 0;
    }
    .status-dot { width: 8px; height: 8px; border-radius: 50%; background: #ef4444; }
    .status-pill.ok .status-dot { background: #10b981; }
    .install-progress {
      height: 10px;
      border-radius: 999px;
      background: rgba(148,163,184,0.15);
      overflow: hidden;
    }
    .install-progress > span {
      display:block;
      height:100%;
      width:0;
      background: linear-gradient(90deg, #14b8a6, #60a5fa);
      transition: width 220ms ease;
    }
    .notice {
      padding: 14px 16px;
      border-radius: 18px;
      border: 1px solid var(--line);
      background: var(--surface-soft);
      color: var(--muted);
    }
    .notice strong { color: var(--text); }
    @media (max-width: 720px) {
      body { padding: 16px; }
      .hero { grid-template-columns: 1fr; }
      .hero-top { align-items: start; }
      .core { width: 84px; height: 84px; }
      .composer { grid-template-columns: 1fr; }
      .command-bar { gap: 10px; }
      .modal-grid { grid-template-columns: 1fr; }
      .tool-hub { grid-template-columns: 1fr; }
      .result-grid { grid-template-columns: 1fr; }
      .app { min-height: calc(100vh - 32px); }
      .workspace.chat-open .main-stage .app { transform: none; }
      .chat-drawer {
        width: 0;
        max-width: 0;
        padding-left: 0;
      }
      .workspace.chat-open .chat-drawer {
        width: calc(100vw - 24px);
        max-width: calc(100vw - 24px);
        flex-basis: calc(100vw - 24px);
      }
      .chat-toggle {
        right: 16px;
        bottom: 16px;
      }
    }
  </style>
</head>
<body data-state="idle" data-theme="light">
  <main class="shell">
    <section id="workspace" class="workspace">
      <div class="main-stage">
        <section class="app">
          <section class="hero">
            <div class="hero-card">
              <div class="hero-top">
                <div>
                  <p class="eyebrow"><span>Voice</span><span>Workspace</span></p>
                  <h1>ARIA</h1>
                  <div id="wakeState" class="stat-value voice-state"><span class="voice-state-dot"></span><span id="wakeStateText" class="voice-state-text">Ready</span></div>
                </div>
                <div id="core" class="core"></div>
              </div>
            </div>
            <div class="panel" style="padding:24px;">
              <div class="command-bar">
                <div class="command-group">
                  <button id="listenBtn" class="primary icon-button" aria-label="Listen once" title="Listen once"><i data-lucide="ear"></i></button>
                  <button id="wakeBtn" class="icon-button" aria-label="Microphone" title="Microphone"><i data-lucide="mic"></i></button>
                  <button id="speakBtn" class="icon-button" aria-label="Speaker" title="Speaker"><i data-lucide="volume-2"></i></button>
                  <button id="resetBtn" class="warn icon-button" aria-label="Reset" title="Reset"><i data-lucide="brush-cleaning"></i></button>
                  <button id="sleepBtn" class="icon-button" aria-label="Sleep" title="Sleep"><i data-lucide="power"></i></button>
                  <button id="settingsBtn" class="settings-button" aria-label="Settings" title="Settings"><i data-lucide="settings"></i></button>
                </div>
              </div>
              <div class="theme-toggle" aria-label="Theme toggle">
                <button id="lightThemeBtn" class="theme-chip active icon-button" type="button" aria-label="Light mode" title="Light mode"><i data-lucide="sun"></i></button>
                <button id="darkThemeBtn" class="theme-chip icon-button" type="button" aria-label="Dark mode" title="Dark mode"><i data-lucide="moon"></i></button>
              </div>
              <div class="pill">
                <span class="pill-dot"></span>
                <span id="signalText">Preparing microphone access</span>
              </div>
              <div class="badge-row" id="activeBadges"></div>
              <p class="hint">Say “aria” to wake it, or type directly below.</p>
            </div>
          </section>

          <section id="transcript" class="transcript">Waiting for the first microphone permission.</section>
          <section class="tool-panel">
            <h2 class="section-title">Tool Activity</h2>
            <div id="toolTimeline" class="timeline"></div>
          </section>
        </section>
      </div>
      <aside id="chatDrawer" class="chat-drawer" aria-hidden="true"></aside>
    </section>
  </main>
  <button id="chatToggleBtn" class="chat-toggle icon-button" aria-label="Toggle conversation" title="Toggle conversation" aria-expanded="false"><i data-lucide="bot-message-square"></i></button>

  <div id="settingsOverlay" class="overlay">
    <section class="modal">
      <div class="command-bar" style="margin-bottom:16px;">
        <h2 style="margin:0;">Settings</h2>
        <button id="closeSettingsBtn" class="icon-button" aria-label="Close settings" title="Close settings"><i data-lucide="x"></i></button>
      </div>
      <div class="modal-grid">
        <div class="modal-card">
          <div class="label">AI Model Selection</div>
          <div id="modelList" class="model-list"></div>
        </div>
        <div class="stack">
          <div class="modal-card">
            <div class="label">Engine</div>
            <div id="currentBrainCard" class="stack"></div>
          </div>
          <div class="modal-card">
            <div class="label">Connection Status</div>
            <div id="connectionStatus" class="stack"></div>
          </div>
          <div class="modal-card">
            <div class="label">API Keys</div>
            <div class="stack">
              <div class="api-field">
                <label for="openaiKey">OpenAI API Key</label>
                <input id="openaiKey" placeholder="sk-...">
                <a href="https://platform.openai.com/api-keys" target="_blank">OpenAI API key</a>
              </div>
              <div class="api-field">
                <label for="geminiKey">Gemini API Key</label>
                <input id="geminiKey" placeholder="AIza...">
                <a href="https://makersuite.google.com/app/apikey" target="_blank">Gemini API key</a>
              </div>
              <div class="api-field">
                <label for="anthropicKey">Anthropic API Key</label>
                <input id="anthropicKey" placeholder="sk-ant-...">
                <a href="https://console.anthropic.com/" target="_blank">Anthropic API key</a>
              </div>
              <button id="saveKeysBtn">Save & Validate</button>
            </div>
          </div>
          <div class="modal-card">
            <div class="label">Local Model Manager</div>
            <div id="localModels" class="stack"></div>
            <div class="install-progress"><span id="installBar"></span></div>
            <div id="installText" class="hint">No installation in progress.</div>
          </div>
          <div id="settingsNotice" class="notice"><strong>Ready.</strong> Choose a model to use, or keep Smart.</div>
        </div>
      </div>
    </section>
  </div>

  <script src="https://unpkg.com/lucide@latest"></script>
  <script>
    const workspace = document.getElementById("workspace");
    const chatDrawer = document.getElementById("chatDrawer");
    const chatToggleBtn = document.getElementById("chatToggleBtn");
    const bodyEl = document.body;
    const core = document.getElementById("core");
    const wakeStateEl = document.getElementById("wakeState");
    const wakeStateTextEl = document.getElementById("wakeStateText");
    const signalText = document.getElementById("signalText");
    const transcriptEl = document.getElementById("transcript");
    const toolTimeline = document.getElementById("toolTimeline");
    const listenBtn = document.getElementById("listenBtn");
    const wakeBtn = document.getElementById("wakeBtn");
    const resetBtn = document.getElementById("resetBtn");
    const sleepBtn = document.getElementById("sleepBtn");
    const speakBtn = document.getElementById("speakBtn");
    const settingsBtn = document.getElementById("settingsBtn");
    const settingsOverlay = document.getElementById("settingsOverlay");
    const closeSettingsBtn = document.getElementById("closeSettingsBtn");
    const modelList = document.getElementById("modelList");
    const connectionStatus = document.getElementById("connectionStatus");
    const currentBrainCard = document.getElementById("currentBrainCard");
    const localModels = document.getElementById("localModels");
    const installBar = document.getElementById("installBar");
    const installText = document.getElementById("installText");
    const settingsNotice = document.getElementById("settingsNotice");
    const activeBadges = document.getElementById("activeBadges");
    const openaiKey = document.getElementById("openaiKey");
    const geminiKey = document.getElementById("geminiKey");
    const anthropicKey = document.getElementById("anthropicKey");
    const saveKeysBtn = document.getElementById("saveKeysBtn");
    const lightThemeBtn = document.getElementById("lightThemeBtn");
    const darkThemeBtn = document.getElementById("darkThemeBtn");
    const SpeechRecognition = window.SpeechRecognition || window.webkitSpeechRecognition;
    let wakeRecognition = null;
    let commandRecognition = null;
    let speakReplies = true;
    let wakeWordEnabled = true;
    let sleepMode = false;
    let micReady = false;
    let commandCaptureActive = false;
    let wakeRestartTimer = null;
    let currentState = "idle";
    let stateTimer = null;
    const wakeRegex = /\b(aria|area|arya)\b/i;
    let appStatus = null;
    let statusPoll = null;
    let toolHistory = [];
    let chatMessages = [];
    let resultCardsCache = [];
    let chatOpen = false;
    let insightsOpen = false;
    let chatOpeningTimer = null;
    let chatDestroyTimer = null;
    let chatInputValue = "";
    const listeningSound = new Audio("/listening.mp3");
    const processingSound = new Audio("/processing_command.mp3");
    const completeSound = new Audio("/complete.mp3");

    function refreshLucide() {
      if (window.lucide && typeof window.lucide.createIcons === "function") {
        window.lucide.createIcons();
      }
    }

    function setVoiceMode(text) {
      wakeStateTextEl.textContent = text;
    }

    function getChatEl() { return document.getElementById("chat"); }
    function getResultCardsEl() { return document.getElementById("resultCards"); }
    function getChatInputEl() { return document.getElementById("textInput"); }
    function getSendBtnEl() { return document.getElementById("sendBtn"); }
    function getChatDrawerCloseBtnEl() { return document.getElementById("chatDrawerCloseBtn"); }
    function getInsightsToggleBtnEl() { return document.getElementById("insightsToggleBtn"); }
    function getInsightsPanelEl() { return document.getElementById("insightsPanel"); }

    function chatDrawerMarkup() {
      return `
        <section class="chat-shell">
          <div class="chat-shell-header">
            <h2 class="chat-shell-title">Conversation</h2>
            <div class="chat-shell-actions">
              <button id="insightsToggleBtn" class="icon-button" aria-label="Toggle activity" title="Toggle activity"><i data-lucide="${insightsOpen ? "chevron-down" : "chevron-up"}"></i></button>
              <button id="chatDrawerCloseBtn" class="icon-button" aria-label="Close conversation" title="Close conversation"><i data-lucide="x"></i></button>
            </div>
          </div>
          <section id="insightsPanel" class="insights-panel ${insightsOpen ? "open" : ""}">
            <div class="insights-panel-body">
              <section class="drawer-panel">
                <h3 class="section-title">Results</h3>
                <div id="resultCards" class="result-grid"></div>
              </section>
            </div>
          </section>
          <section id="chat" class="chat-messages"></section>
          <section class="composer">
            <input id="textInput" placeholder="Type a request">
            <button id="sendBtn" class="icon-button" aria-label="Send" title="Send"><i data-lucide="send-horizontal"></i></button>
          </section>
        </section>
      `;
    }

    function bindChatDrawerEvents() {
      const input = getChatInputEl();
      const sendBtn = getSendBtnEl();
      const closeBtn = getChatDrawerCloseBtnEl();
      const insightsBtn = getInsightsToggleBtnEl();
      if (input) {
        input.value = chatInputValue;
        input.addEventListener("input", () => {
          chatInputValue = input.value;
        });
        input.addEventListener("keydown", (event) => {
          if (event.key === "Enter") sendText(input.value);
        });
      }
      if (sendBtn) {
        sendBtn.onclick = () => sendText((getChatInputEl() || { value: "" }).value);
      }
      if (closeBtn) {
        closeBtn.onclick = () => setChatOpen(false);
      }
      if (insightsBtn) {
        insightsBtn.onclick = () => {
          insightsOpen = !insightsOpen;
          updateInsightsPanel();
        };
      }
    }

    function ensureChatDrawerContent() {
      if (getChatEl()) return;
      chatDrawer.innerHTML = chatDrawerMarkup();
      bindChatDrawerEvents();
      renderChatMessages();
      renderToolTimeline();
      renderResultCards(resultCardsCache);
      renderControlIcons();
    }

    function destroyChatDrawerContent() {
      const input = getChatInputEl();
      if (input) chatInputValue = input.value;
      chatDrawer.innerHTML = "";
    }

    function updateInsightsPanel() {
      const panel = getInsightsPanelEl();
      const toggleBtn = getInsightsToggleBtnEl();
      if (panel) {
        panel.classList.toggle("open", insightsOpen);
      }
      if (toggleBtn) {
        toggleBtn.innerHTML = `<i data-lucide="${insightsOpen ? "chevron-down" : "chevron-up"}"></i>`;
        refreshLucide();
      }
    }

    function renderControlIcons() {
      listenBtn.innerHTML = '<i data-lucide="ear"></i>';
      wakeBtn.innerHTML = `<i data-lucide="${wakeWordEnabled ? "mic" : "mic-off"}"></i>`;
      speakBtn.innerHTML = `<i data-lucide="${speakReplies ? "volume-2" : "volume-x"}"></i>`;
      resetBtn.innerHTML = '<i data-lucide="brush-cleaning"></i>';
      sleepBtn.innerHTML = '<i data-lucide="power"></i>';
      chatToggleBtn.innerHTML = '<i data-lucide="bot-message-square"></i>';
      settingsBtn.innerHTML = '<i data-lucide="settings"></i>';
      const closeBtn = getChatDrawerCloseBtnEl();
      const sendBtn = getSendBtnEl();
      if (closeBtn) closeBtn.innerHTML = '<i data-lucide="x"></i>';
      if (sendBtn) sendBtn.innerHTML = '<i data-lucide="send-horizontal"></i>';
      updateInsightsPanel();
      refreshLucide();
    }

    function setChatOpen(nextOpen) {
      clearTimeout(chatOpeningTimer);
      clearTimeout(chatDestroyTimer);
      chatOpen = nextOpen;
      if (chatOpen) {
        ensureChatDrawerContent();
        workspace.classList.add("chat-opening");
        chatOpeningTimer = setTimeout(() => {
          workspace.classList.remove("chat-opening");
        }, 520);
      } else {
        workspace.classList.remove("chat-opening");
        chatDestroyTimer = setTimeout(() => {
          if (!chatOpen) destroyChatDrawerContent();
        }, 240);
      }
      workspace.classList.toggle("chat-open", chatOpen);
      chatDrawer.setAttribute("aria-hidden", chatOpen ? "false" : "true");
      chatToggleBtn.setAttribute("aria-expanded", chatOpen ? "true" : "false");
    }

    async function applySleepMode(nextSleepMode) {
      sleepMode = nextSleepMode;
      stopAllRecognition();
      stopSpeechPlayback();
      if (sleepMode) {
        setStatus("Sleeping", "idle");
        setVoiceMode("Sleeping");
        setTranscript("Assistant sleeping.");
        return;
      }
      if (wakeWordEnabled) {
        const ok = await ensureMic();
        if (ok) {
          setStatus("Ready", "armed");
          setVoiceMode("Ready");
          setTranscript("Assistant awake.");
          scheduleWakeRestart();
          return;
        }
      }
      setStatus("Ready", "armed");
      setVoiceMode("Ready");
      setTranscript("Assistant awake.");
    }

    function applyTheme(theme) {
      bodyEl.dataset.theme = theme;
      lightThemeBtn.classList.toggle("active", theme === "light");
      darkThemeBtn.classList.toggle("active", theme === "dark");
      localStorage.setItem("aria-theme", theme);
    }

    function getStateDelay(state) {
      return 100;
    }

    function setStatus(text, state = currentState) {
      signalText.textContent = text;
      wakeStateTextEl.textContent = text;
      clearTimeout(stateTimer);
      stateTimer = setTimeout(() => {
        currentState = state;
        bodyEl.dataset.state = state;
        core.className = `core ${state}`.trim();
      }, getStateDelay(state));
    }

    function setTranscript(text) {
      transcriptEl.textContent = text;
    }

    function stopSpeechPlayback() {
      if ("speechSynthesis" in window) {
        window.speechSynthesis.cancel();
      }
    }

    function playCue(audio) {
      try {
        audio.pause();
        audio.currentTime = 0;
        audio.play().catch(() => {});
      } catch (_) {}
    }

    function escapeHtml(text) {
      return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    }

    function renderChatMessages() {
      const chat = getChatEl();
      if (!chat) return;
      chat.innerHTML = "";
      chatMessages.forEach((message) => {
        const item = document.createElement("article");
        item.className = `msg ${message.role}`;
        item.innerHTML = `<div class="role">${message.role}</div><div>${escapeHtml(message.text)}</div>`;
        chat.appendChild(item);
      });
      chat.scrollTop = chat.scrollHeight;
    }

    function addMessage(role, text) {
      chatMessages.push({ role, text });
      renderChatMessages();
    }

    function renderToolTimeline() {
      if (!toolTimeline) return;
      toolTimeline.innerHTML = "";
      if (!toolHistory.length) {
        toolTimeline.innerHTML = '<div class="hint">No tool activity yet.</div>';
        return;
      }
      toolHistory.slice(0, 8).forEach((event) => {
        const item = document.createElement("article");
        item.className = `timeline-item ${event.result && event.result.ok ? "ok" : ""}`;
        item.innerHTML = `
          <div class="timeline-meta">
            <span class="timeline-dot"></span>
            <span>${escapeHtml(event.tool || "tool")} · ${escapeHtml(event.action || "action")}</span>
          </div>
          <div class="timeline-text">${escapeHtml((event.result && event.result.message) || "No detail available.")}</div>
        `;
        toolTimeline.appendChild(item);
      });
    }

    function renderResultCards(cards = []) {
      resultCardsCache = cards;
      const resultCards = getResultCardsEl();
      if (!resultCards) return;
      resultCards.innerHTML = "";
      if (!cards.length) {
        resultCards.innerHTML = '<div class="hint">Searches, file previews, and opened targets will appear here.</div>';
        return;
      }
      cards.slice(0, 8).forEach((card) => {
        const item = document.createElement("article");
        item.className = "result-card";
        const title = escapeHtml(card.title || "Result");
        const snippet = escapeHtml(card.snippet || "");
        const kicker = `${card.tool || "tool"}${card.action ? ` · ${card.action}` : ""}`;
        const href = (card.url || "").trim();
        item.innerHTML = `
          <div class="result-kicker">${escapeHtml(kicker)}</div>
          ${href ? `<a href="${href}" target="_blank" rel="noreferrer">${title}</a>` : `<div style="font-weight:600;">${title}</div>`}
          <div class="hint">${snippet}</div>
        `;
        resultCards.appendChild(item);
      });
    }

    function applyToolEvents(events = [], cards = []) {
      if (events.length) {
        toolHistory = [...events.reverse(), ...toolHistory].slice(0, 20);
        renderToolTimeline();
      }
      renderResultCards(cards);
    }

    function badgesForModel(model) {
      activeBadges.innerHTML = "";
      const badges = [];
      badges.push(model.offline_mode ? "Offline Mode" : model.type === "local" ? "Local AI Brain" : "Cloud AI Brain");
      badges.push(`Model: ${model.label}`);
      badges.push(`Status: ${model.status}`);
      badges.forEach((text, index) => {
        const span = document.createElement("span");
        span.className = `badge ${index === 0 && model.offline_mode ? "lowcost" : model.type === "local" ? "local" : "free"}`;
        span.textContent = text;
        activeBadges.appendChild(span);
      });
    }

    function renderConnectionStatus(providerStatus) {
      connectionStatus.innerHTML = "";
      [["openai","OpenAI"],["gemini","Gemini"],["anthropic","Anthropic"]].forEach(([id, label]) => {
        const row = document.createElement("div");
        row.className = "plain-list-row";
        row.textContent = `${label}: ${providerStatus[id] ? "Connected" : "Not Connected"}`;
        connectionStatus.appendChild(row);
      });
    }

    function renderCurrentBrain(active) {
      currentBrainCard.innerHTML = "";
      const rows = [
        `Model: ${active.label}`,
        `Source: ${active.type === "local" ? "Local (Ollama)" : "Cloud"}`,
        `Status: ${active.status}`,
      ];
      rows.forEach((text) => {
        const row = document.createElement("div");
        row.className = "plain-list-row";
        row.textContent = text;
        currentBrainCard.appendChild(row);
      });
    }

    async function saveSettings(patch) {
      const response = await postJSON("/api/settings", patch);
      appStatus = response.status;
      renderStatus(appStatus);
      return response;
    }

    function showSettingsNotice(message, kind = "info", actionLabel = "", actionFn = null) {
      settingsNotice.innerHTML = `<strong>${kind === "error" ? "Needs attention." : kind === "success" ? "Done." : "Notice."}</strong> ${escapeHtml(message)}`;
      if (actionLabel && actionFn) {
        const button = document.createElement("button");
        button.type = "button";
        button.textContent = actionLabel;
        button.style.marginTop = "12px";
        button.onclick = actionFn;
        settingsNotice.appendChild(button);
      }
    }

    function renderInstallStatus(data) {
      installBar.style.width = `${data.percent || 0}%`;
      if (data.running) {
        installText.textContent = `${data.progress || "Installing model…"} ${data.percent ? `(${data.percent}%)` : ""}`;
      } else if (data.error) {
        installText.textContent = `Install failed: ${data.error}`;
      } else if (data.done) {
        installText.textContent = data.progress || "Local model is ready.";
      } else {
        installText.textContent = "No installation in progress.";
      }
    }

    function renderLocalModels(installed, ollamaAvailable) {
      localModels.innerHTML = "";
      if (!ollamaAvailable) {
        const item = document.createElement("div");
        item.className = "hint";
        item.innerHTML = 'Install Ollama using: <code>curl https://ollama.ai/install.sh | sh</code>';
        localModels.appendChild(item);
        return;
      }
      installed.forEach((model) => {
        const item = document.createElement("div");
        item.className = "plain-list-row";
        item.textContent = `✓ ${model}`;
        localModels.appendChild(item);
      });
      if (!installed.length) {
        const item = document.createElement("div");
        item.className = "hint";
        item.textContent = "No local models detected yet.";
        localModels.appendChild(item);
      }
    }

    function modelBadgeClass(badge) {
      if (badge === "FREE") return "free";
      if (badge === "LOW COST") return "lowcost";
      if (badge === "LOCAL") return "local";
      return "free";
    }

    function renderModels(models, selectedModel) {
      modelList.innerHTML = "";
      models.forEach((model) => {
        const option = document.createElement("button");
        option.type = "button";
        option.className = `model-option ${model.id === selectedModel ? "active" : ""}`;
        const badges = (model.badge || []).map((badge) => `<span class="badge ${modelBadgeClass(badge)}">${badge}</span>`).join("");
        option.innerHTML = `
          <div class="model-meta">
            <div>
              <div style="font-weight:600;">${escapeHtml(model.label)}</div>
              <div class="hint">${escapeHtml(model.type === "local" ? "Ollama (Local)" : model.provider === "openai" ? "OpenAI" : model.provider === "gemini" ? "Gemini" : model.provider === "anthropic" ? "Anthropic" : "Smart Router")} — ${escapeHtml(model.pricing)}</div>
              <div class="badge-row">${badges}</div>
            </div>
            <div class="status-pill ${model.connected || model.installed ? "ok" : ""}">
              <span class="status-dot"></span>
              <span>${model.type === "local" ? (model.installed ? "Installed" : "Not Installed") : (model.connected ? "Connected" : "Not Connected")}</span>
            </div>
            </div>`;
        option.onclick = async () => {
          if (model.id === "auto") {
            await saveSettings({ selected_model: model.id });
            showSettingsNotice("Smart will choose the best model for each task.", "success");
            return;
          }

          if (model.type === "local") {
            if (!appStatus || !appStatus.ollama_available) {
              showSettingsNotice("This local model needs Ollama first. Install it with: curl https://ollama.ai/install.sh | sh", "error");
              return;
            }
            if (!model.installed) {
              showSettingsNotice(
                `${model.label} is not installed yet.`,
                "info",
                `Install ${model.label}`,
                async () => {
                  await installModel(model.id);
                  await saveSettings({ selected_model: model.id });
                  showSettingsNotice(`${model.label} is being installed now. ARIA will switch to it when ready.`, "success");
                }
              );
              return;
            }
            await saveSettings({ selected_model: model.id });
            showSettingsNotice(`${model.label} is now the active preferred model.`, "success");
            return;
          }

          const keyField = model.provider === "openai" ? openaiKey : model.provider === "gemini" ? geminiKey : anthropicKey;
          const apiKey = keyField.value.trim();
          if (!apiKey) {
            showSettingsNotice(`${model.label} needs a ${model.provider === "openai" ? "OpenAI" : model.provider === "gemini" ? "Gemini" : "Anthropic"} API key before it can be selected.`, "error");
            keyField.focus();
            return;
          }

          const validation = await postJSON("/api/test-connection", { provider: model.provider, api_key: apiKey }).catch((error) => ({ ok: false, detail: error.message }));
          if (!validation.ok) {
            showSettingsNotice(`Could not connect ${model.label}: ${validation.detail}`, "error");
            keyField.focus();
            return;
          }
          await saveSettings({ selected_model: model.id, api_keys: { [model.provider]: apiKey } });
          showSettingsNotice(`${model.label} is now the active preferred model.`, "success");
        };
        modelList.appendChild(option);
      });
    }

    function renderStatus(status) {
      const settings = status.settings;
      const active = status.active;
      openaiKey.value = settings.api_keys.openai || "";
      geminiKey.value = settings.api_keys.gemini || "";
      anthropicKey.value = settings.api_keys.anthropic || "";
      renderCurrentBrain(active);
      renderConnectionStatus(status.provider_status);
      renderModels(status.models, settings.selected_model);
      renderLocalModels(status.installed_local_models, status.ollama_available);
      renderInstallStatus(status.install_status);
      badgesForModel(active);
      if (active.offline_mode) {
        setTranscript("Offline Mode. Using local AI brain.");
      }
      if (settings.theme && settings.theme !== bodyEl.dataset.theme) {
        applyTheme(settings.theme);
      }
    }

    async function refreshStatus() {
      appStatus = await fetch("/api/status").then((r) => r.json());
      renderStatus(appStatus);
      if (statusPoll && appStatus.install_status && !appStatus.install_status.running) {
        clearInterval(statusPoll);
        statusPoll = null;
      }
    }

    async function installModel(modelId) {
      await postJSON("/api/install-model", { model: modelId });
      if (statusPoll) clearInterval(statusPoll);
      statusPoll = setInterval(refreshStatus, 1200);
      showSettingsNotice(`Installing ${modelId}. ARIA will keep updating the progress below.`, "success");
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
      if (sleepMode) {
        setTranscript("Assistant sleeping.");
        return;
      }
      const trimmed = text.trim();
      if (!trimmed || trimmed.length < 2) {
        setTranscript("I need a little more detail before I can help.");
        return;
      }
      addMessage("user", trimmed);
      chatInputValue = "";
      const input = getChatInputEl();
      if (input) input.value = "";
      setTranscript(trimmed);
      playCue(processingSound);
      setStatus("Processing", "thinking");
      try {
        const data = await postJSON("/api/chat", { text: trimmed });
        if (data.tool_events && data.tool_events.length) {
          data.tool_events.forEach((event) => {
            addMessage("tool", `${event.tool}.${event.action}: ${event.result.message}`);
          });
        }
        applyToolEvents(data.tool_events || [], data.result_cards || []);
        addMessage("aria", data.reply);
        renderStatus(data.status);
        setStatus(speakReplies ? "Responding" : (wakeWordEnabled ? "Ready" : "Sleeping"), speakReplies ? "speaking" : (wakeWordEnabled ? "armed" : "idle"));
        if (speakReplies && "speechSynthesis" in window) {
          window.speechSynthesis.cancel();
          const utterance = new SpeechSynthesisUtterance(data.reply);
          utterance.onend = () => {
            setStatus(wakeWordEnabled ? "Ready" : "Sleeping", wakeWordEnabled ? "armed" : "idle");
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
        setStatus(wakeWordEnabled ? "Ready" : "Sleeping", wakeWordEnabled ? "armed" : "idle");
        setVoiceMode(wakeWordEnabled ? "Ready" : "Sleeping");
        return true;
      } catch (error) {
        setStatus(`Mic error: ${error.message}`, "error");
        setTranscript("Microphone access is blocked or unavailable.");
        return false;
      }
    }

    function scheduleWakeRestart() {
      if (sleepMode || !wakeWordEnabled || commandCaptureActive) return;
      clearTimeout(wakeRestartTimer);
      wakeRestartTimer = setTimeout(() => {
        if (sleepMode || !wakeWordEnabled || commandCaptureActive) return;
        startWakeRecognition();
      }, 400);
    }

    function startWakeRecognition() {
      if (sleepMode || !wakeRecognition) return;
      try {
        wakeRecognition.start();
      } catch (error) {
        setStatus("Attention needed", "error");
      }
    }

    async function startCommandCapture() {
      if (sleepMode || !commandRecognition) return;
      if (!(await ensureMic())) return;
      commandCaptureActive = true;
      stopSpeechPlayback();
      playCue(listeningSound);
      setStatus("Listening", "listening");
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
        wakeBtn.disabled = true;
        setStatus("Browser speech recognition unavailable", "error");
        setVoiceMode("Unavailable");
        setTranscript("Use typed input because this browser does not expose speech recognition.");
        return;
      }

      wakeRecognition = new SpeechRecognition();
      wakeRecognition.lang = "en-US";
      wakeRecognition.interimResults = false;
      wakeRecognition.continuous = true;
      wakeRecognition.maxAlternatives = 3;

      wakeRecognition.onstart = () => {
        if (!commandCaptureActive) {
          setStatus("Ready", "armed");
          setVoiceMode("Ready");
        }
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
        stopSpeechPlayback();

        if (afterWake) {
          sendText(afterWake).finally(() => {
            commandCaptureActive = false;
            scheduleWakeRestart();
          });
          return;
        }

        setStatus("Listening", "listening");
        setVoiceMode("Listening");
        setTranscript("Wake word accepted. Say your command now.");
        startCommandCapture();
      };

      listenBtn.onclick = async () => {
        if (sleepMode) {
          await applySleepMode(false);
        }
        wakeWordEnabled = false;
        renderControlIcons();
        setVoiceMode("Listening");
        stopAllRecognition();
        stopSpeechPlayback();
        setTranscript("Manual capture started.");
        setStatus("Listening", "listening");
        startCommandCapture();
      };

      commandRecognition = new SpeechRecognition();
      commandRecognition.lang = "en-US";
      commandRecognition.interimResults = false;
      commandRecognition.continuous = false;
      commandRecognition.maxAlternatives = 1;
      commandRecognition.onstart = () => {
        setStatus("Listening", "listening");
        setVoiceMode("Listening");
      };
      commandRecognition.onend = () => {
        commandCaptureActive = false;
        if (wakeWordEnabled) {
          setVoiceMode("Ready");
          scheduleWakeRestart();
        } else {
          setStatus("Sleeping", "idle");
          setVoiceMode("Sleeping");
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

      wakeBtn.onclick = async () => {
        if (sleepMode) {
          await applySleepMode(false);
        }
        wakeWordEnabled = !wakeWordEnabled;
        renderControlIcons();
        setVoiceMode(wakeWordEnabled ? "Ready" : "Sleeping");
        stopAllRecognition();
        if (wakeWordEnabled) {
          if (!(await ensureMic())) return;
          setTranscript("Voice capture resumed.");
          scheduleWakeRestart();
        } else {
          setTranscript("Voice capture paused.");
          setStatus("Sleeping", "idle");
        }
      };

      sleepBtn.onclick = async () => {
        await applySleepMode(!sleepMode);
      };
    }

    chatToggleBtn.onclick = () => setChatOpen(!chatOpen);

    resetBtn.onclick = async () => {
      await postJSON("/api/reset");
      chatMessages = [];
      toolHistory = [];
      resultCardsCache = [];
      renderChatMessages();
      renderToolTimeline();
      renderResultCards([]);
      addMessage("aria", "Conversation reset.");
      setTranscript("Conversation reset.");
      setStatus(wakeWordEnabled ? "Ready" : "Sleeping", wakeWordEnabled ? "armed" : "idle");
      setVoiceMode(wakeWordEnabled ? "Ready" : "Sleeping");
    };

    settingsBtn.onclick = () => settingsOverlay.classList.add("open");
    closeSettingsBtn.onclick = () => settingsOverlay.classList.remove("open");
    settingsOverlay.onclick = (event) => {
      if (event.target === settingsOverlay) settingsOverlay.classList.remove("open");
    };

    speakBtn.onclick = () => {
      speakReplies = !speakReplies;
      renderControlIcons();
      saveSettings({ speech_replies: speakReplies }).catch(() => {});
      if (!speakReplies && "speechSynthesis" in window) {
        window.speechSynthesis.cancel();
      }
    };

    lightThemeBtn.onclick = () => {
      applyTheme("light");
      saveSettings({ theme: "light" }).catch(() => {});
    };
    darkThemeBtn.onclick = () => {
      applyTheme("dark");
      saveSettings({ theme: "dark" }).catch(() => {});
    };

    saveKeysBtn.onclick = async () => {
      await saveSettings({
        api_keys: {
          openai: openaiKey.value.trim(),
          gemini: geminiKey.value.trim(),
          anthropic: anthropicKey.value.trim(),
        }
      });
      const checks = [
        ["openai", openaiKey.value.trim()],
        ["gemini", geminiKey.value.trim()],
        ["anthropic", anthropicKey.value.trim()],
      ];
      for (const [provider, api_key] of checks) {
        if (!api_key) continue;
        const result = await postJSON("/api/test-connection", { provider, api_key }).catch((error) => ({ ok: false, detail: error.message }));
        if (!result.ok) {
          showSettingsNotice(`${provider} key check failed: ${result.detail}`, "error");
          await refreshStatus();
          return;
        }
      }
      showSettingsNotice("API keys validated successfully.", "success");
      await refreshStatus();
    };

    (async () => {
      const savedTheme = localStorage.getItem("aria-theme");
      if (savedTheme === "dark" || savedTheme === "light") {
        applyTheme(savedTheme);
      } else if (window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches) {
        applyTheme("dark");
      }
      renderControlIcons();
      try {
        await fetch("/health");
        await postJSON("/api/warm");
        playCue(completeSound);
        addMessage("aria", "ARIA is ready. Say 'aria' to wake it, or open settings to choose another AI brain.");
        setTranscript("Say 'aria' to wake the assistant.");
        setStatus("Preparing", "armed");
        setVoiceMode("Ready");
        await refreshStatus();
      } catch (error) {
        addMessage("aria", `Startup error: ${error.message}`);
        setStatus("Startup error", "error");
        setVoiceMode("Unavailable");
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
    "${ARIA_DIR}/config.py" \
    "${ARIA_DIR}/models.py" \
    "${ARIA_DIR}/settings_manager.py" \
    "${ARIA_DIR}/router.py" \
    "${ARIA_DIR}/tool_executor.py" \
    "${ARIA_DIR}/aria.py" \
    "${ARIA_DIR}/models/ollama_model.py" \
    "${ARIA_DIR}/models/openai_model.py" \
    "${ARIA_DIR}/models/gemini_model.py" \
    "${ARIA_DIR}/models/claude_model.py" \
    "${ARIA_DIR}/tools/__init__.py" \
    "${ARIA_DIR}/tools/browser_tools.py" \
    "${ARIA_DIR}/tools/system_tools.py" \
    "${ARIA_DIR}/tools/file_tools.py" \
    "${ARIA_DIR}/tools/search_tools.py" \
    "${ARIA_DIR}/conversation.log" \
    "${ARIA_DIR}/web/index.html" \
    "${ARIA_DIR}/web/listening.mp3" \
    "${ARIA_DIR}/web/processing_command.mp3" \
    "${ARIA_DIR}/web/complete.mp3" \
    "${BIN_DIR}/aria-ollama-serve" \
    "${BIN_DIR}/aria" \
    "${APP_DIR}/aria.desktop" \
    "${SYSTEMD_DIR}/ollama.service"

  rm -f "${BIN_DIR}/aria-model-runner" "${ARIA_DIR}/model_terminal.pid"
}

enable_service() {
  log "[7/9] Configuring Ollama user service..."

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
