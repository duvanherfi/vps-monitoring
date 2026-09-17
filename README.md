# Monitoreo de la VPS

Stack de monitoreo para una VPS con servicios en Docker Compose. Cubre tres
preguntas distintas, que conviene no mezclar:

| Pregunta | Herramienta |
|---|---|
| ¿Cómo va el host? (CPU, RAM, disco, red) | node_exporter → Prometheus → Grafana |
| ¿Cómo va cada servicio? (recursos por contenedor) | Telegraf (API de Docker) → Prometheus → Grafana |
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

## Despliegue

El stack se despliega con **Kamal**, igual que las apps del host, pero como
`accessories`: aquí no se construye ninguna imagen, son seis imágenes públicas
más ficheros de configuración. `service` e `image` existen en `config/deploy.yml`
porque Kamal los exige; el rol primario nunca se despliega.

Kamal nombra los contenedores `<service>-<accessory>`, de ahí `monitoring-*` en
los targets de Prometheus, en el datasource de Grafana y en `bin/expose.sh`.

### Automático

Un push a `main` que toque `prometheus/`, `alertmanager/`, `telegraf/`,
`grafana/` o `config/deploy.yml` dispara `.github/workflows/deploy.yml`, que:

1. Valida la config y las reglas con `promtool`, y la de Alertmanager con
   `amtool` renderizando antes el ERB. Un YAML malo deja a Prometheus sin
   arrancar y contigo sin alertas, así que se valida **antes** de tocar nada.
2. Reinicia **solo** los accessories afectados. Cada reinicio es un hueco en
   las métricas; no hay motivo para reiniciar Prometheus porque cambió el
   datasource de Grafana.
3. Comprueba que Prometheus quedó respondiendo.

Un cambio solo en el README no despliega nada.

### A mano

```bash
export DEPLOY_HOST=<ip>  DOCKER_GID=988
export KAMAL_REGISTRY_PASSWORD=...  GF_SECURITY_ADMIN_PASSWORD=...
export TELEGRAM_BOT_TOKEN=...  TELEGRAM_CHAT_ID=...  HEALTHCHECKS_PING_URL=...

kamal accessory reboot prometheus     # uno
kamal accessory reboot all            # todos
kamal accessory logs prometheus -f
```

`reboot` vuelve a subir los ficheros y recrea el contenedor, así que aplica los
cambios de configuración sin necesitar un `SIGHUP`.

### Lo que hace falta configurar en GitHub

**Secrets**: `DEPLOY_SSH_KEY` (clave privada de un usuario `deploy` del VPS),
`GF_SECURITY_ADMIN_PASSWORD`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`,
`HEALTHCHECKS_PING_URL`.

**Variables**: `DEPLOY_HOST` (la IP, para que no acabe en git) y `DOCKER_GID`
(`stat -c %g /var/run/docker.sock`).

Los secretos de Alertmanager ya no viven en un fichero ignorado por git dentro
del servidor: `alertmanager/alertmanager.yml.erb` se renderiza en cada
despliegue a partir del entorno.

## Por qué Telegraf y no cAdvisor

cAdvisor es la opción habitual para métricas por contenedor, y **no funciona en
Docker 29**. Lee la base de capas en disco, en
`/var/lib/docker/image/<driver>/layerdb/`, y el image store de containerd que
Docker 29 trae por defecto (storage driver `overlayfs`) eliminó esa estructura.
cAdvisor falla al crear *cada* contenedor:

```
failed to identify the read-write layer ID for container "a0ba6081..."
open /rootfs/var/lib/docker/image/overlayfs/layerdb/mounts/.../mount-id:
  no such file or directory
