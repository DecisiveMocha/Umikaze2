#!/bin/bash
set -x
set -e
>/root/make-kamikaze.log
exec >  >(tee -ia /root/make-kamikaze.log)
exec 2> >(tee -ia /root/make-kamikaze.log >&2)
#
# base is https://rcn-ee.com/rootfs/2018-02-09/flasher/BBB-eMMC-flasher-ubuntu-16.04.3-console-armhf-2018-02-09-2gb.img.xz
#

# TODO 2.1:
# PCA9685 in devicetree
# Make redeem dependencies built into redeem
# Remove xcb/X11 dependencies
# Add sources to clutter packages
# Slic3r support
# Edit Cura profiles
# Remove root access
# /dev/ttyGS0

# TODO 2.0:
# After boot,
# initrd img / depmod-a on new kernel.

# STAGING:
# Copy uboot files to /boot/uboot
# Restart commands on install for Redeem and Toggle
# Update to Clutter 1.26.0+dsfg-1

# DONE:
# consoleblank=0
# sgx-install after changing kernel
# Custom uboot
# redeem plugin
# Toggle plugin
# Install libyaml
# redeem starts after spidev2.1
# Adafruit lib disregard overlay (Swithed to spidev)
# cura engine
# iptables-persistent https://github.com/eliasbakken/Kamikaze2/releases/tag/v2.0.7rc1
# clear cache
# Update dogtag
# Update Redeem / Toggle
# Sync Redeem master with develop.
# Choose Toggle config

# Get the versioning information from the entries in version.d/

for f in `ls versions.d/*`
  do
    source $f
  done

# Some additional global variables
WD=/usr/src/Umikaze/
DATE=`date`

echo "**Making ${VERSION}**"

export LC_ALL=C

port_forwarding() {
	echo "** Port Forwarding **"
	# Port forwarding

	cat > /etc/iptables/rules.v4 << EOF
# Generated by iptables-save v1.6.0 on Thu May 25 03:45:33 2017
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
COMMIT
# Completed on Thu May 25 03:45:33 2017
# Generated by iptables-save v1.6.0 on Thu May 25 03:45:33 2017
*nat
:PREROUTING ACCEPT [90:20338]
:INPUT ACCEPT [83:20114]
:OUTPUT ACCEPT [164:45201]
:POSTROUTING ACCEPT [164:45201]
:vl - [0:0]
-A PREROUTING -p tcp -m tcp --dport 80 -j REDIRECT --to-ports 5000
COMMIT
# Completed on Thu May 25 03:45:33 2017
EOF
}

