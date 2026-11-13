# The renderer supplies the Rush shebang and the release name.
set -eu
set -o pipefail
export PATH=/user/bin:/user/bin/dev
case "$0" in */*) here="${0%/*}" ;; *) here=. ;; esac
[ "$#" -eq 0 ] || { echo "usage: $0" >&2; exit 2; }

for overlay in "$here"/images/*; do
    [ -d "$overlay" ] || {
        echo "install.sh: missing toolchain payload: $overlay" >&2
        exit 1
    }
done

install_directory() {
    if [ ! -d "$1" ]; then
        mkdir "$1" || return 1
        chmod "$2" "$1" || return 1
    fi
}

# Replacing a file through its writable directory works for image-built files
# too. A copied script needs the read/execute transition before read/write/execute.
install_file() {
    [ ! -e "$2.toolchain-$$" ] || return 1
    cp "$1" "$2.toolchain-$$" || return 1
    case "$3" in rwxrwx*) chmod rwxr-xr-x "$2.toolchain-$$" || return 1 ;; esac
    chmod "$3" "$2.toolchain-$$" || return 1
    mv "$2.toolchain-$$" "$2" || return 1
}

# Configuration defaults are installed only when absent. In particular, a
# reinstall preserves the user's Cargo settings, approvals, and editor settings.
install_defaults() {
    install_directory "$2" "$3" || return 1
    for item in "$1"/*; do
        [ -e "$item" ] || continue
        if [ -d "$item" ]; then
            install_defaults "$item" "$2/${item##*/}" "$3" "$4" || return 1
        elif [ ! -e "$2/${item##*/}" ]; then
            install_file "$item" "$2/${item##*/}" "$4" || return 1
        fi
    done
}

install_directory /user/bin/dev rwxrwxr-x || exit 1
install_directory /user/lib rwxrwxr-x || exit 1
install_directory /none/dev rwxrwxrwx || exit 1

# Remove the owned library trees before merging overlays: rustc and
# rust-analyzer both contribute to the Rust tree.
for tree in "$here"/images/*/user/lib/*; do
    [ -d "$tree" ] || continue
    if [ -e "/user/lib/${tree##*/}" ]; then
        rm -r "/user/lib/${tree##*/}" || exit 1
    fi
done
for overlay in "$here"/images/*; do
    for tree in "$overlay"/user/lib/*; do
        [ -d "$tree" ] || continue
        cp -r "$tree" /user/lib || exit 1
        destination="/user/lib/${tree##*/}"
        # Batch changes in these freshly copied trees. Archive validation
        # excludes newlines, so find's records are literal. cp preserves Rx;
        # that cannot be changed directly to Rw.
        find "$destination" -type d | xargs -r -d '\n' chmod rwxrwxr-x || exit 1
        find "$destination" -type f |
            while IFS= read -r file; do
                if [ -x "$file" ]; then
                    chmod rwxrwxr-x "$file" || exit 1
                else
                    printf '%s\n' "$file"
                fi
            done |
            xargs -r -d '\n' chmod rwxrw-r-- || exit 1
    done
    for command in "$overlay"/user/bin/dev/*; do
        [ -f "$command" ] || continue
        install_file "$command" "/user/bin/dev/${command##*/}" rwxrwxr-x || exit 1
    done
    if [ -d "$overlay/user/cfg" ]; then
        install_defaults "$overlay/user/cfg" /user/cfg rwxrwxr-x rwxrw-r-- || exit 1
    fi
    if [ -d "$overlay/none/cfg" ]; then
        install_defaults "$overlay/none/cfg" /none/cfg rwxrwxrwx rwxrw-rw- || exit 1
    fi
    if [ -d "$overlay/none/dev" ]; then
        install_defaults "$overlay/none/dev" /none/dev rwxrwxrwx rwxrw-rw- || exit 1
    fi
done

# Keep custom console PATH settings, and append the development directory once.
if [ -z "$(sed -n '/^# Motor toolchain PATH$/p' /user/cfg/rush.cfg)" ]; then
    cat >> /user/cfg/rush.cfg <<'PATH_CONFIG'

# Motor toolchain PATH
case ":$PATH:" in
    *:/user/bin/dev:*) ;;
    *) export PATH="$PATH:/user/bin/dev" ;;
esac
PATH_CONFIG
fi
ssh_path=$(sed -nE "s/^[[:space:]]*path[[:space:]]*=[[:space:]]*['\"]([^'\"]*)['\"][[:space:]]*(#.*)?$/\1/p" /user/cfg/sshd.toml)
[ -n "$ssh_path" ] || { echo "install.sh: cannot read path in /user/cfg/sshd.toml" >&2; exit 1; }
case ":$ssh_path:" in
    *:/user/bin/dev:*) ;;
    *)
        # sed -i stages beside the original with permissions readable by None.
        # Rush captures $(...) in TMPDIR; keep that capture private as well.
        export TMPDIR=/user/tmp
        ssh_config=$(sed -E "s|^([[:space:]]*path[[:space:]]*=[[:space:]]*['\"])([^'\"]*)(['\"].*)$|\1\2:/user/bin/dev\3|" /user/cfg/sshd.toml) || exit 1
        printf '%s\n' "$ssh_config" > /user/cfg/sshd.toml || exit 1
        ;;
esac
echo "installed $name in /user/bin/dev and /user/lib"
echo "Reboot to activate the development PATH for console and SSH sessions."
