#!/bin/bash
# Prueba nativa (sin contenedores): NMS + VLC publicador + VLC reproductor, captura en loopback.
# Requiere: node + "npm install node-media-server@4.4.6" dentro de server/, vlc, tcpdump (Linux).
cd "$(dirname "$0")/.."; C=captures/nativo; mkdir -p $C; rm -f $C/*; chmod 777 $C
ROOT=$PWD; (cd server && exec setsid node node_modules/node-media-server/bin/app.js -c ./config.json > $ROOT/$C/nms.log 2>&1) &
echo $! > $C/nms.pid
sleep 4
tcpdump -i lo -s 0 -w $C/rtmp_vlc.pcap 'tcp port 1935' > /dev/null 2>&1 &
TCPD=$!; sleep 1
# VLC publicador: remux del MP4 (H.264/AAC) a FLV sobre RTMP, sin recodificar
runuser -u nobody -- cvlc -I dummy -vv media/muestra.mp4 \
  --sout '#std{access=avio,mux=ffmpeg{mux=flv},dst=rtmp://127.0.0.1:1935/live/test}' \
  vlc://quit > $C/vlc_pub.log 2>&1 &
PUB=$!
sleep 5
# VLC reproductor
runuser -u nobody -- cvlc -I dummy --vout dummy --aout dummy -vv --run-time 12 \
  rtmp://127.0.0.1:1935/live/test vlc://quit > $C/vlc_play.log 2>&1
wait $PUB; sleep 3
kill $TCPD; sleep 1
kill "$(cat $C/nms.pid)" 2>/dev/null; rm -f $C/nms.pid