```

El resultado es silencioso y engañoso: cAdvisor arranca, responde, Prometheus
lo scrapea con `health="up"`, y solo exporta el cgroup raíz. Dashboards vacíos,
alertas que nunca saltan y ningún error salvo en sus propios logs. Probado con
v0.49.1 y v0.52.1; ni `--disable_metrics=disk` ni `--docker_only=false` lo
salvan.

Telegraf lee la **API de Docker**, que es indiferente al storage driver, y de
paso hereda las etiquetas `service` y `role` que Kamal pone en sus contenedores.

## Servicios desplegados con Kamal

Kamal nombra los contenedores `<servicio>-<rol>-<sha-de-git>`, así que el nombre
cambia en **cada** deploy. Eso rompe dos cosas si no se ajustan:

**1. Las alertas.** Kamal etiqueta cada contenedor que gestiona con
`service=<servicio>` y `role=<web|job>`, y esas etiquetas **no** cambian al
desplegar. `prometheus.yml` las combina en una etiqueta `unit`, y las alertas se
apoyan en ella, nunca en el nombre del contenedor:

| Contenedor | Etiquetas de Kamal | `unit` |
|---|---|---|
| `app-web-4fbed717…` | `service=app`, `role=web` | `app-web` |
| `app-job-4fbed717…` | `service=app`, `role=job` | `app-job` |
| `app-db` (accesorio) | `service=app-db` | `app-db` |
| `prometheus` | (ninguna) | `prometheus` |

Durante un deploy el contenedor viejo y el nuevo conviven y ambos llevan
`unit="app-web"`, así que `UnitHasNoContainer` no salta al desplegar. Solo salta
si la unidad se queda sin ningún contenedor.

**2. La red.** Las apps viven en la red `kamal` y el monitoreo en `monitoring`.
`uptime-kuma` está conectado a las dos para poder hablar con `kamal-proxy` y con
los contenedores por nombre, sin salir a internet y volver.

### Monitores de Uptime Kuma con Kamal

Para un rol `web`, apunta a `kamal-proxy` con la cabecera `Host`. Así pruebas la
app y el proxy sin depender de DNS ni de Cloudflare:

- **Monitor Type**: HTTP(s)
- **URL**: `http://kamal-proxy/up`
- **Headers**: `{ "Host": "app-a.TU-DOMINIO" }`
- **Retries**: 2 (un deploy provoca un parpadeo de un segundo)
- **Heartbeat Interval**: 60

Añade además un monitor externo gratuito (UptimeRobot) contra
`https://app-a.TU-DOMINIO/up`: ese sí prueba DNS, Cloudflare y el certificado.

Para un rol `job` (sin HTTP, como `app-job`), usa un monitor de tipo **Push**:
Uptime Kuma te da una URL y un job recurrente de Solid Queue la llama. Si el
worker se atasca, dejan de llegar pings y salta la alerta. Mientras tanto,
`ServiceHasNoContainer` ya cubre el caso de que el contenedor muera.

Para un accesorio de base de datos, un monitor **TCP Port** contra
`app-db:5432` desde la red `kamal`.

## Añadir el tercer servicio

1. **Métricas de contenedor**: nada que hacer. Telegraf lo detecta solo.
2. **Uptime**: añade un monitor en Uptime Kuma.
3. **Métricas de aplicación** (si expone `/metrics`): descomenta un bloque en
   `prometheus/prometheus.yml`, conecta el servicio a la red `monitoring` y
   recarga sin reiniciar:

```bash
docker compose exec prometheus kill -HUP 1
```

## Exponer por dominio (metrics + status)

Grafana en `metrics.TU-DOMINIO` y Uptime Kuma en `status.TU-DOMINIO`, sirviendo
por el mismo `kamal-proxy` que ya atiende las apps. No hace falta otro proxy ni
abrir puertos nuevos.

Dos subdominios y no una subruta porque **Uptime Kuma no soporta correr bajo un
path**: rompe el WebSocket del panel. Grafana sí lo haría, pero no compensa
partir la configuración.

### Por qué un Origin Certificate y no Let's Encrypt

Estos dos son paneles de administración. Publicarlos con ACME obliga a dejar el
DNS en **gris** (DNS-only), porque el reto HTTP-01 no atraviesa la nube naranja
— y en gris Cloudflare no puede filtrar nada: la única defensa sería el login de
cada aplicación.

