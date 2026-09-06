---
layout: default
title: FAQ — unleash
---

# FAQ

## Geral

### Quais versões do macOS são suportadas?

12.x (Monterey) até 15.x (Sequoia), 26.x (Tahoe) e 27.x. Testado em Intel T2, M1, M2, M3, M4, M5.

### É a mesma coisa que bypass-mdm?

Não. Os scripts originais do bypass-mdm (v2, v3, express) só lidam com marcadores DEP e `/etc/hosts`. O Unleash cobre todas as cinco camadas:

- Marcadores DEP (igual ao original)
- Bloqueio de rede via `/etc/hosts` (igual)
- Override de daemons (original tem uma versão básica)
- **Limpeza de artefatos de usuário** (original não faz isso)
- **Firewall pf a nível de kernel** (original não faz isso)
- **Daemon de auto-recuperação**, **monitor em segundo plano**, **auditoria**, **predict**, **remediate** e 30+ comandos

Além de distribuição em arquivo único, Homebrew tap e releases assinados com GPG.

### Preciso desabilitar o SIP?

Não. Todas as escritas miram o volume de Dados. O volume do sistema nunca é modificado.

### Preciso de internet?

`bypass` e `suppress` não precisam de internet. `persist`, `firewall` e `update` precisam (baixam recursos ou contatam o GitHub).

### Sobrevive a uma reinstalação do sistema?

Não. A instalação limpa apaga o volume de Dados. Execute `bypass` do Recovery novamente após reinstalar.

### Sobrevive a uma atualização do macOS?

Geralmente sim, com `persist`. O LaunchDaemon executa `heal` automaticamente na próxima inicialização após uma atualização. Sem `persist`, execute `sudo ./unleash heal` manualmente.

### A organização pode rastrear isso?

O serial do dispositivo permanece no Apple Business Manager para sempre. Só a organização pode removê-lo. Se o dispositivo se conectar à internet com todas as proteções removidas, ele será registrado novamente.

### Posso usar iCloud após o bypass?

Sim. Use `whitelist` em vez de `firewall` ou `suppress` básico. Ele resolve apenas os domínios MDM essenciais para IPs e bloqueia aqueles, deixando iCloud, App Store e atualizações intocados.

### Por que o MDM volta depois do Migration Assistant?

O Migration Assistant copia caches, preferências e launch agents do Mac antigo. Estes contêm artefatos de registro MDM que reativam o processo de registro. A maioria das ferramentas só limpa marcadores DEP de nível de sistema — o Unleash também limpa o diretório Library de cada usuário.

### Tem interface gráfica?

Ainda não. A CLI é a interface principal. Um wrapper SwiftUI está no [roadmap](https://github.com/iacavd/unleash/blob/main/ROADMAP.md).

### Qual é a licença?

MIT. Gratuito para usar, modificar e distribuir.

## Técnico

### Como saber se meu Mac está registrado no MDM?

```bash
sudo ./unleash check
```

Retorna SAFE TO FORMAT (sem MDM) ou MDM DETECTED (vai travar após limpar).

### Como verificar se o bypass ainda está funcionando?

```bash
sudo ./unleash status -d
```

Verifica marcadores DEP, arquivo hosts, overrides de daemon e estado dos perfis.

### `profiles status -v` ainda mostra um perfil MDM — por quê?

Cosmético. O macOS armazena o estado dos perfis no SSV (Volume Selado do Sistema) somente leitura. Os daemons de registro reais estão desabilitados e os marcadores DEP foram removidos. Confie em `unleash status` em vez de `profiles status`.

### Qual a diferença entre `monitor` e `persist`?

`monitor` é um daemon que verifica a cada 5 minutos e envia uma notificação do macOS se o MDM tentar re-registrar. `persist` é um LaunchDaemon que executa `heal` em cada inicialização. Use ambos para proteção completa.

### Qual a diferença entre `firewall` e `whitelist`?

`firewall` bloqueia toda a faixa de IP da Apple (quebra iCloud/App Store). `whitelist` resolve apenas domínios MDM para IPs e bloqueia aqueles (mantém iCloud/App Store funcionando).

### Quais organizações o `remediate` suporta?

JAMF, Mosyle, Addigy, Kandji, VMware Workspace ONE. Ele detecta automaticamente a organização a partir do registro DEP e aplica limpeza direcionada.

### Como o `predict` funciona?

Ele lê o prefixo do número serial e verifica contra prefixos conhecidos de organizações MDM (de pesquisa comunitária). Se encontrar correspondência, prevê qual organização registrou o dispositivo.

## Solução de Problemas

### MDM volta após reiniciar

Execute do Recovery:
```bash
sudo ./unleash suppress
```

Ou de um sistema já iniciado:
```bash
sudo ./unleash harden
```

### Erro "Not a known DirStatus"

A detecção automática de volume falhou. Encontre seu volume de Dados:
```bash
diskutil list
diskutil mount /dev/diskXsY
./unleash bypass
```

### Desbloqueio do FileVault falha no Recovery

Você precisa de uma senha de usuário ou da chave de recuperação do FileVault. Se nenhum estiver disponível, o volume de Dados não pode ser montado do Recovery. Desbloqueie manualmente no Utilitário de Disco primeiro.

### "Not a macOS Data volume"

O Unleash verifica `/private/var/db/dslocal/nodes/Default` no volume montado. Se estiver faltando, você montou o disco errado. Execute `diskutil list` para encontrar o volume de Dados correto.

### Monitor não inicia

1. Verifique se já está rodando: `sudo ./unleash monitor-status`
2. Verifique permissões: precisa de root
3. Verifique logs: `/var/log/unleash-monitor.log`

---

[Voltar ao início](/) · [Guia de Arquitetura](guide)
