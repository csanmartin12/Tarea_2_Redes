#!/bin/bash
# Uso: ./analizar_rtmp.sh captura.pcap
# Resume una captura RTMP con tshark.
# - La captura se entrega a tshark por una tubería (cat | tshark -r -) porque en algunas
#   versiones de Ubuntu el perfil AppArmor de tshark no le deja abrir archivos directamente.
# - En Wireshark 4.2 o anteriores, el disector RTMPT descarta mensajes > 32768 bytes y NMS usa
#   chunk size 65535: si la preferencia rtmpt.max_packet_size existe, se sube a 2000000.
P="$1"
[ -r "$P" ] || { echo "No se puede leer $P"; exit 1; }
O=""
tshark -G defaultprefs 2>/dev/null | grep -q "rtmpt.max_packet_size" && O="-o rtmpt.max_packet_size:2000000"
ts() { cat "$P" | tshark $O -r - "$@" 2>/dev/null; }

echo "== Versión"; tshark --version 2>/dev/null | head -1
echo "== Conversaciones TCP"; ts -q -z conv,tcp
echo "== Mensajes RTMP de control (sin audio/video)"
ts -Y rtmpt -T fields -e frame.number -e frame.time_relative \
  -e ip.src -e tcp.srcport -e ip.dst -e tcp.dstport -e frame.len -e _ws.col.Info \
  | grep -vE "	((Audio|Video) Data\|?)+$" | cut -c1-200
echo "== Conteo por tipo de mensaje"
ts -Y rtmpt -T fields -e _ws.col.Info | tr '|' '\n' | sed 's/ [0-9(].*//' | sort | uniq -c | sort -rn
echo "== (puerto origen, fmt de cabecera de chunk, type id) -> cantidad"
ts -Y rtmpt -T fields -e tcp.srcport -e rtmpt.header.format -e rtmpt.header.typeid | python3 -c '
import sys,collections
c=collections.Counter()
for l in sys.stdin:
    s,f,t=l.rstrip("\n").split("\t")
    for a,b in zip(f.split(","),t.split(",")): c[(s,a,b)]+=1
for k,v in sorted(c.items()): print(k,v)'
echo "== Tipos de frame de video (1=keyframe, 2=inter)"
ts -Y rtmpt -T fields -e tcp.srcport -e rtmpt.video.type | python3 -c '
import sys,collections
c=collections.Counter()
for l in sys.stdin:
    s,t=l.rstrip("\n").split("\t")
    for x in t.split(","):
        if x: c[(s,x)]+=1
for k,v in sorted(c.items()): print(k,v)'
echo "== Bytes de payload TCP por segundo y sentido (puerto origen)"
ts -T fields -e frame.time_relative -e tcp.srcport -e tcp.len | python3 -c '
import sys,collections
c=collections.defaultdict(collections.Counter)
for l in sys.stdin:
    t,s,n=l.rstrip("\n").split("\t")
    if n: c[s][int(float(t))]+=int(n)
for s in sorted(c):
    print(s, " ".join(f"{k}:{v*8//1000}kbps" for k,v in sorted(c[s].items())))'
echo "== Cierre de conexiones (FIN/RST)"
ts -Y "tcp.flags.fin==1 || tcp.flags.reset==1" -T fields -e frame.number -e frame.time_relative \
  -e ip.src -e tcp.srcport -e ip.dst -e tcp.dstport -e tcp.flags.str
