# RISH
SSH Web-server control panel

SSH панель конфигурации и установки web сервера 

Протестировано на CentOS 7

* http/2
* gzip and brotli компрессия
* mpm event для apache
* MariaDB 10.4
* Система не устанавливает никаких дополнительных сервисов и не расходует попусту ресурсов сервера
* PHP 7.4-5.4

Команда установки

    wget https://hika.su/rish.tar.gz && tar -xvf rish.tar.gz && cd rish  && chmod u+x ri.sh && ./ri.sh

Возможно, что в минимальной установке CentOS будет отсутствовать команда wget и ее понадобится установить отдельно:

    yum install wget


Видео об использовании
(https://youtu.be/9wli9f2krCY)
