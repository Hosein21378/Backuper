# بکاپ پاسارگارد [English](readme.md)

**بکاپ پاسارگارد** بکاپ زمان‌بندی‌شده از پنل پاسارگارد (و بقیه‌ی پنل‌های VPN) می‌گیرد،
آن را به **تلگرام / دیسکورد / جیمیل** می‌فرستد و هر وقت لازم شد **دوباره روی سرور
برمی‌گرداند** — هم از خط فرمان و هم از یک پنل وب.

## چرا این پروژه

- **یک فایل، بدون وابستگی** — کل موتور در فایل `pasarguard-backup.sh` است
- **بکاپ + بازگردانی** — از همان کانالی که بکاپ می‌رود، بکاپ هم برمی‌گردد
- **پنل وب** — داشبورد، لاگ زنده، بکاپ و بازگردانی با یک کلیک (فقط Python 3، بدون پکیج)
- **مخصوص پاسارگارد** — فایل `/opt/pasarguard/.env` را خودکار تشخیص می‌دهد، دیتابیس
  PostgreSQL/MySQL و داده‌های پنل را دامپ می‌کند و هنگام بازگردانی ایمپورت می‌کند

## پلتفرم‌های پشتیبانی‌شده

- [x] **تلگرام**
- [x] **دیسکورد**
- [x] **جیمیل**

## ویژگی‌های کلیدی

- **بازگردانی از همان پلتفرمی** که بکاپ ارسال می‌شود (تلگرام / دیسکورد / جیمیل / فایل محلی)
- **پنل وب** — داشبورد، لاگ زنده، بکاپ و بازگردانی یک‌کلیکی
- **نام (remark) سفارشی** — چند بکاپ مستقل روی یک سرور
- **زمان‌بندی خودکار** با کران‌جاب
- **پشتیبانی از چندین قالب** (پنل نصب‌شده خودکار شناسایی می‌شود)
- **افزودن/حذف دایرکتوری‌های دلخواه**
- **ارسال بکاپ بدون محدودیت حجمی** (آرشیو تکه‌تکه، هنگام ریستور ایمن ادغام می‌شود)
- **رمز عبور برای آرشیو**
- **دامپ و ایمپورت دیتابیس** (PostgreSQL / MySQL / MariaDB، روی هاست یا داخل داکر)
- **نسخه‌ی ایمن قبل از هر بازگردانی** (`/root/prerestore-*.zip`)
- **پاکسازی بکاپ‌های قدیمی**
- **درج تاریخ و ساعت در نام فایل**
- **حالت غیرتعاملی** برای اتوماسیون (`BACKUPER_NONINTERACTIVE=1`)
- **بهینه برای عملکرد**

## قالب‌های پشتیبانی‌شده

- [x] **PasarGuard**
- [x] **X-ui** — [x] **S-ui** — [x] **Hiddify** — [x] **Remnawave**
- [x] **Rebecca** — [x] **Marzneshin** (+ Logs)
- [x] **Marzban** (+ Logs) — [x] **MarzHelp + Marzban**
- [x] **MirzaBot** — [x] **Walpanel** — [x] **HolderBot**
- [x] **Phantom** — [x] **OvPanel** — [x] **OvNode** — [x] **MarzGozir**

## نصب

اسکریپت را با دسترسی root روی سرور اجرا کنید:

```bash
sudo bash -c "$(curl -sL https://github.com/Hosein21378/pasarguard-backup/raw/main/pasarguard-backup.sh)"
```

سپس از منو:

```
======== PasarGuard Backup Menu [v1.0.0] ========

1) Install / Create Backup
2) Restore Backup
3) Remove All Backups
4) Run All Backup Scripts
5) Web Panel
6) Exit
```

برای پاسارگارد: گزینه‌ی `1) Install / Create Backup` و بعد قالب **18) PasarGuard** را انتخاب کنید؛
اطلاعات دیتابیس خودکار از `/opt/pasarguard/.env` خوانده می‌شود.

