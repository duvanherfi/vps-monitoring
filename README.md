# Monitoreo de la VPS

Stack de monitoreo para una VPS con servicios en Docker Compose. Cubre tres
preguntas distintas, que conviene no mezclar:

| Pregunta | Herramienta |
|---|---|
| ¿Cómo va el host? (CPU, RAM, disco, red) | node_exporter → Prometheus → Grafana |
| ¿Cómo va cada servicio? (recursos por contenedor) | cAdvisor → Prometheus → Grafana |
| ¿Está caído? | Uptime Kuma (dentro) + Healthchecks.io (fuera) |
| ¿Quién me avisa? | Alertmanager → Telegram |

Consumo aproximado: ~800 MB de RAM y ~2 GB de disco al mes con 30 días de
retención.

## Por qué la capa externa

Todo lo de aquí corre *dentro* de la VPS. Si la VPS muere, el monitoreo muere
con ella y no te enteras. Por eso Prometheus emite una alerta `Watchdog` que
siempre está activa; Alertmanager la manda cada minuto a Healthchecks.io, y
Healthchecks te avisa cuando esos pings **dejan** de llegar. Ese es el único
componente que tiene que vivir fuera.

## Instalación en la VPS, paso a paso

Probado sobre Ubuntu 22.04/24.04 y Debian 12. Si tu VPS ya tiene Docker y un
usuario no-root, salta al paso 3.

### Paso 0 — Conéctate y actualiza

```bash
ssh usuario@IP-DE-TU-VPS
sudo apt update && sudo apt upgrade -y
```

### Paso 1 — Usuario no-root con acceso a Docker

Saltar si ya lo tienes. No corras este stack como `root`.

```bash
sudo adduser duvan
sudo usermod -aG sudo duvan
```

### Paso 2 — Instalar Docker y Docker Compose

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
```

Cierra la sesión SSH y vuelve a entrar para que el grupo `docker` surta efecto.
Comprueba:

```bash
docker run --rm hello-world
docker compose version
```

### Paso 3 — Clonar el repositorio

```bash
git clone https://github.com/duvanherfi/vps-monitoring.git ~/monitoring
cd ~/monitoring
```

### Paso 4 — Crear los ficheros de configuración con secretos

Los dos ficheros con secretos no están en el repo. Se crean a partir de los
`.example`:

```bash
cp .env.example .env
cp alertmanager/alertmanager.yml.example alertmanager/alertmanager.yml
```

Genera una contraseña fuerte para Grafana y déjala en `.env`:

```bash
sed -i "s/change-me-now/$(openssl rand -base64 24)/" .env
grep GRAFANA_ADMIN_PASSWORD .env   # apúntala en tu gestor de contraseñas
```

### Paso 5 — Configurar Telegram

1. Habla con [@BotFather](https://t.me/BotFather) en Telegram → `/newbot` →
   copia el token que te da.
2. Escríbele cualquier cosa a tu bot recién creado (si no, no puede
   responderte).
3. Saca tu `chat_id`:

```bash
curl -s "https://api.telegram.org/bot<TU_TOKEN>/getUpdates" | grep -o '"id":[0-9-]*' | head -1
```

4. Edita `alertmanager/alertmanager.yml` y sustituye
   `REPLACE_WITH_TELEGRAM_BOT_TOKEN` y el `chat_id`.

### Paso 6 — Configurar el dead man's switch

1. Crea una cuenta gratis en [healthchecks.io](https://healthchecks.io).
2. Crea un check con **Period: 5 minutes** y **Grace: 5 minutes**.
3. Copia su ping URL y sustituye `REPLACE_WITH_HEALTHCHECKS_UUID` en
   `alertmanager/alertmanager.yml`.
4. En Healthchecks, configura la notificación a tu email (y/o Telegram).

Esta es la pieza que te avisa si la VPS entera muere. Sin ella, el monitoreo
se cae junto con lo que monitorea.

### Paso 7 — Validar la configuración antes de levantar

```bash
docker compose config -q && echo "compose OK"

docker run --rm -v "$PWD/prometheus:/p:ro" prom/prometheus:v3.1.0 \
  promtool check config /p/prometheus.yml

docker run --rm -v "$PWD/alertmanager:/a:ro" prom/alertmanager:v0.28.0 \
  amtool check-config /a/alertmanager.yml
```

### Paso 8 — Levantar el stack

```bash
docker compose up -d
docker compose ps        # los 6 servicios deben estar Up
docker compose logs -f   # Ctrl-C para salir
```

Comprueba que Prometheus ve sus targets:

```bash
curl -s localhost:9090/api/v1/targets | grep -o '"health":"[a-z]*"'
```

Deberías ver `"health":"up"` para `node-exporter` y `cadvisor`.

### Paso 9 — Firewall

El stack publica todo en `127.0.0.1`, así que no hace falta abrir puertos. Si
usas `ufw`, asegúrate de que sigue cerrado a todo salvo SSH y lo que ya
sirvieran tus servicios:

```bash
sudo ufw status
```

> Cuidado: si tus servicios corren en Docker con puertos publicados, Docker
> escribe reglas en `iptables` que **se saltan `ufw`**. Verifica desde fuera
> con `nmap -Pn TU-IP` qué hay realmente expuesto.

### Paso 10 — Acceder a las UIs

Desde tu máquina local, no desde la VPS:

```bash
ssh -L 3000:localhost:3000 \
    -L 3001:localhost:3001 \
    -L 9090:localhost:9090 \
    -L 9093:localhost:9093 usuario@IP-DE-TU-VPS
