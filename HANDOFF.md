# Handoff: FreeScout Docker deploy

## Objectiu
Script per desplegar automàticament FreeScout a Ubuntu a partir de la imatge
[nfrastack/container-freescout](https://github.com/nfrastack/container-freescout):
- Comprova si hi ha Docker i, si no, l'instal·la (repo oficial + plugin Compose).
- Actualitzable.
- Demana durant l'execució el **token de Cloudflare** i el **nom de domini** per a HTTPS.

## Què està fet
- `deploy-freescout.sh`: script complet (bash, Ubuntu/Debian, root).
  - Instal·la Docker/Compose si falten.
  - Pregunta domini, token Cloudflare (`Zone:DNS:Edit` + `Zone:Zone:Read`) i email ACME.
  - Genera `/opt/freescout/.env` (chmod 600) i `docker-compose.yml`.
  - Serveis: Traefik v3 (Let's Encrypt via Cloudflare DNS-01), `docker.io/nfrastack/freescout`, `mariadb:lts` amb healthcheck.
  - Secrets (DB i admin) generats aleatòriament i conservats en re-execucions.
  - Opcions: (sense res) instal·la/re-executa, `--update`, `--reconfigure`, `--status`.
- `README.md` curt, `.gitattributes` (`*.sh` amb LF; imprescindible, CRLF trenca l'script a Linux).
- Repo git local a `main` amb 2 commits (autor local: Jan <jan.torras.g@pm.me>).

## Què queda
1. **Provar l'script en un Ubuntu real**: no s'ha executat mai (s'ha escrit des de Windows). Punts a vigilar:
   - Que el login de FreeScout no redirigeixi a HTTP darrere de Traefik. Si ho fa, revisar
     `FREESCOUT_APP_PROXY`, `FREESCOUT_APP_TRUSTED_PROXIES`, `FREESCOUT_APP_FORCE_HTTPS` (deduïdes del README de la imatge, no verificades).
   - Que el label `traefik.docker.network=freescout_freescout` coincideixi amb el nom real de la xarxa (projecte `freescout`, xarxa `freescout`).
   - Que el healthcheck de MariaDB (`healthcheck.sh`) existeixi a `mariadb:lts`.
2. **Crear el repo públic a GitHub i pujar-lo** (no s'ha pogut: no hi havia `gh` ni credencials).
   ```bash
   gh auth login
   gh repo create freescout-docker-deploy --public --source . --push
   ```
   o manualment: repo buit a github.com/new + `git remote add origin <url>` + `git push -u origin main`.
3. (Opcional) Actualització automàtica per cron: copiar l'script a `/opt/freescout/` i afegir
   `0 4 * * 0 root /opt/freescout/deploy-freescout.sh --update` a `/etc/cron.d/freescout-update`.
4. (Opcional) Fixar `FREESCOUT_TAG` a una versió concreta en lloc de `latest`.

## Requisits previs al servidor
- Registre DNS A del domini cap a la IP del servidor (a Cloudflare).
- Ports 80 i 443 oberts.
- Primera càrrega de FreeScout: 2-5 min.
