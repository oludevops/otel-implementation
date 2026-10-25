#!/usr/bin/env bash
# End-to-end check through the public frontend: browse, add to cart, check out.
# Exercises every service: frontend, catalog, currency, ads, recommendations, cart+redis,
# checkout, shipping, payment, email.
set -euo pipefail
export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}
NS=online-boutique
URL=${URL:-http://192.168.56.111}
JAR=$(mktemp)
trap 'rm -f "$JAR"' EXIT

# 1. home page and a product page
curl -fsS -c "$JAR" -b "$JAR" -o /dev/null -w 'home      %{http_code} %{time_total}s\n' "$URL/"
curl -fsS -c "$JAR" -b "$JAR" -o /dev/null -w 'product   %{http_code} %{time_total}s\n' "$URL/product/OLJCESPC7Z"

# 2. add to cart, then the cart page must list the item
curl -fsS -c "$JAR" -b "$JAR" -o /dev/null -w 'add-cart  %{http_code}\n' \
  -d product_id=OLJCESPC7Z -d quantity=2 "$URL/cart"
# (pages are captured first: grep -q exiting early would break the pipe under pipefail)
page=$(curl -fsS -c "$JAR" -b "$JAR" "$URL/cart")
if grep -q 'OLJCESPC7Z' <<<"$page"; then
  echo "cart      contains OLJCESPC7Z"
else
  echo "FAIL: cart page does not list OLJCESPC7Z"; exit 1
fi

# 3. checkout must show the confirmation page
page=$(curl -fsS -c "$JAR" -b "$JAR" "$URL/cart/checkout" \
  -d email=someone@example.com -d street_address='1600 Amphitheatre Parkway' -d zip_code=94043 \
  -d city='Mountain View' -d state=CA -d country='United States' \
  -d credit_card_number=4432801561520454 -d credit_card_expiration_month=1 \
  -d credit_card_expiration_year=$(( $(date +%Y) + 1 )) -d credit_card_cvv=672)
if grep -q 'Your order is complete' <<<"$page"; then
  echo "checkout  order complete"
else
  echo "FAIL: checkout did not show the order confirmation"; exit 1
fi

# 4. cluster health: no restarts, load generator running
kubectl -n "$NS" get pods -o custom-columns=POD:.metadata.name,STATUS:.status.phase,RESTARTS:.status.containerStatuses[0].restartCount
kubectl -n "$NS" logs deploy/loadgenerator --tail=15

# 5. nothing still trying to reach Google Cloud or a telemetry collector
for d in $(kubectl -n "$NS" get deploy -o name); do
  hits=$(kubectl -n "$NS" logs "$d" --all-containers --tail=500 2>/dev/null \
         | grep -ciE 'profiler|opentelemetry|otlp|collector|metadata\.google|stackdriver' || true)
  echo "$d telemetry/GCP log lines: $hits"
done
