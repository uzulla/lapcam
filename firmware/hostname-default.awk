# hostname-default.awk - firmware/prepare.sh runs Thingino's S04hostname
# through this: in is_user_modified_hostname(), right after the current name
# is read, the name the rootfs starts with (HOSTNAME in /etc/os-release,
# ing-wyze-cam3) and a name generated from it (ing-wyze-cam3-xxxx) are taken
# for "not chosen by the user", so the script goes on to generate lapcam-xxxx.
{ print }
/^is_user_modified_hostname\(\) \{$/ { infn = 1 }
infn && /^\thostname="\$\(hostname\)"$/ {
	print ""
	print "\t# lapcam: the name the rootfs starts with (Thingino's default) and one"
	print "\t# generated from it are not names the user chose"
	print "\tos_hostname=\"$(sed -n 's/^HOSTNAME=//p' $OS_RELEASE_FILE)\""
	print "\tif [ -n \"$os_hostname\" ] && { [ \"$os_hostname\" = \"$hostname\" ] || echo \"$hostname\" | grep -i -q \"^$os_hostname-[0-9a-f]\\\\{4\\\\}$\"; }; then"
	print "\t\techo -c 142 -e \"Hostname $hostname is Thingino's default and should be generated\" >&2"
	print "\t\treturn 1"
	print "\tfi"
	infn = 0
}
