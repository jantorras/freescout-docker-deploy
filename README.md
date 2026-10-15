# FreeScout Docker deploy (Ubuntu)

Script per desplegar [FreeScout](https://freescout.net) amb la imatge
[nfrastack/container-freescout](https://github.com/nfrastack/container-freescout),
MariaDB, pensat per darrere d'un **túnel de Cloudflare** (l'HTTPS el posa Cloudflare).
FreeScout només escolta a `127.0.0.1:8080`, sense ocupar els ports 80/443.

- Instal·la Docker i el plugin Compose si no hi són
- Demana domini i email d'administrador
- Idempotent i actualitzable

```bash
sudo ./deploy-freescout.sh               # instal·la / re-executa
sudo ./deploy-freescout.sh --update      # actualitza imatges
sudo ./deploy-freescout.sh --reconfigure # canvia domini/email
sudo ./deploy-freescout.sh --status
```

Túnel: afegeix un Public Hostname al túnel amb el domini cap a `http://localhost:8080`.
(Si `cloudflared` corre en un contenidor, connecta'l a la xarxa `freescout` i apunta a `http://freescout-app:80`.)
