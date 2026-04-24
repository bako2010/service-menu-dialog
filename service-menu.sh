#!/bin/bash

# Pruefen, ob 'dialog' installiert ist
if ! command -v dialog &> /dev/null; then
    echo "Das Tool 'dialog' wurde nicht gefunden."
    exit 1
fi

search_term=""

while true; do
    temp_file=$(mktemp)
    
    # Filter-Logik
    if [ -n "$search_term" ]; then
        systemctl list-unit-files --type=service --no-legend | grep -i "$search_term" | awk '{print $1, $2}' > "$temp_file"
    else
        systemctl list-unit-files --type=service --no-legend | awk '{print $1, $2}' > "$temp_file"
    fi

    menu_options=()
    service_map=()
    count=1
    
    while read -r name state; do
        # Template-Units ohne Instanz ueberspringen
        if [[ "$name" == *@ ]]; then
            continue
        fi

        active_status=$(systemctl is-active "$name" 2>/dev/null)

        # User, RAM und Pfad abfragen
        properties=$(systemctl show "$name" --property=User,MemoryCurrent,FragmentPath --value 2>/dev/null)
        owner_name=$(echo "$properties" | sed -n '1p')
        mem_bytes=$(echo "$properties" | sed -n '2p')
        full_path=$(echo "$properties" | sed -n '3p')

        [ -z "$owner_name" ] && owner_name="root"
        [ -z "$full_path" ] && full_path="N/A"

        # Pfad-Anzeige (20 Zeichen)
        short_path=$(dirname "$full_path" 2>/dev/null | sed 's|/lib/systemd/system|/lib/sys/sys|;s|/etc/systemd/system|/etc/sys/sys|')

        # RAM Umrechnung
        if [[ -z "$mem_bytes" || "$mem_bytes" == "[not set]" || "$mem_bytes" == "0" ]]; then
            mem_mb="0"
        else
            mem_mb=$(( mem_bytes / 1024 / 1024 ))
        fi

        # FORMATIERUNG (Service-Name jetzt auf 35 gekuerzt)
        display_name=$(printf "%-42s     %-20s     %-12s %-18s     %-12s %6s MB" \
                      "$name" "$short_path" "$owner_name" "$state" "$active_status" "$mem_mb")

        menu_options+=("$count" "$display_name")
        service_map[$count]="$name"
        ((count++))
    done < "$temp_file"

    # Header-Anpassung (Service auf 35)
    header=$(printf " %-4s | %-35s | %-20s | %-12s | %-18s | %-12s | %-7s" "NR" "SERVICE-NAME" "PATH" "OWNER" "STATE" "ACTIVE" "RAM")
    divider=$(printf '%.s-' {1..165})
    
    legend="written by -- KingKon --
STATE:      enabled (Auto), disabled (Manuell), static (Abhaeng.), masked (Gesperrt)
ACTIVE:     active (laeuft), inactive (aus), failed (Fehler)
OWNER/RAM:  Besitzer des Dienstes | Aktueller Arbeitsspeicherverbrauch in MB"
    
    [ -n "$search_term" ] && title_info="[FILTER: $search_term]" || title_info="[ALLE]"

    # Fensterbreite auf 170 reduziert
    dialog --backtitle "Systemd Manager Pro Ultra $title_info" \
           --title " Service Uebersicht " \
           --ok-label "Auswaehlen" \
           --extra-button --extra-label "Suche" \
           --cancel-label "Beenden" \
           --menu "$header\n$divider\n$legend\n$divider" 32 170 12 \
           "${menu_options[@]}" 2> /tmp/selected_nr

    exit_status=$?
    selection_raw=$(cat /tmp/selected_nr)

    case $exit_status in
        1) rm "$temp_file" /tmp/selected_nr 2>/dev/null; clear; echo "Beendet."; break ;;
        3) dialog --title " Suche " --inputbox "Filter:" 8 50 "$search_term" 2> /tmp/search_input
           [ $? -eq 0 ] && search_term=$(cat /tmp/search_input); continue ;;
        0) 
            [ -z "$selection_raw" ] && continue
            selection=${service_map[$selection_raw]}
            full_path_info=$(systemctl show "$selection" --property=FragmentPath --value 2>/dev/null)

            dialog --backtitle "Management: $selection" \
                   --title " Aktion waehlen " \
                   --menu "Voller Pfad: $full_path_info\n\nWas moechtest du tun?" 22 95 8 \
                   "Status"   "Infos anzeigen" \
                   "Logs"     "Journal-Logs anzeigen" \
                   "Start"    "Jetzt starten" \
                   "Stop"     "Anhalten" \
                   "Enable"   "Auto-Start an" \
                   "Disable"  "Auto-Start aus" \
                   "Owner"    "Besitzer aendern" 2> /tmp/action

            if [ $? -eq 0 ]; then
                action=$(cat /tmp/action)
                clear
                case $action in
                    Status) systemctl status "$selection" ;;
                    Logs)   journalctl -u "$selection" -n 50 --no-hostname ;;
                    Start)  sudo systemctl start "$selection" ;;
                    Stop)   sudo systemctl stop "$selection" ;;
                    Enable) sudo systemctl enable "$selection" ;;
                    Disable) sudo systemctl disable "$selection" ;;
                    Owner)
                        user_list=()
                        while IFS=: read -r user _ _ _ _ _ _; do user_list+=("$user" "Account"); done < /etc/passwd
                        dialog --title " Besitzer " --menu "Neuer Owner:" 20 50 10 "${user_list[@]}" 2> /tmp/chosen_user
                        if [ $? -eq 0 ]; then
                            new_user=$(cat /tmp/chosen_user)
                            sudo mkdir -p "/etc/systemd/system/${selection}.d"
                            echo -e "[Service]\nUser=$new_user" | sudo tee "/etc/systemd/system/${selection}.d/owner_override.conf" > /dev/null
                            sudo systemctl daemon-reload
                            echo "Besitzer auf $new_user geaendert."
                        fi
                        ;;
                esac
                echo -e "\nDruecke Enter..."
                read
            fi ;;
    esac
    rm "$temp_file" /tmp/selected_nr /tmp/action /tmp/search_input /tmp/chosen_user 2>/dev/null
done
