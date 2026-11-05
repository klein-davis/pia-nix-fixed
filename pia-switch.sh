# Fuzzy-pick a PIA server location and switch to it through NetworkManager
# (no sudo). PIA_CONFIG_DIR is set by the Nix package to the fetched PIA
# OpenVPN config bundle.
#
# usage: pia-switch            # fuzzy-pick a location and switch to it
#        pia-switch <location> # switch straight to a location, e.g. us-houston
#
# credentials: $PIA_CREDENTIALS_FILE (default ~/.config/pia/credentials),
# username on line 1, password on line 2, chmod 600.

CREDENTIALS_FILE="${PIA_CREDENTIALS_FILE:-$HOME/.config/pia/credentials}"

if [ ! -f "$CREDENTIALS_FILE" ]; then
  echo "error: $CREDENTIALS_FILE not found." >&2
  echo "Create it with your PIA username on line 1 and password on line 2, then: chmod 600 $CREDENTIALS_FILE" >&2
  exit 1
fi

if [ "$(stat -c '%a' "$CREDENTIALS_FILE")" != "600" ]; then
  echo "error: $CREDENTIALS_FILE must be readable only by you (chmod 600 $CREDENTIALS_FILE)" >&2
  exit 1
fi

PIA_USERNAME=$(sed -n '1p' "$CREDENTIALS_FILE")
PIA_PASSWORD=$(sed -n '2p' "$CREDENTIALS_FILE")
if [ -z "$PIA_USERNAME" ] || [ -z "$PIA_PASSWORD" ]; then
  echo "error: $CREDENTIALS_FILE must have the username on line 1 and password on line 2" >&2
  exit 1
fi

# Same naming as the openvpn-<location> systemd units: file name, "_" -> "-".
locations=$(find "$PIA_CONFIG_DIR" -name '*.ovpn' -printf '%f\n' | sed -E 's/\.ovpn$//; s/_/-/g' | sort)

if [ "$#" -ge 1 ]; then
  location=$1
  if ! printf '%s\n' "$locations" | grep -qx -- "$location"; then
    echo "error: unknown location '$location'" >&2
    exit 1
  fi
else
  location=$(printf '%s\n' "$locations" | fzf --prompt="PIA location> ") || exit 1
fi

# All PIA servers share one CA. NetworkManager needs it at a stable path
# outside the Nix store, so it survives garbage collection and updates.
ca_path="${XDG_DATA_HOME:-$HOME/.local/share}/pia-switch/ca.pem"
mkdir -p "$(dirname "$ca_path")"
cp -f "$PIA_CONFIG_DIR/ca.rsa.2048.crt" "$ca_path"

remote=$(awk '/^remote /{print $2 ":" $3; exit}' "$PIA_CONFIG_DIR/${location//-/_}.ovpn")
conn_name="pia_${location//-/_}"

if ! nmcli -t -f NAME connection show | grep -qx -- "$conn_name"; then
  echo "creating connection for $location..."
  nmcli connection add type vpn con-name "$conn_name" ifname -- \
    vpn.service-type org.freedesktop.NetworkManager.openvpn >/dev/null
  nmcli connection modify "$conn_name" \
    vpn.data \
      "auth = sha1, ca = $ca_path, challenge-response-flags = 2, cipher = aes-128-cbc, compress = yes, connection-type = password, dev = tun, password-flags = 0, remote = $remote, remote-cert-tls = server, reneg-seconds = 0, username = $PIA_USERNAME" \
    vpn.user-name "$PIA_USERNAME" \
    vpn.secrets "password=$PIA_PASSWORD"
fi

# Bring down any other active VPN so two tunnels don't race for the default route.
active_vpns=$(nmcli -t -f NAME,TYPE connection show --active | awk -F: '$2=="vpn"{print $1}')
for c in $active_vpns; do
  [ "$c" = "$conn_name" ] && continue
  nmcli connection down "$c" >/dev/null
done

nmcli connection up "$conn_name"
echo "switched to $location"
