# Rollback
Every file LANSeal replaces is copied first to `/var/lib/lanseal/backups/<UTC timestamp>/<original path>` (clients: `*.bak.<timestamp>` beside the file).
- Gateway firewall locked you out: it auto-removes after 60 s unless you type `keep`; manually: `sudo nft delete table ip lanseal_gw; sudo systemctl disable lanseal-firewall`.
- Remove everything but keep the CA: `sudo ./server/uninstall.sh` (add `--purge` to destroy the CA and state).
- Client: `sudo ./clients/linux/firewall.sh --remove --overlay <overlay cidr>`; `sudo rm /etc/swanctl/conf.d/lanseal.conf; sudo swanctl --load-all`; `sudo systemctl disable --now lanseal-renew.timer`.
