# WLED Animation (`wled_anim`)

Светомузыка для Яндекс Станции Mini 2 на адресной ленте [WLED](https://kno.wled.ge/):
колонка анализирует звук, который сама играет, и в такт рисует анимацию на ленте.
Пакет для менеджера [yam](https://github.com/nyakokitsu/yam) — `kanad/wled-anim`

## Возможности

- Анимации: радуга от центра, одноцветная, VU-метр, пульс, спектр
  (бас / середина / верх) и «эффект WLED под музыку» — любой эффект и палитра
  самой ленты, яркость и интенсивность которых следуют за музыкой.
- Веб-интерфейс на порту 8098: IP ленты с проверкой и поиском, выбор анимации,
  задержка с калибровкой по тестовому биту, яркость, плавность, порог тишины.
- Не мигает в тишине и пока говорит Алиса.
- Голосом: «Алиса, включи / отключи светомузыку».

## Требования

- Яндекс Станция Mini 2 (платформа `yandexmini_2`) с root-доступом по adb.
  Другие модели не поддерживаются: отвод звука собран под конфиг ALSA Mini 2,
  на другой прошивке он просто не включится.
- [yam](https://github.com/nyakokitsu/yam) ≥ 0.2.2 на колонке.
- Entware с `luajit` и `curl` (yam попросит подтвердить их при установке).
- Лента на WLED в той же сети; приём UDP realtime включён (по умолчанию в WLED так).

## Установка

Скачайте `wled-anim-1.0.0.yampkg` из [Releases](../../releases) и выполните:

```sh
adb push wled-anim-1.0.0.yampkg /tmp/
adb shell /data/yam/bin/yam-run install --yes /tmp/wled-anim-1.0.0.yampkg
adb shell /data/yam/bin/wled_anim start
```

Затем откройте `http://<IP станции>:8098` и укажите IP ленты.

При первом запуске колонка один раз перезапускает свой звуковой сервис
(музыка прервётся на секунду): так подключается отвод звука. Штатный
`/etc/asound.conf` не меняется — используется bind mount, после перезагрузки
всё как было.

### Автозапуск

yam 0.2.2 сам службы не запускает, поэтому нужен init-скрипт:

```sh
adb push init/S99wled_anim /tmp/
adb shell "mount -o remount,rw / && cp /tmp/S99wled_anim /etc/init.d/ && chmod 755 /etc/init.d/S99wled_anim; mount -o remount,ro /"
```

## Управление

- `wled_anim start | stop | restart | status` (`stop` возвращает штатный звук).
- Настройки: `/data/yam/var/wled_anim/settings` — их же меняет веб-интерфейс.
- Удаление: `wled_anim stop`, затем `yam-run remove kanad/wled-anim` и удалить
  `/etc/init.d/S99wled_anim`, если ставили автозапуск.

## Как это устроено

- `asound.conf.in` — штатный конфиг ALSA Mini 2 с плагином `file`, который
  отдаёт копию звука в `tap.lua`.
- `tap.lua` каждые 10 мс считает уровни баса, середины и верха и шлёт их
  по UDP на localhost.
- `leds.lua` рисует кадры и отправляет их на WLED по UDP (DRGB) или
  модулирует эффект WLED JSON-пакетами.
- `web.lua` — небольшой HTTP-сервер для интерфейса `index.html`.
- `voice.sh` — голосовые команды по логу Алисы.

## Сборка

```sh
yam-publish pack --source . --platform yandexmini_2 --profiles <каталог platforms из yam> --output dist/wled-anim-1.0.0.yampkg
```

## Об авторстве

Проект сделан с помощью [Claude](https://claude.com/claude-code) (Claude Code,
Anthropic) по идее и под руководством [dailrus](https://github.com/dailrus).
Страницу интерфейса и анимации VU-метр, пульс и спектр по заданию Claude
написал DeepSeek; Claude их проверил и доработал.

## Лицензия

[MIT](LICENSE)
