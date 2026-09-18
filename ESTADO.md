# Estado — Monitoreo VPS

Última actualización: 2026-09-18

> **Repo privado.** `origin` es `duvanherfi/vps-monitoring-private` y aquí sí
> van la IP, los dominios y el mapa de qué servicio corre en cada host.
> `upstream` es la plantilla pública `duvanherfi/vps-monitoring`, que no
> contiene ningún dato real; las mejoras se traen con `git pull upstream main`.

## Contexto

VPS 94.103.167.220 (Ubuntu 24.04, 2 vCPU, 7.8 GB RAM, disco al 41%).
Servicios desplegados con Kamal 2.12 detrás de un `kamal-proxy` compartido:

| Servicio | `service:` | Contenedores | Host | Repo |
|---|---|---|---|---|
| larifaco | `app` | `app-web`, `app-job`, `app-db` | larifaco.com | `duvanherfi/larifa` |
| carrusel-studio | `carrusel-studio` | `…-web`, `…-db` | feed.duvanh.dev | `duvanherfi/feed` |
| andycreativa | `andycreativa` | — (sin desplegar) | andycreativa.com | repo vacío |

Ambos repos desplegados ya tienen push-to-deploy con GitHub Actions y funciona.

## Hecho

- [x] Stack desplegado y corriendo: prometheus, alertmanager, node-exporter,
      telegraf, grafana, uptime-kuma.
- [x] Telegram y Healthchecks.io configurados **en Alertmanager**.
- [x] **Cadena de alertas de Prometheus verificada de extremo a extremo**:
      parar un contenedor dispara `UnitHasNoContainer` y Alertmanager lo
      entrega a Telegram.
- [x] Etiqueta `unit` derivada de las etiquetas `service`/`role` que Kamal pone
      en sus contenedores. 12 unidades, estables entre deploys.
- [x] Grafana conectado a la red `kamal`; `kamal-proxy` alcanza Grafana y Kuma
      con HTTP 200. `GF_SERVER_ROOT_URL=https://metrics.duvanh.dev`.
- [x] `bin/expose.sh` listo para registrar ambos en kamal-proxy.
- [x] **Migrado de Docker Compose a Kamal accessories** con push-to-deploy.
      Contenedores ahora `monitoring-*`; los volúmenes se conservaron, así que
      no se perdió histórico, dashboards ni monitores de Kuma.
- [x] **Deploy automático funcionando y probado**. Clave SSH dedicada
      `vps_monitoring_deploy`, autorizada para `deploy@`. No se reutilizó
      ninguna clave existente: `id_ed25519` entra como root y no debe estar en
      un secret.
- [x] Secretos de Alertmanager movidos a `alertmanager.yml.erb`, renderizado
      desde el entorno en cada despliegue.
- [x] **4 monitores dados de alta en Uptime Kuma** y los cuatro en verde:
      `La Rifa` y `feed` (HTTP contra `kamal-proxy` con cabecera `Host`), y dos
      TCP contra `app-db:5432` y `carrusel-studio-db:5432`.
- [x] **Tres dashboards versionados** en `grafana/provisioning/dashboards/`:
      `overview.json`, `containers.json`, `host.json`. Se cargan solos en cada
      deploy; todas sus consultas verificadas contra el Prometheus real.
- [x] **Telegraf: red y disco por contenedor recuperados.** Estaba con
      `perdevice=false` **y** `total=false`, que no deja ni una serie
      `docker_container_net_*` ni `_blkio_*`. Ahora `total=true`.
- [x] **Telegraf: `container_id` eliminado de verdad.** El `tagexclude` que
      había no hacía nada porque `container_id` es un *campo*, no un tag (y
      `prometheus_client` con `metric_version=2` convierte los campos de texto
      en etiquetas). Ahora es `fieldexclude`. De paso se quita
      `container_version`, que para las apps de Kamal es el SHA de git.
- [x] **README reescrito.** Tenía instrucciones de `docker compose` que ya no
      valen desde la migración a Kamal, y no explicaba lo básico: cómo entrar,
      qué hay corriendo, dónde están los dashboards, ni que Kuma y Alertmanager
      son dos sistemas de aviso independientes.

- [x] **IP y dominios fuera del repo público.** `GRAFANA_ROOT_URL` pasa a ser
      variable de GitHub, `bin/expose.sh` exige `GRAFANA_HOST`/`KUMA_HOST` por
      entorno, y el README usa marcadores. Historial reescrito con
      `git filter-repo` y force push: los 14 commits viejos ya no contienen ni
      la IP ni `duvanh.dev`. Barrido previo del historial: **no había ningún
      secreto** (ni token de Telegram, ni URL de Healthchecks real, ni claves),
      así que no hay nada que rotar.

- [x] **Separado en dos repos.** El público `duvanherfi/vps-monitoring` es la
      plantilla: paso a paso de instalación, cero datos reales, y el job de
      deploy se salta solo porque no tiene `DEPLOY_HOST` (verificado: `validate`
      en verde, `deploy` skipped). El privado
      `duvanherfi/vps-monitoring-private` es el que despliega: tiene los 5
      secrets, las 3 variables y esta bitácora. Deploy desde el privado probado
      y en verde. Los secrets y variables se borraron del público.
- [x] **`/root/monitoring` borrado del VPS.** Antes comprobé que sus dos
      ficheros con secretos (`.env` y el `alertmanager.yml` escrito a mano)
      tenían exactamente los mismos valores que ya estaban desplegados desde los
      secrets de GitHub, así que no se perdió nada.