Con un **Origin Certificate** de Cloudflare el registro puede ir en **naranja**,
y entonces **Cloudflare Access** se pone delante: nadie llega siquiera a la
pantalla de login sin autenticarse antes. Esa es la diferencia que justifica los
pasos extra.

El resto de tus servicios sigue con Let's Encrypt y nube gris; esto solo aplica
a estos dos hostnames.

### 1. En el panel de Cloudflare

**Origin Certificate** — SSL/TLS → Origin Server → Create Certificate. Deja la
clave privada RSA, cubre `*.TU-DOMINIO` y `TU-DOMINIO`, y copia las dos partes.

**Modo SSL** — SSL/TLS → Overview → **Full (strict)**.

**DNS** — dos registros A a la IP del VPS, ambos con la **nube naranja**:

| Tipo | Nombre | Contenido | Proxy |
|---|---|---|---|
| A | `metrics` | la IP del VPS | 🟠 Proxied |
| A | `status` | la IP del VPS | 🟠 Proxied |

**Cloudflare Access** — Zero Trust → Access → Applications → Add a
self-hosted application, una por hostname. Como política, *Allow* con tu email.
El plan gratuito cubre hasta 50 usuarios.

### 2. En el VPS

Deja el certificado donde `kamal-proxy` pueda leerlo:

```bash
sudo mkdir -p /var/lib/docker/volumes/kamal-proxy-config/_data/origin
cd /var/lib/docker/volumes/kamal-proxy-config/_data/origin
sudo nano cert.pem   # pega el Origin Certificate
sudo nano key.pem    # pega la Private Key
```

Apunta Grafana a su URL pública y engánchalo a la red de Kamal:

```bash
cd ~/monitoring
git pull
sed -i 's|^GRAFANA_ROOT_URL=.*|GRAFANA_ROOT_URL=https://metrics.TU-DOMINIO|' .env
docker compose up -d
```

Y publica ambos:

```bash
./bin/expose.sh
```

El script ajusta permisos (kamal-proxy corre sin privilegios y no puede leer
ficheros de root), registra las dos rutas y lista el resultado.

### Comprobar

```bash
curl -sI https://metrics.TU-DOMINIO | head -1   # 302 a Cloudflare Access
curl -sI https://status.TU-DOMINIO  | head -1
docker exec kamal-proxy kamal-proxy list
```

Las rutas viven en `kamal-proxy.state`, dentro del volumen `kamal-proxy-config`,
así que sobreviven a reinicios del proxy y a los despliegues de tus apps.

### Lo que NO se expone

Prometheus y Alertmanager siguen solo en `127.0.0.1`, y ahí se quedan: no tienen
autenticación de ningún tipo y revelan la topología completa de la máquina. Para
ellos, el túnel SSH:

```bash
ssh -L 9090:localhost:9090 -L 9093:localhost:9093 root@TU-IP
```

## Aplicar un cambio de configuración

`docker compose up -d` **no basta**. Compose solo recrea un contenedor cuando su
*definición* cambia; si lo único que cambió es el contenido de un fichero
montado, Prometheus y Alertmanager siguen corriendo con la copia que cargaron en
memoria al arrancar, y el cambio parece aplicado cuando no lo está.

```bash
git pull
docker compose up -d                       # solo si cambio docker-compose.yml
docker compose exec prometheus   kill -HUP 1   # recarga reglas y scrapes
docker compose exec alertmanager kill -HUP 1   # recarga rutas y receptores
```

Comprueba que la recarga surtió efecto antes de darla por buena:

```bash
# las reglas que Prometheus tiene REALMENTE cargadas
curl -s localhost:9090/api/v1/rules | grep -o '"name":"[A-Za-z]*"' | sort -u

# los valores de la etiqueta derivada de Kamal
curl -s localhost:9090/api/v1/label/service/values
```

## Operación

```bash
# Validar la config de Prometheus antes de recargar
docker compose exec prometheus promtool check config /etc/prometheus/prometheus.yml
# (aqui si funciona sin --entrypoint: exec no pasa por el ENTRYPOINT de la imagen)

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
