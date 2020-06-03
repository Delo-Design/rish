# RISH
SSH Web-server control panel

SSH панель конфигурации и установки web сервера 

Протестировано на CentOS 7

* http/2
* gzip and brotli компрессия
* mpm event для apache
* MariaDB 10.4
* Система не устанавливает никаких дополнительных сервисов и не расходует попусту ресурсов сервера
* PHP 7.3-5.4

Команда установки
wget https://hika.su/rish.tar.gz && tar -xvf rish.tar.gz && cd rish  && chmod u+x ri.sh && ./ri.sh
