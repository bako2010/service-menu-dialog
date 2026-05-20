#!/usr/bin/env bash
# Systemd Manager Pro Ultra V2 (by Bako2010 KingKon)
# Features: Distro-agnostic, dynamic UI, safe RAM parsing, systemctl edit, fast bash-native filter
set -o pipefail

# ─── Globale Variablen & Cleanup ───────────────────────────────────────────────
GLOBAL_TEMP="" SEL_TMP="" SEARCH_TMP="" ACTION_TMP="" USER_TMP=""
cleanup() {
    rm -f "$GLOBAL_TEMP" "$SEL_TMP" "$SEARCH_TMP" "$ACTION_TMP" "$USER_TMP" 2>/dev/null
}
trap cleanup EXIT INT TERM

# ─── Sudo/Root Erkennung ───────────────────────────────────────────────────────
SUDO=""
if [ "$EUID" -ne 0 ]; then
    SUDO="sudo"
    if ! command -v sudo &>/dev/null; then
        echo "Fehler: 'sudo' ist nicht installiert, aber für Admin-Aktionen erforderlich."
        exit 1
    fi
fi

# ─── Dialog Installation (Distro-agnostisch) ───────────────────────────────────
if ! command -v dialog &>/dev/null; then
    echo "Das Tool 'dialog' wurde nicht gefunden."
    echo -n "Möchtest du es jetzt installieren? [J/n]: "
    read -r response
    if [[ "$response" =~ ^[Nn] ]]; then
        echo "Abbruch. 'dialog' wird zwingend benötigt."
        exit 1
    fi

    echo "Erkenne Paketmanager und installiere dialog..."
    if command -v apt &>/dev/null; then
        $SUDO apt update && $SUDO apt install -y dialog
    elif command -v dnf &>/dev/null; then
        $SUDO dnf install -y dialog
    elif command -v pacman &>/dev/null; then
        $SUDO pacman -Sy --noconfirm dialog
    elif command -v zypper &>/dev/null; then
        $SUDO zypper install -y dialog
    else
        echo "Fehler: Kein unterstützter Paketmanager gefunden. Bitte 'dialog' manuell installieren."
        exit 1
    fi

    if [ $? -ne 0 ]; then
        echo "Fehler bei der Installation von 'dialog'."
        exit 1
    fi
    echo "'dialog' wurde erfolgreich installiert!"
    sleep 1
fi

search_term=""

