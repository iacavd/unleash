# unleash — Quick Reference

Keep this on your SSD alongside the script.

## From Recovery Mode

1. Boot to Recovery (Apple Silicon: hold Power until startup options appear; Intel: Cmd+R)
2. Open Terminal (Utilities → Terminal)
3. Run Unleash:
   `"/Volumes/Macintosh HD - Data/Users/Shared/unleash/unleash" recovery`
   *(or run `./unleash` without arguments and accept the auto-wipe prompt)*
4. Unleash automatically mounts your Data volume, unlocks FileVault, wipes `.cloudConfigRecordFound` and all DEP markers from disk, disables enrollment daemons, and prompts you to reboot!

## Common scenarios

| Você quer... | Comando |
|---|---|
| Limpar DEP automaticamente no Recovery (mantém seu usuário) | `./unleash recovery` |
| Apagar apenas arquivos DEP do disco | `./unleash wipe-dep` |
| Bypass completo (cria usuário admin do zero) | `./unleash bypass` |
| Só silenciar o MDM (sem criar usuário) | `./unleash suppress` |
| Consertar depois de atualizar macOS | `sudo ./unleash heal` |
| Nunca mais pensar nisso | `sudo ./unleash persist` + `sudo ./unleash whitelist` |
| Saber se vai travar após formatar | `sudo ./unleash check` |
| Vigiar MDM em tempo real | `sudo ./unleash monitor` |
| Instalar monitor para sempre | `sudo ./unleash monitor-install` |
| Limpeza pós-bypass (já logado) | `sudo ./unleash harden` |
| Varredura completa | `sudo ./unleash audit` |
| Voltar ao normal | `./unleash restore` |

## Aliases

`rec` = recovery, `wipe` = wipe-dep, `by` = bypass, `sv` = suppress, `fw` = firewall, `wl` = whitelist,
`st` = status, `mn` = monitor, `mn-st` = monitor-status

## Avisos

- **Não** rode `profiles renew` — isso reativa o MDM
- **Não** use "Apagar Conteúdo e Ajustes" — isso limpa o bypass
- Após formatar (wipe), rode o bypass de novo do Recovery
- Migration Assistant traz o MDM de volta — sempre rode `suppress` depois
