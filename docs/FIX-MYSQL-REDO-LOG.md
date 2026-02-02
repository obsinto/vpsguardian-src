# Fix MySQL Redo Log Corruption

## Problema

Ao restaurar backups de volumes Docker que contêm bancos de dados MySQL/MariaDB, você pode encontrar o seguinte erro:

```
[ERROR] [MY-013879] [InnoDB] The redo log file ./#innodb_redo/#ib_redo532 comes from other data directory than redo log file ./#innodb_redo/#ib_redo13.
[ERROR] [MY-012930] [InnoDB] Plugin initialization aborted with error Generic error.
[ERROR] [MY-010334] [Server] Failed to initialize DD Storage Engine
[ERROR] [MY-010020] [Server] Data Dictionary initialization failed.
```

Esse erro ocorre porque os **arquivos de redo log do InnoDB estão corrompidos ou vieram de diretórios diferentes**. O MySQL não consegue inicializar porque detecta inconsistências nos arquivos de log de transações.

## Causas Comuns

1. **Restauração de backup com arquivos binários**: Quando você faz backup de um volume Docker do MySQL e restaura em outro servidor, os arquivos de redo log podem estar corrompidos.

2. **Mistura de arquivos de diferentes servidores**: Os arquivos `#innodb_redo/` contêm metadados que identificam de qual servidor vieram. Se houver arquivos de servidores diferentes, o MySQL recusa inicializar.

3. **Shutdown não gracioso**: Se o MySQL foi parado abruptamente antes do backup, os redo logs podem estar em estado inconsistente.

4. **Versões diferentes do MySQL**: Migração entre versões do MySQL pode causar incompatibilidade nos redo logs.

## Solução Automática

Use o script de correção automática:

```bash
cd /root/vpsguardian-src/scripts-auxiliares
./fix-mysql-redo-log.sh
```

### Uso Interativo

Se você não especificar o container, o script irá:
1. Detectar automaticamente todos os containers MySQL/MariaDB
2. Mostrar quais têm o erro de redo log
3. Permitir que você selecione qual corrigir

```bash
./fix-mysql-redo-log.sh

# Exemplo de saída:
Containers detectados:

  [0] myapp-db
      Status: restarting
      Image: mysql:8.4
      ⚠️  ERRO DE REDO LOG DETECTADO!

  [1] wordpress-mysql
      Status: running
      Image: mysql:5.7

Selecione o container (0-1): 0
```

### Uso Direto

Se você já sabe o nome do container:

```bash
./fix-mysql-redo-log.sh myapp-db
```

## O Que o Script Faz

1. **Para o container MySQL**: Garante que nenhuma operação está em andamento
2. **Remove arquivos corrompidos**:
   - `#innodb_redo/` (diretório de redo logs)
   - `ib_logfile*` (redo logs legados do MySQL 5.x)
   - `#ib_*` (arquivos temporários do InnoDB)
3. **Reinicia o container**: O MySQL recria os redo logs automaticamente
4. **Verifica o sucesso**: Confirma que o MySQL iniciou corretamente

## Solução Manual

Se preferir fazer manualmente:

### 1. Parar o container

```bash
docker stop myapp-db
```

### 2. Remover redo logs corrompidos

**Opção A: Via Docker Volume**

```bash
# Descobrir o nome do volume
VOLUME=$(docker inspect --format='{{range .Mounts}}{{if eq .Destination "/var/lib/mysql"}}{{.Name}}{{end}}{{end}}' myapp-db)

# Remover redo logs
docker run --rm -v "$VOLUME:/mysql" busybox sh -c "rm -rf /mysql/#innodb_redo /mysql/ib_logfile* /mysql/#ib_*"
```

**Opção B: Via Bind Mount (se o container usa bind mount)**

```bash
# Descobrir o caminho do bind mount
PATH=$(docker inspect --format='{{range .Mounts}}{{if eq .Destination "/var/lib/mysql"}}{{.Source}}{{end}}{{end}}' myapp-db)

# Remover redo logs
rm -rf "$PATH/#innodb_redo" "$PATH/ib_logfile"* "$PATH/#ib_"*
```

### 3. Reiniciar o container

```bash
docker start myapp-db
```

### 4. Verificar logs

```bash
docker logs -f myapp-db
```

Aguarde até ver:

```
[Note] [Entrypoint]: MySQL server is ready for connections
```

ou

```
ready for connections. Version: '8.4.8'
```

## Prevenção

Para evitar esse problema ao fazer backups e migrações:

