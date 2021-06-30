#!/bin/bash

# Nome do arquivo com a imagem do FSArchiver, presente na raiz do pendrive
ARQUIVOFSA="linux.fsa"

# Ponto de montagem da partição EFI no sistema restaurado; as distribuições principais usam /boot/efi
ESPMNT="/boot/efi"

# ----------------------------------------------------

# Ambos bagunçam o terminal e não são importantes para este script
systemctl -q disable --now NetworkManager-dispatcher.service pacman-init.service

declare -A IMGINFO FSORIG FSNOVO UUIDORIG UUIDNOVO PART
PASSADAS=0

PENMNT="/run/archiso/bootmnt"
DESTMNT="/mnt/dest-$RANDOM"

mostraerro() {
    rmdir $DESTMNT 2>/dev/null
    echo      >&2
    echo "$1" >&2
    echo      >&2
    exit 1
}

calctam() {
    local TAMANHO_B=$1
    if (( $TAMANHO_B > 0 )); then
        local TAMANHO_KB=$(( $TAMANHO_B  / 1000 ))
        local TAMANHO_MB=$(( $TAMANHO_KB / 1000 ))
        local TAMANHO_GB=$(( $TAMANHO_MB / 1000 ))
        local TAMANHO_TB=$(( $TAMANHO_GB / 1000 ))
        if (( $TAMANHO_TB == 0 )); then
            if (( $TAMANHO_GB == 0 )); then
                printf '%3s MB\n' $TAMANHO_MB
            else
                printf '%3s GB\n' $TAMANHO_GB
            fi
        else
            printf '%3s TB\n' $TAMANHO_TB
        fi
    else
        echo "???   "
    fi
}

# Gambiarra para preservar o contexto SELinux dos arquivos, visto que o sed do SystemRescue não o faz
meu_sed_ri() {
    local ARQTMP=$(mktemp)
    sed -r "$1" "$2" > $ARQTMP 2>/dev/null && ! cmp -s "$2" $ARQTMP && cat $ARQTMP > "$2"
    rm -f $ARQTMP
}

[[ $(uname -m) == x86_64 ]]    || mostraerro "Linux x86_64 requerido."
mountpoint -q $PENMNT          || mostraerro "Pendrive não encontrado. Não use \"copytoram\"."
[[ -e "$PENMNT/$ARQUIVOFSA" ]] || mostraerro "Arquivo de imagem inexistente."

echo -e "\nPendrive:\t$PENMNT\nDestino:\t$DESTMNT\n"

if FSAINFO=$(LANG=C fsarchiver archinfo "$PENMNT/$ARQUIVOFSA" 2>&1); then
    (( $(awk -F ':[[:blank:]]*' '/^Filesystems count/ {print $2}' <<< "$FSAINFO") > 2 )) && \
        echo -e "\nMais de dois sistemas de arquivos na imagem. Ignorando do terceiro em diante.\n"
    # ID 0 -> raiz
    # ID 1 -> esp
    IMGINFO[raiz]=$(awk '/Filesystem id in archive:[[:blank:]]*0/,/^$/' <<< "$FSAINFO")
    if IMGINFO[esp]=$(awk '/Filesystem id in archive:[[:blank:]]*1/,/^$/ {e=1; print}; END{exit !e}' <<< "$FSAINFO"); then
        FSORIG[esp]=$(awk -F ':[[:blank:]]*' '/^Filesystem format/ {print $2}' <<< "${IMGINFO[esp]}")
        UUIDORIG[esp]=$(awk -F ':[[:blank:]]*' '/^Filesystem uuid/ {print $2}' <<< "${IMGINFO[esp]}")
        [[ ${FSORIG[esp]} == vfat ]] || \
            mostraerro "Imagem da partição EFI não possui sistema de arquivos FAT."
    fi
    FSORIG[raiz]=$(awk -F ':[[:blank:]]*' '/^Filesystem format/ {print $2}' <<< "${IMGINFO[raiz]}")
    UUIDORIG[raiz]=$(awk -F ':[[:blank:]]*' '/^Filesystem uuid/ {print $2}' <<< "${IMGINFO[raiz]}")
    [[ ${FSORIG[raiz]} =~ ext[2-4]|xfs|btrfs|jfs|reiserfs ]] || \
        mostraerro "Imagem não contém sistema de arquivos suportado (EXT2/3/4, XFS, Btrfs, JFS ou ReiserFS)."
else
    mostraerro "Arquivo não é uma imagem do FSArchiver."
