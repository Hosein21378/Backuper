<div align="center">
  <img src="https://github.com/user-attachments/assets/16cc16e2-f1e5-4ae8-9b5f-bbea33fa39bd" alt="Backuper Logo" />
</div>

# What is Backuper? [Persian](readme-fa.md)
**Backuper** is an automated backup script with full customization options and support for multiple platforms.  

## Supported Platforms  

- [x] **Gmail**  
- [x] **Telegram**  
- [x] **Discord**  

## Key Features  

- **Web panel (dashboard, live logs, one-click backup & restore)**
- **Restore backups from the same platform (Telegram / Discord / Gmail / local file)**
- **Customizable remarks**  
- **Automated scheduling**  
- **Multi-template support**  
- **Add/remove custom directories**  
- **Send backups with no size limits**  
- **Set a password for backup files**  
- **User-friendly interface**  
- **Clear old backups**  
- **Include date and time in file names**  
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
- [x] **MarzGozir**
- [x] **PasarGuard**

## Restoring a Backup

Backuper can also **put a backup back on the server**, restoring it from the same
platform the backup was sent to. Just run the script and choose `2) Restore Backup`:

```bash
sudo bash -c "$(curl -sL https://github.com/erfjab/Backuper/raw/master/backuper.sh)"
```

or run only the restore flow:

```bash
sudo bash -c "$(curl -sL https://github.com/erfjab/Backuper/raw/master/backuper.sh) restore"
```

What the restore does:

- Downloads the newest backup from **Telegram**, **Discord**, **Gmail** or from a **local file**
- Finds the backup automatically from the upload history, or lets you paste a message link / file ID
- Detects split archives (`_backuper.z01 ... _backuper.zip`) and merges them safely
- Asks for the password of password-protected archives
- Creates a safety copy of the current files in `/root/prerestore-*.zip` before overwriting anything
- Imports the database dump (`_backuper.sql`) when it exists
- Offers to restart your docker containers after the restore

> [!NOTE]
> Restoring on a fresh server works as well: choose `Manual restore` and enter
> your bot token / webhook URL / Gmail app password, then run the import yourself.

> [!IMPORTANT]
> We thank [AsanPanelBot](https://t.me/AsanPanelBot) for supporting and sponsoring this. project.


## Installation  

To install the latest version, run:  

```bash
sudo bash -c "$(curl -sL https://github.com/erfjab/Backuper/raw/master/backuper.sh)"
```  

## Web Panel

Backuper ships with a small, dependency-free web panel (pure Python 3, no pip packages).
It is a thin UI over the same `backuper.sh`, so nothing about your backups changes.

```bash
sudo bash -c "$(curl -sL https://github.com/erfjab/Backuper/raw/master/panel/install.sh)"
```

The installer prints the panel URL, the user and the generated password.
Or install it from the CLI menu: `5) Web Panel`.

What you can do in the panel:

| Tab | What it does |
|-----|--------------|
| **Dashboard** | every installed backup with its source, schedule, last run — run now, enable/disable, read the log, delete |
| **New backup** | pick the template (detected panels are marked), the interval, the platform and its credentials, an archive password and extra paths |
| **Restore** | restore from Telegram / Discord / Gmail / a local archive, with a live console and confirmation |

Other details:

- runs as a **systemd service** (`backuper-panel`), restarts automatically
- **password protected** (session cookie). Change the password with `backuper-panel --set-password`
- every operation is streamed **live** in the browser, and you can type answers into the console
- the panel talks to the script in *non-interactive mode* (`BACKUPER_NONINTERACTIVE=1`), which is
  also usable directly for automation — see the header of `backuper.sh`
- put it behind a firewall / reverse proxy: it can change files as root

## 💙 Support the Project  

If you find this project useful, giving a **star (⭐)** is more than enough. Thank you!  

🔹 Join [@ErfJabs](https://t.me/erfjabs) for the latest news and updates.  

[![Stargazers over time](https://starchart.cc/erfjab/Backuper.svg?variant=adaptive)](https://starchart.cc/erfjab/Backuper)  
