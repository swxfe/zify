#!/bin/sh
set -eu
umask 077

[ "$#" -eq 0 ] || { printf '%s\n' 'Запустите установщик без аргументов.' >&2; exit 2; }
[ "$(id -u)" = 0 ] && [ -f /etc/openwrt_release ] || {
    printf '%s\n' 'Установщик предназначен для OpenWrt. Запустите его от root по SSH.' >&2
    exit 1
}

# ---- dependency setup ----
append_dependency() {
    case " $missing " in *" $1 "*) ;; *) missing="${missing:+$missing }$1";; esac
}
check_install_space() {
    target_dir=/overlay
    [ -d "$target_dir" ] || target_dir=/
    available=$(df -Pk "$target_dir" | awk 'NR==2 {print $4}')
    case "$available" in ''|*[!0-9]*) printf '%s\n' 'Не удалось проверить свободное место.' >&2; return 1;; esac
    [ "$available" -ge "$1" ] || { printf '%s\n' 'Недостаточно места и безопасного резерва Flash.' >&2; return 1; }
}
ensure_dependencies() {
    missing=''
    for command in curl unzip uci tar; do
        if ! command -v "$command" >/dev/null 2>&1; then append_dependency "$command"; fi
    done
    if ! command -v stty >/dev/null 2>&1; then append_dependency coreutils-stty; fi
    if ! command -v ucode >/dev/null 2>&1; then append_dependency ucode; fi
    for module in fs uci ubus digest uclient uloop; do
        if ! ucode -S -e "import * as required from '$module';" >/dev/null 2>&1; then append_dependency "ucode-mod-$module"; fi
    done
    if [ ! -s /etc/ssl/certs/ca-certificates.crt ]; then append_dependency ca-bundle; fi
    [ -n "$missing" ] || return 0
    check_install_space 5120
    # These names are assembled only from fixed command and module names above.
    # shellcheck disable=SC2086
    set -- $missing
    if command -v apk >/dev/null 2>&1; then
        dependency_manager=apk
        mkdir -p "$work/apk-cache"
        apk --cache-dir "$work/apk-cache" --no-logfile update
        apk --cache-dir "$work/apk-cache" --no-logfile query --recursive --fields name,version,installed-size,file-size "$@" > "$work/dependency-info"
    elif command -v opkg >/dev/null 2>&1; then
        dependency_manager=opkg
        mkdir -p "$work/opkg-lists"
        opkg --lists-dir "$work/opkg-lists" update
        opkg --lists-dir "$work/opkg-lists" --noaction install "$@" > "$work/dependency-solver"
        awk '$1 ~ /^(Installing|Upgrading|Downgrading)$/ && $2 ~ /^[A-Za-z0-9_+.-]+$/ {print $2}' "$work/dependency-solver" > "$work/dependency-names"
        [ -s "$work/dependency-names" ] || { printf '%s\n' 'Не удалось определить зависимости opkg.' >&2; return 1; }
        : > "$work/dependency-info"
        while IFS= read -r dependency; do
            opkg --lists-dir "$work/opkg-lists" info "$dependency" >> "$work/dependency-info"
        done < "$work/dependency-names"
    else
        printf '%s\n' 'Не найден пакетный менеджер apk/opkg.' >&2
        return 1
    fi
    # Both managers expose byte sizes. Unknown or malformed sizes abort before consent/install.
    awk '
        BEGIN {RS=""; FS="\n"}
        {name=""; version=""; installed=""; download="";
         for(i=1;i<=NF;i++) {
             if($i ~ /^(Name|Package): /) {name=$i; sub(/^[^:]+: /,"",name)}
             if($i ~ /^Version: [^[:space:]]+$/) {version=$i; sub(/^[^:]+: /,"",version)}
             if($i ~ /^Installed-Size: [0-9]+$/) {installed=$i; sub(/^[^:]+: /,"",installed)}
             if($i ~ /^(File-Size|Size): [0-9]+$/) {download=$i; sub(/^[^:]+: /,"",download)}
         }
         if(name !~ /^[A-Za-z0-9_+.-]+$/ || version=="" || installed=="" || download=="") exit 1;
         if(!seen[name]++) order[++count]=name;
         if(installed+0>installed_max[name]+0) installed_max[name]=installed;
         if(download+0>download_max[name]+0) download_max[name]=download;
         versions[name]=version}
        END {if(!count) exit 1; for(i=1;i<=count;i++) {name=order[i]; print name,installed_max[name]+0,download_max[name]+0,versions[name]}}
    ' "$work/dependency-info" > "$work/dependency-records" || {
        printf '%s\n' 'Не удалось проверить размеры зависимостей.' >&2; return 1;
    }
    : > "$work/dependency-plan"
    while read -r dependency installed download_bytes dependency_version; do
        if [ "$dependency_manager" = apk ]; then
            if apk info -e "$dependency=$dependency_version" >/dev/null 2>&1; then continue; fi
        fi
        printf '%s %s %s\n' "$dependency" "$installed" "$download_bytes" >> "$work/dependency-plan"
    done < "$work/dependency-records"
    [ -s "$work/dependency-plan" ] || { printf '%s\n' 'Зависимости установлены, но недоступны; проверьте PATH и пакеты.' >&2; return 1; }
    dependency_kb=$(awk '{sum+=($2>$3?$2:$3)} END {printf "%.0f",int((sum+1023)/1024)}' "$work/dependency-plan")
    required=$((dependency_kb * 2 + 5120))
    check_install_space "$required"
    printf '%s\n' 'Для интерфейса и работы zify нужны пакеты:'
    awk '{printf "  %s — %.1f KiB\n",$1,$2/1024; size+=$2; download+=$3} END {printf "Загрузка: %.1f KiB; место после установки: %.1f KiB.\n",download/1024,size/1024}' "$work/dependency-plan"
    printf 'Свободно: %s KiB; требуется с резервом: %s KiB.\n' "$available" "$required"
    printf 'Установить зависимости? [y/N] '
    IFS= read -r answer || answer=''
    case "$answer" in y|Y|yes|YES|д|Д|да|ДА) ;; *) printf '%s\n' 'Установка отменена.'; exit 1;; esac
    # Recheck immediately before invoking the package manager.
    check_install_space "$required"
    if [ "$dependency_manager" = apk ]; then apk --cache-dir "$work/apk-cache" --no-logfile add "$@"
    else opkg --lists-dir "$work/opkg-lists" install "$@"; fi
    check_install_space 5120
    for command in curl unzip uci tar stty; do command -v "$command" >/dev/null 2>&1 || return 1; done
    ucode -S -e 'import * as fs from "fs"; import * as uci from "uci"; import * as ubus from "ubus"; import * as digest from "digest"; import * as uclient from "uclient"; import * as uloop from "uloop";' >/dev/null 2>&1 || {
        printf '%s\n' 'Зависимости интерфейса недоступны после установки.' >&2; return 1;
    }
}
# ---- end dependency setup ----

