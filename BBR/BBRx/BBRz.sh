#!/bin/bash
echo "----BBRz Install----"
sleep 10s
## Installing BBR
# systemd oneshot service starts with no HOME set; anchor it before the HOME-based paths below
HOME="${HOME:-/root}"
cd $HOME

## This part of the script is modified from https://github.com/KozakaiAya/TCP_BBR
#Install dkms if not installed
if [ ! -x /usr/sbin/dkms ]; then
	apt-get -y install dkms
    if [ ! -x /usr/sbin/dkms ]; then
		echo "Error: dkms is not installed" >&2
		exit 1
	fi
fi

if dkms status | grep -q "bbrz/"; then
	for module_ver in $(dkms status | grep "bbrz/" | awk -F, '{print $1}' | awk -F/ '{print $2}' | sort -u); do
		echo "Removing existing bbrz module version: $module_ver"
		dkms remove -m bbrz -v "$module_ver" --all
	done
fi

# Ensure header meta package is installed so headers follow kernel upgrades (always try)
arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
uname_r=$(uname -r)
if echo "$uname_r" | grep -q '\-cloud-'; then
    flavor="cloud"
else
    flavor="generic"
fi
case "$arch" in
    amd64)
        if [ "$flavor" = "cloud" ]; then
            header_meta_pkg="linux-headers-cloud-amd64"
        else
            header_meta_pkg="linux-headers-amd64"
        fi
        ;;
    arm64|aarch64)
        if [ "$flavor" = "cloud" ]; then
            header_meta_pkg="linux-headers-cloud-arm64"
        else
            header_meta_pkg="linux-headers-arm64"
        fi
        ;;
    *)
        header_meta_pkg=""
        ;;
esac
if [ -n "$header_meta_pkg" ]; then
    echo "Installing kernel headers meta package: $header_meta_pkg"
    apt-get -y install "$header_meta_pkg"
fi

#Ensure there is header file
if [ ! -f /usr/src/linux-headers-$(uname -r)/.config ]; then
    if [[ -z $(apt-cache search linux-headers-$(uname -r)) ]]; then
        echo "Error: linux-headers-$(uname -r) not found" >&2
        exit 1
    fi
    echo "Installing specific kernel headers: linux-headers-$(uname -r)"
    apt-get -y install linux-headers-$(uname -r)
    if [ ! -f /usr/src/linux-headers-$(uname -r)/.config ]; then
        echo "Error: linux-headers-$(uname -r) is not installed" >&2
        exit 1
    fi
fi

#bbrz
if [ ! -r /etc/os-release ]; then
    echo "Error: Unsupported OS, /etc/os-release not found" >&2
    exit 1
fi

. /etc/os-release
case "$ID:${VERSION_ID%%.*}" in
    debian:12)
        bbrz_source_url="https://raw.githubusercontent.com/SAGIRIxr/Seedbox-Components/main/BBR/BBRx/tcp_bbrz.c"
        ;;
    debian:13)
        bbrz_source_url="https://raw.githubusercontent.com/SAGIRIxr/Seedbox-Components/main/BBR/BBRx/tcp_bbrz_debian13.c"
        ;;
    *)
        echo "Error: Unsupported OS, only Debian 12 and Debian 13 are supported" >&2
        exit 1
        ;;
esac
wget -O $HOME/tcp_bbrz.c "$bbrz_source_url"
if [ ! -f $HOME/tcp_bbrz.c ]; then
	echo "Error: Download failed! Exiting." >&2
	exit 1
fi
# DKMS 模块版本（与内核无关）。建议固定或使用日期字符串
module_ver=1.0.0
algo=bbrz

# Compile and install
bbr_file=tcp_$algo
bbr_src=$bbr_file.c
bbr_obj=$bbr_file.o

mkdir -p $HOME/.bbr/src
cd $HOME/.bbr/src

mv $HOME/$bbr_src $HOME/.bbr/src/$bbr_src

# Create Makefile（仅声明需要构建的目标，具体内核构建目录交由 dkms.conf 传入）
cat > ./Makefile << EOF
obj-m:=$bbr_obj
EOF

