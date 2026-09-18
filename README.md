# Monitoreo para una VPS con Docker

Plantilla de un stack de monitoreo completo para una VPS pequeña: seis
contenedores, desplegados con Kamal, que te avisan por Telegram cuando algo se
rompe — incluso si lo que se rompe es la VPS entera.

Pensado para una máquina con servicios en Docker (funciona con o sin Kamal), de
2 vCPU en adelante. Consume ~800 MB de RAM y ~2 GB de disco al mes con 30 días
de retención.

## Qué responde

Cuatro preguntas distintas. La confusión más cara de este stack es mezclarlas,
así que van separadas desde el principio:

| Pregunta | Quién la responde |
|---|---|
| ¿Cómo va la máquina? (CPU, RAM, disco) | node-exporter → Prometheus → Grafana |
| ¿Cómo va cada servicio? (recursos por contenedor) | Telegraf (API de Docker) → Prometheus → Grafana |
| ¿Responde por HTTP? | Uptime Kuma |
| ¿Sigue viva la VPS entera? | Healthchecks.io, desde fuera |

Y **dos sistemas de aviso independientes**, que es la otra confusión cara:

```
Prometheus ──> Alertmanager ──> Telegram        (recursos, contenedores caídos)
                           └──> Healthchecks.io (el latido Watchdog)

Uptime Kuma ─────────────────> Telegram         (HTTP y TCP: ¿responde?)
```

Alertmanager y Uptime Kuma **no se hablan**. Cada uno necesita su propia
configuración de Telegram. Saltarse esto es la causa número uno de "Kuma marca
el servicio en rojo y no me llega nada".

## Contenido