fi

PENDEV=$(findmnt -rno SOURCE -M $PENMNT)

# util-linux >= 2.22
for DISCO in $(lsblk -I 8 -drno NAME); do
    [[ $PENDEV =~ $DISCO ]] && continue
    MODELO=$(< /sys/block/$DISCO/device/model)
    TAMANHO=$(calctam $(blockdev --getsize64 /dev/$DISCO))
    echo "/dev/$DISCO $TAMANHO - $MODELO"
    (( $PASSADAS == 0 )) && PRIMEIRODISCO=$DISCO
    (( PASSADAS++ ))
done

(( $PASSADAS == 0 )) && mostraerro "Nenhum dispositivo de armazenamento encontrado."

echo
while true; do
    read -e -p "Dispositivo a ser restaurado: " -i "/dev/$PRIMEIRODISCO" DEV
    if [[ $DEV ]]; then
        if [[ ! -b $DEV ]]; then
            echo
            echo "Dispositivo inválido."
            echo
        elif [[ $PENDEV =~ ${DEV//[[:digit:]]/} ]]; then
            echo
            echo "Mesmo dispositivo do pendrive. Escolha outro."
            echo
        elif [[ $DEV =~ [[:digit:]]+$ ]]; then
            echo
            echo "Dispositivo inválido. Não especifique número de partição."
            echo
        else
            break
        fi
    else
        echo
    fi
done

echo
echo "Mudar sistema de arquivos? O atual é \"${FSORIG[raiz]}\"."
[[ ${IMGINFO[esp]} ]] && echo "(imagem UEFI: pode não inicializar com sistema de arquivos diferente)"
select RESP in SIM NÃO; do
    case $RESP in
        SIM)
            MUDAFS=1
            break
        ;;
        NÃO)
            break
        ;;
    esac
done

if [[ $MUDAFS ]]; then
    for FSATUAL in ext2 ext3 ext4 xfs btrfs jfs reiserfs; do
        [[ $FSATUAL == ${FSORIG[raiz]} ]] && continue
        LISTAFS+="$FSATUAL "
    done
    echo
    echo "Escolha o novo sistema de arquivos."
    select RESP in $LISTAFS; do
        case $RESP in
            ext2)
                FSNOVO[raiz]=ext2
                break
            ;;
            ext3)
                FSNOVO[raiz]=ext3
                break
            ;;
            ext4)
                FSNOVO[raiz]=ext4
                break
            ;;
            xfs)
                FSNOVO[raiz]=xfs
                break
            ;;
            btrfs)
                FSNOVO[raiz]=btrfs
                break
            ;;
            jfs)
                FSNOVO[raiz]=jfs
                break
            ;;
            reiserfs)
                FSNOVO[raiz]=reiserfs
                break
            ;;
        esac
    done
fi

echo
echo "Gerar novo UUID, machine-id e hostname?"
select RESP in SIM NÃO; do
    case $RESP in
        SIM)
            MUDAUUID=1
            break
        ;;
        NÃO)
            break
        ;;
    esac
done

echo
echo "Tem certeza? (TODOS os dados de $DEV serão apagados)"
select RESP in SIM NÃO; do
    case $RESP in
        SIM)
            break
        ;;
        NÃO)
            mostraerro "Cancelado."
        ;;
    esac
done

echo
echo "Particionando..."
# https://github.com/marcosfrm/limpadsk
if command -v limpadsk >/dev/null; then
    limpadsk $DEV
    udevadm settle
fi
# util-linux >= 2.36
if [[ ${IMGINFO[esp]} ]]; then
    # ESP de 500 MiB
    echo -e ',500M,U\n,,L' | sfdisk --quiet --lock=yes --wipe=always --wipe-partitions=always --label=gpt $DEV
    PART[esp]=${DEV}1
    PART[raiz]=${DEV}2
else
    echo ',,L,*' | sfdisk --quiet --lock=yes --wipe=always --wipe-partitions=always --label=dos $DEV
    PART[raiz]=${DEV}1
fi
udevadm settle

echo
echo "Restaurando..."
[[ ${FSNOVO[raiz]} ]] && FSAOPT=",mkfs=${FSNOVO[raiz]}"
if [[ $MUDAUUID ]]; then
    UUIDNOVO[raiz]=$(uuidgen)
    FSAOPT+=",uuid=${UUIDNOVO[raiz]}"