install_dependencies(){
	echo "** Install dependencies **"
	apt-get update
	echo "APT::Install-Recommends \"false\";" > /etc/apt/apt.conf.d/99local
	echo "APT::Install-Suggests \"false\";" >> /etc/apt/apt.conf.d/99local
	apt-get install --no-install-recommends -y \
	python-pip \
	python-setuptools \
	python-dev \
	swig \
	socat \
	libyaml-dev \
	libcogl20 \
	libclutter-1.0-0 \
	libclutter-imcontext-0.1-0 \
	libcluttergesture-0.0.2-0 \
	python-scipy \
	python-smbus \
	python-gi-cairo \
	python-numpy \
	libavahi-compat-libdnssd1 \
	libclutter-1.0-common \
	libclutter-imcontext-0.1-bin \
	libcogl-common \
	libmx-bin \
	libegl1-sgx-omap3 \
	libgles2-sgx-omap3 \
	gir1.2-mash-0.3-0 \
	gir1.2-mx-2.0 \
	screen \
	tmux \
	htop \
	unzip \
	cpufrequtils \
	f2fs-tools \
	ti-pru-cgt-installer \
	ffmpeg

	apt-get -y autoremove
	apt-get -y purge linux-image-4.9.* linux-image-4.4.*
	apt-mark hold linux-image-`uname -r`

	easy_install --upgrade pip
	pip install numpy
	pip install evdev spidev Adafruit_BBIO Adafruit-GPIO sympy docutils sh

	cd /usr/src/
	git clone --branch v5.1.0 --single-branch --depth 1 git://git.ti.com/pru-software-support-package/pru-software-support-package.git
	cd $WD

	wget https://github.com/beagleboard/am335x_pru_package/archive/master.zip
	unzip master.zip
	# install pasm PRU compiler
	mkdir /usr/include/pruss
	cd am335x_pru_package-master/
	cp pru_sw/app_loader/include/prussdrv.h /usr/include/pruss/
	cp pru_sw/app_loader/include/pruss_intc_mapping.h /usr/include/pruss
	chmod 555 /usr/include/pruss/*
	cd pru_sw/app_loader/interface
	CROSS_COMPILE= make
	cp ../lib/* /usr/lib
	ldconfig
	cd ../../utils/pasm_source/
	source linuxbuild
	cp ../pasm /usr/bin/
	chmod +x /usr/bin/pasm

	echo "GOVERNOR=\"performance\"" > /etc/default/cpufrequtils
	systemctl stop ondemand
	systemctl disable ondemand
	apt-get autoremove -y
}

install_sgx() {
	echo "** install SGX **"
	cd $WD
	tar xfv GFX_5.01.01.02_es8.x.tar.gz -C /
	cd /opt/gfxinstall/
	sed -i 's/depmod/#depmod/' sgx-install.sh
	./sgx-install.sh
	cd $WD
	cp scripts/sgx-startup.service /lib/systemd/system/
	systemctl enable sgx-startup.service
	#depmod -a `uname -r`
	#ln -s /usr/lib/libEGL.so /usr/lib/libEGL.so.1
}

create_user() {
	echo "** Create user **"
	default_groups="admin,adm,dialout,i2c,kmem,spi,cdrom,floppy,audio,dip,video,netdev,plugdev,users,systemd-journal,tisdk,weston-launch,xenomai"
	mkdir /home/octo/
	mkdir /home/octo/.octoprint
	useradd -G "${default_groups}" -s /bin/bash -m -p octo -c "OctoPrint" octo
	chown -R octo:octo /home/octo
	chown -R octo:octo /usr/local/lib/python2.7/
	chown -R octo:octo /usr/local/bin
	chmod 755 -R /usr/local/lib/python2.7/
}

install_octoprint_redeem() {
	echo "**install_octoprint_redeem**"
	cd /usr/src/
	if [ ! -d "octoprint_redeem" ]; then
		git clone --no-single-branch --depth 1 https://github.com/eliasbakken/octoprint_redeem
	fi
	cd octoprint_redeem
	python setup.py install
}

install_octoprint_toggle() {
	echo "**install_octoprint_toggle**"
	cd /usr/src
	if [ ! -d "octoprint_toggle" ]; then
		git clone --no-single-branch --depth 1 https://github.com/eliasbakken/octoprint_toggle
	fi
	cd octoprint_toggle
	python setup.py install
}

install_overlays() {
	echo "**install_overlays**"
	cd /usr/src/
	if [ ! -d "bb.org-overlays" ]; then
		git clone --no-single-branch --depth 1 https://github.com/ThatWileyGuy/bb.org-overlays
	fi
	cd bb.org-overlays
	./dtc-overlay.sh # upgrade DTC version!
	./install.sh

	for kernel in `ls /lib/modules`; do update-initramfs -u -k $kernel; done
}

install_toggle() {
    echo "** install toggle **"
    cd /usr/src
    if [ ! -d "toggle" ]; then
        git clone --no-single-branch --depth 1 https://github.com/intelligent-agent/toggle
    fi
	cd toggle
	python setup.py clean install
	# Make it writable for updates
	cp -r configs /etc/toggle
	chown -R octo:octo /usr/src/toggle/
	cp systemd/toggle.service /lib/systemd/system/
	systemctl enable toggle
	chown -R octo:octo /etc/toggle/
}

install_cura() {
	echo "** install Cura **"
	cd /usr/src/
	if [ ! -d "CuraEngine" ]; then
		wget https://github.com/Ultimaker/CuraEngine/archive/15.04.6.zip
		unzip 15.04.6.zip
		rm 15.04.6.zip
	fi
	cd CuraEngine-15.04.6/
	# Do perimeters first
	sed -i "s/SETTING(perimeterBeforeInfill, 0);/SETTING(perimeterBeforeInfill, 1);/" src/settings.cpp
	make
	cp build/CuraEngine /usr/bin/

	# Copy profiles into Cura.
	cd $WD
	mkdir -p /home/octo/.octoprint/slicingProfiles/cura/
	cp ./Cura/profiles/*.profile /home/octo/.octoprint/slicingProfiles/cura/
	chown octo:octo /home/octo/.octoprint/slicingProfiles/cura/
}

install_slic3r() {
	echo "** install Slic3r **"
	cd /usr/src
	if [ ! -d "Slic3r" ]; then
		git clone --no-single-branch --depth 1 https://github.com/alexrj/Slic3r.git
		sudo apt install -y --no-install-recommends build-essential libgtk2.0-dev libwxgtk3.0-dev libwx-perl libmodule-build-perl git cpanminus libextutils-cppguess-perl libboost-all-dev libxmu-dev liblocal-lib-perl wx-common libopengl-perl libwx-glcanvas-perl libtbb-dev
		sudo apt-get install -y --no-install-recommends libboost-thread-dev libboost-system-dev libboost-filesystem-dev
		sudo apt-get install -y --no-install-recommends libxmu-dev freeglut3-dev libwxgtk-media3.0-dev
	fi
	cd Slic3r
	LDLOADLIBS=-lstdc++ perl Build.PL
	chmod +x slic3r.pl
	ln -s slic3r.pl /usr/local/bin/
}

install_uboot() {
	echo "** install U-boot**"
	cd $WD
	export DISK=/dev/mmcblk0
	dd if=./u-boot/MLO of=${DISK} count=1 seek=1 bs=128k
	dd if=./u-boot/u-boot.img of=${DISK} count=2 seek=1 bs=384k
	cp ./u-boot/MLO /boot/uboot/
	cp ./u-boot/u-boot.img /boot/uboot/
}

other() {
	echo "** Performing general actions **"
	sed -i "s/cape_universal=enable/consoleblank=0 fbcon=rotate:1 omap_wdt.nowayout=0/" /boot/uEnv.txt
	sed -i "s/arm/kamikaze/" /etc/hostname
	sed -i "s/arm/kamikaze/g" /etc/hosts
	sed -i "s/AcceptEnv LANG LC_*/#AcceptEnv LANG LC_*/"  /etc/ssh/sshd_config
	echo "** Set Root password to $ROOTPASS **"
	echo "root:$ROOTPASS" | chpasswd
	chown -R octo:octo $WD

	apt-get clean
	apt-get autoclean
	rm -rf /var/cache/doc*
	apt-get -y autoremove
	echo "$VERSION $DATE" > /etc/dogtag
	echo "KERNEL==\"uinput\", GROUP=\"wheel\", MODE:=\"0660\"" > /etc/udev/rules.d/80-lcd-screen.rules
	echo "SYSFS{idVendor}==\"0eef\", SYSFS{idProduct}==\"0001\", KERNEL==\"event*\",SYMLINK+=\"input/touchscreen_eGalaxy3\"" >> /etc/udev/rules.d/80-lcd-screen.rules
	date=$(date +"%d-%m-%Y")
	echo "$VERSION $date" > /etc/kamikaze-release
}

