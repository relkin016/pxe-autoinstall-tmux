#!/bin/bash
# init/install.sh
set -euo pipefail

# ─── КОЛЬОРИ ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'
YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

print_info()    { echo -e "${BLUE}ℹ  ${1}${NC}"; }
print_success() { echo -e "${GREEN}✓  ${1}${NC}"; }
print_warning() { echo -e "${YELLOW}⚠  ${1}${NC}"; }
print_error()   { echo -e "${RED}✗  ${1}${NC}"; }
print_step()    { echo -e "\n${BOLD}${CYAN}══ ${1} ══${NC}"; }
print_sep()     { echo -e "${CYAN}───────────────────────────────────────────────${NC}"; }

# ─── ШЛЯХИ ───────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAYBOOKS_DIR="$SCRIPT_DIR/playbooks"
ROLES_PATH="$PLAYBOOKS_DIR/roles"
SSH_PORT=8022

# ── Глобальна директорія Ansible (поза репо) ──────────────────────────────────
ANSIBLE_DIR="$HOME/ansible"

# Генеровані файли — тепер у $ANSIBLE_DIR
ANSIBLE_CFG="$ANSIBLE_DIR/ansible.cfg"
HOSTS_FILE="$ANSIBLE_DIR/hosts.yaml"
GROUP_VARS_DIR="$ANSIBLE_DIR/group_vars/all/"
GROUP_VARS_DIR_TERMUX="$ANSIBLE_DIR/group_vars/termux"
VAULT_FILE="$GROUP_VARS_DIR/vault.yaml"
VARS_FILE="$GROUP_VARS_DIR_TERMUX/vars.yaml"
VAULT_PASS_FILE="$ANSIBLE_DIR/.vault_pass"
POST_INSTALL_SCRIPT="$ANSIBLE_DIR/post-install.sh"

# Плейбуки (залишаються у репо — тільки читаємо)
PLAYBOOK_STAGE1="$PLAYBOOKS_DIR/init-android.yml"
PLAYBOOK_STAGE2="$PLAYBOOKS_DIR/init-android2.yml"

SSH_KEY_PATH="$HOME/.ssh/id_ed25519"
DEFAULT_GATEWAY=$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')
BASE_IP=$(echo "$DEFAULT_GATEWAY" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.' 2>/dev/null || echo "192.168.1.")

# ─── БАНЕР ────────────────────────────────────────────────────────────────────
display_banner() {
    echo -e "${BOLD}${CYAN}"
    cat << "EOF"
╔════════════════════════════════════════════════════════════╗
║        Termux + Jenkins Automation — Setup Script          ║
║   ADB → Termux preinit → Ansible + Jenkins → Pipeline      ║
╚════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

# ─── ІНІЦІАЛІЗАЦІЯ ANSIBLE_DIR ────────────────────────────────────────────────
init_ansible_dir() {
    if [ ! -d "$ANSIBLE_DIR" ]; then
        mkdir -p "$ANSIBLE_DIR"
        print_success "Створено директорію Ansible: $ANSIBLE_DIR"
    fi
    mkdir -p "$GROUP_VARS_DIR"
    mkdir -p "$GROUP_VARS_DIR_TERMUX"
}

# ─── ПЕРЕВІРКА ОС ─────────────────────────────────────────────────────────────
check_os() {
    [ -f /etc/os-release ] || { print_error "Не вдалося визначити ОС."; exit 1; }
    . /etc/os-release
    case "$ID" in
        ubuntu|debian|linuxmint) ;;
        *)
            print_error "Скрипт підтримує лише Ubuntu, Debian або Linux Mint."
            print_error "Ваша система: $NAME ($ID)"
            exit 1
            ;;
    esac
}

# ─── ПЕРЕВІРКА СТРУКТУРИ РЕПО ─────────────────────────────────────────────────
check_repo_structure() {
    local err=0
    for path in "$PLAYBOOKS_DIR" "$ROLES_PATH" "$PLAYBOOK_STAGE1" "$PLAYBOOK_STAGE2"; do
        if [ ! -e "$path" ]; then
            print_error "Не знайдено: $path"
            err=1
        fi
    done
    [ "$err" -eq 1 ] && {
        print_error "Переконайтесь що скрипт знаходиться у ./init/"
        exit 1
    }
    print_success "Структура репо OK: $SCRIPT_DIR"
}

