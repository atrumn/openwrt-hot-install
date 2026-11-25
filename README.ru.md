[English](README.md) | [Русский](README.ru.md)

# OpenWrt Hot-Installer (`openwrt-hot-install.sh`)

Универсальный POSIX `sh` скрипт для **«горячей» установки OpenWrt** прямо на диск работающего Linux-сервера или VPS из оперативной памяти (`tmpfs`) без использования Rescue-режима и ISO-образов.

> [!CAUTION]
> **Внимание:** скрипт полностью перезаписывает целевой диск и **уничтожает все существующие данные** на нём. Перед запуском сделайте резервные копии и при необходимости проверьте работу с ключом `--dry-run`.

---

## Возможности

- **Выбор версии OpenWrt:**
  - По умолчанию (без флагов): автоматически определяет `stable_version` из `https://downloads.openwrt.org/.versions.json` и ставит актуальный стабильный релиз.
  - `-s` / `-snapshot`: устанавливает сборку `SNAPSHOT`.
  - `-v <версия>` / `-version <версия>`: устанавливает конкретную указанную версию (например, `25.12.6`).
- **Автоопределение окружения:**
  - Архитектура: `x86_64` (`x86/64`) и `aarch64` / `arm64` (`armsr/armv8`).
  - Режим загрузки: Legacy BIOS (`ext4-combined.img.gz`) или UEFI (`ext4-combined-efi.img.gz`).
  - Целевой диск и корневой раздел (`vda`, `sda`, `nvme0n1`, `xvda`).
  - Сетевые настройки: переносит MAC-адрес, IPv4 CIDR/маску, IPv6 адрес/шлюз и DNS. Корректно обрабатывает `/32` и шлюзы вне подсети (`onlink`) через раздельные секции `route` (`scope link` + `onlink '1'`) в `netifd`.
- **Преднастройка доступа и файрвола:**
  - Хеширует пароль из `-p <пароль>` в SHA-512 (`$6$`) для совместимости с `musl` в OpenWrt (либо переносит совместимый хеш из `/etc/shadow`, избегая несовместимых хешей yescrypt `$y$`).
  - Переносит `/root/.ssh/authorized_keys` в `/etc/dropbear/authorized_keys`.
  - Отключает DHCP/RA-серверы (`lan` / `wan`) и открывает `22/tcp` (`Allow-SSH`) в `firewall4`.
- **Безопасная запись из RAM (`tmpfs`):**
  - Скачивает образ и проверяет SHA-256 по официальному `sha256sums` в `tmpfs` (если `/tmp` не в RAM, монтирует отдельный `tmpfs` 300 MiB).
  - Проверяет модифицированную ФС через `e2fsck -fn` (при необходимости чинит безобидный отступ битовой карты инодов от `make_ext4fs`).
  - Останавливает фоновые сервисы записи на диск, блокирует Python-прошивальщик в памяти через `mlockall` (или использует fallback через `chroot` в `tmpfs`, если `python3` не установлен), переводит `/` в `read-only` через SysRq (`s`, `u`), затирает старый backup GPT при записи MBR-образа, записывает образ, проверяет сигнатуру `0x55aa` и перезагружает сервер через `SysRq-b`.
- **Первоначальная настройка для расширения `rootfs` на весь диск:**
  - Записывает в образ сервис `/etc/init.d/firstboot-rootfs-pkgs` (`S99firstboot-rootfs-pkgs`) и скрипт `/usr/sbin/firstboot-install-rootfs-pkgs.sh`, который при первой загрузке OpenWrt дожидается сети и автоматически устанавливает через `apk` или `opkg`:
    `parted`, `resize2fs`, `losetup`, `e2fsprogs`, `partx-utils`.
  - Также добавляет готовый скрипт `/usr/sbin/expand-rootfs.sh` для безопасного офлайн-расширения корневого раздела на 100% диска.

---

## Быстрый старт (`wget`)

Выполняйте от имени `root` на целевом Linux-сервере.

### 1. Установка актуальной стабильной версии (latest stable)

