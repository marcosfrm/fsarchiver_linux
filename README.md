Shell script que uso no [SystemRescue](https://www.system-rescue.org) para restaurar imagem do [FSArchiver](https://github.com/fdupoux/fsarchiver) apagando **todos** os dados do disco de destino.

Para usá-lo, renomeie o script para `autorun` e copie-o para a raiz do pendrive onde está o SystemRescue (6.1.7 ou superior), junto com a imagem do FSArchiver. **Não** use a opção de boot `copytoram`. Ajuste, se necessário, as variáveis do início do script.

- Para instalações BIOS/CSM, a imagem precisa ter apenas um sistema de arquivos (id 0) da partição raiz.
  - Exemplo de captura: `fsarchiver savefs linux.fsa /dev/sda1` (`/dev/sda1` é a partição raiz).

- Para instalações UEFI, a imagem deve ter dois sistemas de arquivos, sendo o primeiro (id 0) da partição raiz e o segundo (id 1) da partição EFI.
  - Exemplo de captura: `fsarchiver savefs linux.fsa /dev/sda2 /dev/sda1` (`/dev/sda2` é a partição raiz e `/dev/sda1` é a partição EFI).

Qualquer outra partição não é suportada, incluindo swap.

O script não faz diferenciação pelo modo em que o SystemRescue foi inicializado (BIOS/CSM ou UEFI). No caso de instalações UEFI, será possível restaurá-las mesmo inicializando via BIOS/CSM, pois não mexe nas variáveis do firmware.
