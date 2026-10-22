conf=~/.wireguard/machport.conf
[ -f $conf ] || { echo "no vpn config yet, run: ansible-playbook vpn.yml"; exit 1; }
if [ "$1" = "--stop" ]; then
  sudo wg-quick down $conf 2> /dev/null && echo "vpn stopped" || echo "vpn not running"
  exit 0
fi
sudo wg-quick up $conf 2> /dev/null && echo "vpn started, company networks reachable directly" || echo "vpn already running, or failed. try: sudo wg-quick up $conf"
