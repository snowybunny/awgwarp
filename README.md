**Киллер фичи** ** (** **Killer feature)**  
1. Возможность подключиться к WARP+  
2. Замена endpoint на любой в том числе ipv6(через socat)  
3. На основе замены endpoint с nat64 можно сделать “soultransfer”  
4. Безотказная работа после перезагрузки машины (персистентность)  
**Быстрая настройка (How to use)**  
Установка (install):  
curl -fsSL https://raw.githubusercontent.com/snowybunny/awgwarp/main/script.sh -o /tmp/awgwarp-install.sh && bash /tmp/awgwarp-install.sh  
   
После установки, запуск командой (after):  
awgwarp  
   
**Поддерживаемые системы (OS support)**  
| | | |  
|-|-|-|  
| **OS** | **Version** | **Support** |   
| Ubuntu | 20.04 | yes |   
| Ubuntu | 22.04 | yes |   
| Ubuntu | 24.04 | yes |   
| Debian | 11 | yes |   
| Debian | 12 | yes |   
| Debian | 13 | yes |   
   
