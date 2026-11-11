# Установка zify

Нужны OpenWrt с `apk` или `opkg`, SSH-доступ от `root`, интернет и свободное место. Поддерживается Zapret первого поколения.

## Установка

Выполните на роутере:

```sh
wget -O /tmp/zify-install.sh https://raw.githubusercontent.com/swxfe/zify/main/tools/bootstrap.sh && sh /tmp/zify-install.sh
```

Установщик проверит зависимости и место, запросит согласие на недостающие пакеты и откроет меню. Сам Zapret и LuCI установите через **«Установка / обновление / удаление» → «Установить Zapret»**.

Для повторного запуска — `zify`.

## Из локальных файлов

Если зависимости уже установлены, скопируйте `dist/zify.sh` и `dist/zify-assets.tar.gz` одного релиза в `/tmp/` роутера:

```sh
sh /tmp/zify.sh --yes manager-install /tmp/zify-assets.tar.gz
zify
```

## Обновление и удаление

Оба действия находятся в **«Установка / обновление / удаление»**. Предыдущая сборка zify сохраняется в `/usr/bin/zify.previous`.

В **«Выборочном удалении»** отдельно выбираются пакеты, файлы Zapret и конфигурация zify. При удалении Zapret с установленным LuCI выберите оба пакета. Общие зависимости сохраняются.

## Разработка

Сборка выполняется в Linux или WSL2. В WSL держите репозиторий на файловой системе Linux.

Зависимости для Ubuntu:

```sh
sudo apt-get update
sudo apt-get install -y git build-essential cmake ninja-build pkg-config libjson-c-dev libpcre2-dev libmd-dev libssl-dev shellcheck curl unzip python3 make
```

Затем из корня репозитория:

```sh
sh tools/setup-dev.sh
export PATH="$HOME/.local/share/zify-dev/openwrt-25.12/bin:$PATH"
make dist
```

Результат — `dist/zify.sh`, `dist/zify-assets.tar.gz`, описание релиза и `SHA256SUMS`. `make dist` запускает тесты перед сборкой; для загрузки ресурсов нужен интернет.

Ревизии источников закреплены в `data/sources.lock.json`. Чтобы обновить их перед новым релизом:

```sh
python3 tools/build-assets.py --refresh-lock --output dist/zify-assets.tar.gz
make dist
```

`make clean` удаляет результаты сборки и временные каталоги. Запускайте отдельно от остальных целей.

[CLI-команды](cli.md) · [Тесты и эмулятор OpenWrt](tests.md)