# ─── ВСТАНОВЛЕННЯ ANSIBLE (без PPA) ──────────────────────────────────────────
install_ansible() {
    print_step "Перевірка Ansible"

    if command -v ansible-playbook &>/dev/null; then
        print_success "Ansible вже встановлено: $(ansible --version 2>/dev/null | head -1)"
        return
    fi

    print_warning "Ansible не знайдено — встановлення через pip3"
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

    sudo -E apt-get update -qq
    sudo -E apt-get install -yq \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        python3 python3-pip python3-venv \
        sshpass adb curl jq openssh-client > /dev/null

    if pip3 install --user ansible 2>/dev/null; then
        export PATH="$HOME/.local/bin:$PATH"
        grep -q '\.local/bin' "$HOME/.bashrc" 2>/dev/null \
            || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
        print_success "Ansible встановлено через pip3 (--user)"
    else
        print_error "pip3 не вдався. Спроба через apt..."
        sudo -E apt-get install -yq ansible > /dev/null \
            || { print_error "Не вдалося встановити Ansible"; exit 1; }
        print_success "Ansible встановлено через apt"
    fi

    command -v ansible-playbook &>/dev/null \
        || { print_error "ansible-playbook не знайдено після встановлення"; exit 1; }
    print_success "$(ansible --version | head -1)"
}

