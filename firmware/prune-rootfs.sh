#!/bin/sh
# prune-rootfs.sh - take Thingino's parts lapcam does not use out of the
# firmware image. Not run by hand: firmware/prepare.sh copies it into the
# Thingino tree and names it as BR2_ROOTFS_POST_FAKEROOT_SCRIPT, so Buildroot
# runs it on the copy of the target directory the rootfs image is made from
# ($1). The target directory itself keeps everything.
#
# Why here and not in the package selection: prudynt's Config.in selects ONVIF
# and Thingino's top Config.in selects the web UI, so they cannot be switched
# off without patching Thingino's package tree.
#
# What goes (about 400 KB of the 5696 KB rootfs, which had 20 KB to spare):
#   Thingino's web UI and its server uhttpd   lapcam is the UI. Without the SD
#       card there is no lapcam (its programs are on the card) and now no web
#       page either: the camera still streams RTSP and answers ssh
#   ONVIF                                      nothing of lapcam speaks it
#   MQTT, Home Assistant, the Telegram agent   never configured by lapcam
# What stays although it looks like a part of them:
#   S48webui-config    creates /etc/thingino-api.key, which prudynt's API wants
#                      (it also writes /var/www/a/runtime-config.js: the empty
#                      directory is kept for it)
#   /usr/libexec/thingino-webui/heartbeat-lib.sh   S99heartbeat sources it
#   S02ssl             the certificate is also agentd's
#   libubox, libblobmsg_json   jshn and odhcp6c link them
#   /etc/default/uhttpd        S50mdnsd reads the ports from it
#
# Every path must exist: a Thingino base that moved them should fail the build
# here, not ship an image that silently grew back (or lost something else).

set -e
T=$1
if [ -z "$T" ] || [ ! -d "$T/etc/init.d" ] || [ ! -d "$T/var/www" ]; then
	echo "prune-rootfs.sh: '$T' is not a target directory" >&2
	exit 1
fi
cd "$T"

gone() {
	for f; do
		if [ ! -e "$f" ] && [ ! -L "$f" ]; then
			echo "prune-rootfs.sh: $f is not in the rootfs (did the Thingino base change?)" >&2
			exit 1
		fi
		rm -rf "$f"
	done
}

# the web UI and uhttpd
gone var/www
mkdir -p var/www/a
chmod 755 var/www var/www/a
gone usr/bin/uhttpd etc/init.d/S60uhttpd etc/httpd-portal.conf \
	usr/lib/libustream-ssl.so usr/lib/libjson_script.so

# ONVIF (its CGI went with /var/www)
gone usr/sbin/onvif_notify_server usr/sbin/wsd_simple_server \
	etc/init.d/S96onvif_discovery etc/init.d/S97onvif_notify etc/onvif.json

# MQTT, Home Assistant, Telegram
gone usr/bin/mosquitto_pub usr/bin/mosquitto_rr usr/bin/mosquitto_sub \
	usr/lib/libmosquitto.so usr/lib/libmosquitto.so.1 etc/mosquitto \
	etc/init.d/S91mqttsub usr/sbin/mqtt-sub-dispatcher \
	etc/init.d/S93ha usr/share/ha-common \
	usr/sbin/telegram-cam-agent usr/sbin/telegram-cam-register
ls usr/sbin/ha-* >/dev/null 2>&1 || { echo "prune-rootfs.sh: no usr/sbin/ha-* in the rootfs (did the Thingino base change?)" >&2; exit 1; }
rm -f usr/sbin/ha-*
