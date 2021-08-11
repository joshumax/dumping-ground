#!/bin/bash

# GPU init
modprobe galcore

# Chroot init
mount --bind /dev/ /mnt/data/armroot/dev
mount --bind /dev/pts /mnt/data/armroot/dev/pts
mount --bind /dev/shm /mnt/data/armroot/dev/shm
mount -t sysfs sysfs /mnt/data/armroot/sys
mount -t proc proc /mnt/data/armroot/proc
cp /etc/resolv.conf /mnt/data/armroot/etc/resolv.conf
chroot /mnt/data/armroot /etc/rc.local