```

Con el túnel abierto:

- Grafana → http://localhost:3000 (usuario `admin`, la contraseña del `.env`)
- Uptime Kuma → http://localhost:3001 (crea la cuenta al primer acceso)
- Prometheus → http://localhost:9090
- Alertmanager → http://localhost:9093

### Paso 11 — Importar los dashboards

En Grafana: **Dashboards → New → Import**, pega el ID y selecciona el
datasource `Prometheus`.

| ID | Qué muestra |
|---|---|
| `1860` | Node Exporter Full — el host, completo |
| `193` | Docker & host — resumen por contenedor |
| `19792` | Alertmanager |

### Paso 12 — Dar de alta tus servicios en Uptime Kuma

En http://localhost:3001 → **Add New Monitor**, uno por servicio:

- **Monitor Type**: HTTP(s)
- **URL**: la URL pública del servicio, o `http://nombre-contenedor:puerto` si
  lo conectas a la red `monitoring` (ver README principal)
- **Heartbeat Interval**: 60 segundos

### Paso 13 — Probar que las alertas llegan de verdad

Una alerta que nunca se ha probado no es una alerta. Para un contenedor
cualquiera y espera ~3 minutos:

```bash
docker stop NOMBRE-DE-UN-SERVICIO
# deberías recibir ContainerDisappeared en Telegram
docker start NOMBRE-DE-UN-SERVICIO
# y la resolución poco después
```

Verifica también que Healthchecks.io está recibiendo pings: su panel debe
mostrar el check en verde con un ping reciente.

### Paso 14 — Arranque automático

No hace falta nada: `restart: unless-stopped` hace que los contenedores
vuelvan solos tras un reinicio de la VPS. Confírmalo:

```bash
sudo reboot
# espera un minuto, reconecta
docker compose ps
```

## Checks externos por servicio (opcional pero recomendado)

Healthchecks solo te dice que la VPS respira. Para saber que cada servicio
responde desde internet, añade un monitor HTTP gratuito por servicio en
[UptimeRobot](https://uptimerobot.com) o [Better Stack](https://betterstack.com).
Uptime Kuma hace lo mismo pero desde dentro de la VPS, así que los dos se
complementan.

## Dashboards de Grafana

Grafana arranca con el datasource de Prometheus ya configurado. Importa estos
dashboards de la comunidad (Dashboards → New → Import → pega el ID):

| ID | Qué muestra |
|---|---|
| `1860` | Node Exporter Full — el host, completo |
| `193` | Docker & host — resumen por contenedor |
| `19792` | Alertmanager |

Para dejarlos versionados: expórtalos como JSON y déjalos en
`grafana/provisioning/dashboards/`; se cargan solos al arrancar.

## Uptime Kuma

Añade un monitor HTTP(s) por cada servicio. Para apuntar a un contenedor por
nombre en vez de por URL pública, conecta ese servicio a la red `monitoring`:

```yaml
# en el docker-compose.yml de tu servicio
networks:
  - default
  - monitoring

networks:
  monitoring:
    external: true
```

Y en Uptime Kuma usa `http://nombre-del-contenedor:puerto/health`.

## Añadir el tercer servicio

1. **Métricas de contenedor**: nada que hacer. cAdvisor lo detecta solo.
2. **Uptime**: añade un monitor en Uptime Kuma.
3. **Métricas de aplicación** (si expone `/metrics`): descomenta un bloque en
   `prometheus/prometheus.yml`, conecta el servicio a la red `monitoring` y
   recarga sin reiniciar:

```bash
docker compose exec prometheus kill -HUP 1
```

## Operación

```bash
# Validar la config de Prometheus antes de recargar
docker compose exec prometheus promtool check config /etc/prometheus/prometheus.yml

# Ver qué alertas están activas
curl -s localhost:9090/api/v1/alerts | jq

# Silenciar temporalmente: Alertmanager UI en localhost:9093

# Actualizar imágenes (los tags están fijados a propósito; súbelos a mano
# y revisa los changelogs antes)
docker compose pull && docker compose up -d
```

## Alertas definidas

Ver `prometheus/alerts.yml`. Resumen:

- **Host**: caído, CPU >85% (15m), RAM >90% (10m), disco >85%, disco que se
  llenará en 24h (`predict_linear`), swap >50%.
- **Contenedores**: desaparecido, en bucle de reinicios, cerca de su límite de
  memoria, CPU sostenida >90%.
- **Scraping**: un target de aplicación que deja de responder (la app está
  arriba pero rota).

Los umbrales son conservadores a propósito. Una alerta que salta cada semana se
acaba silenciando, y una alerta silenciada es peor que ninguna alerta.
