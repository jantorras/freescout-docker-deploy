# FreeScout Docker deploy (Ubuntu)

Script per desplegar [FreeScout](https://freescout.net) amb la imatge
[nfrastack/container-freescout](https://github.com/nfrastack/container-freescout),
MariaDB i Traefik amb HTTPS automàtic (Let's Encrypt via Cloudflare DNS-01).

- Instal·la Docker i el plugin Compose si no hi són
- Demana domini, token de Cloudflare i email
- Idempotent i actualitzable

```bash
sudo ./deploy-freescout.sh               # instal·la / re-executa
sudo ./deploy-freescout.sh --update      # actualitza imatges
sudo ./deploy-freescout.sh --reconfigure # canvia domini/token
sudo ./deploy-freescout.sh --status
```

Token de Cloudflare: permisos `Zone:DNS:Edit` + `Zone:Zone:Read`.
Cal un registre DNS A del domini cap a la IP del servidor.
