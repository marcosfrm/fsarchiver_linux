#!/bin/bash

# Marcos FRM
# 21/03/2020

# Nome do arquivo com a imagem do FSArchiver, presente na raiz do pendrive
ARQUIVOFSA="linux.fsa"

# --------------------------------------

unset DESTMNTOPTS
unset MUDAUUID
unset MUDAFS
unset LISTAFS
unset FSNOVO
unset FSAOPT
PASSADAS=0

PENMNT="/run/archiso/bootmnt"
DESTMNT="/mnt/dest-$RANDOM"

mostraerro() {
    umount -R $DESTMNT 2>/dev/null
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

[[ $(uname -m) == x86_64 ]]    || mostraerro "Linux x86_64 requerido."
mountpoint -q $PENMNT          || mostraerro "Pendrive não encontrado. Não use \"copytoram\"."
[[ -r "$PENMNT/$ARQUIVOFSA" ]] || mostraerro "Arquivo de imagem inexistente."

echo -e "\nPendrive:\t$PENMNT\nDestino:\t$DESTMNT\n"

if FSAINFO=$(LANG=C fsarchiver archinfo "$PENMNT/$ARQUIVOFSA" 2>&1); then
    FSORIG=$(awk -F':[[:blank:]]*' '/^Filesystem format/ {print $2}' <<< "$FSAINFO")
    if (( $(awk -F':[[:blank:]]*' '/^Filesystems count/ {print $2}' <<< "$FSAINFO") > 1 )); then
        mostraerro "Imagem contém mais de um sistema de arquivos. Cancelado."
    elif [[ ! $FSORIG =~ ext[2-4]|xfs|btrfs|jfs|reiserfs ]]; then
        mostraerro "Imagem não contém um sistema de arquivos suportado (EXT2/3/4, XFS, Btrfs, JFS ou ReiserFS)."
    fi
else
    mostraerro "Arquivo não é uma imgem do FSArchiver."
fi

PENDEV=$(findmnt -rno SOURCE -M $PENMNT)

# util-linux >= 2.22
for DISCO in $(lsblk -I 8 -drno NAME); do
    [[ $PENDEV =~ $DISCO ]] && continue
    MODELO=$(cat /sys/block/$DISCO/device/model)
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
echo "Mudar sistema de arquivos? O atual é \"$FSORIG\"."
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
        [[ $FSATUAL == $FSORIG ]] && continue
        LISTAFS+="$FSATUAL "
    done
    echo
    echo "Escolha o novo sistema de arquivos."
    select RESP in $LISTAFS; do
        case $RESP in
            ext2)
                FSNOVO=ext2
                break
            ;;
            ext3)
                FSNOVO=ext3
                break
            ;;
            ext4)
                FSNOVO=ext4
                break
            ;;
            xfs)
                FSNOVO=xfs
                break
            ;;
            btrfs)
                FSNOVO=btrfs
                break
            ;;
            jfs)
                FSNOVO=jfs
                break
            ;;
            reiserfs)
                FSNOVO=reiserfs
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
# util-linux >= 2.30
# https://github.com/karelzak/util-linux/commit/bb88152764837a579cb7a2b3ba3e979963419bed
echo ',,L,*' | flock $DEV sfdisk --quiet --wipe=always --wipe-partitions=always --label=dos $DEV
udevadm settle

echo
echo "Restaurando..."
UUIDORIG=$(awk -F':[[:blank:]]*' '/^Filesystem uuid/ {print $2}' <<< "$FSAINFO")
[[ $FSNOVO ]] && FSAOPT=",mkfs=$FSNOVO"
if [[ $MUDAUUID ]]; then
    UUIDNOVO=$(uuidgen)
    FSAOPT+=",uuid=$UUIDNOVO"
fi
# fsarchiver >= 0.8.0
fsarchiver -j $(nproc) restfs "$PENMNT/$ARQUIVOFSA" id=0,dest=${DEV}1$FSAOPT || \
    mostraerro "Falha ao restaurar imagem."

echo
echo "Definindo configurações..."
DESTMNTOPTS='-o X-mount.mkdir'
# ReiserFS precisa de opções de montagem para habilitar ACLs e XATTRs
if [[ ( ! $FSNOVO && $FSORIG == reiserfs ) || $FSNOVO == reiserfs ]]; then
    DESTMNTOPTS+=',acl,user_xattr'
fi
mount ${DEV}1 $DESTMNT $DESTMNTOPTS 2>/dev/null || mostraerro "Falha ao montar destino."
mount --bind /dev $DESTMNT/dev
mount --bind /proc $DESTMNT/proc
mount --bind /sys $DESTMNT/sys

