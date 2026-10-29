#!/usr/bin/env bash
# =====================================================================
#  Captures REAL screenshots of the running system into
#  docs/screenshots/auto/ using the Microsoft Edge (or Chrome) that is
#  already installed on Windows, in headless mode.
#
#     CI_IP=<server ip> JENKINS_PASSWORD=<pw> ./infra/capture-screenshots.sh
#  (infra/bootstrap-all.sh calls it automatically after collect-evidence.sh)
#
#  Web pages: blog app, Jenkins (stage view, pipeline graph), SonarQube,
#  Grafana, Prometheus. Terminal output (kubectl, MySQL, ECR, Nexus,
#  Jenkins console sections) is rendered to images from docs/evidence/.
#  Jenkins and SonarQube are switched to read-only anonymous viewing for
#  the few minutes of capture (ports are open only to your IP) and are
#  switched back at the end.
# =====================================================================
set -uo pipefail
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
cd "$(dirname "$0")/.."
: "${CI_IP:?set CI_IP}"; : "${JENKINS_PASSWORD:?set JENKINS_PASSWORD}"
OUT=docs/screenshots/auto; EV=docs/evidence; TMPD=$(mktemp -d)
mkdir -p "$OUT"; rm -f "$OUT/MISSING.md"
NS=blogapp
J="http://$CI_IP:8080"
SQ="http://$CI_IP:9000"
APP="http://$(kubectl -n $NS get ingress blogapp-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"

# ---------- find a headless browser ----------
BROWSER=""
for b in "/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe" \
         "/c/Program Files/Microsoft/Edge/Application/msedge.exe" \
         "/c/Program Files/Google/Chrome/Application/chrome.exe" \
         "$(command -v msedge chromium chromium-browser google-chrome 2>/dev/null | head -1)"; do
  [ -n "$b" ] && [ -x "$b" ] && { BROWSER=$b; break; }
done
[ -n "$BROWSER" ] || { echo "No Edge/Chrome found - cannot capture screenshots"; exit 1; }
winpath() { if command -v cygpath >/dev/null; then cygpath -w "$1"; else echo "$1"; fi; }
PROFILE=$(winpath "$TMPD/profile")

# shot <file.png> <url> [width] [height] [wait-ms]
shot() {
  local f="$1" url="$2" w="${3:-1440}" h="${4:-900}" wait="${5:-8000}"
  # --timeout = wait this long for the page to render, then capture; outer timeout guards hangs
  local mode code
  if [[ "$url" == http* ]]; then   # never capture a browser error page
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$url")
    if [ "$code" -lt 200 ] || [ "$code" -ge 400 ]; then
      echo "   [--] $f (page returned HTTP $code)"; echo "- [ ] \`$f\` - open $url and press Win+Shift+S" >> "$OUT/MISSING.md"; return
    fi
  fi
  for mode in --headless=new --headless; do
    timeout 120 "$BROWSER" $mode --disable-gpu --hide-scrollbars --no-first-run --no-default-browser-check \
      --user-data-dir="$PROFILE" --window-size="$w,$h" --timeout="$wait" \
      --screenshot="$(winpath "$PWD/$OUT/$f")" "$url" >/dev/null 2>&1
    [ -s "$OUT/$f" ] && break
  done
  if [ -s "$OUT/$f" ]; then echo "   [ok] $f"
  else echo "   [--] $f (not captured)"; echo "- [ ] \`$f\` - open $url and press Win+Shift+S" >> "$OUT/MISSING.md"; fi
}

