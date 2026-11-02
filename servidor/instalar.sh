#!/usr/bin/env bash
# Servidor de chamadas próprio do Resenha (LiveKit) numa máquina Ubuntu (Oracle Cloud ARM, ou qualquer VPS).
#
# Como usar (na máquina nova, conectado por SSH):
#   curl -fsSL https://raw.githubusercontent.com/.../instalar.sh -o instalar.sh   (ou copie o arquivo)
#   sudo bash instalar.sh voz.resenhachat.online
#
# Antes de rodar:
#   1) No DNS do domínio (Locaweb): registro A  "voz"  →  IP público da máquina.
#   2) No painel da nuvem (Oracle: VCN → Security List), liberar ENTRADA:
#        TCP 80, 443, 7881      UDP 3478, 50000-60000
#
# O que este roteiro faz:
#   - instala o LiveKit (servidor de chamadas) e o Caddy (cuida do certificado https sozinho);
#   - libera as mesmas portas no firewall de dentro da máquina (o Ubuntu da Oracle vem bloqueando tudo);
#   - cria uma chave e um segredo NOVOS, só desta máquina, e mostra no fim para você colar nos
#     Secrets do Supabase. Eles não ficam em lugar nenhum além desta máquina e do Supabase.
set -euo pipefail

DOMINIO="${1:-}"
if [[ -z "$DOMINIO" ]]; then
  echo "Use: sudo bash instalar.sh voz.seudominio.com"; exit 1
fi
if [[ $EUID -ne 0 ]]; then echo "Rode com sudo."; exit 1; fi

echo "==> Atualizando o sistema"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl ca-certificates gnupg debian-keyring debian-archive-keyring apt-transport-https iptables-persistent openssl dnsutils

echo "==> Conferindo o DNS de $DOMINIO"
IP_PUBLICO="$(curl -fsS https://api.ipify.org || true)"
IP_DNS="$(dig +short "$DOMINIO" A | tail -n1 || true)"
echo "    IP desta máquina: ${IP_PUBLICO:-?}   |   $DOMINIO aponta para: ${IP_DNS:-nada}"
if [[ -n "$IP_PUBLICO" && "$IP_DNS" != "$IP_PUBLICO" ]]; then
  echo "    ATENÇÃO: o DNS ainda não aponta para esta máquina. O certificado só sai quando apontar."
  echo "    (Pode continuar; o Caddy tenta de novo sozinho.)"
fi

echo "==> Firewall de dentro da máquina"
# o Ubuntu da Oracle tem uma regra REJECT no fim da cadeia INPUT: as liberações entram antes dela
for regra in "tcp 80" "tcp 443" "tcp 7881" "udp 3478" "udp 50000:60000"; do
  set -- $regra
  iptables -C INPUT -p "$1" --dport "$2" -j ACCEPT 2>/dev/null || iptables -I INPUT 5 -p "$1" --dport "$2" -j ACCEPT
done
netfilter-persistent save

echo "==> Instalando o LiveKit"
curl -sSL https://get.livekit.io | bash

echo "==> Instalando o Caddy (certificado https automático)"
if ! command -v caddy >/dev/null; then
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -y && apt-get install -y caddy
fi

echo "==> Configuração"
mkdir -p /etc/livekit
if [[ ! -f /etc/livekit/livekit.yaml ]]; then
  CHAVE="API$(openssl rand -hex 6)"
  SEGREDO="$(openssl rand -base64 36 | tr -d '/+=\n' | cut -c1-48)"
  cat > /etc/livekit/livekit.yaml <<EOF
port: 7880
bind_addresses: ["127.0.0.1"]
log_level: info
rtc:
  tcp_port: 7881
  port_range_start: 50000
  port_range_end: 60000
  use_external_ip: true
turn:
  enabled: true
  udp_port: 3478
  domain: $DOMINIO
keys:
  $CHAVE: $SEGREDO
room:
  empty_timeout: 300
  max_participants: 20
EOF
  chmod 600 /etc/livekit/livekit.yaml
fi

cat > /etc/caddy/Caddyfile <<EOF
$DOMINIO {
  reverse_proxy 127.0.0.1:7880
}
EOF

cat > /etc/systemd/system/livekit.service <<'EOF'
[Unit]
Description=LiveKit (servidor de chamadas do Resenha)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/livekit-server --config /etc/livekit/livekit.yaml
Restart=always
RestartSec=3
LimitNOFILE=500000

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now livekit
systemctl restart caddy
sleep 3

echo
echo "================================================================"
if systemctl is-active --quiet livekit; then echo " LiveKit rodando."; else echo " O LiveKit não subiu: veja 'journalctl -u livekit -n 50'"; fi
if systemctl is-active --quiet caddy; then echo " Caddy rodando (o certificado sai assim que o DNS apontar)."; else echo " O Caddy não subiu: veja 'journalctl -u caddy -n 50'"; fi
echo
echo " Para o Resenha usar este servidor, cole nos Secrets do Supabase"
echo " (Edge Functions → Secrets), com estes nomes:"
echo
CHAVE_SALVA="$(awk '/^keys:/{getline; sub(/^ +/,""); split($0,a,": "); print a[1]}' /etc/livekit/livekit.yaml)"
SEGREDO_SALVO="$(awk '/^keys:/{getline; sub(/^ +/,""); split($0,a,": "); print a[2]}' /etc/livekit/livekit.yaml)"
echo "   LIVEKIT_PROPRIO_URL     = wss://$DOMINIO"
echo "   LIVEKIT_PROPRIO_KEY     = $CHAVE_SALVA"
echo "   LIVEKIT_PROPRIO_SECRET  = $SEGREDO_SALVO"
echo
echo " (O LiveKit Cloud continua configurado como reserva.)"
echo "================================================================"
