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

## 💙 Support the Project  

If you find this project useful, giving a **star (⭐)** is more than enough. Thank you!  

🔹 Join [@ErfJabs](https://t.me/erfjabs) for the latest news and updates.  

[![Stargazers over time](https://starchart.cc/erfjab/Backuper.svg?variant=adaptive)](https://starchart.cc/erfjab/Backuper)  
