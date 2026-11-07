# Servidor RTMP: Node-Media-Server v4 (https://github.com/illuspas/Node-Media-Server)
FROM node:22-alpine

RUN npm install -g node-media-server@4.4.6

WORKDIR /opt/nms
# Certificados de ejemplo incluidos en el paquete (necesarios para RTMPS/HTTPS)
RUN cp "$(npm root -g)/node-media-server/bin/key.pem" "$(npm root -g)/node-media-server/bin/cert.pem" .
COPY config.json .

# 1935 = RTMP, 1936 = RTMPS, 8000 = HTTP-FLV / WebAdmin / API, 8443 = HTTPS
EXPOSE 1935 1936 8000 8443

CMD ["node-media-server", "-c", "/opt/nms/config.json"]
