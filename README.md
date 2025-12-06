Отличная идея — зафиксировать всё в одном месте 👌
Ниже список **всех файлов, которые реально участвуют в текущей схеме VLESS + dnsmasq + ipset** (плюс отдельно помечу то, что больше не используется, но когда-то было).

---

## 1. XRay (VLESS GVPN_vless-zoo-gate)

**Бинарь:**

* `/opt/sbin/xray`
  XRay core из Entware, запускается через init-скрипт `S24xray`.

**Конфиги XRay:**

* `/opt/etc/xray/configs/01_log.json`
  Логирование XRay:

  * `access: "none"` — access-лог полностью выключен;
  * `error: "/tmp/xray/error.log"` — ошибки только в RAM;
  * `loglevel: "error"` — минимум болтовни, только ошибки;
  * `dnsLog: false` — DNS-логирование отключено.

* `/opt/etc/xray/configs/03_inbounds.json`
  Входящий transparent-прокси:

  * inbound `tag: "redirect"`
  * `protocol: "dokodemo-door"`
  * `port: 61219`
  * `followRedirect: true`
  * `sniffing` включён (`http/tls/quic`), чтобы XRay понимал назначения.

* `/opt/etc/xray/configs/04_outbounds.json`
  Выходы из XRay:

  * `tag: "GVPN_vless-zoo-gate"` – твой VLESS+Reality:

    * `address: 5.61.36.241`, `port: 443`
    * `id: 0fa031dc-1304-4895-b5a1-b7e8f5e5b556`
    * `network: "xhttp"`, `security: "reality"`
    * `pbk`, `sni`, `sid`, `spiderX` как в твоём VLESS-URL
  * `tag: "direct"` – обычный `freedom` (на будущее, пока не используем в routing).

* `/opt/etc/xray/configs/05_routing.json`
  Самый простой routing, заточенный под dnsmasq+ipset:

  ```jsonc
  {
    "routing": {
      "domainStrategy": "AsIs",
      "rules": [
        {
          "type": "field",
          "inboundTag": ["redirect"],
          "outboundTag": "GVPN_vless-zoo-gate"
        }
      ]
    }
  }
  ```

  → Всё, что пришло с инбаунда `redirect` (а туда попадает только ipset `unblock`), уходит через VLESS-транк `GVPN_vless-zoo-gate`.

* `/opt/etc/xray/configs/06_policy.json`
  Политика соединений:

  * для уровня `0` – `connIdle: 30` секунд.

**Init-скрипт XRay:**

* `/opt/etc/init.d/	S24xray`

  ```sh
  #!/bin/sh

  ENABLED=yes
  PROCS=xray
  ARGS="run -confdir /opt/etc/xray/configs"
  PREARGS=""
  DESC=$PROCS
  PATH=/opt/sbin:/opt/bin:/opt/usr/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

  [ -z "$(which $PROCS)" ] && exit 0

  # Логи в RAM — убедимся, что каталог есть
  [ -d /tmp/xray ] || mkdir -p /tmp/xray

  . /opt/etc/init.d/rc.func
  ```

  Делает две вещи:

  * гарантирует наличие `/tmp/xray` при старте;
  * запускает `/opt/sbin/xray run -confdir /opt/etc/xray/configs`.

**Runtime-директория логов:**

* `/tmp/xray/`

  * `/tmp/xray/error.log` — сюда XRay пишет ошибки (в RAM, не во флеш).

---

## 2. DNS + unblock (dnsmasq + ipset)

**Основной конфиг dnsmasq:**

* `/opt/etc/dnsmasq.conf`

  Сейчас в нём:

  ```ini
  user=nobody
  bogus-priv
  no-negcache
  clear-on-reload
  bind-dynamic
  listen-address=172.16.1.1
  listen-address=127.0.0.1
  min-port=4096
  cache-size=1536
  expand-hosts
  log-async
  conf-file=/opt/etc/unblock.dnsmasq

  server=178.239.198.84
  server=1.1.1.1
  server=8.8.8.8
  server=45.86.203.244
  server=178.239.198.86
  server=85.203.37.2
  server=8.8.8.4
  ```

  * слушает на `172.16.1.1` и `127.0.0.1`;
  * подключает `unblock.dnsmasq`;
  * использует твой набор апстрим-DNS.

**Список доменов/IP для туннеля:**

* `/opt/etc/unblock.txt`
  Единый список доменов / CIDR / диапазонов, которые должны идти через VLESS.
  Используется обеими утилитами: `unblock_dnsmasq.sh` и `unblock_ipset.sh`.

**Сгенерированный dnsmasq-файл:**

* `/opt/etc/unblock.dnsmasq`
  Содержит строки вида:

  ```ini
  ipset=/example.com/unblock
  ipset=/another-domain.com/unblock
  ...
  ```

  Генерируется из `unblock.txt` скриптом `unblock_dnsmasq.sh`.

**Скрипты unblock:**

* `/opt/bin/unblock_update.sh`

  Мастер-скрипт обновления схемы unblock:

  ```sh
  #!/bin/sh
  ipset flush unblock
  /opt/bin/unblock_dnsmasq.sh
  /opt/etc/init.d/S56dnsmasq restart
  /opt/bin/unblock_ipset.sh &
  ```

  Делает:

  * чистит ipset `unblock`,
  * пересобирает `unblock.dnsmasq`,
  * перезапускает dnsmasq,
  * запускает наполнение ipset в фоне.

