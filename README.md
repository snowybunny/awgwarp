[![Status](https://img.shields.io/badge/status-alpha-orange?style=flat-square)](https://github.com/snowybunny/awgwarp)
[![Version](https://img.shields.io/badge/version-0.1-blue?style=flat-square)](https://github.com/snowybunny/awgwarp)
[![Platform](https://img.shields.io/badge/platform-Linux-lightgrey?style=flat-square)](https://github.com/snowybunny/awgwarp)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-20.04%20%7C%2022.04%20%7C%2024.04-E95420?style=flat-square&logo=ubuntu&logoColor=white)](https://ubuntu.com/)
[![Debian](https://img.shields.io/badge/Debian-11%20%7C%2012%20%7C%2013-A81D33?style=flat-square&logo=debian&logoColor=white)](https://www.debian.org/)
[![Bash](https://img.shields.io/badge/Bash-script-4EAA25?style=flat-square&logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)

# AWGWARP Manager v0.1

Cascading VPN based on Cloudflare WARP via AmneziaWG (Каскадный VPN на основе Cloudflare WARP через AmneziaWG).

**Scheme (Схема):** `Client ← VPS ← AWG ← WARP`

Root privileges are required for full functionality (Для полноценной работы требуются права **root**).

---

## Killer features (Киллер-фичи)

1. Ability to connect to **WARP+**.
2. Replace the endpoint with any address, including IPv6 (via socat).
3. Create **"soultransfer"** based on endpoint replacement with NAT64.
4. Reliable operation after machine reboot (persistence).

---

## How to use (Быстрая настройка)

### Install (Установка)

```bash
curl -fsSL https://raw.githubusercontent.com/snowybunny/awgwarp/main/script.sh -o /tmp/awgwarp-install.sh && bash /tmp/awgwarp-install.sh
```

### Run (Запуск)

```bash
awgwarp
```

---

## OS support (Поддерживаемые системы)

| OS (ОС) | Version (Версия) | Support (Поддержка) |
|----------|------------------|---------------------|
| Ubuntu   | 20.04            | ✅                  |
| Ubuntu   | 22.04            | ✅                  |
| Ubuntu   | 24.04            | ✅                  |
| Debian   | 11               | ✅                  |
| Debian   | 12               | ✅                  |
| Debian   | 13               | ✅                  |
