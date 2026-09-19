**Киллер фичи (Killer features)**

1. Возможность подключиться к WARP+
2. Замена endpoint на любой, в том числе IPv6 (через socat)
3. На основе замены endpoint с NAT64 можно сделать “soultransfer”
4. Безотказная работа после перезагрузки машины (персистентность)

**Быстрая настройка (How to use)**

Установка (install):

```bash
curl -fsSL https://raw.githubusercontent.com/snowybunny/awgwarp/main/script.sh -o /tmp/awgwarp-install.sh && bash /tmp/awgwarp-install.sh
```

После установки, запуск командой (after):

```bash
awgwarp
```

**Поддерживаемые системы (OS support)**

| OS      | Version | Support |
|---------|---------|---------|
| Ubuntu  | 20.04   | yes     |
| Ubuntu  | 22.04   | yes     |
| Ubuntu  | 24.04   | yes     |
| Debian  | 11      | yes     |
| Debian  | 12      | yes     |
| Debian  | 13      | yes     |