## بازگردانی بکاپ

گزینه‌ی `2) Restore Backup` در منو، یا مستقیم:

```bash
sudo bash -c "$(curl -sL https://github.com/Hosein21378/pasarguard-backup/raw/main/pasarguard-backup.sh) restore"
```

بازگردانی چه می‌کند؟

- آخرین بکاپ را از **تلگرام**، **دیسکورد**، **جیمیل** یا **فایل محلی** دانلود می‌کند
- بکاپ را خودکار از تاریخچه‌ی ارسال پیدا می‌کند، یا لینک پیام / شناسه‌ی فایل می‌گیرد
- بکاپ‌های تکه‌تکه (`_backuper.z01 ... _backuper.zip`) را درست ادغام می‌کند
- اگر آرشیو رمزدار باشد رمز می‌پرسد
- قبل از بازنویسی، نسخه‌ی ایمن در `/root/prerestore-*.zip` می‌سازد
- فایل دیتابیس (`_backuper.sql`) را ایمپورت می‌کند — از جمله دیتابیس پاسارگارد
- در پایان پیشنهاد ری‌استارت کانتینرهای داکر می‌دهد

> روی سرور تازه هم می‌شود: گزینه‌ی `Manual restore` و وارد کردن توکن/وبهوک/رمز ایمیل.

## پنل وب

```bash
sudo bash -c "$(curl -sL https://github.com/Hosein21378/pasarguard-backup/raw/main/panel/install.sh)"
```

نصب‌کننده آدرس پنل، نام کاربری و رمز ساخته‌شده را چاپ می‌کند. از منو هم: `5) Web Panel`.

| تب | کاربرد |
|-----|---------|
| **داشبورد** | همه‌ی بکاپ‌ها با مقصد، زمان‌بندی و آخرین اجرا — اجرای فوری، فعال/غیرفعال، لاگ، حذف |
| **بکاپ جدید** | انتخاب قالب (پنل‌های شناسایی‌شده علامت‌خورده)، بازه، پلتفرم و اطلاعاتش، رمز آرشیو، مسیرهای اضافه |
| **بازگردانی** | بازگردانی از تلگرام / دیسکورد / جیمیل / فایل محلی با کنسول زنده و تأیید |

- سرویس **systemd** با نام `pasarguard-panel`
- ورود با **رمز عبور**؛ تغییر رمز: `pasarguard-panel --set-password`
- خروجی همه‌ی عملیات زنده در مرورگر، با امکان تایپ پاسخ در کنسول

## اتوماسیون (حالت غیرتعاملی)

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

همه‌ی متغیرها در ابتدای فایل `pasarguard-backup.sh` توضیح داده شده‌اند.

## ساختار پروژه

```
pasarguard-backup.sh            موتور بکاپ و بازگردانی (یک فایل)
panel/pasarguard-panel.py       پنل وب (فقط کتابخانه‌های استاندارد)
panel/install.sh                نصب‌کننده‌ی پنل (systemd + رمز عبور)
```

## تغییر برند

- `pasarguard-backup.sh` → `PROJECT_NAME`، `PROJECT_OWNER`، `PROJECT_OWNER_LINK`، `GITHUB_REPO`، `REPO_BRANCH`، `REPO_RAW`، `VERSION`
- `panel/pasarguard-panel.py` → `PRODUCT_NAME`، `PRODUCT_NAME_FA`، `REPO_URL`، `VERSION`
- `panel/install.sh` → `REPO_RAW`، `REPO_URL`

## اعتبارها

موتور بکاپ در ابتدا **Backuper** از [@ErfJabs](https://t.me/erfjabs) بود. این پروژه موتور
بازگردانی کامل، پنل وب، حالت غیرتعاملی و بسته‌بندی مخصوص پاسارگارد را اضافه می‌کند.

## 💙 حمایت

اگر پروژه مفید بود، یک **ستاره (⭐)** کافی است. سپاسگزاریم!
