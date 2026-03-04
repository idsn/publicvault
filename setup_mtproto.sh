#!/bin/bash
# ==============================================================================
# MTProto FakeTLS proxy setup (nineseconds/mtg:2) with Prometheus stats
#
# КАК ЗАПУСТИТЬ:
#   sudo bash setup_mtproto.sh <домен_или_ip> [порт] [порт_статистики]
#
# ПРИМЕРЫ:
#   sudo bash setup_mtproto.sh mydomain.ru          # порты по умолчанию
#   sudo bash setup_mtproto.sh mydomain.ru 2083     # свой порт
#   sudo bash setup_mtproto.sh 1.2.3.4              # без домена, только по IP
#
# ВАЖНО: Если у тебя нет домена — просто передай IP-адрес сервера.
#         Маскировка FakeTLS будет использовать google.com автоматически.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Аргументы
# ------------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
  echo "Использование: sudo bash $0 <домен_или_ip> [порт] [порт_статистики]"
  echo "Пример:        sudo bash $0 mydomain.ru 2083 3129"
  echo "Пример без домена: sudo bash $0 1.2.3.4 2083 3129"
  exit 1
fi

DOMAIN="$1"
PORT="${2:-2083}"
STATS_PORT="${3:-3129}"
CONFIG_DIR="/opt/mtg"
CONFIG_FILE="$CONFIG_DIR/config.toml"
SECRET_FILE="$CONFIG_DIR/secret.txt"