# ─── ВСТАНОВЛЕННЯ ДОДАТКОВИХ ІНСТРУМЕНТІВ ─────────────────────────────────────
install_tools() {
    print_step "Перевірка залежностей (adb, sshpass, jq)"

    local missing=()
    for cmd in adb sshpass jq; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done

    if [ ${#missing[@]} -gt 0 ]; then
        print_warning "Встановлення: ${missing[*]}"
        export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
        sudo -E apt-get install -yq \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold" \
            "${missing[@]}" > /dev/null
    fi

    print_success "Всі інструменти присутні"
}

# ─── ПЕРЕВІРКА ГОТОВНОСТІ ДО ЕТАПУ 2 ─────────────────────────────────────────
stage2_ready() {
    [ -f "$POST_INSTALL_SCRIPT" ] \
        && [ -f "$HOSTS_FILE" ] \
        && [ -f "$VAULT_PASS_FILE" ] \
        && [ -f "$ANSIBLE_CFG" ]
}

# ─── ВИКОНАННЯ ЕТАПУ 2 ────────────────────────────────────────────────────────
run_stage2() {
    if [[ -z "${TERMUX_USER:-}" ]]; then
        get_termux_user
    else
        print_info "Поточний користувач: $TERMUX_USER"
        read -r -p "Змінити? (y/N): " change_user < /dev/tty
        [[ "${change_user:-N}" =~ ^[Yy]$ ]] && get_termux_user
    fi

    generate_hosts
    copy_ssh_key
    generate_post_install
    bash "$POST_INSTALL_SCRIPT"
}

# ─── SSH КЛЮЧ ─────────────────────────────────────────────────────────────────
setup_ssh_key() {
    if [ ! -f "$SSH_KEY_PATH" ]; then
        print_info "Генерація SSH-ключа..."
        ssh-keygen -t ed25519 -N "" -f "$SSH_KEY_PATH" -q
        print_success "SSH-ключ створено: $SSH_KEY_PATH"
    else
        print_success "SSH-ключ вже існує: $SSH_KEY_PATH"
    fi
}

# ─── ПІДКЛЮЧЕННЯ ADB ──────────────────────────────────────────────────────────
get_adb_connection() {
    print_step "Пошук Android-пристрою (ADB)"

    ADB_ID=""
    PHONE_IP=""

    adb start-server > /dev/null 2>&1

    local usb_devices=()
    mapfile -t usb_devices < <(adb devices 2>/dev/null \
        | awk 'NR>1 {if ($2=="device" && $1 !~ /\./) print $1}')
    local dev_count=${#usb_devices[@]}

    if [ "$dev_count" -eq 1 ]; then
        print_info "Знайдено USB-пристрій: ${usb_devices[0]}"
        read -r -p "Використати? (Y/n): " ans < /dev/tty
        [[ "${ans:-Y}" =~ ^[Yy]$ ]] && ADB_ID="${usb_devices[0]}"
    elif [ "$dev_count" -gt 1 ]; then
        echo "Знайдено кілька USB-пристроїв:"
        for i in "${!usb_devices[@]}"; do
            echo "  $((i+1))) ${usb_devices[$i]}"
        done
        read -r -p "Оберіть номер (або Enter — пропустити): " DEV_CHOICE < /dev/tty
        if [[ "$DEV_CHOICE" =~ ^[0-9]+$ ]] \
                && [ "$DEV_CHOICE" -ge 1 ] \
                && [ "$DEV_CHOICE" -le "$dev_count" ]; then
            ADB_ID="${usb_devices[$((DEV_CHOICE-1))]}"
        fi
    else
        print_warning "USB-пристроїв не знайдено"
    fi

    if [ -z "$ADB_ID" ]; then
        print_warning "Переходимо до Wi-Fi ADB..."
        while [ -z "$ADB_ID" ]; do
            printf "IP смартфона [%s]: " "$BASE_IP" > /dev/tty
            read -r TEMP_IP < /dev/tty
            TEMP_IP=$(echo "${TEMP_IP:-$BASE_IP}" | cut -d: -f1)
            [ -z "$TEMP_IP" ] && continue

            printf "ADB порт [5555]: " > /dev/tty
            read -r ADB_PORT < /dev/tty
            ADB_PORT=${ADB_PORT:-5555}

            adb disconnect "$TEMP_IP:$ADB_PORT" > /dev/null 2>&1 || true
            local adb_out
            adb_out=$(adb connect "$TEMP_IP:$ADB_PORT" 2>&1) || true
            echo "  adb: $adb_out"
            if echo "$adb_out" | grep -qE 'connected|already connected'; then
                ADB_ID="$TEMP_IP:$ADB_PORT"
                PHONE_IP="$TEMP_IP"
                print_success "Підключено по Wi-Fi: $ADB_ID"
            else
                print_error "Не вдалося підключитися до $TEMP_IP:$ADB_PORT"
                print_info "Перевірте що на телефоні увімкнено 'Бездротове налагодження'"
            fi
        done
    fi

    if [ -n "$ADB_ID" ] && [ -z "$PHONE_IP" ]; then
        PHONE_IP=$(adb -s "$ADB_ID" shell ip route 2>/dev/null \
            | awk '/wlan/ {print $9; exit}' | tr -d '[:space:]') || true
        if [ -z "$PHONE_IP" ]; then
            printf "Введіть IP смартфона (для SSH) [%s]: " "$BASE_IP" > /dev/tty
            read -r PHONE_IP < /dev/tty
            PHONE_IP=${PHONE_IP:-$BASE_IP}
        fi
    fi

    print_success "ADB: $ADB_ID  |  IP: $PHONE_IP"
}

# ─── ДАНІ TERMUX КОРИСТУВАЧА ──────────────────────────────────────────────────
get_termux_user() {
    print_step "Користувач Termux"
    print_info "Виконайте 'whoami' у Termux щоб дізнатись ім'я (вигляд: u0_a557)"

    while true; do
        read -r -p "Введіть ТІЛЬКИ цифри з імені u0_a[___]: " USER_NUM < /dev/tty
        [[ "$USER_NUM" =~ ^[0-9]+$ ]] || { print_error "Тільки цифри!"; continue; }
        TERMUX_USER="u0_a${USER_NUM}"
        read -r -p "Користувач: '$TERMUX_USER' — правильно? (y/n): " ok < /dev/tty
        [[ "$ok" =~ ^[Yy]$ ]] && break
    done

    print_success "Termux user: $TERMUX_USER"
}

# ─── ПАРОЛІ + VAULT ───────────────────────────────────────────────────────────
setup_vault() {
    print_step "Паролі та Ansible Vault"

    mkdir -p "$GROUP_VARS_DIR_TERMUX"

    if [ -f "$VAULT_FILE" ] && [ -f "$VAULT_PASS_FILE" ]; then
        if ansible-vault view "$VAULT_FILE" \
                --vault-password-file "$VAULT_PASS_FILE" >/dev/null 2>&1; then
            print_info "Знайдено існуючий Vault."
            read -r -p "Використати збережені паролі? (Y/n): " reuse < /dev/tty
            [[ "${reuse:-Y}" =~ ^[Yy]$ ]] && { print_success "Vault без змін"; return; }
        fi
    fi

    while true; do
        read -r -s -p "SSH-пароль Termux: " SSH_PASS < /dev/tty
        echo; [ -n "$SSH_PASS" ] && break
        print_error "Не може бути порожнім"
    done

    while true; do
        read -r -s -p "Jenkins admin пароль [Enter = 'admin']: " JENKINS_PASS < /dev/tty
        echo; JENKINS_PASS=${JENKINS_PASS:-admin}
        read -r -s -p "Повторіть Jenkins пароль: " JENKINS_PASS2 < /dev/tty
        echo; JENKINS_PASS2=${JENKINS_PASS2:-admin}
        [ "$JENKINS_PASS" = "$JENKINS_PASS2" ] && break
        print_error "Паролі не збігаються"
    done

    while true; do
        read -r -s -p "Майстер-пароль Vault: " VAULT_PASS < /dev/tty
        echo
        read -r -s -p "Повторіть: " VAULT_PASS2 < /dev/tty
        echo
        [ "$VAULT_PASS" = "$VAULT_PASS2" ] && break
        print_error "Паролі не збігаються"
    done

    echo "$VAULT_PASS" > "$VAULT_PASS_FILE"
    chmod 600 "$VAULT_PASS_FILE"

    cat > "$VAULT_FILE" << VAULT_EOF
---
ssh_pass: $SSH_PASS
jenkins_admin_password: $JENKINS_PASS
VAULT_EOF

    if ansible-vault view "$VAULT_FILE" \
            --vault-password-file "$VAULT_PASS_FILE" >/dev/null 2>&1; then
        ansible-vault decrypt "$VAULT_FILE" \
            --vault-password-file "$VAULT_PASS_FILE" > /dev/null
    fi

    ansible-vault encrypt "$VAULT_FILE" \
        --vault-password-file "$VAULT_PASS_FILE" \
        --encrypt-vault-id default > /dev/null
    print_success "Vault зашифровано: $VAULT_FILE"
}

# ─── ГЕНЕРАЦІЯ ansible.cfg ────────────────────────────────────────────────────
generate_ansible_cfg() {
    cat > "$ANSIBLE_CFG" << EOF
[defaults]
host_key_checking   = False
vault_password_file = $VAULT_PASS_FILE
inventory           = $HOSTS_FILE
roles_path          = $ROLES_PATH

[ssh_connection]
ssh_args   = -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
pipelining = True
EOF
    print_success "ansible.cfg: $ANSIBLE_CFG"
}

# ─── ГЕНЕРАЦІЯ hosts.yaml + group_vars ────────────────────────────────────────
generate_hosts() {
    mkdir -p "$GROUP_VARS_DIR_TERMUX"

    cat > "$VARS_FILE" << EOF
---
ansible_remote_tmp: /data/data/com.termux/files/home/.ansible/tmp
ssh_public_key_path: ${SSH_KEY_PATH}.pub

termux_prefix: /data/data/com.termux/files
termux_home: /data/data/com.termux/files/home
termux_usr: /data/data/com.termux/files/usr
termux_bin: /data/data/com.termux/files/usr/bin

jenkins_version: 2.555.2
jenkins_port: 8080
jenkins_home: "{{ termux_home }}/.jenkins"
jenkins_war: "{{ jenkins_home }}/jenkins.war"
java_bin: "{{ termux_bin }}/java"
jenkins_admin_user: admin
jenkins_admin_password: "{{ lookup('env', 'JENKINS_ADMIN_PASSWORD') | default('admin', true) }}"

jenkins_agent_home: "{{ termux_home }}/jenkins-agent"
jenkins_agent_user: "{{ ansible_user }}"
jenkins_agent_port: 8022

ssh_port: 8022
ssh_key_type: ed25519
ssh_key_path: "{{ termux_home }}/.ssh"

python_version: latest
git_version: latest

jenkins_memory_mb: 512
max_executors: 2

jcasc_config_path: "{{ jenkins_home }}/jenkins.yaml"
jcasc_reload_token: "{{ lookup('env', 'JCASC_RELOAD_TOKEN') | default('changeme', true) }}"
EOF
    print_success "group_vars/termux/vars.yaml: $VARS_FILE"

    cat > "$HOSTS_FILE" << EOF
---
all:
  children:
    termux:
      hosts:
        bangkk:
          ansible_host: ${PHONE_IP}
          ansible_port: ${SSH_PORT}
          ansible_user: ${TERMUX_USER}
          adb_identify: ${ADB_ID}
          ansible_connection: ssh
          ansible_ssh_pass: "{{ ssh_pass }}"
          ansible_ssh_private_key_file: ${SSH_KEY_PATH}
          ansible_ssh_common_args: >-
            -o StrictHostKeyChecking=no
            -o UserKnownHostsFile=/dev/null
EOF
    print_success "hosts.yaml: $HOSTS_FILE"
}

# ─── КОПІЮВАННЯ SSH КЛЮЧА ─────────────────────────────────────────────────────
copy_ssh_key() {
    print_step "Копіювання SSH ключа на Termux"

    local ssh_pass
    ssh_pass=$(ansible-vault view "$VAULT_FILE" \
        --vault-password-file "$VAULT_PASS_FILE" 2>/dev/null \
        | awk '/^ssh_pass:/{print $2}')

    if [ -z "$ssh_pass" ]; then
        print_error "Не вдалося прочитати ssh_pass з Vault"
        return 1
    fi

    if ssh \
           -o BatchMode=yes \
           -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null \
           -o IdentitiesOnly=yes \
           -o ConnectTimeout=5 \
           -p "$SSH_PORT" \
           -i "$SSH_KEY_PATH" \
           "${TERMUX_USER}@${PHONE_IP}" \
           "echo ok" 2>/dev/null | grep -q "ok"; then
        print_success "SSH ключ вже налаштовано — підключення без пароля працює"
        return
    fi

    print_info "Прокидуємо SSH ключ через sshpass + ssh-copy-id"

    if sshpass -p "$ssh_pass" \
        ssh-copy-id \
            -i "${SSH_KEY_PATH}.pub" \
            -p "$SSH_PORT" \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o PubkeyAuthentication=no \
            "${TERMUX_USER}@${PHONE_IP}"; then
        print_success "SSH ключ скопійовано на Termux"
    else
        print_error "Не вдалося скопіювати ключ"
        print_info "Переконайтесь що у Termux:"
        print_info "  1. sshd запущено: sshd"
        print_info "  2. Дозволено парольну автентифікацію:"
        print_info "     echo 'PasswordAuthentication yes' >> \$PREFIX/etc/ssh/sshd_config"
        print_info "     pkill sshd && sshd"
        return 1
    fi
}

# ─── ЗАПУСК ПЛЕЙБУКУ ─────────────────────────────────────────────────────────
run_playbook() {
    local playbook="$1"
    local description="$2"

    if [ ! -f "$playbook" ]; then
        print_error "Плейбук не знайдено: $playbook"
        return 1
    fi

    print_info "Запуск: $description"
    if ANSIBLE_CONFIG="$ANSIBLE_CFG" ansible-playbook \
            -i "$HOSTS_FILE" \
            --vault-password-file "$VAULT_PASS_FILE" \
            "$playbook"; then
        print_success "$description — завершено"
    else
        print_error "$description — помилка. Перевірте вивід вище."
        return 1
    fi
}

# ─── ВІДНОВЛЕННЯ ПОПЕРЕДНЬОЇ КОНФІГУРАЦІЇ ─────────────────────────────────────
try_restore_previous() {
    [ -f "$HOSTS_FILE" ] || return 1

    local old_ip old_port old_user old_adb
    old_ip=$(awk   '/ansible_host:/{print $2}'                "$HOSTS_FILE" | head -1)
    old_port=$(awk '/ansible_port:/{print $2}'                "$HOSTS_FILE" | head -1)
    old_user=$(awk '/ansible_user:/{gsub(/"/, ""); print $2}' "$HOSTS_FILE" | head -1)
    old_adb=$(awk  '/adb_identify:/{print $2}'                "$HOSTS_FILE" | head -1)

    [ -z "$old_ip" ] && return 1

    print_sep
    print_info "Знайдено попередню конфігурацію:"
    echo "  IP:          $old_ip"
    echo "  SSH порт:    ${old_port:-8022}"
    echo "  Користувач:  ${old_user:-—}"
    echo "  ADB:         ${old_adb:-—}"
    print_sep

    read -r -p "Використати ці дані? (Y/n): " reuse < /dev/tty
    if [[ "${reuse:-Y}" =~ ^[Yy]$ ]]; then
        PHONE_IP="$old_ip"
        SSH_PORT="${old_port:-8022}"
        TERMUX_USER="${old_user:-}"
        ADB_ID="${old_adb:-}"
        return 0
    fi
    return 1
}

# ─── ГЕНЕРАЦІЯ post-install.sh ────────────────────────────────────────────────
generate_post_install() {
    local _cfg="$ANSIBLE_CFG"
    local _hosts="$HOSTS_FILE"
    local _vault_pass="$VAULT_PASS_FILE"
    local _playbook="$PLAYBOOK_STAGE2"
    local _phone_ip="$PHONE_IP"
    local _ssh_port="$SSH_PORT"
    local _termux_user="$TERMUX_USER"

    cat > "$POST_INSTALL_SCRIPT" << SCRIPT_EOF
#!/bin/bash
# post-install.sh — Етап 2: Ansible + Jenkins у Termux
set -euo pipefail

ANSIBLE_CFG="${_cfg}"
HOSTS_FILE="${_hosts}"
VAULT_PASS_FILE="${_vault_pass}"
PLAYBOOK="${_playbook}"
PHONE_IP="${_phone_ip}"
SSH_PORT="${_ssh_port}"
TERMUX_USER="${_termux_user}"

GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
print_success() { echo -e "\${GREEN}✓  \${1}\${NC}"; }
print_error()   { echo -e "\${RED}✗  \${1}\${NC}"; }
print_info()    { echo -e "\${CYAN}ℹ  \${1}\${NC}"; }

echo -e "\${BOLD}\${CYAN}══ Етап 2: Ansible + Jenkins у Termux ══\${NC}"
echo "  Плейбук: \$PLAYBOOK"
echo "  Hosts:   \$HOSTS_FILE"
echo ""

[ -f "\$VAULT_PASS_FILE" ] || {
    print_error ".vault_pass не знайдено. Запустіть install.sh повторно."
    exit 1
}

if ANSIBLE_CONFIG="\$ANSIBLE_CFG" ansible-playbook \\
        -i "\$HOSTS_FILE" \\
        --vault-password-file "\$VAULT_PASS_FILE" \\
        "\$PLAYBOOK"; then
    print_success "Ansible + Jenkins встановлено!"
    echo ""
    echo -e "\${BOLD}Jenkins:\${NC}"
    echo "  URL:     http://\${PHONE_IP}:8080"
    echo "  Логін:   admin"
    echo "  Webhook: http://\${PHONE_IP}:8080/generic-webhook-trigger/invoke?token=jenkins-webhook-token"
    echo ""
    echo -e "\${BOLD}SSH:\${NC}"
    echo "  ssh -p \${SSH_PORT} \${TERMUX_USER}@\${PHONE_IP}"
else
    print_error "Помилка встановлення. Перевірте вивід вище."
    exit 1
fi
SCRIPT_EOF

    chmod +x "$POST_INSTALL_SCRIPT"
    print_success "post-install.sh згенеровано: $POST_INSTALL_SCRIPT"
}

# ═════════════════════════════════════════════════════════════════════════════
# MAIN
# ═════════════════════════════════════════════════════════════════════════════
main() {
    display_banner
    check_os
    check_repo_structure
    install_ansible
    install_tools
    setup_ssh_key
    init_ansible_dir

    print_info "Ansible директорія: $ANSIBLE_DIR"

    # ── Швидкий шлях ─────────────────────────────────────────────────────────
    if stage2_ready; then
        print_sep
        print_success "Знайдено готовий post-install.sh від попереднього запуску."
        print_info "Для запуску Етапу 2 без повторного налаштування виконайте:"
        echo ""
        echo -e "  ${BOLD}bash $POST_INSTALL_SCRIPT${NC}"
        echo ""
        read -r -p "Запустити зараз? (Y/n/skip): " quick < /dev/tty
        case "${quick:-Y}" in
            [Yy]*) bash "$POST_INSTALL_SCRIPT"; exit 0 ;;
            skip)  : ;;
            *)     print_info "Запустіть вручну: bash $POST_INSTALL_SCRIPT"; exit 0 ;;
        esac
        print_info "Продовжуємо повне налаштування..."
        print_sep
    fi

    # ── Крок 1: Дані пристрою ────────────────────────────────────────────────
    print_step "КРОК 1: Дані пристрою"

    TERMUX_USER=""; ADB_ID=""; PHONE_IP=""; SSH_PORT="8022"

    if ! try_restore_previous; then
        get_adb_connection
    else
        print_success "Використовуємо збережену конфігурацію"
        read -r -p "Змінити SSH порт [$SSH_PORT]? (Enter — залишити): " new_port < /dev/tty
        SSH_PORT=${new_port:-$SSH_PORT}
    fi

    # ── Крок 2: Паролі + Vault ───────────────────────────────────────────────
    print_step "КРОК 2: Паролі"
    setup_vault

    # ── Крок 3: Конфігурація ─────────────────────────────────────────────────
    print_step "КРОК 3: Генерація конфігурації"
    generate_ansible_cfg

    # ── Крок 4: Етап 1 ───────────────────────────────────────────────────────
    print_sep
    echo -e "${BOLD}Готово до Етапу 1:${NC}"
    echo "  ADB:      ${ADB_ID:-—}"
    echo "  IP:       $PHONE_IP"
    echo "  SSH порт: $SSH_PORT"
    print_sep

    read -r -p "Запустити Етап 1 — init-android.yml (Termux preinit через ADB)? (Y/n): " \
        run1 < /dev/tty
    if [[ "${run1:-Y}" =~ ^[Yy]$ ]]; then
        mkdir -p "$GROUP_VARS_DIR_TERMUX"
        cat > "$VARS_FILE" << EOF
ansible_remote_tmp: /data/data/com.termux/files/home/.ansible/tmp
ssh_public_key_path: ${SSH_KEY_PATH}.pub
EOF
        cat > "$HOSTS_FILE" << EOF
---
all:
  children:
    termux:
      hosts:
        bangkk:
          ansible_host: ${PHONE_IP}
          ansible_port: ${SSH_PORT}
          ansible_user: termux_init_placeholder
          adb_identify: ${ADB_ID}
          ansible_connection: local
          ansible_ssh_pass: "{{ ssh_pass | default('none') }}"
EOF
        run_playbook "$PLAYBOOK_STAGE1" "Етап 1 — Termux preinit (init-android.yml)"
    else
        print_info "Пропущено."
    fi

    # ── Крок 5: Етап 2 ───────────────────────────────────────────────────────
    print_step "КРОК 5: Підготовка Етапу 2 (Ansible + Jenkins)"
    echo ""
    print_info "Переконайтесь що Termux запущений та SSH доступний: ${PHONE_IP}:${SSH_PORT}"
    echo ""
    read -r -p "Запустити Етап 2 зараз? (y/N): " run2 < /dev/tty

    if [[ "${run2:-N}" =~ ^[Yy]$ ]]; then
        run_stage2
    else
        if [[ -z "${TERMUX_USER:-}" ]]; then
            print_info "Для генерації post-install.sh потрібен Termux user."
            get_termux_user
        fi
        generate_hosts
        generate_post_install

        print_sep
        print_info "post-install.sh збережено. Коли будете готові — запустіть:"
        echo ""
        echo -e "  ${BOLD}bash $POST_INSTALL_SCRIPT${NC}"
        echo ""
        print_info "Повторний запуск install.sh НЕ потрібен."
        print_sep
    fi

    echo ""
    echo -e "${BOLD}Ansible директорія:${NC} $ANSIBLE_DIR"
    echo -e "${BOLD}SSH доступ:${NC}"
    echo "  ssh -p ${SSH_PORT} ${TERMUX_USER:-<user>}@${PHONE_IP}"
}

main