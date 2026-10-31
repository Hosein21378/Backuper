#!/usr/bin/env python3
"""
Backuper Web Panel
==================
A tiny, dependency-free web panel for Backuper.

It talks to `backuper.sh` in non-interactive mode, so the panel never
re-implements the backup logic: every action is the real script.

Features
  * dashboard with all installed backups (remark, source, schedule, last run)
  * create a backup job from a form (all templates / platforms / password / dirs)
  * run / enable / disable / delete a job
  * restore a backup from Telegram, Discord, Gmail or a local archive
  * live output of every operation, with the ability to type into the console
  * password protected (session cookie), single file, stdlib only

Usage
  backuper-panel --port 8080
  backuper-panel --port 8080 --no-auth
  backuper-panel --set-password
"""

import argparse
import hashlib
import hmac
import html
import json
import os
import re
import secrets
import shutil
import signal
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

VERSION = "v1.0.0"

# Branding - change these to make the project your own
PRODUCT_NAME = "Backuper"
REPO_URL = "https://github.com/Hosein21378/Backuper"
DEFAULT_PORT = 8080
DEFAULT_SCRIPT = "/usr/local/lib/backuper/backuper.sh"
CONFIG_FILE = os.environ.get("BACKUPER_PANEL_CONFIG", "/root/.backuper_panel.conf")
COOKIE_NAME = "bp_session"
SESSION_TTL = 12 * 3600
LOG_DIR = "/root"

TEMPLATES = [
    (1, "X-ui", "/etc/x-ui"),
    (2, "S-ui", "/usr/local/s-ui/db"),
    (3, "Hiddify", "/opt/hiddify-manager"),
    (4, "Remnawave", "/opt/remnawave"),
    (5, "Rebecca", "/opt/rebecca"),
    (6, "Marzneshin", "/etc/opt/marzneshin"),
    (7, "Marzneshin Logs", None),
    (8, "Marzban", "/opt/marzban"),
    (9, "Marzban Logs", None),
    (10, "MirzaBot", "/var/www/html/mirzabotconfig"),
    (11, "Walpanel", "/opt/walpanel"),
    (12, "HolderBot", "/opt/erfjab/holderbot"),
    (13, "MarzHelp + Marzban", "/opt/marzban"),
    (14, "Phantom", "/etc/phantom"),
    (15, "OvPanel", "/opt/ov-panel"),
    (16, "OvNode", "/opt/ov-node"),
    (17, "MarzGozir", "/opt/marzgozir"),
    (18, "PasarGuard", "/opt/pasarguard"),
]

PLATFORMS = ["telegram", "discord", "gmail"]

# ---------------------------------------------------------------------------
# Config & auth
# ---------------------------------------------------------------------------


def load_config():
    cfg = {}
    try:
        with open(CONFIG_FILE, "r", encoding="utf-8") as fh:
            cfg = json.load(fh)
    except Exception:
        cfg = {}
    cfg.setdefault("username", "admin")
    cfg.setdefault("salt", secrets.token_hex(16))
    cfg.setdefault("password_hash", "")
    cfg.setdefault("secret", secrets.token_hex(32))
    return cfg