install_usbreset() {
	echo "** Installing usbreset **"
	cd $WD
	cc usbreset.c -o usbreset
	chmod +x usbreset
	mv usbreset /usr/local/sbin/
}

install_smbd() {
	echo "** Installing samba **"
	apt-get -y install --no-install-recommends samba
	cat > /etc/samba/smb.conf <<EOF
	dns proxy = no
	log file = /var/log/samba/log.%m
	syslog = 0
	panic action = /usr/share/samba/panic-action %d
	server role = standalone server
	passdb backend = tdbsam
	obey pam restrictions = yes
	unix password sync = yes
	passwd program = /usr/bin/passwd %u
	passwd chat = *Enter\snew\s*\spassword:* %n\n *Retype\snew\s*\spassword:* %n\n *password\supdated\ssuccessfully* .
	pam password change = yes
	map to guest = bad user
	usershare allow guests = yes

	[homes]
		comment = Home Directories
		browseable = no
		read only = no
		create mask = 0777
		directory mask = 0777
		valid users = %S

	[printers]
		comment = All Printers
		browseable = no
		path = /var/spool/samba
		printable = yes
		guest ok = no
		read only = yes
		create mask = 0700

	[print$]
		comment = Printer Drivers
		path = /var/lib/samba/printers
		browseable = yes
		read only = yes
		guest ok = no
	[public]
		path = /usr/share/models
		public = yes
		writable = yes
		comment = smb share
		printable = no
		guest ok = yes
		locking = no
EOF
	systemctl enable smbd
	systemctl start smbd
}

