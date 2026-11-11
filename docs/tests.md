# Тесты zify

Запускайте из корня репозитория в Linux или WSL2. Подготовка окружения — в [install.md](install.md#разработка).

## Запуск

```sh
make test
```

Запускает локальные проверки: синтаксис, ShellCheck, модульные и интеграционные тесты, HTTP/TLS и самопроверки обвязки эмулятора. Полный прогон OpenWrt выполняется отдельно.

Только статические проверки и запуск CLI:

```sh
make check
```

Тесты и сборка с ucode из OpenWrt 24.10, 25.12 и upstream:

```sh
make test-matrix
```

Независимые наборы выполняются параллельно, максимум в четыре процесса по умолчанию. Чтобы снизить нагрузку:

```sh
ZIFY_TEST_JOBS=2 make test
```

## Что покрыто

- `tests/unit/` — стратегии, каталоги, настройки и обработка данных.
- `tests/integration/` — команды, меню в PTY, установка, фейки, устройства и сетевые настройки.
- `tests/safety/` — нехватка места, ошибки, прерывания и откат.
- `tests/http/` — запросы к локальному HTTP/TLS-серверу.
- `tests/performance/` — навигация без лишних процессов, записей и повторного чтения файлов.
- `tests/e2e/` — полный цикл работы на OpenWrt в QEMU.

## OpenWrt в QEMU

Нужны Linux x86_64 или WSL2, Python 3, SSH/SCP, `unzip`, `zstd` и `ubinize` из `mtd-utils`. Подготовка эмулятора и сборка полного релиза требуют интернета.

```sh
make emulator-setup
```

```sh
E2E_WORKERS=4 make test-e2e
```

24 сценария распределяются между четырьмя эмуляторами Cudy WR3000P. У каждого своя копия Flash и состояние роутера. Последовательный запуск:

```sh
E2E_WORKERS=1 make test-e2e
```

## Отдельные наборы

```sh
sh tests/unit/run.sh
```

```sh
sh tests/integration/run.sh
```

```sh
sh tests/integration/packages.sh
```

```sh
sh tests/safety/transactions.sh
```

```sh
sh tests/safety/uninstall.sh
```

```sh
sh tests/http/run.sh
```

```sh
sh tests/e2e/run.sh selftest
```

Файлы из `tests/integration/cases/` запускаются через `tests/integration/run.sh`: им нужно общее тестовое окружение.

## Результаты

Локальные проверки печатают `PASS` / `FAIL`, время и сообщения об ошибках. Любое падение завершает прогон с ненулевым кодом.

Путь к последнему отчёту E2E записан в `.test-tmp/e2e/latest.txt`. В каталоге отчёта находятся `summary.txt`, `report.json`, `report.tap` и логи отдельных воркеров в `shards/`. Успешный E2E требует прохождения всех сценариев без пропусков.