# term <file.png> <title> <textfile>   - renders terminal output as an image
term() {
  local f="$1" title="$2" src="$3" html="$TMPD/${1%.png}.html"
  [ -s "$src" ] || { echo "   [--] $f (no source $src)"; return; }
  local lines; lines=$(wc -l < "$src")
  local h=$(( lines * 17 + 110 )); [ $h -gt 5200 ] && h=5200; [ $h -lt 300 ] && h=300
  {
    echo '<!doctype html><meta charset="utf-8"><style>
      body{margin:0;background:#0d1117;font:13px/17px Consolas,"Cascadia Mono",monospace;color:#d1d7e0}
      .bar{background:#161b22;padding:9px 14px;color:#8b949e;border-bottom:1px solid #30363d;font-family:Segoe UI,sans-serif}
      .bar b{color:#e6edf3} .dot{display:inline-block;width:11px;height:11px;border-radius:50%;margin-right:6px}
      pre{margin:0;padding:12px 16px;white-space:pre}
      .ok{color:#3fb950}.bad{color:#f85149}.cmd{color:#79c0ff}.hd{color:#d2a8ff;font-weight:bold}</style>'
    printf '<div class="bar"><span class="dot" style="background:#f85149"></span><span class="dot" style="background:#d29922"></span><span class="dot" style="background:#3fb950"></span> <b>%s</b> &nbsp; — captured %s</div><pre>' \
      "$title" "$(date '+%Y-%m-%d %H:%M')"
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
        -e 's/^\(\$ .*\)$/<span class="cmd">\1<\/span>/' \
        -e 's/^\(=\{5,\}.*\)$/<span class="hd">\1<\/span>/' \
        -e 's/\b\(SUCCESS\|Running\|Bound\|PASSED\|Passed\|OK\|successfully rolled out\|ready\)\b/<span class="ok">\1<\/span>/g' \
        -e 's/\b\(FAILURE\|FAILED\|Error\|CrashLoopBackOff\)\b/<span class="bad">\1<\/span>/g' "$src"
    echo '</pre>'
  } > "$html"
  mkdir -p "$OUT/html"; cp "$html" "$OUT/html/"   # keep the page too (open in a browser if the PNG fails)
  shot "$f" "file:///$(winpath "$html" | sed 's#\\#/#g')" 1500 "$h" 2000
}

# slice <src> <pattern> <before> <after> <dest>  - cut a section of a long log
slice() {
  local n; n=$(grep -n -m1 -- "$2" "$1" | cut -d: -f1)
  [ -n "$n" ] || { : > "$5"; return; }
  sed -n "$(( n > $3 ? n - $3 : 1 )),$(( n + $4 ))p" "$1" > "$5"
}

# ---------- temporarily allow read-only anonymous viewing ----------
JC="$TMPD/jcookies"
jenkins_groovy() {
  local crumb
  crumb=$(curl -s -c "$JC" -u "admin:$JENKINS_PASSWORD" "$J/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,%22:%22,//crumb)")
  curl -s -b "$JC" -u "admin:$JENKINS_PASSWORD" -H "$crumb" --data-urlencode "script=$1" "$J/scriptText"
}
echo ">> Enabling temporary read-only anonymous access (Jenkins, SonarQube)"
jenkins_groovy 'jenkins.model.Jenkins.get().authorizationStrategy.allowAnonymousRead = true; jenkins.model.Jenkins.get().save(); println "jenkins: anonymous read ON"'
curl -s -u "admin:$JENKINS_PASSWORD" -X POST "$SQ/api/settings/set" --data key=sonar.forceAuthentication --data value=false && echo "sonarqube: anonymous read ON"
restore() {
  jenkins_groovy 'jenkins.model.Jenkins.get().authorizationStrategy.allowAnonymousRead = false; jenkins.model.Jenkins.get().save(); println "jenkins: anonymous read OFF"'
  curl -s -u "admin:$JENKINS_PASSWORD" -X POST "$SQ/api/settings/set" --data key=sonar.forceAuthentication --data value=true && echo "sonarqube: anonymous read OFF"
  kill ${PF_G:-} ${PF_P:-} 2>/dev/null; rm -rf "$TMPD"
}
trap restore EXIT

BUILD=$(curl -s -u "admin:$JENKINS_PASSWORD" "$J/job/blogapp-cicd/lastSuccessfulBuild/api/json?tree=number" | sed -n 's/.*"number":\([0-9]*\).*/\1/p')
echo ">> Using Jenkins build #$BUILD"

# ---------------------------------------------------------------- A. Jenkins
echo ">> A. Jenkins pipeline"
PO="$J/job/blogapp-cicd/$BUILD/pipeline-overview/"
curl -s -o /dev/null -w '%{http_code}' "$PO" | grep -q 200 || PO="$J/job/blogapp-cicd/$BUILD/pipeline-graph/"
shot A1-jenkins-pipeline-overview.png "$PO" 2400 1300 15000
shot A2-jenkins-stage-view.png "$J/job/blogapp-cicd/" 3000 1100 15000
shot A3-jenkins-build-summary.png "$J/job/blogapp-cicd/$BUILD/" 1600 1100 8000
term A4-jenkins-stage-results.png "Jenkins build #$BUILD - stage results" "$EV/01-jenkins-pipeline-stages.txt"
C="$EV/02-jenkins-console-output.txt"
head -70 "$C" > "$TMPD/c1.txt";                                        term A5-console-checkout-tests.png  "Console output - checkout, install, unit tests" "$TMPD/c1.txt"
slice "$C" "QUALITY GATE STATUS\|Quality Gate\|ANALYSIS SUCCESSFUL" 25 20 "$TMPD/c2.txt"; term A6-console-sonarqube.png       "Console output - SonarQube analysis + Quality Gate" "$TMPD/c2.txt"
slice "$C" "trivy image" 2 60 "$TMPD/c3.txt";                           term A7-console-trivy.png           "Console output - Trivy image scan (gate: fixable HIGH/CRITICAL)" "$TMPD/c3.txt"
slice "$C" "repository/blogapp-artifacts" 6 30 "$TMPD/c4.txt";          term A8-console-nexus-ecr.png       "Console output - Nexus upload + image push" "$TMPD/c4.txt"
slice "$C" "kubectl apply -k k8s/" 5 45 "$TMPD/c5.txt";                 term A9-console-deploy-eks.png      "Console output - deploy to EKS + rollout" "$TMPD/c5.txt"
tail -70 "$C" > "$TMPD/c6.txt";                                         term A10-console-validation-end.png "Console output - deployment validation, Finished: SUCCESS" "$TMPD/c6.txt"

# ---------------------------------------------------------------- B. App
echo ">> B. Application (three-tier)"
SLUG=$(sed -n 's#.*Open in a browser: .*/post/\(.*\)$#\1#p' "$EV/07-three-tier-application-output.txt" | tail -1)
shot B1-app-home.png "$APP/" 1440 1100 10000
[ -n "$SLUG" ] && shot B2-app-post-with-comment.png "$APP/post/$SLUG" 1440 1300 10000
shot B3-app-register-page.png "$APP/register" 1440 900 8000
shot B4-api-posts-json.png "$APP/api/posts" 1440 900 4000
term B5-three-tier-api-flow.png "Three-tier flow: ALB -> nginx frontend -> Node API -> MySQL" "$EV/07-three-tier-application-output.txt"

# ---------------------------------------------------------------- C. Database
echo ">> C. Database"
term C1-database-mysql.png "MySQL StatefulSet: storage, credentials, schema, data, persistence test" "$EV/08-database-mysql.txt"

# ---------------------------------------------------------------- D. EKS + images
echo ">> D. EKS deployment and images"
kubectl -n $NS get deploy,sts,pods,svc,ingress,hpa,pdb -o wide > "$TMPD/d1.txt" 2>&1
term D1-kubectl-get-all.png "kubectl -n blogapp get deploy,sts,pods,svc,ingress,hpa,pdb -o wide" "$TMPD/d1.txt"
slice "$EV/06-eks-deployment.txt" "Image versions actually running" 0 14 "$TMPD/d2.txt"
slice "$EV/06-eks-deployment.txt" "Replicas, rolling update" 0 6 "$TMPD/d3.txt"; cat "$TMPD/d3.txt" >> "$TMPD/d2.txt"
term D2-image-versions-probes-limits.png "Running image versions, replicas, rolling update, probes, requests/limits" "$TMPD/d2.txt"
term D3-eks-deployment-full.png "EKS deployment - full report" "$EV/06-eks-deployment.txt"
term D4-nexus-ecr-images.png "Versioned artifacts and images in Nexus and Amazon ECR" "$EV/05-nexus-and-ecr-images.txt"
term D5-security.png "Network policies, pod security, quotas, IAM access entries, IRSA" "$EV/10-security.txt"

# ---------------------------------------------------------------- E. Quality + monitoring
echo ">> E. SonarQube, Trivy, Grafana, Prometheus"
shot E1-sonarqube-dashboard.png "$SQ/dashboard?id=blogapp" 1600 1100 15000
term E2-sonarqube-quality-gate.png "SonarQube Quality Gate and measures" "$EV/03-sonarqube.txt"
term E3-trivy-reports.png "Trivy reports (filesystem + both images)" "$EV/04-trivy-reports.txt"

echo "   generating traffic for the dashboards..."
for i in $(seq 1 150); do curl -s -o /dev/null "$APP/api/posts"; curl -s -o /dev/null "$APP/"; done
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 13000:80 >/dev/null 2>&1 & PF_G=$!
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 19090:9090 >/dev/null 2>&1 & PF_P=$!
sleep 45   # let Prometheus scrape the new traffic
shot E4-grafana-blogapp-dashboard.png "http://localhost:13000/d/blogapp-overview/?orgId=1&from=now-30m&to=now&kiosk" 1800 1400 20000
shot E5-prometheus-targets.png "http://localhost:19090/targets?search=blogapp" 1600 1000 12000
shot E6-prometheus-alert-rules.png "http://localhost:19090/alerts?search=blog" 1600 1100 12000
term E7-monitoring-logging.png "Prometheus targets, metrics, alert rules, backend logs" "$EV/09-monitoring-and-logging.txt"

echo
echo "Screenshots saved in $OUT/ :"
ls -1 "$OUT"/*.png 2>/dev/null | sed 's#.*/#   #'
[ -f "$OUT/MISSING.md" ] && { echo; echo "Not captured automatically (take these by hand):"; cat "$OUT/MISSING.md"; }
