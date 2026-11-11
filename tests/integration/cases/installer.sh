#!/bin/sh
set -eu
DESTDIR=$work/image sh tools/install.sh > /dev/null
[ -f "$work/image/usr/bin/zify" ]
ucode -S -D "image=$work/image" -e '
    import * as fs from "fs";
    for (let directory in ["/opt", "/opt/zapret", "/opt/zapret/fakes"])
        assert((fs.stat(image + directory).mode & 0777) == 0755, "daemon must traverse new fake directories");
    for (let name in fs.lsdir(image + "/opt/zapret/fakes"))
        assert((fs.stat(image + "/opt/zapret/fakes/" + name).mode & 0777) == 0644, "daemon must read installed fakes");
'

uci -c "$work/image/etc/config" set zify.main.settle_seconds=1
uci -c "$work/image/etc/config" commit zify
cp "$work/image/etc/config/zify" "$work/installed-config.before"
DESTDIR=$work/image sh tools/install.sh > /dev/null
equal_file "$work/image/etc/config/zify" "$work/installed-config.before"
DESTDIR=$work/image sh tools/install.sh uninstall
[ ! -d "$work/image/etc/zify" ]
[ ! -f "$work/image/usr/bin/zify" ]
