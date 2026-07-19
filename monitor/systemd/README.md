# Execução recorrente via systemd (M5)

O monitor deve rodar no **host**, fora do Docker, para continuar funcionando
mesmo quando o Docker travar.

## Instalação

As unidades fazem parte do instalador principal. Não as copie manualmente:

```bash
sudo ./instalar.sh
```

Em instalações existentes, escolha **Atualizar**. O mesmo fluxo instala ou
atualiza as units, executa `daemon-reload` e preserva configuração e estado.

## Verificação

```bash
systemctl status vpsguardian-monitor.timer
systemctl list-timers vpsguardian-monitor.timer
journalctl -u vpsguardian-monitor.service --since "10 min ago"
```

Os alertas são enviados pelo webhook Discord já configurado em
`config/backup-destinations.conf` (variável `WEBHOOK_URL`). Ajuste apenas os
thresholds e flags em `config/monitor.conf`; não duplique o webhook.

## Teste manual do canal

```bash
vps-guardian monitor test-alert
```