rm -f $DESTMNT/.readahead
rm -f $DESTMNT/var/lib/ureadahead/pack
rm -f $DESTMNT/etc/NetworkManager/system-connections/*
find $DESTMNT/var/log/journal -mindepth 1 -maxdepth 1 -type d -not -name remote -exec rm -rf {} + 2>/dev/null
rm -rf $DESTMNT/var/log/journal/remote/*
rm -f $DESTMNT/etc/udev/rules.d/70-persistent-net.rules

if [[ $FSNOVO ]]; then
    sed -i "/$UUIDORIG/ s/$FSORIG/$FSNOVO/" $DESTMNT/etc/fstab
    # ReiserFS: "acl,user_xattr", "user_xattr,acl", "acl", "user_xattr"
    # outros sistemas: "defaults"
    if [[ $FSORIG == reiserfs ]]; then
        sed -ri "/$UUIDORIG/ s/[[:blank:]]+(acl(,user_xattr)?|user_xattr(,acl)?)[[:blank:]]+/\tdefaults\t/" \
            $DESTMNT/etc/fstab
    elif [[ $FSNOVO == reiserfs ]]; then
        sed -ri "/$UUIDORIG/ s/[[:blank:]]+defaults[[:blank:]]+/\tacl,user_xattr\t/" \
            $DESTMNT/etc/fstab
    fi
fi

if [[ $MUDAUUID ]]; then
    sed -i "s/$UUIDORIG/$UUIDNOVO/" $DESTMNT/etc/fstab
    [[ -e $DESTMNT/var/lib/dbus/machine-id && ! -L $DESTMNT/var/lib/dbus/machine-id ]] && \
        dbus-uuidgen > $DESTMNT/var/lib/dbus/machine-id
    > $DESTMNT/etc/machine-id
    chroot $DESTMNT systemd-machine-id-setup
    rm -f $DESTMNT/var/lib/systemd/random-seed
    echo "linux-$RANDOM" > $DESTMNT/etc/hostname
fi

. $DESTMNT/etc/os-release

# initramfs são regerados por último, depois das mudanças de UUID/machine-id/hostname terem sido aplicadas
case $ID in
    fedora|centos)
        find $DESTMNT/etc/sysconfig/network-scripts -type f -name 'ifcfg-*' -a -not -name 'ifcfg-lo' -delete
        [[ -f $DESTMNT/etc/NetworkManager/NetworkManager.conf ]] && \
            echo -e '[main]\nplugins=ifcfg-rh' > $DESTMNT/etc/NetworkManager/NetworkManager.conf
        for RDLISTA in $DESTMNT/boot/initramfs*; do
            # initramfs genérico (--no-hostonly), não precisa ser recriado
            [[ ${RDLISTA##*/} =~ rescue ]] && continue
            KVER=$(sed 's/^initramfs-//;s/\.img$//' <<< ${RDLISTA##*/})
            [[ -d $DESTMNT/usr/lib/modules/${KVER:-xyz} ]] && \
                chroot $DESTMNT dracut --verbose --force /boot/${RDLISTA##*/} $KVER
        done
    ;;
    opensuse)
        find $DESTMNT/etc/sysconfig/network -type f -name 'ifcfg-*' -a -not -name 'ifcfg-lo' -delete
        [[ -f $DESTMNT/etc/NetworkManager/NetworkManager.conf ]] && \
            echo -e '[main]\nplugins=ifcfg-suse,keyfile' > $DESTMNT/etc/NetworkManager/NetworkManager.conf
        # no openSUSE 13.2+, mkinitrd é um shell script que chama o dracut com os parâmetros adequados
        chroot $DESTMNT mkinitrd -B
    ;;
    debian)
        rm -f $DESTMNT/etc/network/interfaces.d/*
        [[ -f $DESTMNT/etc/NetworkManager/NetworkManager.conf ]] && \
            echo -e '[main]\nplugins=ifupdown,keyfile\n\n[ifupdown]\nmanaged=false' \
                > $DESTMNT/etc/NetworkManager/NetworkManager.conf
        chroot $DESTMNT update-initramfs -u -k all
    ;;
    ubuntu)
        rm -f $DESTMNT/etc/network/interfaces.d/*
        [[ -f $DESTMNT/etc/NetworkManager/NetworkManager.conf ]] && \
            echo -e '[main]\nplugins=ifupdown,keyfile,ofono\ndns=dnsmasq\n\n[ifupdown]\nmanaged=false' \
                > $DESTMNT/etc/NetworkManager/NetworkManager.conf
        chroot $DESTMNT update-initramfs -u -k all
    ;;
    arch)
        if [[ -f $DESTMNT/etc/NetworkManager/NetworkManager.conf ]]; then
            # no Arch, nada de tralhas (resolvconf, netconfig)
            echo -e '[main]\nplugins=keyfile\nrc-manager=symlink' \
                > $DESTMNT/etc/NetworkManager/NetworkManager.conf
            rm -f $DESTMNT/etc/resolv.conf.bak
        fi
        chroot $DESTMNT mkinitcpio -p linux
    ;;
esac

echo
echo "Instalando GRUB..."
if [[ $ID == debian || $ID == ubuntu || $ID == arch ]]; then
    [[ $MUDAUUID ]] && chroot $DESTMNT grub-mkconfig -o /boot/grub/grub.cfg
    chroot $DESTMNT grub-install --recheck --no-floppy $DEV
else
    [[ $MUDAUUID ]] && chroot $DESTMNT grub2-mkconfig -o /boot/grub2/grub.cfg
    chroot $DESTMNT grub2-install --recheck --no-floppy $DEV
fi

echo
echo "Desmontando tudo..."
# util-linux >= 2.23
umount -Rv $DESTMNT || mostraerro "Falha ao desmontar."
rmdir $DESTMNT

reboot
