setenv serverip 172.16.252.252
setenv tftpblocksize 1468
setenv bootdelay 0
tftpboot 0x80000000 initramfs.itb
bootm 0x80000000
