#!/bin/bash
# Harmless network test for the Minecraft account. Does NOT touch the Minecraft server or its world.
#   sudo ./diagnose-minecraft.sh
# Paper stalls right after the plugin list, where it contacts Mojang's servers. This checks DNS, HTTPS (curl) and
# Java's own HTTPS client as _svc_minecraft, once from a shell and once from a throwaway launchd service
# (launchd services run in a different context, which is where "screen" broke). Takes about a minute, cleans up after itself.
set -u
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
U=_svc_minecraft; D=/opt/apps/minecraft; L=com.eliastrana.svc.mctest
JAVA="$D/jdk/jdk-25.0.4.1+1/Contents/Home/bin/java"
HOST=discovery.minecraftservices.com; URL=https://$HOST/minecraft/client
P=/Library/LaunchDaemons/$L.plist; LOG=$D/logs/mctest.log
mkdir -p "$D/logs"; chown "$U:$U" "$D" "$D/logs"

cat > "$D/Net.java" <<'JAVASRC'
import java.net.*; import java.net.http.*; import java.time.*;
public class Net {
  public static void main(String[] a) throws Exception {
    long t = System.currentTimeMillis();
    try { InetAddress[] ips = InetAddress.getAllByName(a[0]); System.out.println("  java dns   ok " + ips.length + " addr, first " + ips[0].getHostAddress() + " in " + (System.currentTimeMillis() - t) + " ms"); }
    catch (Exception e) { System.out.println("  java dns   FAILED after " + (System.currentTimeMillis() - t) + " ms: " + e); }
    t = System.currentTimeMillis();
    try {
      var c = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(15)).build();
      var r = c.send(HttpRequest.newBuilder(URI.create(a[1])).timeout(Duration.ofSeconds(20)).build(), HttpResponse.BodyHandlers.discarding());
      System.out.println("  java https ok HTTP " + r.statusCode() + " in " + (System.currentTimeMillis() - t) + " ms");
    } catch (Exception e) { System.out.println("  java https FAILED after " + (System.currentTimeMillis() - t) + " ms: " + e); }
  }
}
JAVASRC

cat > "$D/mctest.sh" <<SCRIPT
#!/bin/sh
cd $D
echo "== \$(date +%T) uid=\$(id -u) user=\$(id -un)"
echo "  curl: \$(/usr/bin/curl -sS -m 15 -o /dev/null -w 'HTTP %{http_code} in %{time_total}s' $URL 2>&1)"
echo "  dns (dscacheutil): \$(dscacheutil -q host -a name $HOST 2>&1 | grep -m1 ip_address || echo 'no address')"
$JAVA -Djava.io.tmpdir=$D/logs $D/Net.java $HOST $URL 2>&1
echo "  -- again with IPv4 only:"
$JAVA -Djava.net.preferIPv4Stack=true -Djava.io.tmpdir=$D/logs $D/Net.java $HOST $URL 2>&1
echo "== done"
SCRIPT
chown "$U:$U" "$D/Net.java" "$D/mctest.sh"; chmod 700 "$D/mctest.sh"

echo "### 1) from a normal shell, as $U"
( cd / && sudo -u "$U" env HOME="$D" "$D/mctest.sh" ) 2>&1 | sed 's/^/   /'

echo; echo "### 2) from a throwaway launchd service, as $U (this is how the real server runs)"
: > "$LOG"; chown "$U:$U" "$LOG"
cat > "$P" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$L</string>
  <key>UserName</key><string>$U</string><key>GroupName</key><string>$U</string>
  <key>WorkingDirectory</key><string>$D</string>
  <key>ProgramArguments</key><array><string>$D/mctest.sh</string></array>
  <key>EnvironmentVariables</key><dict><key>HOME</key><string>$D</string></dict>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$LOG</string><key>StandardErrorPath</key><string>$LOG</string>
</dict></plist>
PLIST
chown root:wheel "$P"; chmod 644 "$P"
launchctl bootstrap system "$P"
for _ in $(seq 1 40); do grep -q "== done" "$LOG" && break; sleep 2; done
sed 's/^/   /' "$LOG"
launchctl bootout "system/$L" 2>/dev/null; rm -f "$P" "$D/mctest.sh" "$D/Net.java"
echo; echo "cleaned up. Copy everything above and send it back."
