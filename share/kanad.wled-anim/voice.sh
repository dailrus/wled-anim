#!/bin/sh
# Голосовое управление: следит за распознанными фразами Алисы в логе maind
# ("recognizedPhrase='...'") и переключает output в settings.
#   «Алиса, включи светомузыку»  — вернуть прежний вывод (по умолчанию wled)
#   «Алиса, отключи светомузыку» — output=off (лента не трогается)
# Запускается и останавливается командой wled_anim (bin/wled_anim).
D=${WLED_ANIM_VAR:-/data/yam/var/wled_anim}
S=$D/settings
LOG=/data/quasar/daemons_logs/maind.log

cur_output() { sed -n 's/^output=//p' $S; }

set_output() {
  [ "$(cur_output)" = "$1" ] && return
  sed -i "s/^output=.*/output=$1/" $S
  echo "$(date '+%F %T') voice: output=$1" >>/tmp/wled_anim.log
}

tail -n 0 -F $LOG 2>/dev/null | while read -r line; do
  case "$line" in *recognizedPhrase=*) ;; *) continue ;; esac
  p=${line##*recognizedPhrase=\'}; p=${p%%\'*}
  case "$p" in *Светомузык*|*светомузык*) ;; *) continue ;; esac
  case "$p" in
    *ыключ*|*тключ*|*убер*|*Убер*|*хватит*|*Хватит*)
      o=$(cur_output); [ "$o" = off ] || echo "$o" >$D/output_on
      set_output off ;;
    *ключ*|*апусти*)
      o=$(cat $D/output_on 2>/dev/null); set_output "${o:-wled}" ;;
  esac
done
