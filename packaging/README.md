# Cydia-репозиторий MangaLib6

Репозиторий состоит из статических файлов. PHP, база данных и постоянно работающий
Python не нужны. Веб-сервер раздаёт `repo/` по адресу `http://tayga16.ru/repo/`.
Пакет рассчитан на jailbreak с обычной файловой системой iOS 5.1+ (ARMv7).
IPA и DEB имеют один bundle ID; данные при переходе с установки IPA в `/Applications`
могут оказаться в другом каталоге, поэтому заранее сохрани нужные скачанные главы.

## Подготовка файлов

```sh
meow build MangaLib6-ipa
meow build MangaLib6-deb
python tools/check_ipa.py build/MangaLib6_0.5.1.ipa
python tools/cydia_repo.py --deb build/ru.mangapad.apitest_0.5.1_iphoneos-arm.deb --ipa build/MangaLib6_0.5.1.ipa
```

`build/cydia/repo/` содержит `Release`, `Packages`, `Packages.gz`, `Packages.bz2`,
иконку, страницу с кнопкой добавления в Cydia и `debs/` с пакетом. Рядом появляется
`MangaLib6_0.5.1_Cydia_repo.tar.gz`, готовый для переноса на сервер. Генератор проверяет
версию, ARM, права файлов, md5sums пакета, совпадение файлов IPA/DEB и хеши индексов.
DEB использует gzip: старые версии dpkg в iOS не читают новые форматы сжатия.
Скрипты установки обновляют список приложений через старую команду `uicache`.

## Если SSH на VPS ещё не работает

В панели провайдера открой консоль/VNC сервера. Для **Debian или Ubuntu** выполни:

```sh
sudo apt update
sudo apt install openssh-server
sudo systemctl enable --now ssh
sudo systemctl status ssh --no-pager
```

Если вошёл как root, `sudo` можно убрать. У провайдера разреши входящий TCP 22
(либо фактический порт SSH) и TCP 80. Если UFW уже включён, разреши эти порты
через `sudo ufw allow OpenSSH` и `sudo ufw allow 80/tcp`.

Используй пользователя и пароль/ключ, выданные при создании VPS.
На Windows подключение запускается из PowerShell:

```powershell
ssh ИМЯ_ПОЛЬЗОВАТЕЛЯ@IP_СЕРВЕРА
```

Пароль вводится в терминале и не отображается. Не публикуй его в переписке.
Для другой ОС команды установки SSH нужно подобрать под её пакетный менеджер.

## Self hosting через Proxmox

В Proxmox выбери **VM или LXC с веб-сервером → Console**. Команды установки
SSH и nginx выполняются внутри гостевой системы. На сам узел Proxmox веб-сервер
репозитория устанавливать не нужно.

Если отдельной машины ещё нет, можно создать Debian LXC:

1. На хранилище Proxmox открой **CT Templates → Templates**, скачай шаблон Debian.
2. Нажми **Create CT**: имя, например `cydia-repo`, шаблон Debian, диск 4 ГБ,
   1 CPU и 256–512 МБ RAM. Оставь контейнер unprivileged.
3. В Network выбери мост домашней сети (обычно `vmbr0`), укажи IP и шлюз своей
   сети либо DHCP. Для публикации закрепи адрес контейнера в роутере.
4. Запусти контейнер и открой его **Console**. Установи SSH и nginx командами
   выше. Через `hostname -I` узнай адрес контейнера.
5. На компьютере открой `http://IP_КОНТЕЙНЕРА/`: должна появиться страница nginx.
   Размести архив и настрой `/repo/`, как описано ниже.

Если сайт `tayga16.ru` уже проходит через reverse proxy, добавь на нём маршрут
`/repo/` к контейнеру с сохранением пути, например
`http://IP_КОНТЕЙНЕРА:80/repo/`. Он должен работать по HTTP без авторизации
и браузерных проверок. Если reverse proxy нет, направь TCP 80 роутера на
веб-сервер и DNS A домена на внешний IP. Для прямой публикации необходим
доступный извне IP или существующий внешний туннель/proxy; NAT провайдера
сам по себе входящие соединения не пропускает.

SSH нужен только для управления и переноса файлов: Cydia обращается к HTTP.
SSH и панель Proxmox можно оставить доступными только в локальной сети.

## Размещение на Linux

Если сайт уже работает, используй его существующий веб-сервер. Не заменяй
конфигурацию сайта целиком. Пример ниже — для nginx и каталога `/var/www/tayga16`.

1. Скачай архив репозитория из релиза `ios-v0.5.1` на GitHub или загрузи его через SFTP.
   На сервере можно скачать командой:

   ```sh
   curl -fL -o MangaLib6_0.5.1_Cydia_repo.tar.gz https://github.com/tayga16/MangaLib6/releases/download/ios-v0.5.1/MangaLib6_0.5.1_Cydia_repo.tar.gz
   ```

2. Создай каталог и распакуй архив:

   ```sh
   sudo mkdir -p /var/www/tayga16
   sudo tar -xzf MangaLib6_0.5.1_Cydia_repo.tar.gz -C /var/www/tayga16
   ```

3. В HTTP-блок `server` для `tayga16.ru` добавь содержимое
   [nginx-location.conf](nginx-location.conf). Если путь сайта другой, измени `alias`.
   Если nginx ещё не установлен, на Debian/Ubuntu установи `sudo apt install nginx`
   и создай блок `server` с `listen 80;`, `server_name tayga16.ru;` и этими `location`.
   Проверь отсутствие другого блока, обслуживающего тот же домен.

4. Проверь конфигурацию и примени её:

   ```sh
   sudo nginx -t
   sudo systemctl reload nginx
   ```

DNS-запись A домена должна указывать на публичный IPv4 сервера.
Если есть AAAA, сервер должен быть доступен и по указанному IPv6.
Редирект на HTTPS, проверка браузера или авторизация для `/repo/` помешают старой Cydia.
Редирект в `server` до обработки `location` нужно перенести в `location /`, чтобы
путь `/repo/` оставался доступен по HTTP.

## Проверка с другого устройства

```sh
curl -f http://tayga16.ru/repo/Release
curl -f http://tayga16.ru/repo/Packages
curl -f http://tayga16.ru/repo/Packages.gz | gzip -dc
curl -f -o MangaLib6.deb http://tayga16.ru/repo/debs/ru.mangapad.apitest_0.5.1_iphoneos-arm.deb
```

Ответы должны содержать индексы и бинарный пакет, а не HTML с ошибкой.
В Cydia добавь источник `http://tayga16.ru/repo/`, обнови источники и установи MangaLib6.
Репозиторий пока без GPG-подписи; предупреждение Cydia о неизвестном источнике ожидаемо.
Структура и целостность пакета проверяются при сборке; установка DEB на реальном
jailbroken устройстве требует отдельной проверки.