# ------------------------------------------------------------------------------
# Определяем: домен или IP
# Если передан IP — FakeTLS маскируется под google.com (клиентам не важно)
# ------------------------------------------------------------------------------
if [[ "$DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  IS_IP=true
  TLS_DOMAIN="google.com"
  echo ">>> Обнаружен IP-адрес. FakeTLS будет маскироваться под: $TLS_DOMAIN"
else
  IS_IP=false
  TLS_DOMAIN="$DOMAIN"
fi

echo ""
echo "=============================="
echo "  MTProto Setup"
echo "=============================="
echo "  Домен/IP    : $DOMAIN"
echo "  TLS-маска   : $TLS_DOMAIN"
echo "  Порт        : $PORT"
echo "  Статистика  : 127.0.0.1:$STATS_PORT (только локально)"
echo "=============================="
echo ""

# ------------------------------------------------------------------------------
# Шаг 1/7 — Docker
# ------------------------------------------------------------------------------
echo "[1/7] Проверка Docker..."
if ! command -v docker &>/dev/null; then
  echo "      Docker не найден — устанавливаем..."
  apt-get update -q
  apt-get install -y -q ca-certificates curl gnupg lsb-release
  curl -fsSL https://get.docker.com | sh
  systemctl enable docker --now
  echo "      Docker установлен ✓"
else
  echo "      Docker уже установлен ✓"
fi

# ------------------------------------------------------------------------------
# Шаг 2/7 — Получение образа
# ------------------------------------------------------------------------------
echo "[2/7] Загрузка образа nineseconds/mtg:2..."
if ! docker pull nineseconds/mtg:2; then
  echo "      ОШИБКА: не удалось загрузить образ. Проверь интернет-соединение."
  exit 1
fi
echo "      Образ загружен ✓"

# ------------------------------------------------------------------------------
# Шаг 3/7 — Генерация секрета
# ------------------------------------------------------------------------------
echo "[3/7] Генерация FakeTLS-секрета для домена: $TLS_DOMAIN..."
SECRET=$(docker run --rm nineseconds/mtg:2 generate-secret --hex "$TLS_DOMAIN")
if [[ -z "$SECRET" ]]; then
  echo "      ОШИБКА: секрет не сгенерирован."
  exit 1
fi
echo "      Секрет: $SECRET"

# Сохраняем секрет в файл — пригодится при восстановлении
mkdir -p "$CONFIG_DIR"
echo "$SECRET" > "$SECRET_FILE"
chmod 600 "$SECRET_FILE"
echo "      Секрет сохранён в $SECRET_FILE"

# ------------------------------------------------------------------------------
# Шаг 4/7 — Конфигурация
# ВАЖНО: stats bind-to = 0.0.0.0 внутри контейнера,
#        снаружи доступ ограничен через -p 127.0.0.1:STATS_PORT
# ------------------------------------------------------------------------------
echo "[4/7] Запись конфига в $CONFIG_FILE..."
cat > "$CONFIG_FILE" <<EOF
secret = "$SECRET"
bind-to = "0.0.0.0:$PORT"

[stats.prometheus]
enabled = true
bind-to = "0.0.0.0:$STATS_PORT"
http-path = "/"
EOF
echo "      Конфиг записан ✓"

# ------------------------------------------------------------------------------
# Шаг 5/7 — Запуск контейнера
# Останавливаем старый, если был (например при переустановке)
# ------------------------------------------------------------------------------
echo "[5/7] Запуск контейнера mtg..."
docker stop mtg 2>/dev/null && docker rm mtg 2>/dev/null || true

docker run -d \
  --name mtg \
  --restart=always \
  -p "$PORT:$PORT" \
  -p "127.0.0.1:$STATS_PORT:$STATS_PORT" \
  -v "$CONFIG_FILE:/config.toml:ro" \
  nineseconds/mtg:2 \
  run /config.toml

# Ждём запуска (до 15 секунд)
echo "      Ожидаем запуска контейнера..."
STARTED=false
for i in {1..15}; do
  if docker ps --filter "name=^mtg$" --filter "status=running" | grep -q mtg; then
    STARTED=true
    break
  fi
  sleep 1
done

if [[ "$STARTED" == true ]]; then
  echo "      Контейнер запущен ✓"
else
  echo "      ОШИБКА: контейнер не запустился. Логи:"
  docker logs mtg
  exit 1
fi

# ------------------------------------------------------------------------------
# Шаг 6/7 — Firewall (UFW)
# Если используется другой файрвол (iptables, nftables) — настрой вручную
# ------------------------------------------------------------------------------
echo "[6/7] Настройка UFW..."
if command -v ufw &>/dev/null; then
  ufw allow "$PORT/tcp" comment 'MTProto Telegram'
  ufw reload
  echo "      Порт $PORT открыт в UFW ✓"
else
  echo "      UFW не найден. Открой порт вручную:"
  echo "      iptables -A INPUT -p tcp --dport $PORT -j ACCEPT"
fi

# ------------------------------------------------------------------------------
# Шаг 7/7 — Проверка статистики
# ------------------------------------------------------------------------------
echo "[7/7] Проверка endpoint статистики..."
sleep 3
if curl -s --max-time 5 "http://127.0.0.1:$STATS_PORT/" | grep -q "mtg"; then
  echo "      Статистика работает ✓"
else
  echo "      Статистика пока недоступна (это нормально — попробуй через минуту):"
  echo "      curl http://127.0.0.1:$STATS_PORT/"
fi

# ------------------------------------------------------------------------------
# Получаем внешний IP сервера
# ------------------------------------------------------------------------------
SERVER_IP=$(curl -s --max-time 5 ifconfig.me || echo "не удалось определить")

# ------------------------------------------------------------------------------
# Итог
# ------------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  MTProto прокси готов!"
echo "============================================================"
echo ""
if [[ "$IS_IP" == true ]]; then
  echo "  Подключение по IP:"
  echo "  tg://proxy?server=$DOMAIN&port=$PORT&secret=$SECRET"
else
  echo "  Подключение по домену:"
  echo "  tg://proxy?server=$DOMAIN&port=$PORT&secret=$SECRET"
  echo ""
  echo "  Подключение по IP (резерв):"
  echo "  tg://proxy?server=$SERVER_IP&port=$PORT&secret=$SECRET"
fi
echo ""
echo "  Секрет сохранён: $SECRET_FILE"
echo ""
echo "  Статистика (только с сервера):"
echo "  curl http://127.0.0.1:$STATS_PORT/"
echo ""
echo "  Мониторинг в реальном времени:"
echo "  watch -n 2 'curl -s http://127.0.0.1:$STATS_PORT/ | grep -E \"connections|traffic\"'"
echo ""
echo "  Перезапуск прокси:"
echo "  docker restart mtg"
echo ""
echo "  Логи:"
echo "  docker logs -f mtg"
echo "============================================================"
