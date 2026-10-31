# Backuper [فارسی](readme-fa.md)

**Backuper** is an automated backup & restore toolkit for VPN panel servers.
It takes scheduled backups of your panel, sends them to Telegram, Discord or Gmail —
and puts them back on the server when you need them.

## Supported Platforms

- [x] **Telegram**
- [x] **Discord**
- [x] **Gmail**

## Key Features

- **One script, everything included** — backups, restoring and a web panel
- **Restore from the same platform** you send backups to (Telegram / Discord / Gmail / local file)
- **Web panel** — dashboard, live logs, one-click backup & restore
- **Customizable remarks** (one remark per backup job, several jobs per server)
- **Automated scheduling** with cron
- **Multi-template support** (auto-detects the panels installed on the server)
- **Add/remove custom directories**
- **Send backups with no size limits** (split archives)
- **Set a password for backup files** (AES/ZipCrypto)
- **Clear old backups**
- **Include date and time in file names**
- **Non-interactive mode** for automation (`BACKUPER_NONINTERACTIVE=1`)
- **Optimized for performance**

## Supported Templates

- [x] **X-ui**
- [x] **S-ui**
- [x] **Hiddify**
- [x] **Remnawave**
- [x] **Rebecca**
- [x] **Marzneshin**
- [x] **Marzneshin Logs**
- [x] **Marzban**
- [x] **Marzban Logs**
- [x] **MirzaBot**
- [x] **Walpanel**
- [x] **HolderBot**
- [x] **MarzHelp + Marzban**
- [x] **Phantom**
- [x] **OvPanel**
- [x] **OvNode**
- [x] **MarzGozir**
- [x] **PasarGuard**

## Installation

Run the script on your server as root:

```bash
sudo bash -c "$(curl -sL https://github.com/Hosein21378/Backuper/raw/master/backuper.sh)"
```

Then pick an option from the menu:

```
======== Backuper Menu [v1.0.0] ========

1) Install Backuper
2) Restore Backup
3) Remove All Backups
4) Run All Backup Scripts
5) Web Panel
6) Exit
```

## Restoring a Backup

Backuper can put a backup back on the server, restoring it from **the same platform the
backup was sent to**. Choose `2) Restore Backup` (or run the restore flow directly):

```bash
sudo bash -c "$(curl -sL https://github.com/Hosein21378/Backuper/raw/master/backuper.sh) restore"
```

What the restore does:

- Downloads the newest backup from **Telegram**, **Discord**, **Gmail** or a **local file**
- Finds the backup automatically from the upload history, or lets you paste a message link / file ID
- Detects split archives (`_backuper.z01 ... _backuper.zip`) and merges them safely
- Asks for the password of password-protected archives
- Creates a safety copy of the current files in `/root/prerestore-*.zip` before overwriting anything
- Imports the database dump (`_backuper.sql`) when it exists
- Offers to restart your docker containers after the restore

> Restoring on a fresh server works as well: choose `Manual restore` and enter
> your bot token / webhook URL / Gmail app password.

## Web Panel

A small, dependency-free web panel (pure Python 3, no pip packages) ships with the project.
It is a thin UI over the same `backuper.sh`, so nothing about your backups changes.

```bash
sudo bash -c "$(curl -sL https://github.com/Hosein21378/Backuper/raw/master/panel/install.sh)"
```

The installer prints the panel URL, the user and the generated password.
You can also install it from the menu: `5) Web Panel`.

| Tab | What it does |
|-----|--------------|
| **Dashboard** | every installed backup with its source, schedule and last run — run now, enable/disable, read the log, delete |
| **New backup** | pick the template (detected panels are marked), the interval, the platform and its credentials, an archive password and extra paths |
| **Restore** | restore from Telegram / Discord / Gmail / a local archive, with a live console and confirmation |

Details:

- runs as a **systemd service** (`backuper-panel`), restarts automatically
- **password protected** (session cookie); change it with `backuper-panel --set-password`
- every operation is streamed **live** in the browser, and you can type answers into the console
- the panel drives the script in non-interactive mode, which you can also use directly:

```bash
BACKUPER_NONINTERACTIVE=1 \
BACKUPER_REMARK=master BACKUPER_TEMPLATE=1 BACKUPER_TIMER=60 \
BACKUPER_PLATFORM=telegram BACKUPER_TG_TOKEN="..." BACKUPER_TG_CHAT="..." \
bash backuper.sh install
```

> The panel can change files as root — keep it behind a firewall or a reverse proxy.

## Project layout

```
backuper.sh                 the whole backup / restore engine (single file)
panel/backuper-panel.py     web panel (stdlib only)
panel/install.sh            panel installer (systemd + credentials)
```

## Changing the branding

Everything that points to the project lives in a few constants:

- `backuper.sh` → `PROJECT_NAME`, `PROJECT_OWNER`, `PROJECT_OWNER_LINK`, `GITHUB_REPO`, `REPO_RAW`, `VERSION`
- `panel/backuper-panel.py` → `PRODUCT_NAME`, `REPO_URL`, `VERSION`
- `panel/install.sh` → `REPO_RAW`, `REPO_URL`

## Credits

This project started as **Backuper** by [@ErfJabs](https://t.me/erfjabs) — a great
backup script for VPN panels. This fork adds a full restore engine, a web panel and a
non-interactive mode.

## Support the Project

If you find this project useful, giving it a **star (⭐)** is more than enough. Thank you!
