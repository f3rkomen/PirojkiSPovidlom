# ArzMarket Fork — ручной релизный конвейер

## Установка для пользователя

Скачай только [PirojkiSPovidlom_Loader.lua](release/PirojkiSPovidlom_Loader.lua)
в корень папки `moonloader`. При первом подключении loader скачает проверенный
`#PirojkiArzMarket[...].lua` из этого репозитория и запустит его. Второй
вручную установленный Lua-файл не нужен.

Этот набор нужен для безопасной модели обновлений:

1. **Watcher** на отдельной машине видит новый официальный манифест и сохраняет
   кандидат в `incoming/`.
2. Ты вручную декомпилируешь и проверяешь кандидат, переносишь разрешённые
   клиентские UI-изменения и тестируешь его.
3. `build_release.py` создаёт твой `release/ArzMarket.lua` и
   `release/updateArzMarket.js`.
4. Ты сам коммитишь релизный Lua, manifest и loader в свой GitHub-репозиторий. Только после этого
   пользователи видят встроенное окно обновления.

Клиенты форка **не** опрашивают официальный манифест: loader читает только
`release/updateArzMarket.js` из твоего репозитория, сам обновляет loader при
смене `loaderLatest` и устанавливает новую версию клиента.

## Подготовка своего GitHub-репозитория

Создай пустой приватный или публичный репозиторий. В него должны попасть этот
toolkit и каталог `release/`. Скопируй шаблон и заполни `YOUR_GITHUB_LOGIN` и
`YOUR_REPOSITORY`:

```powershell
Copy-Item .\config\fork.example.json .\config\fork.json
notepad .\config\fork.json
```

`release_url` должен быть прямым raw-URL на `release/ArzMarket.lua`, а
`manifest_url` — raw-URL на `release/updateArzMarket.js` этого же репозитория.

## Первый ручной релиз

В качестве исходника можно использовать уже проверенный локальный
`#ArzMarket[3_56].lua` с разрешённым интерфейсом «Выгодная продажа». Команда
ниже не меняет исходник: она создаёт только два файла в `release/`.

```powershell
python .\tools\build_release.py `
  --source 'D:\Arizona Games Launcher\bin\arizona\moonloader\#ArzMarket[3_56].lua' `
  --version 3.56-fork.1 `
  --luajit 'D:\Arizona Games Launcher\bin\arizona\moonloader\lib\luajit\bin\luajit.exe'
```

После проверки коммитятся `release/ArzMarket.lua`,
`release/updateArzMarket.js` и `release/PirojkiSPovidlom_Loader.lua`.
Пользователь кладёт только loader в корень `moonloader`; сам Market loader
скачивает и запускает при первом старте. В Lua прямой встроенный чек обновлений
отключён, чтобы не было гонки с loader.

## Новый официальный релиз

1. Watcher скачал бинарный/исходный кандидат в `incoming/<версия>/`.
2. На Windows запусти предоставленный `decompile_arzmarket_cp1251.ps1` для
   кандидата, если это LuaJIT bytecode.
3. Перенеси только совместимые разрешённые клиентские изменения и проверь
   скрипт LuaJIT.
4. Запусти `build_release.py` с новой версией, протестируй, сделай commit/push.

Lua-исходник не нужно «компилировать» для MoonLoader: здесь используется
компиляционная проверка LuaJIT (`loadstring`) до публикации. Это ловит
синтаксические ошибки без выполнения скрипта.

## Границы набора

В наборе нет и не будет передачи `authToken`/`authClient`, повторного
использования сессий, подмены UID, обхода серверной проверки или `/ambridge`.
Он предназначен для обновляемого клиентского форка и локального интерфейса
«Выгодная продажа».
