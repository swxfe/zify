#!/bin/sh
set -eu
compound_groups() {
    zify source compose flowseal base_general youtube_general discord_general games_general
    zify config get NFQWS_OPT > "$root/opts"
    for name in base_general youtube_general discord_general games_general; do [ "$(grep -c "^#$name\$" "$root/opts")" -eq 1 ]; done
    [ "$(grep -c '^--new$' "$root/opts")" -eq 5 ]
    health
    zify source group flowseal base base_general_alt
    zify config get NFQWS_OPT > "$root/opts"
    for name in base_general_alt youtube_general discord_general games_general; do [ "$(grep -c "^#$name\$" "$root/opts")" -eq 1 ]; done
    reject grep -q '^#base_general$' "$root/opts"
    health
}
flowseal() {
    zify source list flowseal
    zify source list flowseal > "$root/flowseal-names"
    name=$(sed -n '1p' "$root/flowseal-names")
    if grep -q '^general$' "$root/flowseal-names"; then name=general; fi
    alt9=$(grep -i '^general[_ (]*alt9[_ )]*$' "$root/flowseal-names" | head -n 1)
    if [ -n "$alt9" ]; then name=$alt9; fi
    [ -n "$name" ]
    zify source apply flowseal "$name"
    zify config get NFQWS_OPT > "$root/opts"
    [ "$(grep -c '^#' "$root/opts")" -eq 1 ]
    grep -q "^#$name\$" "$root/opts"
    [ "$(zify source show flowseal "$name")" = "$(zify config get NFQWS_OPT)" ]
    health
    zify source group flowseal games games_general
    zify config get NFQWS_OPT > "$root/opts"
    grep -q "^#$name\$" "$root/opts"
    [ "$(grep -c '^#games_general$' "$root/opts")" -eq 1 ]
    health
    zify source remove flowseal games
    zify config get NFQWS_OPT > "$root/opts"
    grep -q "^#$name\$" "$root/opts"
    reject grep -q '^#games_general$' "$root/opts"
    health
}
