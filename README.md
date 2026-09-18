# Monitoreo de la VPS

Seis contenedores que responden a cuatro preguntas distintas. La confusión más
cara de este stack es mezclarlas, así que van separadas desde el principio:

| Pregunta | Quién la responde |
|---|---|
| ¿Cómo va la máquina? (CPU, RAM, disco) | node-exporter → Prometheus → Grafana |
| ¿Cómo va cada servicio? (recursos por contenedor) | Telegraf (API de Docker) → Prometheus → Grafana |
| ¿Responde por HTTP? | Uptime Kuma |
| ¿Sigue viva la VPS entera? | Healthchecks.io, desde fuera |

Y dos sistemas de aviso **independientes**, que es la otra confusión cara:
Alertmanager avisa de lo que ve Prometheus, y Uptime Kuma avisa por su cuenta.
Ninguno de los dos sabe que el otro existe. Ver *[Las alertas van por dos
caminos](#las-alertas-van-por-dos-caminos)*.

Consumo aproximado: ~800 MB de RAM y ~2 GB de disco al mes con 30 días de
retención.

---

## Cómo se mira esto

Nada del stack está publicado todavía en internet (los pasos de Cloudflare
siguen pendientes). Hasta entonces, todo pasa por un túnel SSH:

```bash
ssh -L 3000:localhost:3000 \
    -L 3001:localhost:3001 \
    -L 9090:localhost:9090 \
    -L 9093:localhost:9093 \
    root@TU-IP
```

Con el túnel abierto:

| Qué | Dónde | Para qué |
|---|---|---|
| **Grafana** | http://localhost:3000 | Los dashboards. Usuario `admin`. |
| **Uptime Kuma** | http://localhost:3001 | Monitores HTTP/TCP y sus avisos. |
| **Prometheus** | http://localhost:9090 | Consultar métricas a mano, ver qué reglas hay cargadas. |
| **Alertmanager** | http://localhost:9093 | Ver qué está disparado y silenciar. |

Prometheus y Alertmanager **no se van a publicar nunca**: no tienen
autenticación de ningún tipo y enseñan la topología completa de la máquina.
El túnel es su única puerta, a propósito.

## Qué hay corriendo

Kamal nombra cada contenedor `<service>-<accessory>`, de ahí el prefijo
`monitoring-` en todas partes (targets de Prometheus, datasource de Grafana,
`bin/expose.sh`).

| Contenedor | Puerto | Qué hace |
|---|---|---|
| `monitoring-prometheus` | 127.0.0.1:9090 | Guarda las métricas (30 días) y evalúa las alertas. |
| `monitoring-alertmanager` | 127.0.0.1:9093 | Agrupa, silencia y entrega a Telegram y a Healthchecks. |
| `monitoring-node-exporter` | — | Métricas de la máquina. |
| `monitoring-telegraf` | — | Métricas por contenedor, leyendo la API de Docker. |
| `monitoring-grafana` | 127.0.0.1:3000 | Los dashboards. |
| `monitoring-uptime-kuma` | 127.0.0.1:3001 | Comprobaciones activas desde dentro. |

## Los dashboards

Viven en `grafana/provisioning/dashboards/` y se cargan solos en cada deploy;
no hay que importar nada a mano. Están en la carpeta **VPS** de Grafana:

| Dashboard | Para qué |
|---|---|
| **VPS · Visión general** (`vps-overview`) | La de diario. Si todo está en verde, no hace falta mirar más. |
| **VPS · Contenedores** (`vps-containers`) | CPU, memoria, red, disco y reinicios de cada servicio. |
| **VPS · Host** (`vps-host`) | CPU por modo, memoria, uso de disco y E/S de la máquina. |

Además hay un **Node Exporter Full** importado a mano desde grafana.com. Ése
no está versionado: si se borra el volumen, se vuelve a importar (ID `1860`).

Todo se agrupa por la etiqueta **`unit`**, no por nombre de contenedor. Eso es
deliberado y está explicado en *[Por qué `unit` y no el nombre del
contenedor](#por-qué-unit-y-no-el-nombre-del-contenedor)*.

### Tocar un dashboard

Los dashboards están provisionados con `allowUiUpdates: true`, así que se
pueden editar en la interfaz para probar. Pero **el fichero manda**: en el
siguiente deploy Grafana vuelve a cargar el JSON del repo y se pierde lo que
no se haya guardado ahí. El ciclo bueno es:

1. Editar en la interfaz hasta que quede bien.
2. Panel de dashboard → *Export* → *Export as JSON* (sin "externally shared").
3. Pegar el JSON en el fichero correspondiente, subiendo `version` en 1.
4. Commit y push. El deploy lo recarga.

---

## Las alertas van por dos caminos

Éste es el punto donde es fácil perder una hora. **Son dos sistemas separados
que no se hablan**, y cada uno necesita su propia configuración de Telegram:

```
Prometheus ──> Alertmanager ──> Telegram        (métricas: recursos, contenedores caídos)
                           └──> Healthchecks.io (el latido Watchdog)

Uptime Kuma ─────────────────> Telegram         (HTTP y TCP: ¿responde?)
```

**Alertmanager** se configura por fichero: `alertmanager/alertmanager.yml.erb`,
versionado en el repo, con el token saliendo del entorno en cada deploy.

**Uptime Kuma no tiene fichero de configuración.** Todo vive en su SQLite
(`/app/data/kuma.db`, dentro del volumen `monitoring_uptime_kuma_data`) y solo
se toca por la interfaz. Sus avisos **no** pasan por Alertmanager: si Kuma no
tiene una notificación propia dada de alta, un servicio se puede caer, Kuma
marcarlo en rojo, y no llegar absolutamente nada.

### Dar de alta Telegram en Uptime Kuma

Con el túnel abierto, en http://localhost:3001:

1. Arriba a la derecha → **Settings** → **Notifications** → **Setup
   Notification**.
2. **Notification Type**: `Telegram`.
3. **Friendly Name**: `Telegram`.
4. **Bot Token** y **Chat ID**: los mismos que usa Alertmanager. Son los
   secrets `TELEGRAM_BOT_TOKEN` y `TELEGRAM_CHAT_ID` del repo en GitHub; en el
   servidor se pueden leer del contenedor ya renderizado:

   ```bash
   docker exec monitoring-alertmanager \
     grep -E 'bot_token|chat_id' /etc/alertmanager/alertmanager.yml
   ```

5. Marca **las dos** casillas de abajo, que es donde se cae la mayoría:
   - **Default enabled** — las notificaciones que crees a partir de ahora la
     llevan puesta.
   - **Apply on all existing monitors** — se la pone a los que ya existen.
     Sin esto, la notificación queda creada pero sin enlazar a ningún monitor,
     y no se entera nadie.
6. **Test** antes de guardar. Debe llegar un mensaje al chat.
7. **Save**.

Para comprobar que quedó enlazada de verdad, y no solo creada:

```bash
docker exec monitoring-uptime-kuma sqlite3 /app/data/kuma.db \
  "SELECT m.name, n.name FROM monitor m
     JOIN monitor_notification mn ON mn.monitor_id = m.id
     JOIN notification n ON n.id = mn.notification_id;"
```

Tiene que salir una fila por cada monitor. Si la consulta no devuelve nada, la
notificación existe pero no está aplicada a ninguno.

### Monitores de Kuma con Kamal

Para un rol `web`, apunta a `kamal-proxy` con la cabecera `Host`. Así pruebas
la app y el proxy sin depender de DNS ni de Cloudflare:

- **Monitor Type**: HTTP(s)
- **URL**: `http://kamal-proxy/up`
- **Headers**: `{ "Host": "app-a.TU-DOMINIO" }`
- **Retries**: 2 (un deploy provoca un parpadeo de un segundo)
- **Heartbeat Interval**: 60

Para un accesorio de base de datos, un monitor **TCP Port** contra
`app-db:5432`.

Para un rol `job` (sin HTTP, como `app-job`), un monitor de tipo **Push**:
Kuma da una URL y un job recurrente de Solid Queue la llama. Si el worker se
atasca dejan de llegar pings y salta el aviso. Mientras tanto,
`UnitHasNoContainer` ya cubre el caso de que el contenedor se muera del todo.

Añade además un monitor externo gratuito (UptimeRobot) contra
`https://app-a.TU-DOMINIO/up`: ése sí prueba DNS, Cloudflare y el certificado.

### Por qué hace falta la capa externa

Todo lo de aquí corre *dentro* de la VPS. Si la VPS muere, el monitoreo muere
con ella y no te enteras. Por eso Prometheus emite una alerta `Watchdog` que
está **siempre** disparada; Alertmanager la manda cada minuto a
Healthchecks.io, y Healthchecks avisa cuando esos pings **dejan** de llegar.
Es el único componente que tiene que vivir fuera.

## Alertas definidas

Las reglas están en `prometheus/alerts.yml`. Los umbrales son conservadores a
propósito: una alerta que salta cada semana se acaba silenciando, y una alerta
silenciada es peor que ninguna alerta.

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
| `ContainerOOMKilled` | el kernel mató el contenedor por memoria | inmediata |
| `ContainerHighMemory` | > 90% de su límite de memoria | 10 min |
| `ContainerHighCPU` | > 90% de un núcleo, sostenido | 20 min |
| `TargetDown` | un target de aplicación deja de responder | 5 min |

Los ~6 minutos de `UnitHasNoContainer` no son un descuido: son 5 del *lookback
delta* de Prometheus (una serie sigue siendo consultable 5 minutos después de
su última muestra) más 1 del `for`. Lo que detecta una caída web en menos de un
minuto es Uptime Kuma; esta alerta es la red de seguridad para lo que no se
puede comprobar por HTTP.

---

## Cambiar algo

### Automático

Un push a `main` que toque `prometheus/`, `alertmanager/`, `telegraf/`,
`grafana/` o `config/deploy.yml` dispara `.github/workflows/deploy.yml`, que:

1. **Valida antes de tocar nada**: la config y las reglas con `promtool`, y la
   de Alertmanager con `amtool`, renderizando antes el ERB. Un YAML malo deja
   a Prometheus sin arrancar y a ti sin alertas.
2. **Reinicia solo los accessories afectados**. Cada reinicio es un hueco en
   las métricas; no hay motivo para reiniciar Prometheus porque cambió un
   dashboard de Grafana.
3. **Comprueba que Prometheus quedó en pie.**

Un cambio solo en el README no despliega nada. Un cambio en `config/deploy.yml`
reinicia todo, porque puede afectar a cualquiera.

### A mano

```bash
export DEPLOY_HOST=TU-IP  DOCKER_GID=988  GRAFANA_ROOT_URL=https://metrics.TU-DOMINIO
export KAMAL_REGISTRY_PASSWORD=...  GF_SECURITY_ADMIN_PASSWORD=...
export TELEGRAM_BOT_TOKEN=...  TELEGRAM_CHAT_ID=...  HEALTHCHECKS_PING_URL=...

kamal accessory reboot prometheus     # uno
kamal accessory reboot all            # todos
kamal accessory logs prometheus -f
```

`reboot` vuelve a subir los ficheros **y** recrea el contenedor. Eso es justo
lo que con Docker Compose era una trampa: `docker compose up -d` solo recrea un
contenedor cuando cambia su *definición*, así que un cambio en un fichero
montado parecía aplicado sin estarlo.

### Comprobar que el cambio entró

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

### Lo que hace falta en GitHub

**Secrets**: `DEPLOY_SSH_KEY` (clave privada del usuario `deploy` del VPS),
`GF_SECURITY_ADMIN_PASSWORD`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`,
`HEALTHCHECKS_PING_URL`.

**Variables**: `DEPLOY_HOST` (la IP), `DOCKER_GID`
(`stat -c %g /var/run/docker.sock`) y `GRAFANA_ROOT_URL` (la URL pública de
Grafana).

Nada de eso está en el repo a propósito: **esto es público**. La IP, los
dominios y los secretos entran por el entorno, y la bitácora de trabajo
(`ESTADO.md`, con la IP y qué servicio va en cada host) está en `.gitignore` y
vive solo en local.

### Añadir un servicio nuevo al monitoreo

1. **Recursos del contenedor**: nada que hacer. Telegraf lo detecta solo en
   cuanto arranca.
2. **Uptime**: añadir un monitor en Uptime Kuma (ver arriba).
3. **Métricas de aplicación** (si expone `/metrics`): descomentar un bloque en
   `prometheus/prometheus.yml`, conectar el contenedor a la red `kamal` y
   `kamal accessory reboot prometheus`.

---

## Decisiones de fondo

### Por qué `unit` y no el nombre del contenedor

Kamal nombra los contenedores `<servicio>-<rol>-<sha-de-git>`, así que el
nombre cambia en **cada** deploy. Un dashboard o una alerta que se apoye en él
se rompe cada vez que despliegas.

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
`unit="app-web"`, así que `UnitHasNoContainer` no salta al desplegar. Solo
salta si la unidad se queda sin **ningún** contenedor. (El efecto secundario
es que durante esos segundos los paneles suman los dos.)

### Por qué Telegraf y no cAdvisor

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

El resultado es silencioso y engañoso: arranca, responde, Prometheus lo
scrapea con `health="up"`, y solo exporta el cgroup raíz. Dashboards vacíos,
alertas que nunca saltan, y ningún error salvo en sus propios logs. Probado
con v0.49.1 y v0.52.1; ni `--disable_metrics=disk` ni `--docker_only=false` lo
salvan.

Telegraf lee la **API de Docker**, que es indiferente al storage driver, y de
paso hereda las etiquetas `service` y `role` de Kamal.

### Por qué Kamal accessories y no Docker Compose

Para desplegar el stack igual que las apps, con push-to-deploy, y para evitar
la trampa del `docker compose up -d` descrita arriba. El coste: Kamal pasa
`cmd` por bash, así que los argumentos con paréntesis o `$` hay que
entrecomillarlos (ver el regex de node-exporter en `config/deploy.yml`).

### Por qué un Origin Certificate y no Let's Encrypt

Grafana y Kuma son paneles de administración. Publicarlos con ACME obliga a
dejar el DNS en **gris** (DNS-only), porque el reto HTTP-01 no atraviesa la
nube naranja — y en gris Cloudflare no puede filtrar nada: la única defensa
sería el login de cada aplicación.

Con un **Origin Certificate** el registro va en **naranja**, y entonces
**Cloudflare Access** se pone delante: nadie llega siquiera a la pantalla de
login sin autenticarse antes. El resto de servicios sigue con Let's Encrypt y
nube gris; esto solo aplica a estos dos hostnames.

---

## Lo que este stack no ve

Ninguna de estas es un fallo que se pueda arreglar mirando un dashboard, así
que conviene tenerlas escritas:

- **La red del host.** node-exporter corre en la red `kamal`, no en la del
  host, y `/proc/net` es específico del namespace de red. Las series
  `node_network_*` son las de **su propio contenedor**, no las de la máquina.
  Por eso el dashboard de Host no tiene panel de red. El tráfico real de las
  apps sí se ve, por contenedor, en el dashboard de Contenedores. Arreglarlo
  pide `network: host` en el accessory más una regla de ufw para que
  Prometheus siga alcanzándolo.
- **El límite de memoria de los contenedores.** Sin `memory` en Kamal, Docker
  reporta como límite la RAM total de la máquina, así que
  `docker_container_mem_usage_percent` compara contra los 7.8 GB del host.
  Sigue siendo la cifra útil aquí, pero no es "el % de su límite".
- **Los logs.** No hay agregación de logs. Para eso, `kamal accessory logs` y
  `docker logs`.
- **La configuración de Uptime Kuma.** No se puede versionar: vive en su
  SQLite. Si se pierde el volumen `monitoring_uptime_kuma_data`, los monitores
  y las notificaciones se dan de alta otra vez a mano.

---

## Exponer por dominio (pendiente)

Grafana en `metrics.TU-DOMINIO` y Uptime Kuma en `status.TU-DOMINIO`, por el
mismo `kamal-proxy` que ya atiende las apps. No hace falta otro proxy ni abrir
puertos nuevos.

Dos subdominios y no una subruta porque **Uptime Kuma no soporta correr bajo
un path**: rompe el WebSocket del panel.

### 1. En el panel de Cloudflare

**Origin Certificate** — SSL/TLS → Origin Server → Create Certificate. Deja la
clave privada RSA, cubre `*.TU-DOMINIO` y `TU-DOMINIO`, y copia las dos partes.

**Modo SSL** — SSL/TLS → Overview → **Full (strict)**.

**DNS** — dos registros A a la IP del VPS, ambos con la **nube naranja**:

| Tipo | Nombre | Contenido | Proxy |
|---|---|---|---|
| A | `metrics` | la IP del VPS | 🟠 Proxied |
| A | `status` | la IP del VPS | 🟠 Proxied |

**Cloudflare Access** — Zero Trust → Access → Applications → Add a self-hosted
application, una por hostname. Como política, *Allow* con tu email. El plan
gratuito cubre hasta 50 usuarios.

### 2. En el VPS

Deja el certificado donde `kamal-proxy` pueda leerlo:

```bash
sudo mkdir -p /var/lib/docker/volumes/kamal-proxy-config/_data/origin
cd /var/lib/docker/volumes/kamal-proxy-config/_data/origin
sudo nano cert.pem   # pega el Origin Certificate
sudo nano key.pem    # pega la Private Key
```

Y publica ambos (los hostnames ya no están dentro del script):

```bash
GRAFANA_HOST=metrics.TU-DOMINIO KUMA_HOST=status.TU-DOMINIO ./bin/expose.sh
```

El script ajusta permisos (kamal-proxy corre sin privilegios y no puede leer
ficheros de root), registra las dos rutas y lista el resultado. Para que los
enlaces que genera Grafana salgan bien, la variable `GRAFANA_ROOT_URL` de
GitHub tiene que apuntar a `https://metrics.TU-DOMINIO`.

### 3. Comprobar

```bash
curl -sI https://metrics.TU-DOMINIO | head -1   # 302 a Cloudflare Access
curl -sI https://status.TU-DOMINIO  | head -1
docker exec kamal-proxy kamal-proxy list
```

Las rutas viven en `kamal-proxy.state`, dentro del volumen
`kamal-proxy-config`, así que sobreviven a reinicios del proxy y a los
despliegues de las apps.
