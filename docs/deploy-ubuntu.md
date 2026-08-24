# Watcher на Ubuntu без затрагивания других проектов

Watcher сам ничего не публикует и не запускает скачанный Lua. Он только кладёт
новую официальную версию в `incoming/<версия>/` с SHA-256 и метаданными.

## Каталог

Используй отдельный путь, например `/opt/arzmarket-upstream-watcher`. Не
размещай его в каталоге Nakhodka и не запускай от `root`.

```bash
sudo useradd --system --home /opt/arzmarket-upstream-watcher --shell /usr/sbin/nologin arzmarket
sudo install -d -o arzmarket -g arzmarket /opt/arzmarket-upstream-watcher
sudo -u arzmarket git clone <ТВОЙ_РЕПОЗИТОРИЙ_С_TOOLKIT> /opt/arzmarket-upstream-watcher/app
sudo -u arzmarket cp /opt/arzmarket-upstream-watcher/app/watcher/watcher-config.example.json \
  /opt/arzmarket-upstream-watcher/app/watcher/watcher-config.json
```

Затем проверь один запуск:

```bash
sudo -u arzmarket python3 /opt/arzmarket-upstream-watcher/app/watcher/watch_upstream.py --once
```

## systemd timer (раз в 10 минут)

`/etc/systemd/system/arzmarket-upstream-watch.service`:

```ini
[Unit]
Description=Stage official ArzMarket updates for manual review

[Service]
Type=oneshot
User=arzmarket
Group=arzmarket
WorkingDirectory=/opt/arzmarket-upstream-watcher/app
ExecStart=/usr/bin/python3 /opt/arzmarket-upstream-watcher/app/watcher/watch_upstream.py --once
```

`/etc/systemd/system/arzmarket-upstream-watch.timer`:

```ini
[Unit]
Description=Check upstream ArzMarket manifest every 10 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=10min
Persistent=true

[Install]
WantedBy=timers.target
```

Включение:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now arzmarket-upstream-watch.timer
systemctl list-timers arzmarket-upstream-watch.timer
```

После ежедневного рестарта VPS systemd сам выполнит пропущенную проверку
благодаря `Persistent=true`. Это не подключается к игре и не хранит логины,
пароли или игровые токены.
