# PasarGuard Backup · بکاپ پاسارگارد [فارسی](readme-fa.md)

**PasarGuard Backup** takes scheduled, encrypted backups of your PasarGuard panel
(and every other supported VPN panel), sends them to **Telegram / Discord / Gmail**,
and **restores them back on the server** whenever you need — from the CLI or from a
built-in web panel.

## Why this project

- **One file, no dependencies** — the whole engine is `pasarguard-backup.sh`
- **Backup + Restore** — the same channel that receives the backup is used to restore it
- **Web panel** — dashboard, live logs, one-click backup & restore (pure Python 3, stdlib only)
- **PasarGuard ready** — detects `/opt/pasarguard/.env`, dumps the PostgreSQL/MySQL database
  and the panel data, and imports them back on restore

## Supported Platforms

- [x] **Telegram**
- [x] **Discord**
- [x] **Gmail**

## Key Features

- **Restore from the same platform** you send backups to (Telegram / Discord / Gmail / local file)
- **Web panel** — dashboard, live logs, one-click backup & restore
- **Customizable remarks** (one remark per backup job, several jobs per server)
- **Automated scheduling** with cron
- **Multi-template support** (auto-detects the panels installed on the server)
- **Add/remove custom directories**
- **Send backups with no size limits** (split archives, merged safely on restore)
- **Set a password for backup files**
- **Database dump & import** (PostgreSQL / MySQL / MariaDB, host or docker)
- **Safety copy before every restore** (`/root/prerestore-*.zip`)
- **Clear old backups**
- **Include date and time in file names**
- **Non-interactive mode** for automation (`BACKUPER_NONINTERACTIVE=1`)
- **Optimized for performance**

## Supported Templates

- [x] **PasarGuard**
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

## Installation

Run the script on your server as root:

```bash
sudo bash -c "$(curl -sL https://github.com/Hosein21378/pasarguard-backup/raw/main/pasarguard-backup.sh)"
```

Then pick an option from the menu:

```
======== PasarGuard Backup Menu [v1.0.0] ========

1) Install / Create Backup
2) Restore Backup
3) Remove All Backups
4) Run All Backup Scripts
5) Web Panel
6) Exit
```

For PasarGuard: choose `1) Install / Create Backup`, pick template **18) PasarGuard**, and enter
your Telegram / Discord / Gmail destination. The database credentials are read from
`/opt/pasarguard/.env` automatically.

## Restoring a Backup

Choose `2) Restore Backup`, or run the restore flow directly:

```bash
sudo bash -c "$(curl -sL https://github.com/Hosein21378/pasarguard-backup/raw/main/pasarguard-backup.sh) restore"
```

What the restore does:

- Downloads the newest backup from **Telegram**, **Discord**, **Gmail** or a **local file**
- Finds the backup automatically from the upload history, or lets you paste a message link / file ID
- Detects split archives (`_backuper.z01 ... _backuper.zip`) and merges them safely
- Asks for the password of password-protected archives
- Creates a safety copy of the current files in `/root/prerestore-*.zip` before overwriting anything
- Imports the database dump (`_backuper.sql`) when it exists — including the PasarGuard database
- Offers to restart your docker containers after the restore

> Restoring on a fresh server works as well: choose `Manual restore` and enter
> your bot token / webhook URL / Gmail app password.

## Web Panel

A small, dependency-free web panel ships with the project. It is a thin UI over the same
`pasarguard-backup.sh`, so nothing about your backups changes.

```bash
sudo bash -c "$(curl -sL https://github.com/Hosein21378/pasarguard-backup/raw/main/panel/install.sh)"
```

The installer prints the panel URL, the user and the generated password.
You can also install it from the menu: `5) Web Panel`.

| Tab | What it does |
|-----|--------------|
| **Dashboard** | every installed backup with its source, schedule and last run — run now, enable/disable, read the log, delete |
| **New backup** | pick the template (detected panels are marked), the interval, the platform and its credentials, an archive password and extra paths |
| **Restore** | restore from Telegram / Discord / Gmail / a local archive, with a live console and confirmation |

Details:

- runs as a **systemd service** (`pasarguard-panel`), restarts automatically
- **password protected** (session cookie); change it with `pasarguard-panel --set-password`
- every operation is streamed **live** in the browser, and you can type answers into the console

## Automation (non-interactive mode)

```bash
BACKUPER_NONINTERACTIVE=1 \
BACKUPER_REMARK=pasarguard BACKUPER_TEMPLATE=18 BACKUPER_TIMER=360 \
BACKUPER_PLATFORM=telegram BACKUPER_TG_TOKEN="..." BACKUPER_TG_CHAT="..." \
BACKUPER_DIRS_EXTRA="/opt/pasarguard /var/lib/pasarguard" \
bash pasarguard-backup.sh install

BACKUPER_NONINTERACTIVE=1 \
BACKUPER_RESTORE_PLATFORM=telegram BACKUPER_RESTORE_REMARK=pasarguard \
BACKUPER_RESTORE_YES=1 BACKUPER_RESTORE_DB=yes \
bash pasarguard-backup.sh restore
```

All variables are documented at the top of `pasarguard-backup.sh`.

## Project layout

```
pasarguard-backup.sh            the whole backup / restore engine (single file)
panel/pasarguard-panel.py       web panel (stdlib only)
panel/install.sh                panel installer (systemd + credentials)
```

## Changing the branding

- `pasarguard-backup.sh` → `PROJECT_NAME`, `PROJECT_OWNER`, `PROJECT_OWNER_LINK`, `GITHUB_REPO`, `REPO_BRANCH`, `REPO_RAW`, `VERSION`
- `panel/pasarguard-panel.py` → `PRODUCT_NAME`, `PRODUCT_NAME_FA`, `REPO_URL`, `VERSION`
- `panel/install.sh` → `REPO_RAW`, `REPO_URL`

## Credits

The backup engine started as **Backuper** by [@ErfJabs](https://t.me/erfjabs) — a great
backup script for VPN panels. This project adds a full restore engine, a web panel,
a non-interactive mode and PasarGuard-focused packaging.

## Support the Project

If you find this project useful, giving it a **star (⭐)** is more than enough. Thank you!
