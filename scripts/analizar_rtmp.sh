#!/bin/bash
# Uso: ./analizar_rtmp.sh captura.pcap
# Resume una captura RTMP con tshark. Sube max_packet_size porque NMS usa chunk size 65535
# y el disector de Wireshark (32768 por defecto) deja de reconocer los mensajes.
P="$1"; O="-o rtmpt.max_packet_size:2000000"
echo "== Conversaciones TCP"; tshark -r "$P" -q -z conv,tcp
echo "== Mensajes RTMP de control (sin audio/video)"
tshark $O -r "$P" -Y rtmpt -T fields -e frame.number -e frame.time_relative \
  -e tcp.srcport -e tcp.dstport -e frame.len -e _ws.col.Info \
  | grep -vE "	((Audio|Video) Data\|?)+$" | cut -c1-200
echo "== Conteo por tipo de mensaje"
tshark $O -r "$P" -Y rtmpt -T fields -e _ws.col.Info | tr '|' '\n' | sed 's/ [0-9(].*//' | sort | uniq -c | sort -rn
echo "== (puerto origen, fmt de cabecera de chunk, type id) -> cantidad"
tshark $O -r "$P" -Y rtmpt -T fields -e tcp.srcport -e rtmpt.header.format -e rtmpt.header.typeid | python3 -c '
import sys,collections
c=collections.Counter()
for l in sys.stdin:
    s,f,t=l.rstrip("\n").split("\t")
    for a,b in zip(f.split(","),t.split(",")): c[(s,a,b)]+=1
for k,v in sorted(c.items()): print(k,v)'
echo "== Tipos de frame de video (1=keyframe, 2=inter)"
tshark $O -r "$P" -Y rtmpt -T fields -e tcp.srcport -e rtmpt.video.type | python3 -c '
import sys,collections
c=collections.Counter()
for l in sys.stdin:
    s,t=l.rstrip("\n").split("\t")
    for x in t.split(","):
        if x: c[(s,x)]+=1
for k,v in sorted(c.items()): print(k,v)'
echo "== Cierre de conexiones (FIN/RST)"
tshark -r "$P" -Y "tcp.flags.fin==1 || tcp.flags.reset==1" -T fields -e frame.number -e frame.time_relative -e tcp.srcport -e tcp.dstport -e tcp.flags.str
