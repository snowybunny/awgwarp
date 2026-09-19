# AWGWARP Manager v0.1

Каскадный VPN на основе Cloudflare WARP через AmneziaWG (AWG).  
(Cascading VPN based on Cloudflare WARP via AmneziaWG)

**Схема (Scheme):** `Клиент ← VPS ← AWG ← WARP`  
(`Client ← VPS ← AWG ← WARP`)

Для полноценной работы требуются права **root**.  
(Root privileges are required for full functionality)

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
