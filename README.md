# 🛡️ VPS Guardian

> Sistema completo de backup, manutenção e migração para Coolify + Docker

[![Bash](https://img.shields.io/badge/Bash-5.0+-green.svg)](https://www.gnu.org/software/bash/)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Status](https://img.shields.io/badge/Status-Testes%20automatizados-blue.svg)]()

## 🚀 Quick Start

```bash
# Clone no local correto (padrão Unix)
cd /usr/local/src
sudo git clone https://github.com/SEU-USUARIO/vpsguardian.git
cd vpsguardian

# Instale (o caminho é confirmado pelo instalador)
sudo ./instalar.sh
```

**Comando global instalado:** `vps-guardian`

> **📁 Por que `/usr/local/src`?** É o local padrão Unix para código-fonte de ferramentas locais. O instalador usa cópias por padrão (modo recomendado), ainda aceita symlinks por compatibilidade e registra o caminho real em `/etc/vpsguardian/install.conf`.

## ✨ Principais Recursos

- **Backup Completo:** DB + SSH keys + configs + volumes
- **Backup S3:** Upload automático para AWS, Backblaze, Wasabi, MinIO
- **Migração Automatizada:** Mover Coolify entre servidores em 15-30min
- **Retenção Inteligente:** Estratégias Simple, Count e GFS
- **Manutenção:** Limpeza automática de disco, logs e Docker
- **Firewall Interativo:** Perfis de segurança (Seguro/Híbrido/Básico)
- **Monitor Preventivo:** Host, Docker, containers e workers Laravel com alertas,
  correlação, histórico e pacotes de emergência

## 📦 Principais Scripts

### Backup
- `backup-coolify.sh` - Backup completo local
- `backup-destinos.sh` - Replicação para S3, Google Drive e SSH
- `backup-databases-dump-auto.sh` - Backup automatizado dos bancos
- `restaurar-coolify-remoto.sh` - Restauração automatizada

### Migração
- `migrar-completo.sh` - **Migração COMPLETA** (Coolify + Apps + Volumes)
- `migrar-coolify.sh` - Migração apenas Coolify (DB + config)
- `backup-volumes.sh` - Backup volumes Docker (aplicações)
- `transfer-volumes.sh` - Transferir volumes entre servidores
- `restore-volumes.sh` - Restaurar volumes de backup
- `validar-pre-migracao.sh` - 30+ verificações pré-migração
- `validar-pos-migracao.sh` - 40+ verificações pós-migração

### Manutenção
- `manutencao-completa.sh` - Limpeza de logs, Docker, apt
- `verificar-saude-completa.sh` - Diagnóstico do sistema
- `limpar-backups-antigos.sh` - Gestão de retenção
- `firewall-interativo.sh` - Gerenciador de firewall UFW

## 🎯 Comandos Globais

```bash
vps-guardian              # Menu interativo
vps-guardian backup       # Backup local
vps-guardian backup-s3    # Backup para S3
vps-guardian migrate      # Migração
vps-guardian status       # Status do sistema
vps-guardian firewall     # Gerenciar firewall
vps-guardian monitor self-check  # Validar monitor e timer
vps-guardian monitor check       # Executar verificação preventiva

# Aliases rápidos
backup-vps                # = vps-guardian backup
backup-s3-vps             # = vps-guardian backup-s3
firewall-vps              # = vps-guardian firewall
status-vps                # = vps-guardian status
```

## 📚 Documentação

- **[INSTALACAO.md](docs/INSTALACAO.md)** - Instalação e configuração
- **[GUIA-RAPIDO.md](docs/GUIA-RAPIDO.md)** - Comandos essenciais
- **[USO-SCRIPTS.md](docs/USO-SCRIPTS.md)** - Documentação completa dos scripts
- **[BACKUP-S3-GUIDE.md](docs/BACKUP-S3-GUIDE.md)** - Backup para S3
- **[RETENCAO-BACKUPS.md](docs/RETENCAO-BACKUPS.md)** - Gestão de retenção
- **[MIGRACAO-APPS.md](docs/MIGRACAO-APPS.md)** - Migração COMPLETA (Coolify + Apps)
- **[GUIA-MIGRACAO-COMPLETA.md](docs/GUIA-MIGRACAO-COMPLETA.md)** - Migração apenas Coolify
- **[FIREWALL-GUIDE.md](docs/FIREWALL-GUIDE.md)** - Configuração de firewall
- **[COMANDOS.md](docs/COMANDOS.md)** - Referência de comandos
- **[GUIA-MONITOR-PREVENTIVO.md](docs/GUIA-MONITOR-PREVENTIVO.md)** - Monitor integrado, atualização, relatórios e emergência

## 🏗️ Arquitetura

```
📂 CÓDIGO FONTE (Git)
/usr/local/src/vpsguardian/
├── backup/              # Scripts de backup/restauração
├── migrar/              # Scripts de migração
├── manutencao/          # Scripts de manutenção
├── scripts-auxiliares/  # Utilitários e validadores
├── lib/                 # Bibliotecas compartilhadas
│   ├── common.sh        # → Loader principal + utils
│   ├── logging.sh       # → Sistema de logs padronizado
│   ├── colors.sh        # → Cores ANSI para output
│   └── validation.sh    # → 50+ funções de validação
├── config/              # Configurações e exemplos
├── monitor/             # Monitor preventivo e units systemd
└── menu-principal.sh    # Menu interativo principal

📂 INSTALAÇÃO (Symlinks)
/opt/vpsguardian/ → /usr/local/src/vpsguardian/

📂 DADOS
/var/backups/vpsguardian/
├── coolify/             # Backups Coolify (tar.gz)
├── databases/           # Dumps SQL (sql.gz)
└── volumes/             # Backups volumes (tar.gz)

/var/log/vpsguardian/
└── *.log                # Logs estruturados

/var/lib/vpsguardian/monitor/
├── history/             # Histórico M7
└── incidents/           # Pacotes de emergência M8
```

Os caminhos acima são os padrões usuais. Consulte
`/etc/vpsguardian/install.conf` para a instalação real.

## 🔄 Atualização

Execute o mesmo instalador e selecione **Atualizar**:

```bash
sudo ./instalar.sh --mode update --non-interactive
```

Configuração, estados, histórico e incidentes são preservados. O fluxo possui
validação, smoke test e rollback de todos os artefatos imutáveis gerenciados
pelo instalador. Configurações e dados mutáveis não são revertidos.

## 💡 Exemplos Rápidos

### Backup Diário Automático
```bash
sudo vps-guardian cron
# Selecionar: backup-coolify.sh
# Frequência: diária às 02:00
```

### Migrar Coolify + Apps para Novo Servidor
```bash
# Migração TOTAL (Coolify + todas as aplicações):
source /etc/vpsguardian/install.conf
sudo "$INSTALL_ROOT/migrar/migrar-completo.sh" --auto

# OU apenas Coolify (sem volumes de apps):
sudo vps-guardian migrate
```

### Configurar Firewall Seguro
```bash
sudo firewall-vps
# Selecionar perfil: Seguro (Cloudflare Tunnel)
```

### Backup para S3
```bash
sudo backup-s3-vps
# Modo interativo na primeira vez
# Automático nas próximas
```

## 🔒 Segurança

**Permissões:**
- `/opt/vpsguardian` → 755 (rwxr-xr-x)
- `/var/backups/vpsguardian` → 700 (rwx------) - **Apenas root**
- `/var/log/vpsguardian` → 750 (rwxr-x---)

**Backups contêm dados sensíveis:**
- APP_KEY do Coolify
- Chaves SSH privadas
- Credenciais de banco de dados

**⚠️ Nunca exponha `/var/backups/vpsguardian` publicamente!**

## 📊 Estatísticas

- **997 linhas** de bibliotecas compartilhadas
- **50+ funções** de validação reutilizáveis
- **20+ scripts** especializados
- **14 scripts** refatorados com padrão moderno
- **0 duplicações** de código

## 🛠️ Requisitos

- Ubuntu 20.04+ / Debian 11+
- Docker instalado
- Coolify instalado (opcional)
- Acesso root
- 10GB+ espaço disponível

## 📄 Licença

MIT License - veja [LICENSE](LICENSE)

---

**🛡️ VPS Guardian - Proteja seu servidor com confiança**

<div align="center">

**[📥 Instalação](docs/INSTALACAO.md)** • **[📖 Documentação](docs/USO-SCRIPTS.md)** • **[⚡ Guia Rápido](docs/GUIA-RAPIDO.md)**

</div>
