#!/bin/bash

set -ex

top_dir=$(cd `dirname $0`; cd ..; pwd)
version=$1 # branch or tag
build_dir=$(cd /root/$2 && pwd)

out=${build_dir}/out/release/${version}/CentOS/netboot
distro_dir=${build_dir}/tmp/centos
workspace=${distro_dir}/installer
out_installer=${workspace}/out
source_url=${CENTOS_ESTUARY_REPO:-"http://repo.estuarydev.org/releases/5.1/centos"}
base_url=${CENTOS_MIRROR:-"http://mirror.centos.org/altarch/7/os/aarch64/"}

rm -rf ${workspace}
mkdir -p ${workspace} && cd ${workspace}
mkdir -p centos-installer

wget -O /etc/yum.repos.d/estuary.repo https://raw.githubusercontent.com/open-estuary/distro-repo/master/estuaryftp.repo
chmod +r /etc/yum.repos.d/estuary.repo
rpm --import http://repo.estuarydev.org/releases/ESTUARY-GPG-KEY
yum remove -y epel-release
yum makecache fast
sudo yum install -y yum-plugin-ovl
sudo yum install -y cpio lorax python-requests wget xz createrepo
seq 0 7 | xargs -I {} mknod -m 660 /dev/loop{} b 7 {} || true
chgrp disk /dev/loop[0-7]

# Call lorax to create the netinstall image
cd centos-installer
sudo rm -rf netinstall
sudo lorax '--product=CentOS Linux' --version=7 --release=7.4.1708 \
  --source=${base_url} \
  --source=${source_url}  \
  --isfinal --nomacboot --noupgrade --buildarch=aarch64 '--volid=CentOS 7 aarch64' netinstall/

# Modify initrd to include a default kickstart (that includes the external repository)
cd netinstall/images/pxeboot/
sudo mkdir initrd; cd initrd
sudo sh -c 'xzcat ../initrd.img | cpio -d -i -m'
cat > /tmp/ks.cfg << EOF
url --url="http://mirror.centos.org/altarch/7/os/aarch64/"
repo --name="estuary" --baseurl=${source_url}
repo --name="extras" --baseurl="http://mirror.centos.org/altarch/7/extras/aarch64/"
network  --bootproto=dhcp --device=eth0 --ipv6=auto --no-activate
text

%packages
bash-completion
epel-release
wget
%end

%post --interpreter=/bin/bash
wget -T 120 -c -O /etc/yum.repos.d/estuary.repo https://raw.githubusercontent.com/open-estuary/distro-repo/master/estuaryftp.repo
chmod +r /etc/yum.repos.d/estuary.repo
rpm --import http://repo.estuarydev.org/releases/ESTUARY-GPG-KEY
wget -T 120 -c http://repo.linaro.org/rpm/linaro-overlay/centos-7/linaro-overlay.repo -O /etc/yum.repos.d/linaro-overlay.repo
yum clean dbcache
%end
EOF
sudo cp /tmp/ks.cfg ks.cfg
sed '1,3d' ks.cfg > ks-iso.cfg

sudo sh -c 'find . | cpio -o -H newc | xz --check=crc32 --lzma2=dict=512KiB > ../initrd.img'
cd ..; sudo rm -rf initrd

# Rebuild boot.iso
netinstall_dir=${workspace}/centos-installer/netinstall
sed -i 's/vmlinuz.*/& inst.ks=file:\/ks.cfg ip=dhcp/' ${netinstall_dir}/EFI/BOOT/grub.cfg
rm -rf ${netinstall_dir}/images/boot.iso
mkisofs -o ${netinstall_dir}/images/boot.iso -eltorito-alt-boot \
  -e images/efiboot.img -no-emul-boot -R -J -V 'CentOS 7 aarch64' -T \
  -graft-points \
  images/pxeboot=${netinstall_dir}/images/pxeboot \
  LiveOS=${netinstall_dir}/LiveOS \
  EFI/BOOT=${netinstall_dir}/EFI/BOOT \
  images/efiboot.img=${netinstall_dir}/images/efiboot.img

# Final preparation for publishing
mkdir -p ${out_installer} && mkdir -p ${out}
cd ${workspace}/centos-installer
cp -rf lorax.log netinstall/.discinfo netinstall/.treeinfo netinstall/EFI netinstall/images netinstall/LiveOS ${out_installer}
cp -rf  ${out_installer}/* ${out}