fi
# fsarchiver >= 0.8.0
fsarchiver -j $(nproc) restfs "$PENMNT/$ARQUIVOFSA" id=0,dest=${PART[raiz]}${FSAOPT} || \
    mostraerro "Falha ao restaurar imagem (raiz)."

if [[ ${IMGINFO[esp]} ]]; then
    FSAOPT=
    if [[ $MUDAUUID ]]; then
        UUIDNOVO[esp]=$(openssl rand -hex 4 | tr '[:lower:]' '[:upper:]')
        # https://github.com/fdupoux/fsarchiver/pull/106
        #FSAOPT=",uuid=${UUIDNOVO[esp]}"
        FSAOPT=",mkfsopt=-i${UUIDNOVO[esp]}"
    fi
    fsarchiver -j $(nproc) restfs "$PENMNT/$ARQUIVOFSA" id=1,dest=${PART[esp]}${FSAOPT} || \
        mostraerro "Falha ao restaurar imagem (esp)."
fi

echo
echo "Definindo configurações..."
DESTMNTOPTS='-o X-mount.mkdir'
# ReiserFS precisa de opções de montagem para habilitar ACLs e XATTRs
[[ ( ! ${FSNOVO[raiz]} && ${FSORIG[raiz]} == reiserfs ) || ${FSNOVO[raiz]} == reiserfs ]] && \
    DESTMNTOPTS+=',acl,user_xattr'

mount ${PART[raiz]} $DESTMNT $DESTMNTOPTS 2>/dev/null || mostraerro "Falha ao montar destino (raiz)."

if [[ ${IMGINFO[esp]} ]]; then
    mount ${PART[esp]} ${DESTMNT}${ESPMNT} -o 'utf8,iocharset=ascii' 2>/dev/null || \
        mostraerro "Falha ao montar destino (esp)."
fi
for PM in dev proc sys run; do
    mount --bind /$PM $DESTMNT/$PM
done

