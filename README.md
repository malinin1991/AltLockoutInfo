# Alt Lockout Info

Аддон World of Warcraft: рейд-локауты по альтам одной учётной записи и вкладка маунтов из Encounter Journal.

## Установка

Скопируйте папку аддона в:

```text
World of Warcraft\_retail_\Interface\AddOns\AltLockoutInfo
```

Имя папки должно совпадать с `AltLockoutInfo.toc`. Репозиторий на GitHub рекомендуется называть **AltLockoutInfo**.

## Команды

| Команда | Действие |
|---------|----------|
| `/ali` или `/altlockout` | Открыть таблицу статуса |
| `/ali options` | Настройки |
| `/ali debug` | Отладка |
| `/ali help` | Справка |

Алиасы: `config` / `opt` / `настройки` для options; `dump` / `отладка` для debug.

## Миникарта

- **ЛКМ** — таблица статуса  
- **ПКМ** — настройки  
- Перетаскивание — перемещение кнопки  

## Ограничения

- Данные альта появляются только после входа на этого персонажа.
- Разные Battle.net-аккаунты не синхронизируются (без ручных symlink на SavedVariables).
- LFR-секции могут отображаться как отдельные записи Blizzard — показываются как есть.

## Совместимость

`## Interface:` **120001**, **121000** (см. `AltLockoutInfo.toc`).

## Тесты

```bash
lua tests/run.lua
```

## Структура

```text
AltLockoutInfo.toc
Core.lua              — события, slash-команды
DB.lua / Data.lua     — SavedVariables (ALInfoDB), сканирование локаутов
Catalog.lua           — Encounter Journal
Mounts.lua / MountsData.lua
UI_*.lua              — интерфейс
MinimapButton.lua
Locales/              — enUS, ruRU
tests/                — headless-тесты
```

---

## English

**Alt Lockout Info** tracks raid lockouts across your alts and shows a mounts tab from Encounter Journal loot.

**Install:** `Interface/AddOns/AltLockoutInfo`

**Commands:** `/ali`, `/ali options`, `/ali debug`, `/ali help`, `/altlockout`

**Minimap:** LMB status, RMB settings. **Limits:** login per alt; no Battle.net sync; LFR wings as separate lockouts.

**Interface:** 120001, 121000. **Tests:** `lua tests/run.lua`. License: MIT.
