MTProto FakeTLS proxy setup (nineseconds/mtg:2) with Prometheus stats

КАК ЗАПУСТИТЬ:
   sudo bash setup_mtproto.sh <домен_или_ip> [порт] [порт_статистики]
   

 ПРИМЕРЫ:
   sudo bash setup_mtproto.sh mydomain.ru          # порты по умолчанию
   sudo bash setup_mtproto.sh mydomain.ru 2083     # свой порт
   sudo bash setup_mtproto.sh 1.2.3.4              # без домена, только по IP

 ВАЖНО: Если у тебя нет домена — просто передай IP-адрес сервера.
         Маскировка FakeTLS будет использовать google.com автоматически.
