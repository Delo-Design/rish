# RISH – Robust Internet Server Host 

SSH Web-server control panel

![appletouch](https://user-images.githubusercontent.com/3103677/151532067-f10dfc07-b86c-44de-a083-c28b21f82d57.png)

SSH панель конфигурации и установки web сервера 

Официальный сайт RISH https://rish.su

Протестировано на AlmaLinux (CentOS 8), Rocky Linux и Fedora

* http/2
* gzip and brotli компрессия
* mpm event для apache
* MariaDB 10.6
* Система не устанавливает никаких дополнительных сервисов и не расходует попусту ресурсов сервера
* Все актуальные версии PHP начиная с 7.2 (список держится в актуальном состоянии)
* Есть возможность установки Joomla

Команда установки

Предпочтительная команда установки с основного сервера:

    curl -L get.rish.su | sh

Если у вас блокируется установка с серверов РФ – воспользуйтесь альтернативным адресом. Установка произойдет с серверов github. Альтернативная команда установки:
    
    curl -L getrish.sovmart.com | sh

Внимание! Запускать скрипт надо от root!

Возможно, что в минимальной установке CentOS будет отсутствовать команда curl и ее понадобится установить отдельно:

    yum install curl