work=$(mktemp -d /tmp/zify-install.XXXXXX)
trap 'rm -rf -- "$work"' 0
trap 'exit 130' INT
trap 'exit 143' TERM HUP
ensure_dependencies
download() {
    curl --fail --silent --show-error --location --max-redirs 3 --proto '=https' --proto-redir '=https' \
        --connect-timeout 10 --max-time 120 --max-filesize "$3" --output "$2" "$1"
}
target_dir=/overlay
[ -d "$target_dir" ] || target_dir=/
available=$(df -Pk "$target_dir" | awk 'NR==2 {print $4}')
case "$available" in ''|*[!0-9]*) printf '%s\n' 'Не удалось проверить свободное место.' >&2; exit 1;; esac
[ "$available" -ge 5120 ] || { printf '%s\n' 'Недостаточно свободного места: требуется резерв 5120 KB.' >&2; exit 1; }
# A commit SHA keeps the code and resource archive from different revisions apart.
download https://api.github.com/repos/swxfe/zify/git/ref/heads/main "$work/revision.json" 65536
revision=$(ucode -S -e 'import * as fs from "fs"; let ref=json(fs.readfile(ARGV[0])); let sha=ref.object?.sha; if(ref.ref!="refs/heads/main" || ref.object?.type!="commit" || type(sha)!="string" || !match(sha,/^[a-f0-9]{40}$/)) exit(1); print(sha);' "$work/revision.json")
base=https://raw.githubusercontent.com/swxfe/zify/$revision/dist
# The immutable release index describes the exact code/resource pair.
download "$base/release.json" "$work/release.json" 65536
ucode -S -e '
    import * as fs from "fs";
    let data=json(fs.readfile(ARGV[0]));
    if(data.format!=1 || data.bundle_format!=2 || type(data.version)!="string" ||
       !match(data.version,/^[0-9]+\.[0-9]+(\.[0-9]+)?$/)) exit(1);
    for(let kind in ["code","assets"]) {
        let entry=data[kind], path=kind=="code"?"dist/zify.sh":"dist/zify-assets.tar.gz";
        if(type(entry)!="object" || entry.path!=path || type(entry.size)!="int" || entry.size<1 ||
           entry.size>(kind=="code"?2097152:8388608) || type(entry.sha256)!="string" ||
           !match(entry.sha256,/^[a-f0-9]{64}$/)) exit(1);
    }
    printf("%d %s %d %s\n",data.code.size,data.code.sha256,data.assets.size,data.assets.sha256);
' "$work/release.json" > "$work/release-plan"
read -r code_size code_sha asset_size asset_sha < "$work/release-plan"
required=$(( ((code_size + asset_size + 1023) / 1024) * 2 + 5120 ))
[ "$available" -ge "$required" ] || { printf '%s\n' 'Недостаточно места для zify, ассетов и резерва Flash.' >&2; exit 1; }
download "$base/zify.sh" "$work/manager.sh" 2097152
download "$base/zify-assets.tar.gz" "$work/zify-assets.tar.gz" 8388608
[ "$(wc -c < "$work/manager.sh")" -eq "$code_size" ]
[ "$(wc -c < "$work/zify-assets.tar.gz")" -eq "$asset_size" ]
printf '%s  %s\n%s  %s\n' "$code_sha" "$work/manager.sh" "$asset_sha" "$work/zify-assets.tar.gz" > "$work/SHA256SUMS"
sha256sum -c "$work/SHA256SUMS"
sh -n "$work/manager.sh"
# Expanded-size preflight and validation run before any managed asset is written.
sh "$work/manager.sh" --yes manager-install "$work/zify-assets.tar.gz"
rm -rf -- "$work"
trap - 0 INT TERM HUP
if [ -t 0 ]; then exec /usr/bin/zify; fi
exec /usr/bin/zify --version
