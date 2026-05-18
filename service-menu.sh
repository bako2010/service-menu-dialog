#!/bin/bash

# Prüfen, ob 'dialog' installiert ist, andernfalls Installation anbieten
if ! command -v dialog &> /dev/null; then
    echo "Das Tool 'dialog' wurde nicht gefunden."
    echo -n "Möchtest du es jetzt installieren? (sudo apt install dialog) [J/n]: "
    read -r response
    if [[ "$response" =~ ^[Nn] ]]; then
        echo "Abbruch. 'dialog' wird zwingend für dieses Skript benötigt."
        exit 1
    else
        echo "Starte Installation..."
        sudo apt update && sudo apt install -y dialog
        if [ $? -ne 0 ]; then
            echo "Fehler bei der Installation von 'dialog'. Bitte manuell installieren."
            exit 1
        fi
        echo "'dialog' wurde erfolgreich installiert!"
        sleep 1
    fi
fi

search_term=""

# Sauberer Cleanup beim Beenden
cleanup() {
    rm -f "$GLOBAL_TEMP" "$ACTION_TMP" "$SEARCH_TMP" "$USER_TMP" "$SEL_TMP" 2>/dev/null
}
trap cleanup EXIT

while true; do
    GLOBAL_TEMP=$(mktemp)
    SEL_TMP=$(mktemp)
    
    # Massen-Abfrage aller benötigten Systemd-Eigenschaften (Extrem schnell!)
    systemctl show --type=service --property=Id,LoadState,ActiveState,User,MemoryCurrent,FragmentPath --value "*" > "$GLOBAL_TEMP"

    menu_options=()
    declare -A service_map
    count=1

    # Variablen für den Parser blockweise einlesen
    while read -r id && read -r load_state && read -r active_state && read -r user && read -r mem_bytes && read -r full_path; do
        [ -z "$id" ] && continue
        [[ "$id" == *@ ]] && continue

        # Filter-Logik (Greift im Speicher)
        if [ -n "$search_term" ]; then
            if ! echo "$id" | grep -iq "$search_term"; then
                continue
            fi
        fi

        # Defaults setzen
        [ -z "$user" ] && user="root"
        [ -z "$full_path" ] && full_path="N/A"

        # Pfad-Anzeige einkürzen
        short_path=$(dirname "$full_path" 2>/dev/null | sed 's|/lib/systemd/system|/lib/sys/sys|;s|/etc/systemd/system|/etc/sys/sys|')

        # RAM Umrechnung (Byte zu MB)
        if [[ -z "$mem_bytes" || "$mem_bytes" == "[not set]" || "$mem_bytes" == "0" ]]; then
            mem_mb="0"
        else
            mem_mb=$(( mem_bytes / 1024 / 1024 ))
        fi

        # Textbeschneidung für absolute Spaltentreue
        name_trunc=$(printf "%.35s" "$id")
        path_trunc=$(printf "%.20s" "$short_path")
        user_trunc=$(printf "%.12s" "$user")

        # Formatierung für das dialog-Menü
        display_name=$(printf "%-35s | %-20s | %-12s | %-12s | %-10s | %6s MB" \
                      "$name_trunc" "$path_trunc" "$user_trunc" "$load_state" "$active_state" "$mem_mb")

        menu_options+=("$count" "$display_name")
        service_map[$count]="$id"
        ((count++))
    done < "$GLOBAL_TEMP"

    # Header und Divider
    header=$(printf " %-4s | %-35s | %-20s | %-12s | %-12s | %-10s | %-7s" "NR" "SERVICE-NAME" "PATH" "OWNER" "STATE" "ACTIVE" "RAM")
    divider=$(printf '%.s-' {1..115})
    
    legend="Written by KingKon | Modded for Speed & Auto-Install