**Пошагово (скачать, сделать исполняемым, запустить):**
```sh
wget -O openwrt-hot-install.sh https://raw.githubusercontent.com/atrumn/openwrt-hot-install/main/openwrt-hot-install.sh
chmod +x openwrt-hot-install.sh
./openwrt-hot-install.sh -p 'YourStrongRootPassword'
```

**Либо одной командой:**
```sh
wget -O openwrt-hot-install.sh https://raw.githubusercontent.com/atrumn/openwrt-hot-install/main/openwrt-hot-install.sh && sh openwrt-hot-install.sh -p 'YourStrongRootPassword'
```

### 2. Установка SNAPSHOT версии (`-s` / `-snapshot`)

```sh
wget -O openwrt-hot-install.sh https://raw.githubusercontent.com/atrumn/openwrt-hot-install/main/openwrt-hot-install.sh && sh openwrt-hot-install.sh -snapshot -p 'YourStrongRootPassword'
```

### 3. Установка конкретной версии (`-v` / `-version`)

```sh
wget -O openwrt-hot-install.sh https://raw.githubusercontent.com/atrumn/openwrt-hot-install/main/openwrt-hot-install.sh && sh openwrt-hot-install.sh -version 25.12.6 -p 'YourStrongRootPassword'
```

### 4. Пробный запуск (`--dry-run`, без записи на диск)

Скачивает образ, проверяет SHA-256, преднастраивает `rootfs` в RAM, выполняет `e2fsck` и завершает работу, **не затрагивая диск**:

```sh
wget -O openwrt-hot-install.sh https://raw.githubusercontent.com/atrumn/openwrt-hot-install/main/openwrt-hot-install.sh && sh openwrt-hot-install.sh --dry-run -p 'YourStrongRootPassword'
```

---

## Параметры командной строки

| Параметр | Описание |
| :--- | :--- |
| *(без флагов)* | Установить актуальную стабильную версию из `downloads.openwrt.org/.versions.json` |
| `-s`, `-snapshot`, `--snapshot` | Установить `SNAPSHOT` сборку (несовместимо с `-v`/`-version`) |
| `-v`, `-version`, `--version <версия>` | Установить конкретный релиз, например `25.12.6` |
| `-p`, `--password <пароль>` | Задать пароль `root` для OpenWrt (хеш SHA-512 `$6$`) |
| `-d`, `--disk <устройство>` | Явно указать целевой диск (например, `/dev/vda`) |
| `-y`, `--yes` | Пропустить 5-секундную паузу подтверждения перед прошивкой |
| `--dry-run` | Подготовить и проверить образ только в RAM без записи на диск |
| `-h`, `-help`, `--help` | Показать справку и выйти |

---

## Расширение корневого раздела после перезагрузки

1. После первой загрузки OpenWrt в фоне запустится `/etc/init.d/firstboot-rootfs-pkgs` и установит пакеты `parted`, `resize2fs`, `losetup`, `e2fsprogs`, `partx-utils`. Проверить статус установки можно по SSH:
   ```sh
   ls -la /etc/firstboot-rootfs-pkgs.done
   cat /var/log/firstboot-rootfs-pkgs.log
   ```
2. Когда файл `/etc/firstboot-rootfs-pkgs.done` появится, запустите встроенный помощник для безопасного расширения раздела на весь диск (сервер автоматически перезагрузится через SysRq):
   ```sh
   /usr/sbin/expand-rootfs.sh
   ```
3. После перезагрузки проверьте размер раздела командой `df -h`.

---

## Требования

- Linux-сервер с правами `root` и не менее **320 MiB** свободной оперативной памяти.
- Утилиты на сервере: `wget` или `curl`, `gunzip`, `sha256sum`, `losetup`, `mount`, `umount`, `e2fsck`, `dd`, `awk`, `sed`, `grep`, `ip`, а также `python3` / `openssl` / `mkpasswd` для `-p`.
- Поддержка SysRq в ядре (`/proc/sys/kernel/sysrq`).

---

## Лицензия

[MIT](LICENSE)