rm -f $DESTMNT/.readahead
rm -f $DESTMNT/var/lib/ureadahead/pack
find $DESTMNT/var/log/journal -mindepth 1 -maxdepth 1 -type d -not -name remote -exec rm -rf {} + 2>/dev/null
rm -rf $DESTMNT/var/log/journal/remote/*
rm -f $DESTMNT/etc/udev/rules.d/70-persistent-net.rules

rm -f $DESTMNT/etc/NetworkManager/system-connections/*
meu_sed_ri '/^no-auto-default=/d' $DESTMNT/etc/NetworkManager/NetworkManager.conf

if [[ ${FSNOVO[raiz]} ]]; then
    meu_sed_ri "/${UUIDORIG[raiz]}/ s/${FSORIG[raiz]}/${FSNOVO[raiz]}/" $DESTMNT/etc/fstab
    # ReiserFS: "acl,user_xattr", "user_xattr,acl", "acl", "user_xattr"
    # Outros sistemas: "defaults"
    if [[ ${FSORIG[raiz]} == reiserfs ]]; then
        meu_sed_ri "/${UUIDORIG[raiz]}/ s/[[:blank:]]+(acl(,user_xattr)?|user_xattr(,acl)?)[[:blank:]]+/\tdefaults\t/" \
            $DESTMNT/etc/fstab
    elif [[ ${FSNOVO[raiz]} == reiserfs ]]; then
        meu_sed_ri "/${UUIDORIG[raiz]}/ s/[[:blank:]]+defaults[[:blank:]]+/\tacl,user_xattr\t/" \
            $DESTMNT/etc/fstab
    fi
fi

if [[ $MUDAUUID ]]; then
    meu_sed_ri "s/${UUIDORIG[raiz]}/${UUIDNOVO[raiz]}/" $DESTMNT/etc/fstab
    if [[ ${IMGINFO[esp]} ]]; then
        # 12345678 -> 1234-5678
        UUIDORIG[esp]=$(printf '%s-%s' ${UUIDORIG[esp]:0:4} ${UUIDORIG[esp]:4:4})
        UUIDNOVO[esp]=$(printf '%s-%s' ${UUIDNOVO[esp]:0:4} ${UUIDNOVO[esp]:4:4})
        meu_sed_ri "s/${UUIDORIG[esp]}/${UUIDNOVO[esp]}/" $DESTMNT/etc/fstab
    fi

    [[ -e $DESTMNT/var/lib/dbus/machine-id && ! -L $DESTMNT/var/lib/dbus/machine-id ]] && \
        dbus-uuidgen > $DESTMNT/var/lib/dbus/machine-id
    > $DESTMNT/etc/machine-id
    chroot $DESTMNT systemd-machine-id-setup
    rm -f $DESTMNT/var/lib/systemd/random-seed
    echo "linux-$RANDOM" > $DESTMNT/etc/hostname
fi

. $DESTMNT/etc/os-release

# initramfs são regerados por último, depois das mudanças de UUID/machine-id/hostname terem sido aplicadas
# Nem sempre há correspondência entre ID e o diretório na partição EFI
case $ID in
    fedora|rhel|centos|ol|rocky|mageia)
        find $DESTMNT/etc/sysconfig/network-scripts -type f -name 'ifcfg-*' -a -not -name 'ifcfg-lo' -delete
        chroot $DESTMNT dracut --regenerate-all --force
        [[ $ID == rhel || $ID == ol ]] && ID=redhat
    ;;
    sled|sles|opensuse*)
        find $DESTMNT/etc/sysconfig/network -type f -name 'ifcfg-*' -a -not -name 'ifcfg-lo' -delete
        chroot $DESTMNT dracut --regenerate-all --force
        [[ $ID == opensuse* ]] && ID=opensuse
    ;;
    debian|ubuntu)
        rm -f $DESTMNT/etc/network/interfaces.d/*
        chroot $DESTMNT update-initramfs -u -k all
    ;;
    arch)
        chroot $DESTMNT mkinitcpio -P
    ;;
esac

export PATH=${PATH}:/usr/sbin

echo
echo "Instalando/configurando GRUB..."
[[ $ID == debian || $ID == ubuntu || $ID == arch ]] && GRUBPRE=grub || GRUBPRE=grub2
GRUBDIR=/boot/$GRUBPRE
# BIOS/CSM apenas; em UEFI não instalamos coisa alguma; distribuições que não configuram o fallback
# EFI/BOOT/BOOTX64.EFI na ESP precisarão de intervenção manual; no Debian, quando o instalador perguntar
# "Forçar instalação extra no caminho de mídia removível EFI?", responda "Sim"; para fazê-lo depois de
# instalado: dpkg-reconfigure grub-efi-amd64
#
# grub-install não funciona em distribuições com suporte ao secure boot, pois o binário grubx64.efi é
# assinado e tem todos os drivers suportados pela distribuição embutidos; exceto no Debian, que tem um
# patch não oficial adicionando a opção --uefi-secure-boot (padrão caso os pacotes shim-signed e
# grub-efi-amd64-signed estejam instalados)
#
# Não rodar, por outro lado, grub-install em distribuições *sem* suporte ao secure boot, ou seja, cujo
# grubx64.efi seja criado localmente usando os drivers de /usr/lib/grub/x86_64-efi, significa que, caso o
# sistema de arquivos seja alterado, o driver requerido não fará parte do binário e a inicialização
# provavelmente falhará
#
# Fedora, openSUSE e Debian usam o mesmo mecanismo:
# grubx64.efi monolítico e assinado, que lê arquivo stub na ESP, que, através do UUID, acha sistema de
# arquivos contendo o diretório /boot para então carregar o arquivo de configuração principal
[[ ${IMGINFO[esp]} ]] || chroot $DESTMNT ${GRUBPRE}-install --recheck $DEV

if [[ $MUDAUUID ]]; then
    # BIOS/CSM e UEFI com configuração unificada
    [[ -e ${DESTMNT}${GRUBDIR}/grub.cfg ]] && chroot $DESTMNT ${GRUBPRE}-mkconfig -o $GRUBDIR/grub.cfg

    if [[ ${IMGINFO[esp]} && -e ${DESTMNT}${ESPMNT}/EFI/${ID:-$RANDOM}/grub.cfg ]]; then
        # Heurística: se for menor que 300 bytes, assumimos arquivo stub
        # https://fedoraproject.org/wiki/Changes/UnifyGrubConfig
        if (( $(stat -c '%s' ${DESTMNT}${ESPMNT}/EFI/$ID/grub.cfg) < 300 )); then
            meu_sed_ri "s/${UUIDORIG[raiz]}/${UUIDNOVO[raiz]}/" ${DESTMNT}${ESPMNT}/EFI/$ID/grub.cfg
        else
            chroot $DESTMNT ${GRUBPRE}-mkconfig -o $ESPMNT/EFI/$ID/grub.cfg
        fi
    fi
fi

echo
echo "Desmontando tudo..."
# util-linux >= 2.23
umount -Rv $DESTMNT || mostraerro "Falha ao desmontar destino."
rmdir $DESTMNT

reboot