- [Antes de empezar](#antes-de-empezar)
- [Instalación paso a paso](#instalación-paso-a-paso) ← **empieza aquí**
- [Uso diario](#uso-diario)
- [Cambiar algo](#cambiar-algo)
- [Publicar por dominio](#publicar-por-dominio-opcional)
- [Decisiones de fondo](#decisiones-de-fondo)
- [Lo que este stack no ve](#lo-que-este-stack-no-ve)

---

# Antes de empezar

Necesitas:

- Una **VPS** con Docker 24+ y `ufw` (o el firewall que uses).
- Un **repositorio propio** a partir de esta plantilla. Lo normal es tenerlo
  **privado**: aunque aquí no haya ningún dato tuyo, tus Actions dejan a la
  vista cuándo despliegas y contra qué. Ver
  [Montarlo en tu repo](#paso-0-montarlo-en-tu-repo).
- Una cuenta en **Telegram** y otra en **Healthchecks.io** (plan gratuito).
- `git`, `ssh` y, para los pasos de configuración, la CLI
  [`gh`](https://cli.github.com) autenticada.

Nada de la configuración específica de tu máquina vive en el repo: la IP, los
dominios y los secretos entran por **variables y secrets de GitHub**. Por eso
todos los ejemplos usan los marcadores `TU-IP` y `TU-DOMINIO`.

---

# Instalación paso a paso

Ocho pasos. Los seis primeros dejan el monitoreo funcionando y avisando; el 7 y
el 8 son opcionales.

## Paso 0: montarlo en tu repo

El patrón recomendado son **dos repos**: éste como plantilla pública, y el tuyo
privado con `upstream` apuntando aquí para poder traerte las mejoras.

```bash
# 1. Clona la plantilla
git clone https://github.com/duvanherfi/vps-monitoring.git mi-monitoreo
cd mi-monitoreo

# 2. Crea TU repo privado y hazlo el remoto principal
gh repo create mi-monitoreo --private --source=. --remote=origin --push

# 3. Deja la plantilla como upstream para futuras mejoras
git remote add upstream https://github.com/duvanherfi/vps-monitoring.git
```

Cuando quieras traerte cambios de la plantilla, `git pull upstream main`.

## Paso 1: preparar la VPS

Un usuario `deploy` con acceso a Docker, para no desplegar como root:

```bash
ssh root@TU-IP

adduser --disabled-password --gecos "" deploy
usermod -aG docker deploy
mkdir -p /home/deploy/.ssh && chmod 700 /home/deploy/.ssh
chown -R deploy:deploy /home/deploy/.ssh

# Apunta este número: hace falta en el paso 5
stat -c %g /var/run/docker.sock
```

Y una clave SSH **dedicada a este repo** (desde tu máquina):

```bash
ssh-keygen -t ed25519 -f ~/.ssh/vps_monitoring_deploy -N "" \
  -C "vps-monitoring deploy"
ssh-copy-id -i ~/.ssh/vps_monitoring_deploy.pub deploy@TU-IP

# Compruébalo
ssh -i ~/.ssh/vps_monitoring_deploy deploy@TU-IP 'docker ps'
```

> **Una clave por repositorio.** Si se filtra la de un repo, rotas solo ésa y
> los despliegues de los demás siguen intactos. No reutilices tu clave personal:
> acabaría dentro de un secret de GitHub.

## Paso 2: crear el bot de Telegram

1. En Telegram, habla con [@BotFather](https://t.me/BotFather) → `/newbot`.
   Te da un **token** con la forma `123456789:AAE...`.
2. **Escríbele un mensaje cualquiera a tu bot.** Sin eso no puede contestarte.
3. Saca tu **chat id**:

```bash
curl -s "https://api.telegram.org/bot<TU-TOKEN>/getUpdates" \
  | grep -o '"chat":{"id":[0-9-]*' | head -1
```

Guarda el token y el chat id: los vas a usar dos veces, una en el paso 5 y otra
en el paso 7 (Uptime Kuma tiene su propia configuración).

## Paso 3: crear el check externo

En [Healthchecks.io](https://healthchecks.io), *Add Check*:

- **Name**: `vps-watchdog`
- **Period**: 5 minutos
- **Grace**: 5 minutos

Copia su **Ping URL** (`https://hc-ping.com/<uuid>`).

> **Por qué hace falta algo fuera.** Todo este stack corre *dentro* de la VPS:
> si la VPS muere, el monitoreo muere con ella y no te enteras. Por eso
> Prometheus emite una alerta `Watchdog` que está **siempre** disparada;
> Alertmanager la manda cada minuto aquí, y Healthchecks te avisa cuando esos
> pings **dejan** de llegar.

## Paso 4: revisar qué vas a desplegar

Dos ficheros merecen un vistazo antes del primer deploy:

- **`prometheus/alerts.yml`** — los umbrales. Vienen conservadores a propósito:
  una alerta que salta cada semana se acaba silenciando, y una alerta silenciada
  es peor que ninguna alerta. Ver [Alertas](#alertas-incluidas).
- **`config/deploy.yml`** — las versiones de las imágenes, fijadas a propósito,
  y los volúmenes. Si ya tenías un stack parecido, aquí es donde apuntas a tus
  volúmenes existentes para no perder el histórico.

Si tus contenedores **no** los gestiona Kamal, mira
[Por qué `unit`](#por-qué-unit-y-no-el-nombre-del-contenedor): sin las etiquetas
`service`/`role` de Kamal, `unit` cae al nombre del contenedor, que es lo
razonable para un stack de Compose.

## Paso 5: configurar GitHub

Cinco secrets y tres variables. Con la CLI, desde el repo:

```bash
# Secrets
gh secret set DEPLOY_SSH_KEY < ~/.ssh/vps_monitoring_deploy
gh secret set GF_SECURITY_ADMIN_PASSWORD   # contraseña de admin de Grafana
gh secret set TELEGRAM_BOT_TOKEN           # paso 2
gh secret set TELEGRAM_CHAT_ID             # paso 2
gh secret set HEALTHCHECKS_PING_URL        # paso 3

# Variables (no son secretas, pero tampoco van en el repo)
gh variable set DEPLOY_HOST      --body "TU-IP"
gh variable set DOCKER_GID       --body "988"    # el número del paso 1
gh variable set GRAFANA_ROOT_URL --body "http://localhost:3000"
```

`GRAFANA_ROOT_URL` solo importa si vas a publicar Grafana por dominio
(paso 8). Mientras tanto, `http://localhost:3000` vale.

## Paso 6: desplegar

```bash
gh workflow run Deploy
gh run watch
```

El workflow **valida antes de tocar la máquina** (`promtool` para Prometheus y
sus reglas, `amtool` para Alertmanager renderizando el ERB), reinicia solo lo
afectado y comprueba que Prometheus quedó en pie. Un YAML malo aquí te dejaría
sin alertas, así que se valida primero.

**Comprueba que quedó vivo:**

```bash
ssh root@TU-IP 'docker ps --filter name=monitoring- --format "{{.Names}}\t{{.Status}}"'
```

Deben salir seis: `monitoring-prometheus`, `-alertmanager`, `-node-exporter`,
`-telegraf`, `-grafana`, `-uptime-kuma`.

**Comprueba que la cadena de alertas llega de verdad.** Esto no es opcional: un
monitoreo que no has visto avisar no es un monitoreo. Levanta un contenedor de
mentira y párale:

```bash
ssh root@TU-IP
docker run -d --name alerta-de-prueba --label service=alerta-de-prueba alpine sleep 3600
sleep 120 && docker rm -f alerta-de-prueba
```

En unos 6 minutos debe llegarte un Telegram con `UnitHasNoContainer`. Si no
llega, mira los logs: `docker logs monitoring-alertmanager | tail -30`.

Y en Healthchecks, el check debe estar en verde en un par de minutos.

## Paso 7: configurar Uptime Kuma

**Éste es el paso que más se salta la gente**, y sin él Kuma no avisa de nada.

Kuma no tiene fichero de configuración: todo vive en su SQLite y solo se toca
por la interfaz. Abre un túnel:

```bash
ssh -L 3001:localhost:3001 root@TU-IP
```

### 7a. La notificación de Telegram

En http://localhost:3001 (la primera vez te pide crear usuario) → arriba a la
derecha → **Settings** → **Notifications** → **Setup Notification**:

- **Notification Type**: `Telegram`
- **Bot Token** y **Chat ID**: los mismos del paso 2
- ✅ **Default enabled**
- ✅ **Apply on all existing monitors** ← **sin esta, la notificación queda
  creada pero sin enlazar a ningún monitor, y no se entera nadie**
- **Test**, y si llega el mensaje, **Save**

Verifica que quedó **enlazada**, no solo creada:

```bash
ssh root@TU-IP 'docker exec monitoring-uptime-kuma sqlite3 /app/data/kuma.db \
  "SELECT m.name, n.name FROM monitor m
     JOIN monitor_notification mn ON mn.monitor_id = m.id
     JOIN notification n ON n.id = mn.notification_id;"'
```

Tiene que salir una fila por monitor. Vacío = te faltó la segunda casilla.

### 7b. Los monitores

Uno por servicio. Si usas Kamal, apunta a `kamal-proxy` con la cabecera `Host`:
así pruebas la app y el proxy sin depender de DNS ni de Cloudflare.

| Tipo de servicio | Monitor |
|---|---|
| Web (rol `web`) | HTTP(s) → `http://kamal-proxy/up`, header `{ "Host": "app.TU-DOMINIO" }`, *Retries* 2 |
| Base de datos | TCP Port → `app-db:5432` |
| Worker sin HTTP (rol `job`) | Push → Kuma te da una URL y un job recurrente la llama |

*Retries* 2 en los web: un deploy provoca un parpadeo de un segundo y no quieres
un aviso por cada despliegue.

Añade además un monitor externo gratuito (UptimeRobot) contra
`https://app.TU-DOMINIO/up`: ése sí prueba DNS, Cloudflare y el certificado
desde fuera.

## Paso 8: publicar por dominio (opcional)

Ver [Publicar por dominio](#publicar-por-dominio-opcional) más abajo. Mientras
no lo hagas, todo se mira por túnel SSH, que es perfectamente razonable.

---

# Uso diario

## Cómo se mira

Si no has hecho el paso 8, todo pasa por un túnel:

```bash
ssh -L 3000:localhost:3000 \
    -L 3001:localhost:3001 \
    -L 9090:localhost:9090 \
    -L 9093:localhost:9093 \
    root@TU-IP
```

| Qué | Dónde | Para qué |
|---|---|---|
| **Grafana** | http://localhost:3000 | Los dashboards. Usuario `admin`. |
| **Uptime Kuma** | http://localhost:3001 | Monitores y sus avisos. |
| **Prometheus** | http://localhost:9090 | Consultar métricas, ver qué reglas hay cargadas. |
| **Alertmanager** | http://localhost:9093 | Ver qué está disparado y silenciar. |

**Prometheus y Alertmanager no se publican nunca**: no tienen autenticación de
ningún tipo y enseñan la topología completa de la máquina. El túnel es su única
puerta, a propósito.

## Qué hay corriendo

Kamal nombra cada contenedor `<service>-<accessory>`, de ahí el prefijo
`monitoring-` en los targets de Prometheus, el datasource de Grafana y
`bin/expose.sh`.

| Contenedor | Puerto | Qué hace |
|---|---|---|
| `monitoring-prometheus` | 127.0.0.1:9090 | Guarda las métricas (30 días) y evalúa las alertas. |
| `monitoring-alertmanager` | 127.0.0.1:9093 | Agrupa, silencia y entrega a Telegram y a Healthchecks. |
| `monitoring-node-exporter` | — | Métricas de la máquina. |
| `monitoring-telegraf` | — | Métricas por contenedor, leyendo la API de Docker. |
| `monitoring-grafana` | 127.0.0.1:3000 | Los dashboards. |
| `monitoring-uptime-kuma` | 127.0.0.1:3001 | Comprobaciones activas desde dentro. |

## Los dashboards

Viven en `grafana/provisioning/dashboards/` y se cargan solos en cada deploy; no
hay que importar nada a mano. Están en la carpeta **VPS** de Grafana:

| Dashboard | Para qué |
|---|---|
| **VPS · Visión general** (`vps-overview`) | La de diario. Si todo está en verde, no hace falta mirar más. |
| **VPS · Contenedores** (`vps-containers`) | CPU, memoria, red, disco y reinicios de cada servicio. |
| **VPS · Host** (`vps-host`) | CPU por modo, memoria, uso de disco y E/S de la máquina. |

Para el host también va muy bien **Node Exporter Full** (ID `1860` en
grafana.com), importándolo a mano. No está versionado aquí a propósito: son
10.000 líneas de JSON que no mantenemos nosotros.

### Tocar un dashboard

Están provisionados con `allowUiUpdates: true`, así que puedes editarlos en la
interfaz para probar. Pero **el fichero manda**: en el siguiente deploy Grafana
recarga el JSON del repo y se pierde lo que no hayas guardado ahí.

1. Edita en la interfaz hasta que quede bien.
2. *Export* → *Export as JSON* (sin "externally shared").
3. Pega el JSON en el fichero, subiendo `version` en 1.
4. Commit y push.

## Alertas incluidas

Las reglas están en `prometheus/alerts.yml`.

| Alerta | Salta cuando | Tarda |
|---|---|---|
| `Watchdog` | siempre (va a Healthchecks, no a ti) | — |
| `HostDown` | node-exporter deja de responder | 2 min |
| `HostHighCPU` | CPU > 85% | 15 min |
| `HostHighMemory` | RAM > 90% | 10 min |
| `HostDiskFillingUp` | disco > 85% | 10 min |
| `HostDiskWillFillIn24h` | `predict_linear` sobre 6 h dice que se llena | 1 h |
| `HostSwapping` | swap > 50% | 15 min |
| `UnitHasNoContainer` | una unidad se queda sin ningún contenedor | ~6 min |
| `ContainerRestartLoop` | más de 3 reinicios en 15 min | inmediata |
| `ContainerOOMKilled` | el kernel lo mató por memoria | inmediata |
| `ContainerHighMemory` | > 90% de su límite de memoria | 10 min |
| `ContainerHighCPU` | > 90% de un núcleo, sostenido | 20 min |
| `TargetDown` | un target de aplicación deja de responder | 5 min |

Los ~6 minutos de `UnitHasNoContainer` no son un descuido: son 5 del *lookback
delta* de Prometheus (una serie sigue siendo consultable 5 minutos tras su
última muestra) más 1 del `for`. Lo que detecta una caída web en menos de un
minuto es Uptime Kuma; esta alerta es la red de seguridad para lo que no se
puede comprobar por HTTP, como un worker.

---

# Cambiar algo

## Automático

Un push a `main` que toque `prometheus/`, `alertmanager/`, `telegraf/`,
`grafana/` o `config/deploy.yml` dispara `.github/workflows/deploy.yml`, que:

1. **Valida antes de tocar nada**, con `promtool` y `amtool`.
2. **Reinicia solo los accessories afectados.** Cada reinicio es un hueco en las
   métricas; no hay motivo para reiniciar Prometheus porque cambió un dashboard.
3. **Comprueba que Prometheus quedó en pie.**

Un cambio solo en el README no despliega nada. Un cambio en `config/deploy.yml`
reinicia todo, porque puede afectar a cualquiera.

## A mano

```bash
export DEPLOY_HOST=TU-IP  DOCKER_GID=988  GRAFANA_ROOT_URL=http://localhost:3000
export KAMAL_REGISTRY_PASSWORD=...  GF_SECURITY_ADMIN_PASSWORD=...
export TELEGRAM_BOT_TOKEN=...  TELEGRAM_CHAT_ID=...  HEALTHCHECKS_PING_URL=...

kamal accessory reboot prometheus     # uno
kamal accessory reboot all            # todos
kamal accessory logs prometheus -f
```

`reboot` vuelve a subir los ficheros **y** recrea el contenedor. Eso es justo lo
que con Docker Compose era una trampa: `docker compose up -d` solo recrea un
contenedor cuando cambia su *definición*, así que un cambio en un fichero
montado parecía aplicado sin estarlo.

## Comprobar que el cambio entró

```bash
# Las reglas que Prometheus tiene REALMENTE cargadas
curl -s localhost:9090/api/v1/rules | grep -o '"name":"[A-Za-z]*"' | sort -u

# Los valores de la etiqueta derivada de las de Kamal
curl -s localhost:9090/api/v1/label/unit/values

# Qué hay disparado ahora
curl -s localhost:9093/api/v2/alerts | jq '.[].labels'

# Validar la config de Prometheus sin recargar
docker exec monitoring-prometheus \
  promtool check config /etc/prometheus/prometheus.yml
```

## Añadir un servicio nuevo

1. **Recursos del contenedor**: nada que hacer. Telegraf lo detecta solo.
2. **Uptime**: añade un monitor en Uptime Kuma (paso 7b).
3. **Métricas de aplicación** (si expone `/metrics`): descomenta un bloque en
   `prometheus/prometheus.yml`, conecta el contenedor a la red `kamal` y
   `kamal accessory reboot prometheus`.

---

# Publicar por dominio (opcional)

Grafana en `metrics.TU-DOMINIO` y Uptime Kuma en `status.TU-DOMINIO`, por el
mismo `kamal-proxy` que ya atiende tus apps. No hace falta otro proxy ni abrir
puertos nuevos.

Dos subdominios y no una subruta porque **Uptime Kuma no soporta correr bajo un
path**: rompe el WebSocket del panel.

## 1. En Cloudflare

**Origin Certificate** — SSL/TLS → Origin Server → Create Certificate. Deja la
clave privada RSA, cubre `*.TU-DOMINIO` y `TU-DOMINIO`, y copia las dos partes.

**Modo SSL** — SSL/TLS → Overview → **Full (strict)**.

**DNS** — dos registros A a la IP de la VPS, ambos con la **nube naranja**:

| Tipo | Nombre | Contenido | Proxy |
|---|---|---|---|
| A | `metrics` | la IP de la VPS | 🟠 Proxied |
| A | `status` | la IP de la VPS | 🟠 Proxied |

**Cloudflare Access** — Zero Trust → Access → Applications → Add a self-hosted
application, una por hostname. Como política, *Allow* con tu email. El plan
gratuito cubre hasta 50 usuarios.

## 2. En la VPS

```bash
sudo mkdir -p /var/lib/docker/volumes/kamal-proxy-config/_data/origin
cd /var/lib/docker/volumes/kamal-proxy-config/_data/origin
sudo nano cert.pem   # pega el Origin Certificate
sudo nano key.pem    # pega la Private Key
```

Y publica ambos (los hostnames no están dentro del script a propósito):

```bash
GRAFANA_HOST=metrics.TU-DOMINIO KUMA_HOST=status.TU-DOMINIO ./bin/expose.sh
```

Actualiza la variable para que los enlaces que genera Grafana salgan bien:

```bash
gh variable set GRAFANA_ROOT_URL --body "https://metrics.TU-DOMINIO"
gh workflow run Deploy
```

## 3. Cerrar el origen

Con los registros en naranja, **restringe 80/443 a los rangos de Cloudflare**.
Esto es lo que hace irrelevante que alguien descubra la IP de tu VPS:

```bash
for ip in $(curl -s https://www.cloudflare.com/ips-v4); do
  ufw allow from "$ip" to any port 80,443 proto tcp
done
ufw delete allow 80/tcp
ufw delete allow 443/tcp
```

> Hazlo **después** de comprobar que el proxy naranja funciona, o te quedas
> fuera de tus propias webs.

## 4. Comprobar

```bash
curl -sI https://metrics.TU-DOMINIO | head -1   # 302 a Cloudflare Access
curl -sI https://status.TU-DOMINIO  | head -1
docker exec kamal-proxy kamal-proxy list
```

Las rutas viven en `kamal-proxy.state`, dentro del volumen
`kamal-proxy-config`, así que sobreviven a reinicios del proxy y a los
despliegues de tus apps.

---

# Decisiones de fondo

## Por qué `unit` y no el nombre del contenedor

Kamal nombra los contenedores `<servicio>-<rol>-<sha-de-git>`, así que el nombre
cambia en **cada** deploy. Un dashboard o una alerta que se apoye en él se rompe
cada vez que despliegas.

Lo que no cambia son las etiquetas: Kamal marca cada contenedor con
`service=<servicio>` y `role=<web|job>`. `prometheus.yml` las combina en una
etiqueta `unit`, y todo lo demás se apoya en ella:

| Contenedor | Etiquetas de Kamal | `unit` |
|---|---|---|
| `app-web-4fbed717…` | `service=app`, `role=web` | `app-web` |
| `app-job-4fbed717…` | `service=app`, `role=job` | `app-job` |
| `app-db` (accesorio) | `service=app-db` | `app-db` |
| `kamal-proxy` | (ninguna) | `kamal-proxy` |

Durante un deploy el contenedor viejo y el nuevo conviven y ambos llevan
`unit="app-web"`, así que `UnitHasNoContainer` no salta al desplegar: solo salta
si la unidad se queda sin **ningún** contenedor. El efecto secundario es que
durante esos segundos los paneles suman los dos.

Si no usas Kamal, la última regla de relabeling deja `unit` igual al nombre del
contenedor, que para Compose es lo correcto.

## Por qué Telegraf y no cAdvisor

cAdvisor es la opción habitual para métricas por contenedor, y **no funciona en
Docker 29**. Lee la base de capas en disco, en
`/var/lib/docker/image/<driver>/layerdb/`, y el image store de containerd que
Docker 29 trae por defecto eliminó esa estructura. Falla al crear *cada*
contenedor:

```
failed to identify the read-write layer ID for container "a0ba6081..."
open /rootfs/var/lib/docker/image/overlayfs/layerdb/mounts/.../mount-id:
  no such file or directory
```

El resultado es silencioso y engañoso: arranca, responde, Prometheus lo scrapea
con `health="up"`, y solo exporta el cgroup raíz. Dashboards vacíos, alertas que
nunca saltan, y ningún error salvo en sus propios logs. Probado con v0.49.1 y
v0.52.1; ni `--disable_metrics=disk` ni `--docker_only=false` lo salvan.

Telegraf lee la **API de Docker**, indiferente al storage driver, y de paso
hereda las etiquetas `service` y `role` de Kamal.

## Por qué Kamal accessories y no Docker Compose

Para desplegar el monitoreo igual que las apps, con push-to-deploy, y para
evitar la trampa del `docker compose up -d` descrita arriba. El coste: Kamal
pasa `cmd` por bash, así que los argumentos con paréntesis o `$` hay que
entrecomillarlos (ver el regex de node-exporter en `config/deploy.yml`).

## Por qué un Origin Certificate y no Let's Encrypt

Grafana y Kuma son paneles de administración. Publicarlos con ACME obliga a
dejar el DNS en **gris** (DNS-only), porque el reto HTTP-01 no atraviesa la nube
naranja — y en gris Cloudflare no puede filtrar nada: la única defensa sería el
login de cada aplicación.

Con un **Origin Certificate** el registro va en **naranja**, y entonces
**Cloudflare Access** se pone delante: nadie llega siquiera a la pantalla de
login sin autenticarse antes. El resto de tus servicios sigue con Let's Encrypt
y nube gris; esto solo aplica a estos dos hostnames.

---

# Lo que este stack no ve

Ninguna de estas es un fallo que se detecte mirando un dashboard, así que
conviene tenerlas escritas:

- **La red del host.** node-exporter corre en la red de Kamal, no en la del
  host, y `/proc/net` es específico del namespace de red: las series
  `node_network_*` son las de **su propio contenedor**. Por eso el dashboard de
  Host no tiene panel de red; el tráfico real de las apps sí se ve, por
  contenedor, en el de Contenedores. Arreglarlo pide `network: host` en el
  accessory más una regla de firewall para que Prometheus lo siga alcanzando.
- **El límite de memoria de los contenedores.** Sin `memory` en Kamal, Docker
  reporta como límite la RAM total de la máquina, así que
  `docker_container_mem_usage_percent` compara contra el total del host. Sigue
  siendo la cifra útil en una VPS pequeña, pero no es "el % de su límite".
- **Los logs.** No hay agregación. Para eso, `kamal accessory logs` y
  `docker logs`.
- **La configuración de Uptime Kuma.** No se puede versionar: vive en su SQLite.
  Si pierdes el volumen `monitoring_uptime_kuma_data`, los monitores y las
  notificaciones se dan de alta otra vez a mano.
