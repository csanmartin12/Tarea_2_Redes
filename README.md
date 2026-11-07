# Tarea 2 — Taller de Redes: RTMP con Node-Media-Server + VLC

Integrantes: Cristian San Martín, _(compañero/a)_ — Grupo 14

Dupla asignada (grupo 14):

| Rol | Software | Repositorio |
|---|---|---|
| Servidor | Node-Media-Server v4.4.6 | https://github.com/illuspas/Node-Media-Server |
| Cliente (publicador y reproductor) | VLC 3.0.x | https://github.com/videolan/vlc |

Ambos se ejecutan en contenedores Docker dentro de una red bridge `rtmpnet` (172.28.0.0/24).

```
 vlc-publisher (172.28.0.20) --RTMP publish--> nms (172.28.0.10:1935) --RTMP play--> vlc-player (172.28.0.30)
                                                  ^
                                         sniffer (tcpdump, misma interfaz que nms)
```

## Video de la entrega

Enlace: _(pegar aquí el enlace al video, ≤ 8 min)_

## Requisitos

- Docker Engine 24+ con el plugin `docker compose`.
- Wireshark en el host para abrir las capturas.
- Para ver el video en una ventana: Linux con X11 (`xhost +local:`) o Windows 11 con WSLg.
- Probado en: Ubuntu _(versión)_ en máquina virtual, Docker _(versión)_.

## Estructura

```
docker-compose.yml     orquesta servidor, publicador, reproductor y sniffer
server/                Dockerfile + config.json de Node-Media-Server
vlc/                   Dockerfile de VLC (se usa como publicador y reproductor)
media/muestra.mp4      video de prueba (H.264 640x360 25 fps + AAC 44.1 kHz, 30 s)
scripts/               analizar_rtmp.sh (resumen con tshark), prueba_nativa.sh (sin Docker)
captures/              capturas .pcap
informe/               informe en Typst (main.typ + template.typ) e imágenes
```

## Uso

```bash
# 1. Construir y levantar el servidor y la captura
docker compose up -d --build nms sniffer
docker compose logs -f nms            # debe decir "Rtmp Server listening on port 0.0.0.0:1935"

# 2. Publicar el video de prueba con VLC (dura ~30 s)
docker compose up publisher

# 3. En otra terminal, mientras se publica: reproducir con VLC
docker compose --profile headless up player      # sin ventana
# o bien
xhost +local: && docker compose --profile gui up player-gui   # con ventana

# 4. Detener y revisar la captura
docker compose down
wireshark captures/rtmp_docker.pcap
./scripts/analizar_rtmp.sh captures/rtmp_docker.pcap
```

También se puede reproducir desde el VLC del host: *Medio → Abrir ubicación de red →* `rtmp://localhost:1935/live/test`.
El panel web de Node-Media-Server está en http://localhost:8000/admin (usuario `admin`, contraseña `admin`).

## Nota sobre Wireshark

Node-Media-Server fija el *chunk size* en 65535 bytes, pero el disector RTMP de Wireshark trae
`rtmpt.max_packet_size = 32768` y, con ese valor, deja de decodificar los mensajes (aparecen como
`Unknown (0x0)` o `Malformed`). Solución: *Edit → Preferences → Protocols → RTMPT → Maximum packet size* = `2000000`
(en tshark: `-o rtmpt.max_packet_size:2000000`).

## Regenerar el video de prueba

```bash
ffmpeg -f lavfi -i testsrc=size=640x360:rate=25 -f lavfi -i sine=frequency=440:sample_rate=44100 \
  -t 30 -pix_fmt yuv420p -c:v libx264 -preset veryfast -g 50 -b:v 600k -c:a aac -b:a 96k media/muestra.mp4
```