### 1. **Use dump SQL ao invés de cópia de volumes** (RECOMENDADO)

Para MySQL:
```bash
docker exec myapp-db mysqldump -u root -p database_name > backup.sql
```

Para restaurar:
```bash
cat backup.sql | docker exec -i myapp-db mysql -u root -p database_name
```

### 2. **Pare o MySQL antes de fazer backup de volumes**

```bash
docker stop myapp-db
docker run --rm -v myapp-db-volume:/source -v /backups:/dest busybox tar czf /dest/backup.tar.gz -C /source .
docker start myapp-db
```

### 3. **Limpe redo logs antes de restaurar**

Ao restaurar um backup de volume em um novo servidor:

```bash
# Extrair backup
tar xzf backup.tar.gz -C /volume-path/

# Limpar redo logs ANTES de iniciar o container
rm -rf /volume-path/#innodb_redo
rm -f /volume-path/ib_logfile*
rm -f /volume-path/#ib_*

# Agora iniciar o container
docker start myapp-db
```

## Perguntas Frequentes

### Os dados do banco serão perdidos?

**NÃO.** Os redo logs são apenas arquivos de transação/recuperação. Os dados reais estão nos arquivos `.ibd` (tabelas) e `ibdata1` (dados do sistema). Ao remover os redo logs, você está apenas removendo o histórico de transações, não os dados em si.

### Por que o MySQL recria os redo logs automaticamente?

O MySQL **sempre** precisa de redo logs para funcionar. Se eles não existirem, o MySQL cria novos automaticamente durante a inicialização. Esses novos redo logs começam "limpos", sem conflitos.

### Isso pode causar perda de transações?

Se você fez o backup com o MySQL rodando e houve transações em andamento, **sim**, essas transações específicas podem ser perdidas. Por isso, é recomendado:
1. Sempre parar o MySQL antes de fazer backup de volumes
2. Ou usar `mysqldump` que faz backup consistente mesmo com MySQL rodando

### Posso fazer isso com o MySQL rodando?

**NÃO.** Você **deve** parar o container primeiro. Tentar remover redo logs com o MySQL rodando causará corrupção de dados e perda de transações.

## Troubleshooting

### Erro persiste após executar o script

1. Verifique se há múltiplos volumes montados:
   ```bash
   docker inspect myapp-db | grep -A 10 "Mounts"
   ```

2. Certifique-se de ter removido TODOS os redo logs:
   ```bash
   # Liste os arquivos no volume
   docker run --rm -v volume_name:/mysql busybox ls -la /mysql/ | grep -E "innodb|ib_"
   ```

3. Verifique permissões:
   ```bash
   docker run --rm -v volume_name:/mysql busybox ls -l /mysql/
   # O owner deve ser mysql (UID 999 geralmente)
   ```

### MySQL não inicia após a correção

1. Verifique os logs completos:
   ```bash
   docker logs myapp-db --tail 100
   ```

2. Procure por outros erros:
   ```bash
   docker logs myapp-db 2>&1 | grep -i error
   ```

3. Possíveis causas:
   - **Sem espaço em disco**: `df -h`
   - **Permissões incorretas**: O diretório `/var/lib/mysql` deve pertencer ao usuário `mysql` (UID 999)
   - **Configuração incorreta**: Verifique `my.cnf` ou variáveis de ambiente

### Container fica em loop de restart

Isso geralmente significa que o MySQL está falhando ao iniciar. Remova a política de restart temporariamente para investigar:

```bash
docker update --restart=no myapp-db
docker stop myapp-db
docker start myapp-db
docker logs myapp-db -f
```

## Suporte

Se o problema persistir após seguir este guia:

1. Verifique os logs completos: `docker logs myapp-db > mysql-error.log`
2. Verifique a estrutura do volume: `docker run --rm -v volume:/mysql busybox ls -laR /mysql/ > volume-structure.txt`
3. Relate o problema com os logs anexados

## Scripts Relacionados

- **backup-volumes.sh**: Criar backups de volumes Docker
- **migrar-volumes.sh**: Migrar volumes para novo servidor
- **restaurar-completo.sh**: Restaurar backup completo do sistema

## Referências

- [MySQL 8.0 Redo Log Documentation](https://dev.mysql.com/doc/refman/8.0/en/innodb-redo-log.html)
- [InnoDB Crash Recovery](https://dev.mysql.com/doc/refman/8.0/en/innodb-recovery.html)
- [MySQL Upgrade Best Practices](https://dev.mysql.com/doc/refman/8.0/en/upgrading.html)
