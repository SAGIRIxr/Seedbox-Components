#!/bin/bash
echo "----BBRx Install----"
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

if dkms status | grep -q "bbrx/"; then
	for module_ver in $(dkms status | grep "bbrx/" | awk -F, '{print $1}' | awk -F/ '{print $2}' | sort -u); do
		echo "Removing existing bbrx module version: $module_ver"
		dkms remove -m bbrx -v "$module_ver" --all
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

#BBRx
wget https://raw.githubusercontent.com/SAGIRIxr/Seedbox-Components/main/BBR/BBRx/tcp_bbrx.c
if [ ! -f $HOME/tcp_bbrx.c ]; then
	echo "Error: Download failed! Exiting." >&2
	exit 1
fi
# DKMS 模块版本（与内核无关）
module_ver=1.0.0
algo=bbrx

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

    # Create dkms.conf
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
    sed -i '/tcp_bbrx/d' /etc/modules
    dkms remove -m $algo/$module_ver --all
    exit 1
fi

dkms build -m $algo -v $module_ver
if [ ! $? -eq 0 ]; then
    sed -i '/tcp_bbrx/d' /etc/modules
    dkms remove -m $algo/$module_ver --all
    exit 1
fi

dkms install -m $algo -v $module_ver
if [ ! $? -eq 0 ]; then
    sed -i '/tcp_bbrx/d' /etc/modules
    dkms remove -m $algo/$module_ver --all
    exit 1
fi

# Test loading module
modprobe $bbr_file
if [ ! $? -eq 0 ]; then
    exit 1
fi

# Auto-load kernel module at system startup
sed -i '/tcp_bbrx/d' /etc/modules
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
rm /root/BBRx.sh > /dev/null 2>&1
shutdown -r +1
