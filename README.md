# 🔐 MTProto Proxy — автоматическая установка

Автоматическая установка MTProto-прокси для Telegram на Ubuntu-сервере.  
Использует [`nineseconds/mtg:2`](https://github.com/9seconds/mtg) с FakeTLS-маскировкой и встроенной статистикой Prometheus.

**Работает с доменом и без домена (только по IP).**  
Совместим с серверами, где уже установлен 3x-ui + REALITY.

---

## ⚡ Быстрый старт

### Вариант 1 — Есть домен

```bash
curl -fsSL https://raw.githubusercontent.com/idsn/publicvault/9f530db6f937d24c958012f5a013bed4ebc294b0/setup_mtproto.sh | sudo bash -s -- yourdomain.com
```

### Вариант 2 — Только IP (домена нет)

```bash
curl -fsSL https://raw.githubusercontent.com/idsn/publicvault/9f530db6f937d24c958012f5a013bed4ebc294b0/setup_mtproto.sh | sudo bash -s -- $(curl -s ifconfig.me)
```

> Замени `yourdomain.com` на свой домен, либо используй второй вариант — скрипт сам определит IP сервера.

---

## 🛠 Ручной запуск (если хочешь контролировать каждый шаг)

```bash
# 1. Скачай скрипт
wget -O setup_mtproto.sh https://raw.githubusercontent.com/idsn/publicvault/9f530db6f937d24c958012f5a013bed4ebc294b0/setup_mtproto.sh

# 2. Дай права на выполнение
chmod +x setup_mtproto.sh

# 3. Запусти
sudo bash setup_mtproto.sh yourdomain.com
```

---

## 📋 Синтаксис

```
sudo bash setup_mtproto.sh <домен_или_IP> [порт] [порт_статистики]
```

| Аргумент | Обязательный | По умолчанию | Описание |
|---|---|---|---|
| `домен_или_IP` | ✅ Да | — | Домен или IP-адрес сервера |
| `порт` | ❌ Нет | `2083` | Порт MTProto (должен быть открыт) |
| `порт_статистики` | ❌ Нет | `3129` | Порт Prometheus (только localhost) |

### Примеры

```bash
# Минимально — только домен
sudo bash setup_mtproto.sh example.com

# Со своим портом
sudo bash setup_mtproto.sh example.com 443

# Все параметры явно
sudo bash setup_mtproto.sh example.com 2083 3129

# Без домена, по IP
sudo bash setup_mtproto.sh 1.2.3.4
```

---

## 🔗 Ссылка для подключения

После установки скрипт выведет готовую ссылку вида:

```
tg://proxy?server=yourdomain.com&port=2083&secret=ee...
```

Просто **отправь эту ссылку другу** — он нажмёт и прокси добавится в Telegram автоматически.

---

## 📊 Статистика и мониторинг

```bash
# Разовая проверка
curl http://127.0.0.1:3129/

# Мониторинг в реальном времени
watch -n 2 'curl -s http://127.0.0.1:3129/ | grep -E "connections|traffic"'
```

> Статистика доступна **только с самого сервера** (localhost). Снаружи не открыта.

---

## 🔧 Управление прокси

```bash
# Статус контейнера
docker ps | grep mtg

# Логи
docker logs -f mtg

# Перезапуск
docker restart mtg

# Остановить
docker stop mtg

# Посмотреть сохранённый секрет
cat /opt/mtg/secret.txt
```

---

## ✅ Требования

- Ubuntu 20.04 / 22.04 / 24.04
- Root-доступ (`sudo`)
- Открытый порт (по умолчанию `2083/tcp`)
- Интернет-соединение на сервере

> **Совместимость:** скрипт не затрагивает 3x-ui, REALITY и другие сервисы — конфликтов нет, если порты не совпадают.

---

## 🧩 Как это работает

```
Клиент Telegram
      │
      │  TLS handshake (маскировка под обычный HTTPS)
      ▼
  Твой сервер :2083
      │
      │  mtg расшифровывает и проксирует
      ▼
  Серверы Telegram
```

**FakeTLS** — прокси выглядит как обычный HTTPS-сайт. Если домен не указан, маскировка работает под `google.com`. DPI-фильтрам сложно его заблокировать.

---

## 📁 Файлы на сервере

| Путь | Описание |
|---|---|
| `/opt/mtg/config.toml` | Конфигурация прокси |
| `/opt/mtg/secret.txt` | Сохранённый секрет (для восстановления ссылки) |

---

## 🆘 Если что-то пошло не так

```bash
# Посмотри логи контейнера
docker logs mtg

# Проверь, слушает ли порт
ss -tlnp | grep 2083

# Проверь firewall
ufw status
```

Если контейнер не стартует — скорее всего занят порт. Проверь: `sudo lsof -i :2083`
