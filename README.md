[![Status](https://img.shields.io/badge/status-alpha-orange?style=flat-square)](https://github.com/snowybunny/awgwarp)
[![Version](https://img.shields.io/badge/version-0.1-blue?style=flat-square)](https://github.com/snowybunny/awgwarp)
[![Platform](https://img.shields.io/badge/platform-Linux-lightgrey?style=flat-square)](https://github.com/snowybunny/awgwarp)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-20.04%20%7C%2022.04%20%7C%2024.04-E95420?style=flat-square&logo=ubuntu&logoColor=white)](https://ubuntu.com/)
[![Debian](https://img.shields.io/badge/Debian-11%20%7C%2012%20%7C%2013-A81D33?style=flat-square&logo=debian&logoColor=white)](https://www.debian.org/)
[![Bash](https://img.shields.io/badge/Bash-script-4EAA25?style=flat-square&logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)

# AWGWARP Manager v0.1

Каскадный VPN на основе Cloudflare WARP через AmneziaWG (Cascading VPN based on Cloudflare WARP via AmneziaWG).

**Схема (Scheme):** `Client ← VPS ← AWG ← WARP`

Для полноценной работы требуются права **root**. (Root privileges are required for full functionality)

---

## Киллер-фичи (Killer features)

1. Возможность подключиться к **WARP+**
2. Замена endpoint на любой, в том числе IPv6 (через socat)
3. На основе замены endpoint с NAT64 можно сделать **“soultransfer”**
4. Безотказная работа после перезагрузки машины (персистентность)

---

## Быстрая настройка (How to use)

### Установка (Install)

```bash
curl -fsSL https://raw.githubusercontent.com/snowybunny/awgwarp/main/script.sh -o /tmp/awgwarp-install.sh && bash /tmp/awgwarp-install.sh
```

### Запуск (Run)

```bash
awgwarp
```

---

## Поддерживаемые системы (OS support)

| ОС (OS)  | Версия (Version) | Поддержка (Support) |
|----------|------------------|---------------------|
| Ubuntu   | 20.04            | ✅                  |
| Ubuntu   | 22.04            | ✅                  |
| Ubuntu   | 24.04            | ✅                  |
| Debian   | 11               | ✅                  |
| Debian   | 12               | ✅                  |
| Debian   | 13               | ✅                  |