def save_config(cfg):
    try:
        os.makedirs(os.path.dirname(CONFIG_FILE), exist_ok=True)
        fd = os.open(CONFIG_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(cfg, fh, indent=2)
    except Exception as exc:  # pragma: no cover
        print("warning: cannot save config: %s" % exc)


def hash_password(cfg, password):
    return hashlib.sha256((cfg["salt"] + password).encode("utf-8")).hexdigest()


def set_password(password, username=None):
    cfg = load_config()
    if username:
        cfg["username"] = username
    cfg["password_hash"] = hash_password(cfg, password)
    save_config(cfg)
    return cfg


def make_token(cfg):
    payload = "%s|%d" % (cfg["username"], int(time.time()) + SESSION_TTL)
    sig = hmac.new(cfg["secret"].encode(), payload.encode(), hashlib.sha256).hexdigest()
    return "%s|%s" % (payload, sig)


def check_token(cfg, token):
    try:
        username, expiry, sig = token.rsplit("|", 2)
        payload = "%s|%s" % (username, expiry)
        expected = hmac.new(cfg["secret"].encode(), payload.encode(), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(sig, expected):
            return False
        return int(expiry) > time.time()
    except Exception:
        return False


# ---------------------------------------------------------------------------
# Helpers to inspect and control the backups on this host
# ---------------------------------------------------------------------------


def run(cmd, timeout=15):
    try:
        return subprocess.run(
            cmd, shell=isinstance(cmd, str), capture_output=True, text=True, timeout=timeout
        )
    except Exception as exc:
        class R:
            returncode = 1
            stdout = ""
            stderr = str(exc)
        return R()


def cron_lines():
    res = run(["crontab", "-l"], timeout=10)
    if res.returncode != 0:
        return []
    return res.stdout.splitlines()


def write_cron(lines):
    res = subprocess.run(["crontab", "-"], input="\n".join(lines) + "\n", text=True,
                         capture_output=True)
    return res.returncode == 0


DISABLED_PREFIX = "#backuper-disabled# "

CRON_FIELDS = re.compile(r"^(\S+\s+\S+\s+\S+\s+\S+\s+\S+)\s+(.*)$")


def human_schedule(expr):
    parts = expr.split()
    if len(parts) != 5:
        return expr
    minute, hour, dom, month, dow = parts
    if minute.startswith("*/") and hour == "*":
        return "هر %s دقیقه" % minute[2:]
    if minute == "0" and hour.startswith("*/"):
        return "هر %s ساعت" % hour[2:]
    if minute == "0" and hour == "0":
        return "هر روز ساعت ۰۰:۰۰"
    if minute.isdigit() and hour.isdigit():
        return "هر روز ساعت %02d:%02d" % (int(hour), int(minute))
    return expr


def list_jobs(script_path=None):
    jobs = []
    states = {}
    if os.path.isdir("/root"):
        for name in sorted(os.listdir("/root")):
            if name.startswith(".backuper_") and name.endswith(".conf"):
                full = os.path.join("/root", name)
                data = parse_state_file(full)
                if data.get("REMARK"):
                    states[data["REMARK"]] = data

    cron = cron_lines()

    remarks = set(states.keys())
    if os.path.isdir("/root"):
        for name in os.listdir("/root"):
            m = re.match(r"^_(.+)_backuper_script\.sh$", name)
            if m:
                remarks.add(m.group(1))

    for remark in sorted(remarks):
        script = "/root/_%s_backuper_script.sh" % remark
        state = states.get(remark, {})
        entry = None
        enabled = False
        for line in cron:
            if script in line:
                entry = line
                enabled = not line.startswith(DISABLED_PREFIX)
                break

        schedule = ""
        if entry:
            clean = entry[len(DISABLED_PREFIX):] if entry.startswith(DISABLED_PREFIX) else entry
            m = CRON_FIELDS.match(clean)
            if m:
                schedule = human_schedule(m.group(1))

        run_log = os.path.join(LOG_DIR, ".backuper_%s_run.log" % remark)
        last_run = None
        if os.path.exists(run_log):
            last_run = time.strftime("%Y-%m-%d %H:%M", time.localtime(os.path.getmtime(run_log)))

        jobs.append({
            "remark": remark,
            "platform": state.get("PLATFORM", ""),
            "directories": state.get("BACKUP_DIRECTORIES", ""),
            "schedule": schedule,
            "cron": entry or "",
            "enabled": enabled,
            "installed": os.path.exists(script),
            "last_run": last_run,
            "has_log": os.path.exists(run_log),
            "has_db": bool(state.get("RESTORE_DB_COMMAND")),
            "has_password": bool(state.get("ZIP_PASSWORD")),
        })
    return jobs


def parse_state_file(path):
    data = {}
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                value = value.strip()
                if len(value) >= 2 and value[0] == "'" and value[-1] == "'":
                    value = value[1:-1].replace("'\\''", "'")
                elif len(value) >= 2 and value[0] == '"' and value[-1] == '"':
                    value = value[1:-1]
                data[key] = value
    except Exception:
        pass
    return data


def detect_panels():
    found = []
    for number, name, path in TEMPLATES:
        if path and os.path.exists(path):
            found.append({"template": number, "name": name, "path": path})
    return found


# ---------------------------------------------------------------------------
# Process manager (streams the output of backuper.sh)
# ---------------------------------------------------------------------------


class Proc:
    def __init__(self, proc_id, cmd, env, cwd=None, log_path=None):
        self.id = proc_id
        self.cmd = cmd
        self.buf = ""
        self.lock = threading.Lock()
        self.done = False
        self.rc = None
        self.started = time.time()
        self.log_path = log_path
        self.env = env
        try:
            self.proc = subprocess.Popen(
                cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, cwd=cwd, env=env, bufsize=0,
            )
        except Exception as exc:
            self.buf = "failed to start: %s\n" % exc
            self.done = True
            self.rc = -1
            self.proc = None
            return
        threading.Thread(target=self._reader, daemon=True).start()

    def _reader(self):
        fd = self.proc.stdout.fileno()
        log = None
        if self.log_path:
            try:
                log = open(self.log_path, "a", encoding="utf-8", errors="replace")
            except Exception:
                log = None
        while True:
            try:
                chunk = os.read(fd, 4096)
            except OSError:
                break
            if not chunk:
                break
            text = chunk.decode("utf-8", "replace")
            with self.lock:
                self.buf += text
            if log is not None:
                try:
                    log.write(text)
                    log.flush()
                except Exception:
                    pass
        if log is not None:
            log.close()
        self.rc = self.proc.wait()
        self.done = True

    def send(self, line):
        if self.proc is None or self.done:
            return False
        try:
            self.proc.stdin.write((line + "\n").encode())
            self.proc.stdin.flush()
            return True
        except Exception:
            return False

    def kill(self):
        if self.proc is None or self.done:
            return
        try:
            os.killpg(os.getpgid(self.proc.pid), signal.SIGTERM)
        except Exception:
            try:
                self.proc.terminate()
            except Exception:
                pass

    def snapshot(self):
        with self.lock:
            return {"output": self.buf, "done": self.done, "rc": self.rc}


PROCS = {}
PROCS_LOCK = threading.Lock()


def new_proc(cmd, env, log_path=None):
    proc_id = secrets.token_hex(8)
    with PROCS_LOCK:
        PROCS[proc_id] = Proc(proc_id, cmd, env, log_path=log_path)
        # keep the store small
        if len(PROCS) > 40:
            for key in sorted(PROCS, key=lambda k: PROCS[k].started)[:-20]:
                PROCS.pop(key, None)
    return PROCS[proc_id]


def get_proc(proc_id):
    with PROCS_LOCK:
        return PROCS.get(proc_id)


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------


class Handler(BaseHTTPRequestHandler):
    server_version = "BackuperPanel/" + VERSION
    script = DEFAULT_SCRIPT
    no_auth = False

    # --- low level helpers -------------------------------------------------
    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _send(self, code, body, content_type="text/html; charset=utf-8", extra=None):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Frame-Options", "SAMEORIGIN")
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        try:
            self.wfile.write(body)
        except Exception:
            pass

    def render(self, page):
        return page.replace("{{REPO}}", REPO_URL).replace("{{PRODUCT}}", PRODUCT_NAME)

    def _json(self, obj, code=200):
        self._send(code, json.dumps(obj), "application/json; charset=utf-8")

    def _cookie_token(self):
        raw = self.headers.get("Cookie", "")
        for part in raw.split(";"):
            if "=" in part:
                key, _, value = part.strip().partition("=")
                if key == COOKIE_NAME:
                    return value
        return ""

    def _authed(self):
        if self.no_auth:
            return True
        cfg = load_config()
        if not cfg.get("password_hash"):
            return True  # password not configured yet
        return check_token(cfg, self._cookie_token())

    def _body(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        try:
            return json.loads(raw.decode("utf-8"))
        except Exception:
            return {k: v[0] for k, v in parse_qs(raw.decode("utf-8", "replace")).items()}

    # --- routing -----------------------------------------------------------
    def do_GET(self):
        path = urlparse(self.path).path

        if path == "/login":
            return self.page_login()
        if path == "/api/health":
            return self._json({"ok": True, "version": VERSION})

        if not self._authed():
            if path.startswith("/api/"):
                return self._json({"error": "unauthorized"}, 401)
            return self._send(302, "", extra={"Location": "/login"})

        if path == "/":
            return self._send(200, self.render(INDEX_HTML))
        if path == "/api/overview":
            return self._json(self.overview())
        if path == "/api/templates":
            return self._json({"templates": [{"id": n, "name": nm} for n, nm, _ in TEMPLATES]})
        if path == "/api/detect":
            return self._json({"detected": detect_panels()})
        if path == "/api/jobs/log":
            return self.job_log()
        if path.startswith("/api/proc/"):
            return self.proc_get(path)
        return self._send(404, "not found", "text/plain; charset=utf-8")

    def do_POST(self):
        path = urlparse(self.path).path

        if path == "/login":
            return self.do_login()
        if path == "/logout":
            return self._send(302, "", extra={
                "Location": "/login",
                "Set-Cookie": "%s=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax" % COOKIE_NAME,
            })

        if not self._authed():
            return self._json({"error": "unauthorized"}, 401)

        if path == "/api/jobs/run":
            return self.job_run()
        if path == "/api/jobs/toggle":
            return self.job_toggle()
        if path == "/api/jobs/delete":
            return self.job_delete()
        if path == "/api/install":
            return self.start_install()
        if path == "/api/restore":
            return self.start_restore()
        if path.startswith("/api/proc/"):
            return self.proc_post(path)
        return self._json({"error": "not found"}, 404)

    # --- pages -------------------------------------------------------------
    def page_login(self):
        cfg = load_config()
        query = parse_qs(urlparse(self.path).query)
        if not cfg.get("password_hash"):
            message = "برای این پنل هنوز رمز عبوری تنظیم نشده است. با فلگ --set-password رمز تعیین کنید."
        elif query.get("error"):
            message = "نام کاربری یا رمز عبور نادرست است."
        else:
            message = ""
        return self._send(200, self.render(LOGIN_HTML).replace("{{MSG}}", html.escape(message)))

    def do_login(self):
        cfg = load_config()
        body = self._body()
        password = body.get("password", "")
        username = body.get("username", "")
        if cfg.get("password_hash") and hmac.compare_digest(
            hash_password(cfg, password), cfg["password_hash"]
        ) and username == cfg.get("username", "admin"):
            token = make_token(cfg)
            cookie = "%s=%s; Path=/; HttpOnly; SameSite=Lax; Max-Age=%d" % (
                COOKIE_NAME, token, SESSION_TTL)
            if self.headers.get("Content-Type", "").startswith("application/json"):
                return self._send(200, json.dumps({"ok": True}), "application/json",
                                  extra={"Set-Cookie": cookie})
            return self._send(302, "", extra={"Location": "/", "Set-Cookie": cookie})
        if self.headers.get("Content-Type", "").startswith("application/json"):
            return self._json({"error": "نام کاربری یا رمز عبور نادرست است"}, 401)
        return self._send(302, "", extra={"Location": "/login?error=1"})

    # --- api ---------------------------------------------------------------
    def overview(self):
        jobs = list_jobs()
        info = {
            "version": VERSION,
            "host": os.uname().nodename if hasattr(os, "uname") else "",
            "ip": first_ip(),
            "script": self.script,
            "script_exists": os.path.exists(self.script),
            "root": os.geteuid() == 0,
            "platforms": PLATFORMS,
            "templates": [{"id": n, "name": nm} for n, nm, _ in TEMPLATES],
            "detected": detect_panels(),
            "time": time.strftime("%Y-%m-%d %H:%M:%S"),
        }
        return {"info": info, "jobs": jobs}

    def job_run(self):
        body = self._body()
        remark = (body.get("remark") or "").strip()
        if not re.match(r"^[A-Za-z0-9_]+$", remark):
            return self._json({"error": "invalid remark"}, 400)
        script = "/root/_%s_backuper_script.sh" % remark
        if not os.path.exists(script):
            return self._json({"error": "اسکریپت این بکاپ پیدا نشد: %s" % script}, 404)
        log_path = os.path.join(LOG_DIR, ".backuper_%s_run.log" % remark)
        env = clean_env()
        env["PATH"] = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        proc = new_proc(["bash", script], env, log_path=log_path)
        return self._json({"id": proc.id})

    def job_toggle(self):
        body = self._body()
        remark = (body.get("remark") or "").strip()
        enable = bool(body.get("enabled"))
        script = "/root/_%s_backuper_script.sh" % remark
        if not os.path.exists(script):
            return self._json({"error": "not found"}, 404)
        lines = cron_lines()
        out = []
        changed = False
        for line in lines:
            if script in line:
                changed = True
                if enable:
                    out.append(line[len(DISABLED_PREFIX):] if line.startswith(DISABLED_PREFIX) else line)
                else:
                    out.append(line if line.startswith(DISABLED_PREFIX) else DISABLED_PREFIX + line)
            else:
                out.append(line)
        if not changed:
            return self._json({"error": "کران‌جاب این بکاپ پیدا نشد"}, 404)
        if not write_cron(out):
            return self._json({"error": "ذخیره کران‌جاب ناموفق بود"}, 500)
        return self._json({"ok": True, "enabled": enable})

    def job_delete(self):
        body = self._body()
        remark = (body.get("remark") or "").strip()
        if not re.match(r"^[A-Za-z0-9_]+$", remark):
            return self._json({"error": "invalid remark"}, 400)
        script = "/root/_%s_backuper_script.sh" % remark
        lines = [line for line in cron_lines() if script not in line]
        write_cron(lines)
        for path in (
            script,
            "/root/.backuper_%s.conf" % remark,
            "/root/.backuper_%s_upload.log" % remark,
            "/root/.backuper_%s_run.log" % remark,
        ):
            try:
                os.remove(path)
            except FileNotFoundError:
                pass
            except Exception as exc:
                return self._json({"error": str(exc)}, 500)
        return self._json({"ok": True})

    def job_log(self):
        query = parse_qs(urlparse(self.path).query)
        remark = (query.get("remark") or [""])[0]
        try:
            lines = int((query.get("lines") or ["300"])[0])
        except ValueError:
            lines = 300
        if not re.match(r"^[A-Za-z0-9_]+$", remark):
            return self._json({"error": "invalid remark"}, 400)
        path = os.path.join(LOG_DIR, ".backuper_%s_run.log" % remark)
        if not os.path.exists(path):
            return self._json({"log": "", "exists": False})
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                content = fh.readlines()[-lines:]
        except Exception as exc:
            return self._json({"error": str(exc)}, 500)
        return self._json({"log": "".join(content), "exists": True})

    def proc_get(self, path):
        parts = path.strip("/").split("/")
        if len(parts) < 4:
            return self._json({"error": "not found"}, 404)
        proc = get_proc(parts[2])
        if proc is None:
            return self._json({"error": "not found"}, 404)
        if parts[3] == "stream":
            return self.proc_stream(proc)
        return self._json(proc.snapshot())

    def proc_post(self, path):
        parts = path.strip("/").split("/")
        if len(parts) < 4:
            return self._json({"error": "not found"}, 404)
        proc = get_proc(parts[2])
        if proc is None:
            return self._json({"error": "not found"}, 404)
        if parts[3] == "input":
            body = self._body()
            ok = proc.send(str(body.get("line", "")))
            return self._json({"ok": ok})
        if parts[3] == "kill":
            proc.kill()
            return self._json({"ok": True})
        return self._json({"error": "not found"}, 404)

    def proc_stream(self, proc):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "keep-alive")
        self.end_headers()
        sent = 0
        try:
            while True:
                snap = proc.snapshot()
                output = snap["output"]
                if len(output) > sent:
                    chunk = output[sent:]
                    sent = len(output)
                    self.wfile.write(("data: " + json.dumps({"text": chunk, "done": False}) + "\n\n").encode())
                    self.wfile.flush()
                if snap["done"]:
                    self.wfile.write(("data: " + json.dumps(
                        {"text": "", "done": True, "rc": snap["rc"]}) + "\n\n").encode())
                    self.wfile.flush()
                    break
                time.sleep(0.25)
        except (BrokenPipeError, ConnectionResetError):
            pass
        return

    def start_install(self):
        body = self._body()
        env = clean_env()
        env["BACKUPER_NONINTERACTIVE"] = "1"
        env["PATH"] = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

        remark = (body.get("remark") or "").strip()
        if not re.match(r"^[A-Za-z0-9_]{3,}$", remark):
            return self._json({"error": "نام بکاپ باید حداقل ۳ کاراکتر و فقط شامل حروف/عدد/آندرلاین باشد."}, 400)
        if os.path.exists("/root/_%s_backuper_script.sh" % remark):
            return self._json({"error": "بکاپی با این نام از قبل وجود دارد."}, 409)

        template = str(body.get("template") or "0")
        timer = str(body.get("timer") or "60")
        platform = (body.get("platform") or "").strip()

        env["BACKUPER_REMARK"] = remark
        env["BACKUPER_TEMPLATE"] = template
        env["BACKUPER_TIMER"] = timer
        env["BACKUPER_PLATFORM"] = platform

        if platform == "telegram":
            env["BACKUPER_TG_TOKEN"] = (body.get("tg_token") or "").strip()
            env["BACKUPER_TG_CHAT"] = (body.get("tg_chat") or "").strip()
            env["BACKUPER_TG_TOPIC"] = (body.get("tg_topic") or "").strip()
        elif platform == "discord":
            env["BACKUPER_DISCORD_WEBHOOK"] = (body.get("discord_webhook") or "").strip()
        elif platform == "gmail":
            env["BACKUPER_GMAIL_ADDRESS"] = (body.get("gmail_address") or "").strip()
            env["BACKUPER_GMAIL_PASSWORD"] = (body.get("gmail_password") or "").strip()
        else:
            return self._json({"error": "یک پلتفرم برای ارسال بکاپ انتخاب کنید."}, 400)

        password = (body.get("password") or "").strip()
        if password:
            env["BACKUPER_PASSWORD"] = password

        dirs = (body.get("dirs") or "").strip()
        if dirs:
            env["BACKUPER_DIRS_EXTRA"] = dirs

        if not os.path.exists(self.script):
            return self._json({"error": "اسکریپت backuper.sh پیدا نشد: %s" % self.script}, 500)

        proc = new_proc(["bash", self.script, "install"], env)
        return self._json({"id": proc.id})

    def start_restore(self):
        body = self._body()
        env = clean_env()
        env["BACKUPER_NONINTERACTIVE"] = "1"
        env["PATH"] = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        env["BACKUPER_RESTORE_PLATFORM"] = (body.get("platform") or "").strip()
        env["BACKUPER_RESTORE_YES"] = "1" if body.get("confirmed") else ""
        env["BACKUPER_RESTORE_DB"] = "yes" if body.get("restore_db") else "no"
        env["BACKUPER_RESTORE_RESTART"] = "yes" if body.get("restart") else "no"

        remark = (body.get("remark") or "").strip()
        if remark:
            if not re.match(r"^[A-Za-z0-9_]+$", remark):
                return self._json({"error": "invalid remark"}, 400)
            env["BACKUPER_RESTORE_REMARK"] = remark

        platform = env["BACKUPER_RESTORE_PLATFORM"]
        if platform == "telegram":
            env["BACKUPER_TG_TOKEN"] = (body.get("tg_token") or "").strip()
            env["BACKUPER_TG_CHAT"] = (body.get("tg_chat") or "").strip()
            env["BACKUPER_TG_TOPIC"] = (body.get("tg_topic") or "").strip()
            if (body.get("message") or "").strip():
                env["BACKUPER_RESTORE_MSG"] = body["message"].strip()
        elif platform == "discord":
            env["BACKUPER_DISCORD_WEBHOOK"] = (body.get("discord_webhook") or "").strip()
            if (body.get("message") or "").strip():
                env["BACKUPER_RESTORE_MSG"] = body["message"].strip()
        elif platform == "gmail":
            env["BACKUPER_GMAIL_ADDRESS"] = (body.get("gmail_address") or "").strip()
            env["BACKUPER_GMAIL_PASSWORD"] = (body.get("gmail_password") or "").strip()
        elif platform == "local":
            path = (body.get("path") or "").strip()
            if not path:
                return self._json({"error": "مسیر آرشیو را وارد کنید."}, 400)
            env["BACKUPER_RESTORE_PATH"] = path
        else:
            return self._json({"error": "منبع بازگردانی را انتخاب کنید."}, 400)

        if (body.get("zip_password") or "").strip():
            env["BACKUPER_ZIP_PASSWORD"] = body["zip_password"].strip()

        if not body.get("confirmed"):
            return self._json({"error": "برای بازگردانی باید تأیید کنید."}, 400)
        if not os.path.exists(self.script):
            return self._json({"error": "اسکریپت backuper.sh پیدا نشد: %s" % self.script}, 500)

        proc = new_proc(["bash", self.script, "restore"], env)
        return self._json({"id": proc.id})


def clean_env():
    env = {k: v for k, v in os.environ.items() if not k.startswith("BACKUPER_")}
    env.setdefault("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
    env["TERM"] = "dumb"
    return env


def first_ip():
    try:
        out = subprocess.run(["hostname", "-I"], capture_output=True, text=True, timeout=5).stdout
        return out.split()[0]
    except Exception:
        return ""


# ---------------------------------------------------------------------------
# HTML
# ---------------------------------------------------------------------------

LOGIN_HTML = """<!doctype html>
<html lang="fa" dir="rtl">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>ورود به پنل بکاپر</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body { margin:0; min-height:100vh; display:flex; align-items:center; justify-content:center;
         font-family: Vazirmatn, "Segoe UI", Tahoma, sans-serif;
         background: radial-gradient(1200px 600px at 20% -10%, #12332b, #0b0f14 60%); color:#e7eef2; }
  form { width: 340px; background:#111820; border:1px solid #1f2b36; border-radius:16px; padding:26px;
         box-shadow: 0 25px 60px rgba(0,0,0,.45); }
  h1 { font-size:19px; margin:0 0 4px; }
  p.sub { color:#8aa0b0; font-size:12.5px; margin:0 0 18px; }
  label { display:block; font-size:12.5px; color:#9db0be; margin:12px 0 6px; }
  input { width:100%; padding:11px 12px; border-radius:10px; border:1px solid #24313d;
          background:#0c1218; color:#e7eef2; font-size:14px; font-family:inherit; }
  input:focus { outline:none; border-color:#2fd39b; box-shadow:0 0 0 3px rgba(47,211,155,.15); }
  button { width:100%; margin-top:18px; padding:11px; border:0; border-radius:10px; cursor:pointer;
           font-family:inherit; font-size:14.5px; font-weight:700; color:#04130d;
           background:linear-gradient(135deg,#2fd39b,#20b37f); }
  .msg { margin-top:14px; font-size:12.5px; color:#ffb4a8; line-height:1.7; }
</style>
</head>
<body>
<form method="post" action="/login">
  <h1>📦 پنل بکاپر</h1>
  <p class="sub">مدیریت بکاپ و بازگردانی</p>
  <label>نام کاربری</label>
  <input name="username" value="admin" autocomplete="username" required>
  <label>رمز عبور</label>
  <input name="password" type="password" autocomplete="current-password" required autofocus>
  <button type="submit">ورود</button>
  <div class="msg">{{MSG}}</div>
  <div style="margin-top:14px;font-size:11.5px;color:#5f7484"><a href="{{REPO}}" target="_blank" rel="noopener" style="color:#5f7484">github.com/Hosein21378/Backuper</a></div>
</form>
</body>
</html>
"""

INDEX_HTML = r"""<!doctype html>
<html lang="fa" dir="rtl">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>پنل بکاپر</title>
<style>
  :root { color-scheme: dark; --bg:#0b0f14; --card:#111820; --line:#1e2a35; --txt:#e7eef2;
          --mut:#8aa0b0; --acc:#2fd39b; --acc2:#20b37f; --warn:#ffb454; --err:#ff6b6b; }
  * { box-sizing:border-box; }
  body { margin:0; font-family: Vazirmatn, "Segoe UI", Tahoma, sans-serif; background:
         radial-gradient(900px 500px at 85% -15%, #12332b, transparent), var(--bg); color:var(--txt); }
  a { color: var(--acc); }
  header { display:flex; align-items:center; gap:14px; padding:16px 22px; border-bottom:1px solid var(--line);
           position:sticky; top:0; backdrop-filter: blur(10px); background:rgba(11,15,20,.75); z-index:5; }
  header h1 { font-size:17px; margin:0; }
  header .badge { font-size:11px; color:var(--mut); border:1px solid var(--line); border-radius:999px;
                  padding:3px 9px; }
  header .spacer { flex:1; }
  main { max-width:1080px; margin:0 auto; padding:20px 18px 60px; }
  .tabs { display:flex; gap:8px; margin-bottom:18px; flex-wrap:wrap; }
  .tab { padding:9px 15px; border-radius:11px; border:1px solid var(--line); background:#0e151c;
         color:var(--mut); cursor:pointer; font-size:13.5px; font-family:inherit; }
  .tab.active { color:#04130d; background:linear-gradient(135deg,#2fd39b,#20b37f); border-color:transparent;
                font-weight:700; }
  .card { background:var(--card); border:1px solid var(--line); border-radius:16px; padding:18px; margin-bottom:14px; }
  .card h2 { font-size:14.5px; margin:0 0 14px; }
  .row { display:flex; gap:12px; flex-wrap:wrap; }
  .col { flex:1 1 220px; }
  label { display:block; font-size:12px; color:var(--mut); margin:10px 0 5px; }
  input, select, textarea { width:100%; padding:10px 11px; border-radius:10px; border:1px solid #24313d;
        background:#0c1218; color:var(--txt); font-size:13.5px; font-family:inherit; }
  textarea { min-height:64px; resize:vertical; }
  input:focus, select:focus, textarea:focus { outline:none; border-color:var(--acc);
        box-shadow:0 0 0 3px rgba(47,211,155,.13); }
  button.btn { padding:10px 16px; border-radius:10px; border:1px solid var(--line); background:#0e151c;
        color:var(--txt); cursor:pointer; font-family:inherit; font-size:13px; }
  button.btn:hover { border-color:#2b3b49; }
  button.primary { background:linear-gradient(135deg,#2fd39b,#20b37f); color:#04130d; border:0; font-weight:700; }
  button.danger { color:#ffb4a8; border-color:#4a2626; background:#1a1013; }
  .job { border:1px solid var(--line); border-radius:14px; padding:14px; margin-bottom:10px; background:#0e151c; }
  .job .top { display:flex; align-items:center; gap:10px; flex-wrap:wrap; }
  .job .name { font-weight:700; font-size:14.5px; }
  .pill { font-size:11px; padding:3px 9px; border-radius:999px; border:1px solid var(--line); color:var(--mut); }
  .pill.on { color:#7ef0c4; border-color:#1d5d47; background:#0c2019; }
  .pill.off { color:#ffb4a8; border-color:#5a2a2a; background:#1a1013; }
  .job .meta { color:var(--mut); font-size:12px; margin-top:8px; line-height:1.9; direction:ltr; text-align:right; }
  .job .actions { display:flex; gap:8px; margin-top:12px; flex-wrap:wrap; }
  .empty { color:var(--mut); text-align:center; padding:26px; font-size:13px; }
  .hint { color:var(--mut); font-size:12px; line-height:1.8; }
  .err { color:var(--err); font-size:12.5px; margin-top:10px; min-height:16px; }
  .ok { color:var(--acc); font-size:12.5px; }
  /* console */
  .overlay { position:fixed; inset:0; background:rgba(4,7,10,.72); display:none; z-index:20;
             align-items:center; justify-content:center; padding:16px; }
  .overlay.show { display:flex; }
  .console { width:100%; max-width:900px; height:min(78vh, 640px); background:#080c11; border:1px solid var(--line);
             border-radius:16px; display:flex; flex-direction:column; overflow:hidden; }
  .console .bar { display:flex; align-items:center; gap:10px; padding:10px 14px; border-bottom:1px solid var(--line);
                  background:#0c1319; font-size:12.5px; }
  .console pre { flex:1; margin:0; padding:14px; overflow:auto; font-family: ui-monospace, Menlo, Consolas, monospace;
                 font-size:12px; line-height:1.65; white-space:pre-wrap; word-break:break-word; direction:ltr; text-align:left; }
  .console .inbar { display:flex; gap:8px; padding:10px 12px; border-top:1px solid var(--line); background:#0c1319; }
  .console .inbar input { font-family: ui-monospace, Menlo, Consolas, monospace; direction:ltr; }
  .status { font-size:11.5px; padding:2px 8px; border-radius:999px; border:1px solid var(--line); color:var(--mut); }
  .status.run { color:#0b1a14; background:var(--acc); border-color:transparent; font-weight:700; }
  .status.done { color:#9fe8c8; border-color:#1d5d47; }
  .status.fail { color:#ffb4a8; border-color:#5a2a2a; }
  @media (max-width:600px) { header h1 { font-size:15px; } main { padding:14px 12px 50px; } }
</style>
</head>
<body>
<header>
  <h1>📦 پنل بکاپر</h1>
  <span class="badge" id="ver">…</span>
  <span class="badge" id="host"></span>
  <span class="spacer"></span>
  <a href="{{REPO}}" target="_blank" rel="noopener" style="font-size:12.5px;text-decoration:none">GitHub</a>
  <a href="/logout" style="font-size:12.5px;text-decoration:none" onclick="return logout(event)">خروج</a>
</header>
<main>
  <div class="tabs">
    <button class="tab active" data-tab="dash">داشبورد</button>
    <button class="tab" data-tab="new">بکاپ جدید</button>
    <button class="tab" data-tab="restore">بازگردانی</button>
  </div>

  <div class="card" id="warn" style="display:none;border-color:#5a2a2a;background:#1a1013;color:#ffb4a8;font-size:12.5px"></div>

  <section id="tab-dash">
    <div class="card">
      <h2>بکاپ‌های نصب‌شده</h2>
      <div id="jobs"><div class="empty">در حال بارگذاری…</div></div>
    </div>
  </section>

  <section id="tab-new" style="display:none">
    <div class="card">
      <h2>ساخت بکاپ جدید</h2>
      <div class="row">
        <div class="col">
          <label>نام بکاپ (remark)</label>
          <input id="n_remark" placeholder="master" value="master">
        </div>
        <div class="col">
          <label>قالب</label>
          <select id="n_template"></select>
        </div>
        <div class="col">
          <label>فاصله‌ی بکاپ (دقیقه)</label>
          <input id="n_timer" type="number" min="1" max="1440" value="60">
        </div>
      </div>
      <div class="row">
        <div class="col">
          <label>پلتفرم ارسال</label>
          <select id="n_platform">
            <option value="telegram">تلگرام</option>
            <option value="discord">دیسکورد</option>
            <option value="gmail">جیمیل</option>
          </select>
        </div>
        <div class="col">
          <label>رمز آرشیو (اختیاری)</label>
          <input id="n_password" placeholder="حداقل ۸ کاراکتر، فقط حروف و عدد">
        </div>
      </div>

      <div id="pf_telegram">
        <div class="row">
          <div class="col"><label>توکن ربات</label><input id="n_tg_token" placeholder="123456:ABC…"></div>
          <div class="col"><label>Chat ID</label><input id="n_tg_chat" placeholder="-1001234567890"></div>
          <div class="col"><label>Topic ID (اختیاری)</label><input id="n_tg_topic"></div>
        </div>
      </div>
      <div id="pf_discord" style="display:none">
        <label>آدرس Webhook دیسکورد</label>
        <input id="n_discord" placeholder="https://discord.com/api/webhooks/…">
      </div>
      <div id="pf_gmail" style="display:none">
        <div class="row">
          <div class="col"><label>ایمیل</label><input id="n_gmail" placeholder="you@gmail.com"></div>
          <div class="col"><label>App Password</label><input id="n_gmail_pw" placeholder="xxxx xxxx xxxx xxxx"></div>
        </div>
      </div>

      <label>مسیرهای اضافه (اختیاری، با فاصله جدا کنید)</label>
      <input id="n_dirs" placeholder="/etc/myapp /var/lib/myapp">

      <div style="margin-top:16px;display:flex;gap:10px;align-items:center">
        <button class="btn primary" onclick="startInstall()">نصب و اجرای بکاپ</button>
        <span class="hint">بعد از نصب، اولین بکاپ همین حالا ارسال می‌شود.</span>
      </div>
      <div class="err" id="n_err"></div>
    </div>
  </section>

  <section id="tab-restore" style="display:none">
    <div class="card">
      <h2>بازگردانی بکاپ</h2>
      <p class="hint">بکاپ از همان پلتفرمی که ارسال شده دانلود و روی این سرور بازگردانی می‌شود.
        قبل از بازنویسی، از فایل‌های فعلی یک نسخه‌ی ایمن در <code>/root/prerestore-*.zip</code> ساخته می‌شود.</p>
      <div class="row">
        <div class="col">
          <label>منبع</label>
          <select id="r_platform">
            <option value="telegram">تلگرام</option>
            <option value="discord">دیسکورد</option>
            <option value="gmail">جیمیل</option>
            <option value="local">فایل محلی روی سرور</option>
          </select>
        </div>
        <div class="col">
          <label>نام بکاپ (اختیاری)</label>
          <input id="r_remark" placeholder="master" list="joblist">
          <datalist id="joblist"></datalist>
        </div>
        <div class="col">
          <label>رمز آرشیو (اگر رمزدار است)</label>
          <input id="r_zip_pw">
        </div>
      </div>

      <div id="rp_telegram">
        <div class="row">
          <div class="col"><label>توکن ربات</label><input id="r_tg_token" placeholder="اگر خالی باشد از پروفایل ذخیره‌شده خوانده می‌شود"></div>
          <div class="col"><label>Chat ID</label><input id="r_tg_chat"></div>
          <div class="col"><label>Topic ID</label><input id="r_tg_topic"></div>
        </div>
        <label>لینک پیام یا file_id (اختیاری)</label>
        <input id="r_msg" placeholder="https://t.me/c/123456789/42">
      </div>
      <div id="rp_discord" style="display:none">
        <label>آدرس Webhook دیسکورد</label>
        <input id="r_discord" placeholder="https://discord.com/api/webhooks/…">
        <label>لینک/آیدی پیام (اختیاری)</label>
        <input id="r_discord_msg" placeholder="https://discord.com/channels/…/…/…">
      </div>
      <div id="rp_gmail" style="display:none">
        <div class="row">
          <div class="col"><label>ایمیل</label><input id="r_gmail"></div>
          <div class="col"><label>App Password</label><input id="r_gmail_pw"></div>
        </div>
      </div>
      <div id="rp_local" style="display:none">
        <label>مسیر فایل یا پوشه‌ی آرشیو</label>
        <input id="r_path" placeholder="/root/1031-1530_master_backuper.zip">
      </div>

      <div class="row" style="margin-top:14px">
        <div class="col"><label><input type="checkbox" id="r_db" checked style="width:auto"> ایمپورت دیتابیس</label></div>
        <div class="col"><label><input type="checkbox" id="r_restart" style="width:auto"> ری‌استارت کانتینرهای داکر</label></div>
        <div class="col"><label><input type="checkbox" id="r_confirm" style="width:auto"> بازگردانی را تأیید می‌کنم</label></div>
      </div>

      <div style="margin-top:16px">
        <button class="btn primary" onclick="startRestore()">شروع بازگردانی</button>
      </div>
      <div class="err" id="r_err"></div>
    </div>
  </section>
</main>

<div class="overlay" id="overlay">
  <div class="console">
    <div class="bar">
      <strong id="c_title">اجرا</strong>
      <span class="status" id="c_status">در حال اجرا…</span>
      <span class="spacer" style="flex:1"></span>
      <button class="btn danger" onclick="killProc()">توقف</button>
      <button class="btn" onclick="closeConsole()">بستن</button>
    </div>
    <pre id="c_out"></pre>
    <div class="inbar">
      <input id="c_in" placeholder="پاسخ به سؤال اسکریپت (Enter برای ارسال)" onkeydown="if(event.key==='Enter'){sendInput()}">
      <button class="btn" onclick="sendInput()">ارسال</button>
    </div>
  </div>
</div>

<script>
const $ = (id) => document.getElementById(id);
let state = { jobs: [], procId: null, es: null, timer: null };

document.querySelectorAll('.tab').forEach(t => t.onclick = () => {
  document.querySelectorAll('.tab').forEach(x => x.classList.remove('active'));
  t.classList.add('active');
  ['dash','new','restore'].forEach(name => $('tab-'+name).style.display = (name===t.dataset.tab)?'':'none');
  if (t.dataset.tab === 'dash') loadOverview();
});

async function api(path, opts={}) {
  const res = await fetch(path, Object.assign({headers:{'Content-Type':'application/json'}}, opts));
  if (res.status === 401) { location.href = '/login'; throw new Error('unauthorized'); }
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || ('HTTP ' + res.status));
  return data;
}

async function loadOverview() {
  try {
    const data = await api('/api/overview');
    state.jobs = data.jobs;
    $('ver').textContent = 'نسخه ' + data.info.version;
    $('host').textContent = (data.info.ip || data.info.host || '');
    const msgs = [];
    if (!data.info.root) msgs.push('پنل با دسترسی root اجرا نشده است؛ نصب بکاپ و بازگردانی نیاز به root دارد.');
    if (!data.info.script_exists) msgs.push('اسکریپت backuper.sh پیدا نشد: ' + data.info.script);
    $('warn').style.display = msgs.length ? '' : 'none';
    $('warn').textContent = msgs.join('  •  ');
    renderJobs();
    renderDetected(data.info, data.jobs || []);
  } catch (e) { $('jobs').innerHTML = '<div class="empty">خطا: ' + e.message + '</div>'; }
}

function renderDetected(info, jobs) {
  $('joblist').innerHTML = (jobs || []).map(j => `<option value="${j.remark}">`).join('');
  const sel = $('n_template');
  if (sel.dataset.filled) return;
  const detected = new Map((info.detected || []).map(d => [d.template, d.path]));
  sel.innerHTML = (info.templates || []).map(t => {
    const mark = detected.has(t.id) ? ' ✅ پیدا شد' : '';
    return `<option value="${t.id}">${t.name}${mark}</option>`;
  }).join('') + '<option value="0">Custom (بدون قالب)</option>';
  const first = (info.detected || [])[0];
  if (first) sel.value = String(first.template);
  sel.dataset.filled = '1';
}

function renderJobs() {
  const box = $('jobs');
  if (!state.jobs.length) {
    box.innerHTML = '<div class="empty">هنوز بکاپی روی این سرور نصب نشده است. از تب «بکاپ جدید» شروعنید.</div>';
    return;
  }
  box.innerHTML = state.jobs.map(j => `
    <div class="job">
      <div class="top">
        <span class="name">${escapeHtml(j.remark)}</span>
        <span class="pill ${j.enabled ? 'on' : 'off'}">${j.enabled ? 'فعال' : 'غیرفعال'}</span>
        ${j.platform ? `<span class="pill">${escapeHtml(j.platform)}</span>` : ''}
        ${j.schedule ? `<span class="pill">${escapeHtml(j.schedule)}</span>` : '<span class="pill off">بدون زمان‌بندی</span>'}
        ${j.has_password ? '<span class="pill">رمزدار</span>' : ''}
        ${j.has_db ? '<span class="pill">دیتابیس</span>' : ''}
      </div>
      <div class="meta">
        ${j.directories ? 'مسیرها: ' + escapeHtml(j.directories) : ''}
        ${j.last_run ? '<br>آخرین اجرا: ' + escapeHtml(j.last_run) : '<br>هنوز اجرا نشده'}
      </div>
      <div class="actions">
        <button class="btn primary" onclick="runNow('${j.remark}')">اجرای فوری</button>
        <button class="btn" onclick="toggleJob('${j.remark}', ${!j.enabled})">${j.enabled ? 'غیرفعال کردن' : 'فعال کردن'}</button>
        <button class="btn" onclick="showLog('${j.remark}')">لاگ</button>
        <button class="btn danger" onclick="deleteJob('${j.remark}')">حذف</button>
      </div>
    </div>`).join('');
}

function escapeHtml(s) {
  return String(s || '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}

async function runNow(remark) {
  try {
    const {id} = await api('/api/jobs/run', {method:'POST', body:JSON.stringify({remark})});
    openConsole('اجرای بکاپ ' + remark, id, () => loadOverview());
  } catch (e) { alert(e.message); }
}

async function toggleJob(remark, enabled) {
  try { await api('/api/jobs/toggle', {method:'POST', body:JSON.stringify({remark, enabled})}); loadOverview(); }
  catch (e) { alert(e.message); }
}

async function deleteJob(remark) {
  if (!confirm('بکاپ «' + remark + '» و زمان‌بندی آن حذف شود؟')) return;
  try { await api('/api/jobs/delete', {method:'POST', body:JSON.stringify({remark})}); loadOverview(); }
  catch (e) { alert(e.message); }
}

async function showLog(remark) {
  try {
    const data = await api('/api/jobs/log?remark=' + encodeURIComponent(remark) + '&lines=400');
    openConsole('لاگ ' + remark, null, null, data.exists ? data.log : 'لاگی برای این بکاپ ثبت نشده است.');
  } catch (e) { alert(e.message); }
}

/* console ----------------------------------------------------------------- */
function openConsole(title, procId, onDone, staticText) {
  $('c_title').textContent = title;
  $('c_out').textContent = staticText || '';
  $('c_status').textContent = procId ? 'در حال اجرا…' : 'پایان';
  $('c_status').className = 'status' + (procId ? ' run' : ' done');
  $('overlay').classList.add('show');
  state.procId = procId;
  state.onDone = onDone;
  if (state.es) { state.es.close(); state.es = null; }
  if (!procId) return;
  const es = new EventSource('/api/proc/' + procId + '/stream');
  state.es = es;
  es.onmessage = (ev) => {
    const msg = JSON.parse(ev.data);
    if (msg.text) {
      const pre = $('c_out');
      const atBottom = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 40;
      pre.textContent += msg.text;
      if (atBottom) pre.scrollTop = pre.scrollHeight;
    }
    if (msg.done) {
      es.close(); state.es = null;
      const ok = msg.rc === 0;
      $('c_status').textContent = ok ? 'با موفقیت تمام شد' : ('خطا (کد ' + msg.rc + ')');
      $('c_status').className = 'status ' + (ok ? 'done' : 'fail');
      if (state.onDone) state.onDone();
      loadOverview();
    }
  };
  es.onerror = () => { if (state.es) { state.es.close(); state.es = null; } };
}

function closeConsole() {
  if (state.es) { state.es.close(); state.es = null; }
  $('overlay').classList.remove('show');
}

async function sendInput() {
  if (!state.procId) return;
  const line = $('c_in').value;
  $('c_in').value = '';
  await api('/api/proc/' + state.procId + '/input', {method:'POST', body:JSON.stringify({line})}).catch(()=>{});
}

async function killProc() {
  if (!state.procId) return;
  await api('/api/proc/' + state.procId + '/kill', {method:'POST', body:'{}'}).catch(()=>{});
}

/* forms ------------------------------------------------------------------- */
$('n_platform').onchange = () => {
  const p = $('n_platform').value;
  $('pf_telegram').style.display = p === 'telegram' ? '' : 'none';
  $('pf_discord').style.display = p === 'discord' ? '' : 'none';
  $('pf_gmail').style.display = p === 'gmail' ? '' : 'none';
};
$('r_platform').onchange = () => {
  const p = $('r_platform').value;
  $('rp_telegram').style.display = p === 'telegram' ? '' : 'none';
  $('rp_discord').style.display = p === 'discord' ? '' : 'none';
  $('rp_gmail').style.display = p === 'gmail' ? '' : 'none';
  $('rp_local').style.display = p === 'local' ? '' : 'none';
};

async function startInstall() {
  $('n_err').textContent = '';
  const body = {
    remark: $('n_remark').value.trim(),
    template: $('n_template').value,
    timer: $('n_timer').value,
    platform: $('n_platform').value,
    password: $('n_password').value.trim(),
    dirs: $('n_dirs').value.trim(),
    tg_token: $('n_tg_token').value.trim(),
    tg_chat: $('n_tg_chat').value.trim(),
    tg_topic: $('n_tg_topic').value.trim(),
    discord_webhook: $('n_discord').value.trim(),
    gmail_address: $('n_gmail').value.trim(),
    gmail_password: $('n_gmail_pw').value.trim(),
  };
  try {
    const {id} = await api('/api/install', {method:'POST', body: JSON.stringify(body)});
    openConsole('نصب بکاپ ' + body.remark, id, () => loadOverview());
  } catch (e) { $('n_err').textContent = e.message; }
}

async function startRestore() {
  $('r_err').textContent = '';
  const body = {
    platform: $('r_platform').value,
    remark: $('r_remark').value.trim(),
    zip_password: $('r_zip_pw').value,
    tg_token: $('r_tg_token').value.trim(),
    tg_chat: $('r_tg_chat').value.trim(),
    tg_topic: $('r_tg_topic').value.trim(),
    message: $('r_platform').value === 'discord' ? $('r_discord_msg').value.trim() : $('r_msg').value.trim(),
    discord_webhook: $('r_discord').value.trim(),
    gmail_address: $('r_gmail').value.trim(),
    gmail_password: $('r_gmail_pw').value.trim(),
    path: $('r_path').value.trim(),
    restore_db: $('r_db').checked,
    restart: $('r_restart').checked,
    confirmed: $('r_confirm').checked,
  };
  if (!body.confirmed) { $('r_err').textContent = 'تیک تأیید بازگردانی را بزنید.'; return; }
  try {
    const {id} = await api('/api/restore', {method:'POST', body: JSON.stringify(body)});
    openConsole('بازگردانی بکاپ', id, () => loadOverview());
  } catch (e) { $('r_err').textContent = e.message; }
}

async function logout(ev) {
  ev.preventDefault();
  await fetch('/logout', {method:'POST'}).catch(()=>{});
  location.href = '/login';
  return false;
}

loadOverview();
setInterval(() => { if ($('tab-dash').style.display !== 'none') loadOverview(); }, 30000);
</script>
</body>
</html>
"""


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(description="Backuper web panel")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--script", default=DEFAULT_SCRIPT, help="path to backuper.sh")
    parser.add_argument("--no-auth", action="store_true", help="disable the login (not recommended)")
    parser.add_argument("--set-password", nargs="?", const="", metavar="PASSWORD",
                        help="set (or generate) the panel password and exit")
    parser.add_argument("--username", default=None)
    args = parser.parse_args()

    if args.set_password is not None:
        password = args.set_password or secrets.token_urlsafe(12)
        cfg = set_password(password, args.username)
        print("user:     %s" % cfg["username"])
        print("password: %s" % password)
        print("config:   %s" % CONFIG_FILE)
        return 0

    cfg = load_config()
    if not cfg.get("password_hash") and not args.no_auth:
        print("No panel password is set. Run: %s --set-password" % sys.argv[0], file=sys.stderr)
        return 1
    save_config(cfg)

    Handler.script = args.script
    Handler.no_auth = args.no_auth

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.daemon_threads = True
    print("Backuper panel %s listening on http://%s:%d" % (VERSION, args.host, args.port))
    print("script: %s" % args.script)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