* `/opt/bin/unblock_dnsmasq.sh`

  Читает `/opt/etc/unblock.txt` и строит `/opt/etc/unblock.dnsmasq`.
  Игнорирует пустые строки, комментарии, голые IP — то есть в `unblock.dnsmasq` попадают только домены.

* `/opt/bin/unblock_ipset.sh`

  Тоже читает `/opt/etc/unblock.txt` и:

  * добавляет в ipset `unblock` CIDR-сети (`x.x.x.x/yy`),
  * диапазоны IP,
  * одиночные IP;
  * для доменов делает `dig +short ... @localhost` и добавляет полученные IP в ipset `unblock`.

**Init-скрипты:**

* `/opt/etc/init.d/S56dnsmasq`
  Старт/стоп dnsmasq с конфигом `/opt/etc/dnsmasq.conf`.

* `/opt/etc/init.d/S99unblock`

  ```sh
  #!/bin/sh
  [ "$1" != "start" ] && exit 0
  /opt/bin/unblock_ipset.sh &
  ```

  При старте Entware поднимает ipset `unblock` на основе `unblock.txt`.

---

## 3. NAT / интеграция с Keenetic (netfilter)

**Скрипт для NAT и DNS-DNAT:**

* `/opt/etc/ndm/netfilter.d/100-redirect.sh`

  Актуальное содержимое:

  ```sh
  #!/bin/sh
  [ "$type" == "ip6tables" ] && exit 0
  if [ -z "$(iptables-save 2>/dev/null | grep unblock)" ]; then
      ipset create unblock hash:net -exist
      iptables -I PREROUTING -w -t nat -i br0 -p tcp -m set --match-set unblock dst -j REDIRECT --to-port 61219
      iptables -I PREROUTING -w -t nat -i br0 -p udp -m set --match-set unblock dst -j REDIRECT --to-port 61219
  fi
  if [ -z "$(iptables-save 2>/dev/null | grep "udp \-\-dport 53 \-j DNAT")" ]; then
      iptables -w -t nat -I PREROUTING -i br0 -p udp --dport 53 -j DNAT --to 172.16.1.1
  fi
  if [ -z "$(iptables-save 2>/dev/null | grep "tcp \-\-dport 53 \-j DNAT")" ]; then
      iptables -w -t nat -I PREROUTING -i br0 -p tcp --dport 53 -j DNAT --to 172.16.1.1
  fi
  exit 0
  ```

  Делает:

  * создаёт (или гарантирует) ipset `unblock`;
  * вешает REDIRECT с `br0` → порт `61219` (XRay) для `dst ∈ ipset unblock`;
  * заворачивает весь DNS (br0:53/udp,tcp) на `172.16.1.1` (dnsmasq).

**Дополнительный скрипт netfilter (может существовать):**

* `/opt/etc/ndm/netfilter.d/100-ipset.sh`

  Исторический скрипт:

  ```sh
  #!/bin/sh
  [ "$1" != "start" ] && exit 0
  ipset create unblock hash:net -exist
  exit 0
  ```

  Сейчас **функционально не обязателен**, т.к. ipset `unblock` создаётся внутри `100-redirect.sh`, но, если он лежит в `netfilter.d`, NDM всё равно его выполняет. В текущей схеме можно считать его «лишней, но безвредной страховкой».

---

## 4. Службы и основные команды

Чтобы зафиксировать ещё и «командную часть» схемы — вот краткий список того, чем ты реально пользуешься/можешь пользоваться:

**XRay:**

* Проверка конфига:

  ```sh
  /opt/sbin/xray run -test -confdir /opt/etc/xray/configs
  ```

* Управление сервисом:

  ```sh
  /opt/etc/init.d/S24xray start
  /opt/etc/init.d/S24xray stop
  /opt/etc/init.d/S24xray restart
  ```

* Проверка, что процесс жив:

  ```sh
  ps | grep [x]ray
  ```

* Логи ошибок:

  ```sh
  tail -n 50 /tmp/xray/error.log
  ```

**dnsmasq + unblock:**

* Перезапуск dnsmasq:

  ```sh
  /opt/etc/init.d/S56dnsmasq restart
  ```

* Обновление unblock (dnsmasq + ipset):

  ```sh
  /opt/bin/unblock_update.sh
  ```

* Запуск ipset-наполнения при старте (обычно автоматом):

  ```sh
  /opt/etc/init.d/S99unblock start
  ```

* Проверка, что ipset `unblock` жив и наполнен:

  ```sh
  ipset list unblock | head
  ```

**NAT / контроль:**

* Проверить, что NAT-редиректы на 61219 активны:

  ```sh
  iptables-save -t nat | grep unblock
  ```

---

## 5. Что **больше не используется** (но может ещё лежать на флеше)

Чтобы не было путаницы «а этот файл за что», отдельно помечу то, что мы *отвязали* от схемы:

* `/opt/etc/shadowsocks.json` – **удалён**
* `/opt/etc/init.d/S22shadowsocks` – **удалён**
* `/opt/etc/dnsmasq_socks.conf` – **удалён** (локальная копия была только для удобства)

Скрипты для автогенерации роутинга XRay по доменам (`xray_update_routing.sh`, `xray_update_routing_ru.sh`) **в текущей схеме не используются**:
маршрутизация у нас максимально простая (`redirect → GVPN_vless-zoo-gate`), а доменные списки живут в `dnsmasq + ipset`.

---

Если хочешь, следующим шагом можем:

* это всё сохранить в какой-нибудь `/opt/etc/README.vless-keenetic.txt`,
* или сделать маленький скрипт `/opt/bin/xray-status.sh`, который одним запуском покажет состояние XRay, dnsmasq, ipset и NAT.