# Create dkms.conf（使用 dkms 注入的 kernel_source_dir/ dkms_tree 等变量，确保针对目标内核构建）
cd ..
cat > ./dkms.conf << EOF
PACKAGE_NAME=$algo
PACKAGE_VERSION=$module_ver
MAKE="make -C \${kernel_source_dir} M=\${dkms_tree}/$algo/$module_ver/build/src modules"
CLEAN="make -C \${kernel_source_dir} M=\${dkms_tree}/$algo/$module_ver/build/src clean"
BUILT_MODULE_NAME=$bbr_file
BUILT_MODULE_LOCATION=src/
DEST_MODULE_LOCATION=/updates/net/ipv4
AUTOINSTALL=yes
EOF

# Start dkms install
cp -R . /usr/src/$algo-$module_ver

dkms add -m $algo -v $module_ver
if [ ! $? -eq 0 ]; then
    sed -i '/tcp_bbrz/d' /etc/modules
    dkms remove -m $algo/$module_ver --all
    exit 1
fi

dkms build -m $algo -v $module_ver
if [ ! $? -eq 0 ]; then
    sed -i '/tcp_bbrz/d' /etc/modules
    dkms remove -m $algo/$module_ver --all
    exit 1
fi

dkms install -m $algo -v $module_ver
if [ ! $? -eq 0 ]; then
    sed -i '/tcp_bbrz/d' /etc/modules
    dkms remove -m $algo/$module_ver --all
    exit 1
fi

# --- Build the module for every other installed kernel ----------------------
# The apt calls earlier in this script ("apt-get install dkms" and the
# linux-headers meta package) frequently pull in a kernel NEWER than the one
# currently running.  DKMS' autoinstall hook for that new kernel has already
# run by then -- before this module was registered with DKMS -- so the module
# never gets built for it.  Since this script reboots at the end, the machine
# comes back up on that newer kernel with no tcp_bbrz.ko present, the
# net.ipv4.tcp_congestion_control sysctl fails to apply, and the kernel
# silently falls back to cubic.  Building for every installed kernel that has
# headers available makes the reboot safe whichever kernel GRUB selects.
for _kbuild in /lib/modules/*/build; do
    [ -e "$_kbuild" ] || continue          # dangling symlink => headers not installed
    _kver=$(basename "$(dirname "$_kbuild")")
    if [ "$_kver" = "$(uname -r)" ]; then
        continue                           # already handled by the dkms install above
    fi
    if find "/lib/modules/$_kver" -name "$bbr_file.ko*" -print -quit 2>/dev/null | grep -q .; then
        continue                           # already built for this kernel
    fi
    echo "Building $algo for additional installed kernel: $_kver"
    if ! dkms install -m $algo -v $module_ver -k "$_kver"; then
        echo "Warning: could not build $algo for $_kver; booting that kernel will fall back to the default congestion control" >&2
    fi
done
unset _kbuild _kver

# Report which kernels ended up with the module, so a wrong result is visible
# in the install log instead of only showing up after the reboot.
_built=""
for _kdir in /lib/modules/*/; do
    _k=$(basename "$_kdir")
    if find "$_kdir" -name "$bbr_file.ko*" -print -quit 2>/dev/null | grep -q .; then
        _built="$_built $_k"
    fi
done
echo "$algo module is installed for kernel(s):$_built"
unset _kdir _k _built
# ---------------------------------------------------------------------------

# Test loading module
modprobe $bbr_file
if [ ! $? -eq 0 ]; then
    exit 1
fi

# Auto-load kernel module at system startup
sed -i '/tcp_bbrz/d' /etc/modules
echo $bbr_file | tee -a /etc/modules

sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control = $algo" >> /etc/sysctl.conf
sysctl -p > /dev/null

cd $HOME
rm -r $HOME/.bbr

## Clear
systemctl disable bbrinstall.service > /dev/null 2>&1
rm /etc/systemd/system/bbrinstall.service > /dev/null 2>&1
rm /root/BBRz.sh > /dev/null 2>&1
shutdown -r +1