# ─── Hauptmenü-Schleife ────────────────────────────────────────────────────────
while true; do
    GLOBAL_TEMP=$(mktemp)
    SEL_TMP=$(mktemp)
    
    # Daten holen (ohne sudo, da Lesezugriff meist ausreicht)
    systemctl show --type=service --property=Id,LoadState,ActiveState,User,MemoryCurrent,FragmentPath "*" > "$GLOBAL_TEMP" 2>/dev/null || true

    unset service_map
    declare -A service_map
    menu_options=()
    count=1

    id="" load_state="" active_state="" user="" mem_bytes="" full_path=""

    # Case-insensitive Filterung aktivieren (bash-intern, sehr schnell)
    shopt -s nocasematch

    while IFS='=' read -r key val; do
        [[ -z "$key" ]] && continue
        case "$key" in
            Id) id="$val" ;;
            LoadState) load_state="$val" ;;
            ActiveState) active_state="$val" ;;
            User) user="$val" ;;
            MemoryCurrent) mem_bytes="$val" ;;
            FragmentPath) 
                full_path="$val" 
                
                # Block verarbeiten (FragmentPath ist letzte angeforderte Property)
                if [[ -n "$id" && "$id" != *@* ]]; then
                    
                    # Filter-Logik (bash-native, keine Subshell)
                    if [[ -n "$search_term" && "$id" != *"$search_term"* ]]; then
                        id=""; continue
                    fi

                    # Defaults
                    [[ -z "$user" ]] && user="root"
                    [[ -z "$full_path" || "$full_path" == "N/A" ]] && full_path="N/A"

                    # Pfad einkürzen
                    if [[ "$full_path" != "N/A" ]]; then
                        short_path=$(dirname "$full_path" 2>/dev/null | sed 's|/lib/systemd/system|/lib/sys/sys|;s|/etc/systemd/system|/etc/sys/sys|')
                    else
                        short_path="N/A"
                    fi

                    # RAM Umrechnung mit Overflow-Schutz (Bash ist signed 64-bit)
                    if [[ "$mem_bytes" =~ ^[0-9]+$ ]]; then
                        if (( ${#mem_bytes} > 15 )); then
                            mem_mb=">10TB"
                        else
                            mem_mb=$(( mem_bytes / 1024 / 1024 ))
                        fi
                    else
                        mem_mb="0"
                    fi

                    # Spaltentreue Kürzung
                    name_trunc=$(printf "%.35s" "$id")
                    path_trunc=$(printf "%.20s" "$short_path")
                    user_trunc=$(printf "%.12s" "$user")

                    # Dialog-Formatierung
                    display_name=$(printf "%-35s | %-20s | %-12s | %-12s | %-10s | %6s MB" \
                                  "$name_trunc" "$path_trunc" "$user_trunc" "$load_state" "$active_state" "$mem_mb")

                    menu_options+=("$count" "$display_name")
                    service_map[$count]="$id"
                    ((count++))
                fi
                # Reset für nächsten Block
                id="" load_state="" active_state="" user="" mem_bytes="" full_path=""
                ;;
        esac
    done < "$GLOBAL_TEMP"
    shopt -u nocasematch

    # Fallback bei leerer Liste
    if [ ${#menu_options[@]} -eq 0 ]; then
        menu_options+=("1" "Keine Dienste gefunden (Filter prüfen)")
    fi

    # Header & Layout
    header=$(printf " %-4s | %-35s | %-20s | %-12s | %-12s | %-10s | %-7s" "NR" "SERVICE-NAME" "PATH" "OWNER" "STATE" "ACTIVE" "RAM")
    divider=$(printf '%.s-' {1..115})
    legend="Revised for Safety & Portability | STATE: enabled/disabled/static/masked | ACTIVE: active/inactive/failed"
    
    [[ -n "$search_term" ]] && title_info="[FILTER: $search_term]" || title_info="[ALLE]"

    # Dynamische Terminal-Größe
    TERM_COLS=$(tput cols 2>/dev/null || echo 120)
    TERM_LINES=$(tput lines 2>/dev/null || echo 30)
    DIALOG_WIDTH=$(( TERM_COLS > 125 ? 125 : TERM_COLS - 2 ))
    DIALOG_HEIGHT=$(( TERM_LINES > 30 ? 30 : TERM_LINES - 2 ))
    (( DIALOG_WIDTH < 80 )) && DIALOG_WIDTH=80
    (( DIALOG_HEIGHT < 20 )) && DIALOG_HEIGHT=20

    dialog --backtitle "-- Systemd -- Service Menu by KingKon(Bako2010)" \
           --title " Service Uebersicht " \
           --ok-label "Auswaehlen" \
           --extra-button --extra-label "Suche" \
           --cancel-label "Beenden" \
           --menu "$header\n$divider\n$legend\n$divider" "$DIALOG_HEIGHT" "$DIALOG_WIDTH" 12 \
           "${menu_options[@]}" 2> "$SEL_TMP"

    exit_status=$?
    selection_raw=$(cat "$SEL_TMP" 2>/dev/null)

    case $exit_status in
        1|255) # Beenden oder ESC
            clear; echo "Beendet."; break ;;
        3) # Suche
            SEARCH_TMP=$(mktemp)
            dialog --title " Suche " --inputbox "Filter nach Service-Name:" 8 50 "$search_term" 2> "$SEARCH_TMP"
            if [ $? -eq 0 ]; then
                search_term=$(cat "$SEARCH_TMP" 2>/dev/null)
            fi
            rm -f "$SEARCH_TMP"
            continue ;;
        0) # Auswahl
            [[ -z "$selection_raw" ]] && continue
            selection=${service_map[$selection_raw]:-}
            [[ -z "$selection" ]] && continue
            
            full_path_info=$(systemctl show "$selection" --property=FragmentPath --value 2>/dev/null)
            [[ -z "$full_path_info" ]] && full_path_info="N/A"

            ACTION_TMP=$(mktemp)
            dialog --backtitle "Management: $selection" \
                   --title " Aktion waehlen " \
                   --menu "Voller Pfad: $full_path_info\n\nWas moechtest du tun?" 22 80 9 \
                   "Status"   "Infos anzeigen (systemctl status)" \
                   "Logs"     "Die letzten 50 Journal-Einträge" \
                   "Edit"     "Service-Datei sicher editieren (Override)" \
                   "Start"    "Dienst jetzt starten" \
                   "Stop"     "Dienst anhalten" \
                   "Enable"   "Auto-Start aktivieren" \
                   "Disable"  "Auto-Start deaktivieren" \
                   "Owner"    "Besitzer (User) via Override aendern" 2> "$ACTION_TMP"

            if [ $? -eq 0 ]; then
                action=$(cat "$ACTION_TMP" 2>/dev/null)
                clear
                case $action in
                    Status) 
                        systemctl status "$selection" --no-pager 
                        ;;
                    Logs)   
                        journalctl -u "$selection" -n 50 --no-hostname --no-pager
                        ;;
                    Edit)
                        echo "Oeffne sicheren Override-Editor für $selection..."
                        echo "(Dein Standard-Editor wird verwendet. Speichern & Beenden aktiviert den Override.)"
                        $SUDO systemctl edit "$selection"
                        echo "Erledigt. (systemd daemon-reload erfolgt automatisch)"
                        ;;
                    Start)  
                        echo "Starte $selection..."
                        $SUDO systemctl start "$selection" && echo "Erfolg." || echo "Fehler beim Starten."
                        ;;
                    Stop)   
                        echo "Stoppe $selection..."
                        $SUDO systemctl stop "$selection" && echo "Erfolg." || echo "Fehler beim Stoppen."
                        ;;
                    Enable) 
                        echo "Aktiviere Auto-Start für $selection..."
                        $SUDO systemctl enable "$selection" && echo "Erfolg." || echo "Fehler beim Aktivieren."
                        ;;
                    Disable) 
                        echo "Deaktiviere Auto-Start für $selection..."
                        $SUDO systemctl disable "$selection" && echo "Erfolg." || echo "Fehler beim Deaktivieren."
                        ;;
                    Owner)
                        dialog --msgbox "ACHTUNG: Das Aendern des Users kann Dienste brechen, wenn Dateirechte, Capabilities oder Sockets nicht passen.\nEmpfohlen: Nur bei eigenen/custom Services nutzen." 10 65
                        USER_TMP=$(mktemp)
                        user_list=()
                        while IFS=: read -r u _ _ _ _ _ _; do 
                            user_list+=("$u" "Account")
                        done < /etc/passwd
                        
                        dialog --title " Besitzer waehlen " --menu "Neuer Owner für $selection:" 20 50 10 "${user_list[@]}" 2> "$USER_TMP"
                        if [ $? -eq 0 ]; then
                            new_user=$(cat "$USER_TMP" 2>/dev/null)
                            override_dir="/etc/systemd/system/${selection}.d"
                            override_file="${override_dir}/owner_override.conf"
                            echo "Erstelle Override: $override_file"
                            $SUDO mkdir -p "$override_dir"
                            echo -e "[Service]\nUser=$new_user" | $SUDO tee "$override_file" > /dev/null
                            echo "Lade systemd neu..."
                            $SUDO systemctl daemon-reload
                            echo "Besitzer erfolgreich auf '$new_user' geaendert (Override aktiv)."
                            echo "Hinweis: Ggf. muss der Dienst neu gestartet werden."
                        fi
                        rm -f "$USER_TMP"
                        ;;
                esac
                echo -e "\n[Druecke ENTER um zum Hauptmenue zurueckzukehren]"
                read -r
            fi
            rm -f "$ACTION_TMP"
            ;;
    esac
    rm -f "$GLOBAL_TEMP" "$SEL_TMP"
done
