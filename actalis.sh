#!/usr/bin/env bash
# +------------------------------------------------------------------------+
# | LEGACY SCRIPT -- kept as-is, now redundant.                            |
# |                                                                        |
# | Actalis has been a first-class provider since nginx-cert 2.0:          |
# |                                                                        |
# |   CERT_PROVIDER=actalis                                                |
# |   CERT_EAB_KID=<your kid>                                              |
# |   CERT_EAB_HMAC_KEY=<your hmac>                                        |
# |   CERT_DOMAINS=data.example.eu                                         |
# |   CERT_EMAIL=you@example.com                                           |
# |                                                                        |
# | Renewal, the nginx reload and falling back to another authority are    |
# | then handled automatically. See examples/compose.actalis.yml.          |
# | This file can be deleted without consequence.                          |
# +------------------------------------------------------------------------+
set -euo pipefail

### ===== VÉRIFICATION DES PARAMÈTRES =====
if [[ $# -ne 4 ]]; then
  echo "❌ ERREUR : paramètres manquants"
  echo
  echo "Usage : $0 <nom_de_domaine> <email> <eab-kid> <eab-hmac-key>"
  echo
  echo "Exemple :"
  echo "  $0 data.soilhealthbenchmarks.eu rachid.yahiaoui@inrae.fr YOUR_EAB_KID YOUR_EAB_HMAC"
  exit 1
fi

### ===== PARAMÈTRES =====
DOMAIN="$1"
EMAIL="$2"
EAB_KID="$3"
EAB_HMAC="$4"

### ===== VARIABLES =====
BASE_DIR="certme_actalis"
NGINX_DIR="$BASE_DIR/nginx"
CERTBOT_DIR="$BASE_DIR/certbot"
LIVE_CERT_DIR="$CERTBOT_DIR/etc/live/$DOMAIN"

### ===== CONTRÔLES DOCKER =====
if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
  echo "❌ ERREUR : Docker et Docker Compose sont requis"
  exit 1
fi

### ===== RESET DU RÉPERTOIRE =====
echo "🧹 Nettoyage du répertoire $BASE_DIR"
rm -rf "$BASE_DIR"
mkdir -p "$NGINX_DIR" "$CERTBOT_DIR"/{etc,lib,www}

### ===== DOCKER COMPOSE =====
cat > "$BASE_DIR/docker-compose.yml" <<EOF
services:
  nginx:
    image: nginx:alpine
    container_name: actalis-nginx
    ports:
      - "80:80"
    volumes:
      - ./nginx/default.conf:/etc/nginx/conf.d/default.conf:ro
      - ./certbot/www:/var/www/certbot
    restart: unless-stopped

  certbot:
    image: certbot/certbot
    container_name: actalis-certbot
    volumes:
      - ./certbot/etc:/etc/letsencrypt
      - ./certbot/lib:/var/lib/letsencrypt
      - ./certbot/www:/var/www/certbot
EOF

### ===== CONFIG NGINX =====
cat > "$NGINX_DIR/default.conf" <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
        allow all;
    }

    location / {
        return 200 "ACME HTTP-01 ready\n";
        add_header Content-Type text/plain;
    }
}
EOF

### ===== DÉMARRAGE NGINX =====
echo "🚀 Démarrage de Nginx"
cd "$BASE_DIR"
docker compose up -d nginx

### ===== GÉNÉRATION DU CERTIFICAT =====
echo "🔐 Génération du certificat Actalis pour $DOMAIN"
set +e
docker compose run --rm certbot certonly \
  --server https://acme-api.actalis.com/acme/directory \
  --webroot \
  -w /var/www/certbot \
  --agree-tos \
  --email "$EMAIL" \
  --eab-kid "$EAB_KID" \
  --eab-hmac-key "$EAB_HMAC" \
  -d "$DOMAIN"

STATUS=$?
set -e

if [[ $STATUS -ne 0 ]]; then
  echo "❌ ERREUR : échec de génération du certificat"
  echo "💡 Vérifiez la connectivité HTTP (port 80), le domaine, et vos identifiants EAB"
  echo "Pour relancer, utilisez la commande :"
  echo "  $0 $DOMAIN $EMAIL $EAB_KID $EAB_HMAC"
  docker compose logs certbot
  exit 1
fi

### ===== VÉRIFICATION =====
if [[ ! -f "$LIVE_CERT_DIR/fullchain.pem" ]]; then
  echo "❌ Certificat introuvable après génération"
  exit 1
fi

### ===== DATE D'EXPIRATION =====
EXPIRY_DATE=$(openssl x509 -enddate -noout -in "$LIVE_CERT_DIR/fullchain.pem" \
  | cut -d= -f2 \
  | xargs -I{} date -d "{}" +"%Y-%m-%d")

TARGET_DIR="../certificate_until_${EXPIRY_DATE}"
mkdir -p "$TARGET_DIR"

### ===== COPIE DES CERTIFICATS (réels, pas les liens) =====
for f in fullchain.pem privkey.pem cert.pem chain.pem; do
  cp -L "$LIVE_CERT_DIR/$f" "$TARGET_DIR/$f"
done

### ===== SUCCÈS =====
echo "✅ Certificat généré avec succès"
echo "📁 Certificats copiés dans : $TARGET_DIR"
echo "📅 Expiration le : $EXPIRY_DATE"
