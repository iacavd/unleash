#!/usr/bin/env bash
# Unleash — Embedded Web UI & Prometheus Metrics Server

set -euo pipefail

WEB_PORT=8080
WEB_PID_FILE="/tmp/unleash-web.pid"

generate_html_dashboard() {
  local sip_status fv_status pf_status pf_class
  sip_status=$(csrutil status 2>/dev/null || echo "Unknown")
  fv_status=$(fdesetup status 2>/dev/null || echo "Unknown")
  if pfctl -s info 2>&1 | grep -q "Status: Enabled"; then
    pf_status="Active"
    pf_class="active"
  else
    pf_status="Inactive"
    pf_class="inactive"
  fi

  cat <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Unleash Dashboard</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #0f172a; color: #f8fafc; padding: 2rem; }
    .card { background: #1e293b; border-radius: 8px; padding: 1.5rem; margin-bottom: 1rem; border: 1px solid #334155; }
    h1 { color: #38bdf8; margin-top: 0; }
    .badge { display: inline-block; padding: 0.25rem 0.5rem; border-radius: 4px; font-weight: bold; }
    .active { background: #166534; color: #4ade80; }
    .inactive { background: #991b1b; color: #fca5a5; }
  </style>
</head>
<body>
  <h1>🚀 Unleash macOS Compliance Dashboard</h1>
  <div class="card">
    <h3>System Security Posture</h3>
    <p>SIP Status: <strong>$sip_status</strong></p>
    <p>FileVault: <strong>$fv_status</strong></p>
    <p>PF Firewall: <span class="badge $pf_class">$pf_status</span></p>
    <p>Unleash Version: <strong>2.0.0</strong></p>
  </div>
</body>
</html>
EOF
}

generate_prometheus_metrics() {
  local pf_active=0 persist_active=0

  pfctl -s info 2>&1 | grep -q "Status: Enabled" && pf_active=1 || pf_active=0
  [ -f "/Library/LaunchDaemons/com.unleash.heal.plist" ] && persist_active=1 || persist_active=0

  cat <<EOF
# HELP unleash_firewall_active Indicates whether the PF firewall is active (1) or inactive (0)
# TYPE unleash_firewall_active gauge
unleash_firewall_active $pf_active

# HELP unleash_persist_active Indicates whether auto-heal persistence is installed (1) or inactive (0)
# TYPE unleash_persist_active gauge
unleash_persist_active $persist_active

# HELP unleash_info Information metric for Unleash utility
unleash_info{version="2.0.0"} 1
EOF
}

cmd_web_server() {
  local port="${1:-8080}"
  info "Starting Unleash Web Server & Prometheus Metrics Exporter on port $port..."

  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import http.server, socketserver, subprocess

PORT = '$port'

class UnleashHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/metrics":
            self.send_response(200)
            self.send_header("Content-type", "text/plain; version=0.0.4")
            self.end_headers()
            metrics = subprocess.check_output(["bash", "-c", "source '$SCRIPT_DIR'/lib/colors.sh; source '$SCRIPT_DIR'/lib/web.sh; generate_prometheus_metrics"]).decode("utf-8")
            self.wfile.write(metrics.encode("utf-8"))
        else:
            self.send_response(200)
            self.send_header("Content-type", "text/html")
            self.end_headers()
            html = subprocess.check_output(["bash", "-c", "source '$SCRIPT_DIR'/lib/colors.sh; source '$SCRIPT_DIR'/lib/web.sh; generate_html_dashboard"]).decode("utf-8")
            self.wfile.write(html.encode("utf-8"))

with socketserver.TCPServer(("", PORT), UnleashHandler) as httpd:
    print(f"Server running on port {PORT}")
    httpd.serve_forever()
' &
    echo $! > "$WEB_PID_FILE"
    success "Web server started in background (PID: $(cat "$WEB_PID_FILE")). Access at http://localhost:$port"
  else
    warn "python3 is required for the web dashboard."
    return 1
  fi
}

cmd_web_stop() {
  if [ -f "$WEB_PID_FILE" ]; then
    local pid
    pid=$(cat "$WEB_PID_FILE")
    kill "$pid" 2>/dev/null || true
    rm -f "$WEB_PID_FILE"
    success "Unleash Web server stopped."
  else
    info "No web server PID file found."
  fi
}