STATE:  enabled (Auto), disabled (Manuell), static (Abhaeng.), masked (Gesperrt)
ACTIVE: active (laeuft), inactive (aus), failed (Fehler)"
    
    [ -n "$search_term" ] && title_info="[FILTER: $search_term]" || title_info="[ALLE]"

    # Dialog aufgeräumt auf Breite 125
    dialog --backtitle "Systemd Manager Pro Ultra V2 $title_info" \
           --title " Service Uebersicht " \
           --ok-label "Auswaehlen" \
           --extra-button --extra-label "Suche" \
           --cancel-label "Beenden" \
           --menu "$header\n$divider\n$legend\n$divider" 30 125 12 \
           "${menu_options[@]}" 2> "$SEL_TMP"

    exit_status=$?
    selection_raw=$(cat "$SEL_TMP")

    case $exit_status in
        1) # Beenden
            clear; echo "Beendet."; break ;;
        3) # Suche
            SEARCH_TMP=$(mktemp)
            dialog --title " Suche " --inputbox "Filter nach Service-Name:" 8 50 "$search_term" 2> "$SEARCH_TMP"
            if [ $? -eq 0 ]; then
                search_term=$(cat "$SEARCH_TMP")
            fi
            rm -f "$SEARCH_TMP"
            continue ;;
        0) # Auswählen
            [ -z "$selection_raw" ] && continue
            selection=${service_map[$selection_raw]}
            full_path_info=$(systemctl show "$selection" --property=FragmentPath --value 2>/dev/null)

            ACTION_TMP=$(mktemp)
            dialog --backtitle "Management: $selection" \
                   --title " Aktion waehlen " \
                   --menu "Voller Pfad: $full_path_info\n\nWas moechtest du tun?" 22 80 8 \
                   "Status"   "Infos anzeigen (systemctl status)" \
                   "Logs"     "Die letzten 50 Journal-Einträge" \
                   "Start"    "Dienst jetzt starten" \
                   "Stop"     "Dienst anhalten" \
                   "Enable"   "Auto-Start aktivieren" \
                   "Disable"  "Auto-Start deaktivieren" \
                   "Owner"    "Besitzer (User) via Override aendern" 2> "$ACTION_TMP"

            if [ $? -eq 0 ]; then
                action=$(cat "$ACTION_TMP")
                clear
                case $action in
                    Status) 
                        systemctl status "$selection" 
                        ;;
                    Logs)   
                        journalctl -u "$selection" -n 50 --no-hostname --no-pager
                        ;;
                    Start)  
                        echo "Starte $selection..." && sudo systemctl start "$selection" 
                        ;;
                    Stop)   
                        echo "Stoppe $selection..." && sudo systemctl stop "$selection" 
                        ;;
                    Enable) 
                        sudo systemctl enable "$selection" 
                        ;;
                    Disable) 
                        sudo systemctl disable "$selection" 
                        ;;
                    Owner)
                        USER_TMP=$(mktemp)
                        user_list=()
                        while IFS=: read -r user _ _ _ _ _ _; do 
                            user_list+=("$user" "Account")
                        done < /etc/passwd
                        
                        dialog --title " Besitzer waehlen " --menu "Neuer Owner für $selection:" 20 50 10 "${user_list[@]}" 2> "$USER_TMP"
                        if [ $? -eq 0 ]; then
                            new_user=$(cat "$USER_TMP")
                            sudo mkdir -p "/etc/systemd/system/${selection}.d"
                            echo -e "[Service]\nUser=$new_user" | sudo tee "/etc/systemd/system/${selection}.d/owner_override.conf" > /dev/null
                            sudo systemctl daemon-reload
                            echo "Besitzer erfolgreich auf '$new_user' geändert (Override aktiv)."
                        fi
                        rm -f "$USER_TMP"
                        ;;
                esac
                echo -e "\n[Drücke ENTER um zum Hauptmenü zurückzukehren]"
                read
            fi
            rm -f "$ACTION_TMP"
            ;;
    esac
    rm -f "$GLOBAL_TEMP" "$SEL_TMP"
done