## Falta

- [ ] **Uptime Kuma no tiene ninguna notificación configurada.** Es la causa de
      que no llegue nada a Telegram: Kuma no habla con Alertmanager, tiene su
      propio sistema, y su tabla `notification` está vacía. Se da de alta a
      mano en la interfaz — pasos exactos en el README, sección *Dar de alta
      Telegram en Uptime Kuma*. Las dos casillas que hay que marcar son
      **Default enabled** y **Apply on all existing monitors**.
- [ ] **Pedir a GitHub Support el GC de los commits huérfanos.** Tras el force
      push, el commit viejo `190c753` sigue accesible por su SHA en
      github.com/duvanherfi/vps-monitoring hasta que GitHub recoja la basura.
      El repo tiene 0 forks, así que hay que conocer el SHA para llegar, pero
      el borrado definitivo se pide por soporte.
- [ ] **Restringir 80/443 a los rangos de Cloudflare en ufw**, cuando los
      registros estén en naranja. Es lo que de verdad hace irrelevante que se
      conozca la IP de origen; ahora mismo ufw deja 80/443 abiertos a todo
      internet.
- [ ] **Cloudflare** (manual, no tengo token): Origin Certificate, registros A
      `metrics` y `status` en naranja, SSL en Full (strict), y dos aplicaciones
      de Cloudflare Access. Luego `./bin/expose.sh` en el VPS.
- [ ] Monitor **Push** en Kuma para `app-job`, que no tiene HTTP.
- [ ] Primer push de `andycreativa` (los workflows ya están escritos en local).
- [ ] Probar un `kamal deploy` de una app y confirmar que no llega ninguna
      alerta.
- [ ] **Métricas de red del host, mal.** node-exporter corre en la red `kamal`,
      y `/proc/net` es específico del namespace de red: las series
      `node_network_*` son las de su propio contenedor, no las de la máquina.
      Por eso el dashboard de Host no lleva panel de red. Arreglarlo pide
      `network: host` en el accessory (Kamal lo soporta: `accessory.network`)
      más una regla de ufw para que Prometheus lo siga alcanzando, porque al
      salir de la red `kamal` deja de resolver por nombre.

## Decisiones y por qué

- **Dos repos, no uno.** El público es la plantilla y el privado despliega. La
  única diferencia intencionada entre ambos es la línea de `ESTADO.md` en el
  `.gitignore`, para que `git pull upstream main` no dé conflictos. Todo lo
  específico de esta máquina (IP, dominios, secretos) vive en variables y
  secrets de GitHub, no en ficheros, así que el código de los dos es idéntico.

- **Telegraf, no cAdvisor.** cAdvisor está roto en Docker 29: lee
  `/var/lib/docker/image/<driver>/layerdb/`, que el image store de containerd
  eliminó. Falla en cada contenedor y solo exporta el cgroup raíz — en silencio,
  con `health="up"` en Prometheus. Reproducido en v0.49.1 y v0.52.1.
- **`unit` desde las etiquetas de Kamal**, no recortando el SHA del nombre con
  un regex. Kamal ya pone `service` y `role`; son estables y no hay que parsear.
- **En Telegraf, `perdevice`/`total` deprecados a propósito.** Telegraf avisa de
  que hay que migrar a `perdevice_include`/`total_include` antes de 1.35, pero
  en 1.32.3 las opciones nuevas no suprimen nada: ni `perdevice_include = []`
  ni `["cpu"]` evitan el desglose por interfaz y por dispositivo. Solo funciona
  el par viejo. Hay que revisarlo al subir la imagen.
- **Detección de caída ~6 min** (5 de lookback delta de Prometheus + `for: 1m`).
  Uptime Kuma es lo que detecta un servicio web en menos de un minuto; esta
  alerta es la red de seguridad para lo que no se puede comprobar por HTTP.
- **Kamal accessories, no Compose.** Elegido para desplegar el stack igual que
  las apps. De paso resuelve algo que con Compose era una trampa: `docker
  compose up -d` no aplica cambios en ficheros montados (solo recrea si cambia
  la *definición* del contenedor), mientras que `kamal accessory reboot`
  re-sube los ficheros y recrea. Coste: `cmd` pasa por bash, así que los
  argumentos con paréntesis o `$` hay que entrecomillarlos.
- **Los dashboards no usan el uid del datasource.** Cada uno declara una
  variable de tipo `datasource`, así que siguen funcionando si se rehace el
  volumen de Grafana y el datasource provisionado sale con otro uid.
- **Origin Certificate en vez de Let's Encrypt** para metrics/status: ACME exige
  nube gris, y en gris Cloudflare no puede filtrar. Con Origin Cert los
  registros van en naranja y Cloudflare Access se pone delante.
- **Una clave SSH por repositorio.** Si se filtra la de un repo, se rota solo
  esa y los despliegues de los demás siguen intactos.
- **`.kamal/secrets` se commitea** (convención de Kamal): solo tiene
  indirecciones `VAR=$VAR`. Ignorarlo rompe el deploy con "no secret files
  provided".
- **`ssh-keyscan` sin `-H` en CI.** Kamal usa Net::SSH, que no resuelve las
  entradas hasheadas de known_hosts y falla con HostKeyMismatch. OpenSSH sí
  las entiende, así que a mano no se reproduce.
- **Prometheus y Alertmanager nunca se exponen.** Sin autenticación de ningún
  tipo. Solo túnel SSH.
