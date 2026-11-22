# Исходная иконка MangaLib

`mangalib-original.jpg` — изображение 240×240 из ссылки RuStore, предоставленной
пользователем. Логотип не перерисован. Источник:

https://static.rustore.ru/apk/2063541439/content/ICON/6fc5feaf-001c-41ab-ad45-fdfb43ffc53d.jpg

Название и логотип MangaLib принадлежат их правообладателям; MangaLib6 —
неофициальный экспериментальный клиент.

`tools/make_icons.py` создаёт PNG без прозрачности для iPhone/iPad и Retina.
Скругление, стандартный блик и тень добавляет SpringBoard iOS 5/6:
в `Info.plist` установлен `UIPrerenderedIcon = false`.
