#!/usr/bin/env python3
import argparse, html, os, subprocess, urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

ROOT="/etc/nexuspacket-manager"
DB=os.path.join(ROOT,"users.db")

def sh(*args):
    return subprocess.run(args, text=True, capture_output=True).stdout.strip()

def rows():
    out=[]
    if os.path.exists(DB):
        for line in open(DB, errors="ignore"):
            p=line.rstrip("\n").split(":")
            if len(p)>=6:
                out.append(p)
    return out

class H(BaseHTTPRequestHandler):
    def page(self, body):
        data=f"""<!doctype html><html><head><meta charset=utf-8>
        <title>NexusPacket</title>
        <style>body{{font-family:system-ui;background:#0b0d10;color:#eee;margin:30px}}
        table{{border-collapse:collapse;width:100%}}td,th{{padding:8px;border-bottom:1px solid #333}}
        a{{color:#ff4fd8}} h1{{color:#c77dff}} .card{{padding:15px;border:1px solid #333;margin-bottom:20px}}
        footer{{color:#777;margin-top:20px;font-size:13px}}</style></head>
        <body><h1>NexusPacket</h1>{body}
        <footer>Powered by NexusPacket &middot;
        <a href="https://t.me/NexusPacket_Official">Channel</a> &middot;
        <a href="https://t.me/NexusPacket">Contact</a></footer>
        </body></html>"""
        b=data.encode(); self.send_response(200); self.send_header("Content-Type","text/html; charset=utf-8")
        self.send_header("Content-Length",str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        q=urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        if self.path.startswith("/action"):
            u=q.get("user",[""])[0]; a=q.get("a",[""])[0]
            if u and a in ("lock","unlock","renew"):
                if a=="lock": sh("passwd","-l",u)
                if a=="unlock": sh("passwd","-u",u)
                if a=="renew":
                    sh("chage","-E",(sh("date","-d","+30 days","+%F") or ""),u)
            self.send_response(302); self.send_header("Location","/"); self.end_headers(); return
        trs=""
        for r in rows():
            u,e,lim,bw,st=(r[0],r[2],r[3],r[4],r[5])
            online=sh("bash","-lc",f"ps -eo user=,comm= | awk -v u='{u}' '$1==u && $2 ~ /^(sshd|sshd-session)$/ {{n++}} END{{print n+0}}'")
            trs+=f"<tr><td>{html.escape(u)}</td><td>{html.escape(e)}</td><td>{html.escape(lim)}</td><td>{html.escape(bw)} GB</td><td>{html.escape(st)}</td><td>{online}</td><td><a href='/action?a=lock&user={urllib.parse.quote(u)}'>lock</a> · <a href='/action?a=unlock&user={urllib.parse.quote(u)}'>unlock</a> · <a href='/action?a=renew&user={urllib.parse.quote(u)}'>renew</a></td></tr>"
        body=f"""<div class=card><b>Host:</b> {html.escape(sh("hostname"))}<br>
        <b>Uptime:</b> {html.escape(sh("uptime","-p"))}<br>
        <b>Load:</b> {html.escape(open("/proc/loadavg").read().split()[0])}</div>
        <table><tr><th>User</th><th>Expires</th><th>Limit</th><th>BW</th><th>Status</th><th>Online</th><th>Actions</th></tr>{trs}</table>"""
        self.page(body)

if __name__=="__main__":
    ap=argparse.ArgumentParser(); ap.add_argument("--port",type=int,default=44380)
    a=ap.parse_args(); HTTPServer(("0.0.0.0",a.port),H).serve_forever()
