# Cliente RTMP: VLC (https://github.com/videolan/vlc)
# La misma imagen se usa como publicador (sout -> rtmp://) y como reproductor (rtmp:// -> pantalla).
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        vlc-bin vlc-plugin-base vlc-plugin-video-output vlc-plugin-qt \
        ca-certificates iproute2 iputils-ping \
    && rm -rf /var/lib/apt/lists/*

# VLC se niega a ejecutarse como root
RUN useradd -m -u 1000 vlcuser
USER vlcuser
WORKDIR /home/vlcuser

ENTRYPOINT ["cvlc"]
