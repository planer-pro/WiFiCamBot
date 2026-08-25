#!/usr/bin/env bash
# Проброс WiFiCamBot на localhost — геймпад в Firefox (и прочие штуки,
# которым нужен «безопасный контекст»: микрофон и т.п.).
#
# Firefox даёт Gamepad API только HTTPS-страницам или localhost — в отличие
# от Chrome, обходного флага у него нет (см. README). Скрипт прозрачно
# переносит оба порта робота на эту машину (80 -> 8080, 81 -> 81) и открывает
# http://localhost:8080: для браузера страница теперь с localhost, геймпад
# становится виден. Стрим страница сама возьмёт с localhost:81.
#
# Запуск:   ./tunnel.sh [адрес-робота]     (умолчание — wificambot.local)
#           ./tunnel.sh --no-open [...]    — не открывать браузер самому
# Останов:  Ctrl+C — оба проброса закрываются сами.
#
# Пока ездите, скрипт должен работать. Ещё немного вырастет задержка:
# стрим и команды идут транзитом через этот компьютер.
#
# Нюанс: локальный порт 81 привилегированный (<1024). Чтобы скрипт не просил
# sudo при каждом запуске, один раз на машине даём socat право слушать такие
# порты (уже сделано на компьютере разработчика):
#   sudo setcap cap_net_bind_service=+ep "$(readlink -f "$(command -v socat)")"

set -u

OPEN_BROWSER=1
if [ "${1:-}" = "--no-open" ]; then
  OPEN_BROWSER=0
  shift
fi
HOST="${1:-wificambot.local}"

if ! command -v socat >/dev/null 2>&1; then
  echo "нет socat — установите: sudo apt install socat" >&2
  exit 1
fi

if ! getent hosts "$HOST" >/dev/null 2>&1; then
  echo "адрес $HOST не резолвится — передайте IP робота аргументом:" >&2
  echo "  $0 192.168.x.x" >&2
  exit 1
fi

# робот вообще в сети? (socat с fork примет локальное соединение и молча,
# поэтому проверяем сами — иначе непонятно, почему не открывается)
if ! timeout 2 bash -c "echo > /dev/tcp/$HOST/80" 2>/dev/null; then
  echo "робот $HOST не отвечает на порту 80 — включён? в той же сети?" >&2
  exit 1
fi

P1=""
P2=""
cleanup()
{
  [ -n "$P1" ] && kill "$P1" 2>/dev/null
  [ -n "$P2" ] && kill "$P2" 2>/dev/null
}
trap cleanup EXIT INT TERM

# слушаем только на loopback: туннель — личное дело этой машины, в LAN
# (и по IPv6-адресу хоста) он не торчит
socat TCP-LISTEN:8080,bind=127.0.0.1,fork,reuseaddr TCP:"$HOST":80 & P1=$!
socat TCP-LISTEN:81,bind=127.0.0.1,fork,reuseaddr TCP:"$HOST":81 & P2=$!
sleep 1
if ! kill -0 "$P1" 2>/dev/null || ! kill -0 "$P2" 2>/dev/null; then
  echo "не удалось занять локальные порты 8080/81:" >&2
  echo "  заняты кем-то другим — либо (для порта 81) socat без права bind:" >&2
  echo "  sudo setcap cap_net_bind_service=+ep \"\$(readlink -f \$(command -v socat))\"" >&2
  exit 1
fi

echo "робот $HOST доступен как http://localhost:8080 (Ctrl+C — закрыть)"
if [ "$OPEN_BROWSER" = 1 ]; then
  xdg-open http://localhost:8080 >/dev/null 2>&1 || true
fi
wait
