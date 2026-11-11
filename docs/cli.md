# CLI zify

Формат: `zify <команда> [аргументы]`. Полная справка — `zify --help`.

## Сервис и обновления

```sh
zify status
zify service restart
zify service enable
zify manager-check
zify manager-update
```

Для сервиса доступны `start`, `stop`, `restart`, `enable` и `disable`. Перед обновлением выполните `manager-check`. `manager-update` обновляет код, стратегии и фейки одной транзакцией.

## Стратегии

```sh
zify source list flowseal
zify source list manager
zify source select flowseal general_alt9
zify source select manager Gv1
zify fake list
```

Имена пресетов берутся из `source list`. Игровой профиль добавляется к основной стратегии.

## Настройки

```sh
zify config get DISABLE_IPV6
zify config set DISABLE_IPV6 0
zify devices list
zify network status
zify network quic on
zify network offload software
```

`DISABLE_IPV6`: `0` — IPv6 включён, `1` — выключен. Для блокировки QUIC используйте `on` / `off`.

Режимы offloading: `software`, `hardware`, `none`, `donttouch`. `restore` возвращает настройки, сохранённые до изменений zify.

## Параметры

- `-y`, `--yes` — выполнить без подтверждения; нужен для изменений из скриптов и без терминала.
- `-c ФАЙЛ`, `--config ФАЙЛ` — другой конфиг zify, по умолчанию `/etc/config/zify`.
- `-h`, `--help` — справка; `-V`, `--version` — версия.

Пример для скрипта: `zify service restart --yes`.