install_dummy_logging() {
	echo "** Install dummy logging **"
	apt-get install -y --no-install-recommends rungetty
	useradd -m dummy
	usermod -a -G systemd-journal dummy
	echo "clear" >> /home/dummy/.profile
	echo "journalctl -f" >> /home/dummy/.profile
	text="ExecStart=-/sbin/getty -a dummy 115200 %I"
	sed -i "/.*ExecStart*./ c $text" /etc/systemd/system/getty.target.wants/getty@tty1.service
}

install_mjpgstreamer() {
	echo "** Install mjpgstreamer **"
	apt-get install -y --no-install-recommends cmake libjpeg62-dev
	cd /usr/src/
	git clone --no-single-branch --depth 1 https://github.com/jacksonliam/mjpg-streamer
	cd mjpg-streamer/mjpg-streamer-experimental
	sed -i "s:add_subdirectory(plugins/input_raspicam):#add_subdirectory(plugins/input_raspicam):" CMakeLists.txt
	make
	make install
	echo "KERNEL==\"video0\", TAG+=\"systemd\"" > /etc/udev/rules.d/50-video.rules
	cat > /lib/systemd/system/mjpg.service << EOL
[Unit]
 Description=Mjpg streamer
 Wants=dev-video0.device
 After=dev-video0.device

[Service]
 ExecStart=/usr/local/bin/mjpg_streamer -i "/usr/local/lib/mjpg-streamer/input_uvc.so" -o "/usr/local/lib/mjpg-streamer/output_http.so"

[Install]
 WantedBy=basic.target
EOL
	systemctl enable mjpg.service
	systemctl start mjpg.service
}

rename_ssh() {
	echo "** Update SSH message **"
	cat > /etc/issue.net << EOL
$VERSION
rcn-ee.net console Ubuntu Image 2017-01-13

Check that nothing is printing before any CPU/disk intensive operations!
EOL
	rm /etc/issue
	ln -s /etc/issue.net /etc/issue
}

cleanup() {
	cd $WD
	userdel ubuntu
	chage -d 0 root
    rm -r /var/cache/*
    rm GFX_5.01.01.02_es8.x.tar.gz
	rm -r /usr/src/pru-software-support-package/examples /usr/src/pru-software-support-package/labs
	rm -r /opt/gfxsdkdemos/ /opt/source/
	sed -i 's\	*.=notice;*.=warn	|/dev/xconsole\	*.=notice;*.=warn\' /etc/rsyslog.d/50-default.conf
}

prepare_flasher() {
	cp functions.sh init-eMMC-flasher-v3.sh /opt/scripts/tools/eMMC/
	sed -i 's/#cmdline=/cmdline=/' /boot/uEnv.txt
	sed -i 's/#enable_/enable_/' /boot/uEnv.txt
}

construct_distribution() {
	port_forwarding
	install_dependencies
#   install_sgx
	create_user

    source Redeem/build_script_functions.sh
	install_redeem

    source OctoPrint/build_script_functions.sh
	install_octoprint

	install_octoprint_redeem
	install_octoprint_toggle
	install_overlays
	install_toggle
#	install_cura
#	install_slic3r
#   install_uboot
	other
	install_usbreset
	install_smbd
	install_dummy_logging
	install_mjpgstreamer
	rename_ssh
	cleanup
	prepare_flasher
}

construct_distribution

echo "Now reboot!"
