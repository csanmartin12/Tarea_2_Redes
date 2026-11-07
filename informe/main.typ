#import "template.typ": udp-template, title-page, RoyalBlue

#set text(lang: "es", region: "CL")
#set page(numbering: "1 ")
#set heading(numbering: "1.1.1")

#title-page(
  informe-nombre: "Protocolo RTMP: Node-Media-Server y VLC",
  informe-num: "Tarea 2",
  integrantes: "Cristian San Martín, Compañero/a", // TODO: completar pareja
  profesor: "...", // TODO
  ayudantes: "No",
  fecha: "Noviembre de 2026",
)

#show: rest => udp-template(rest)

// ================================================================
// UTILIDADES
// ================================================================

// Recuadro para capturas de pantalla pendientes (reemplazar por image("archivo.png"))
#let pendiente(desc, alto: 5cm) = rect(width: 100%, height: alto, fill: rgb("#fff4e5"),
  stroke: (dash: "dashed", paint: rgb("#d08000")),
  align(center + horizon, text(fill: rgb("#a06000"), size: 10pt)[*INSERTAR CAPTURA:* #desc]))

// Bloques de código y listados de consola
#show raw.where(block: true): set text(size: 8pt)
#show raw.where(block: true): block.with(fill: luma(246), inset: 8pt, radius: 3pt, width: 100%)

// ================================================================
// ÍNDICES
// ================================================================

#outline(
  title: text(16pt, weight: "bold", fill: RoyalBlue)[Índice de contenido],
)

#v(2em)

#outline(
  title: text(16pt, weight: "bold", fill: RoyalBlue)[Índice de tablas],
  target: figure.where(kind: table),
)

#v(2em)

#outline(
  title: text(16pt, weight: "bold", fill: RoyalBlue)[Índice de figuras],
  target: figure.where(kind: image),
)

#pagebreak()

// ================================================================
// INTRODUCCIÓN
// ================================================================

= Introducción

La transmisión de video en vivo es hoy uno de los servicios de red que más tráfico genera, y gran parte de ese tráfico comienza su recorrido a través del protocolo RTMP (_Real-Time Messaging Protocol_). Aunque los navegadores ya no reproducen RTMP directamente, el protocolo sigue siendo el estándar _de facto_ para la etapa de ingesta: los codificadores (OBS, FFmpeg, cámaras IP, VLC) empujan el flujo hacia un servidor de medios usando RTMP y es ese servidor el que luego lo redistribuye a los espectadores.

El objetivo de esta tarea es estudiar el comportamiento de RTMP en una red real a partir de una dupla servidor–cliente asignada: Node-Media-Server como servidor y VLC como cliente. Para ello se instalaron ambos programas en contenedores Docker conectados por una red _bridge_ propia, se configuraron para establecer una comunicación de publicación (un VLC envía un video al servidor) y de reproducción (otro VLC consume ese mismo flujo), y se capturó el tráfico intercambiado con `tcpdump` para analizarlo luego en Wireshark y `tshark`.

Para facilitar la comprensión del trabajo se definen los siguientes conceptos clave:
- *Servidor de medios*: programa que recibe flujos de audio y video y los redistribuye a los clientes que los solicitan (en este caso, Node-Media-Server).
- *Publicador*: cliente que envía un flujo al servidor mediante el comando `publish`.
- *Reproductor*: cliente que solicita un flujo al servidor mediante el comando `play`, lo decodifica y lo muestra.
- *Chunk*: fragmento en que RTMP divide cada mensaje para intercalar varios flujos lógicos sobre una misma conexión TCP.
- *AMF0*: formato binario con que RTMP serializa los comandos y metadatos.
- *GOP (_Group of Pictures_)*: secuencia de cuadros de video que comienza con un _keyframe_, el único cuadro que puede decodificarse sin depender de otros.

El informe se organiza en dos capítulos. La @cap-protocolo presenta el marco teórico del protocolo: su origen, sus objetivos, la estructura del _handshake_, la división de mensajes en _chunks_, los mensajes de control y los comandos AMF0, junto con una descripción del tráfico que se espera observar. La @cap-trafico documenta la instalación, la configuración y el uso de los programas, analiza en detalle el tráfico capturado y lo contrasta con lo esperado, y finalmente plantea suposiciones sobre las repercusiones que tendría modificar distintos campos del tráfico en tránsito, lo que servirá de base para el tercer capítulo (Tarea 3).

// ================================================================
// CAPÍTULO 1: INTRODUCCIÓN AL PROTOCOLO
// ================================================================

= Introducción al protocolo <cap-protocolo>

== Origen y objetivo de RTMP

RTMP es un protocolo de capa de aplicación diseñado por Macromedia (luego Adobe) para transportar audio, video y datos entre el reproductor Flash y un servidor de medios con baja latencia. Adobe publicó su especificación abierta (versión 1.0) en 2012 (Adobe Systems, 2012). Su objetivo principal es *multiplexar varios flujos lógicos (audio, video, comandos y metadatos) sobre una única conexión TCP persistente*, intercalándolos de forma que un paquete grande de video no retrase a los pequeños paquetes de audio o de control.

Funciona sobre TCP, por defecto en el puerto *1935*. Al depender de TCP, la entrega es confiable y ordenada: una pérdida se traduce en retransmisión y, por lo tanto, en aumento de latencia, nunca en datos corruptos. Existen variantes: RTMPS (RTMP sobre TLS, puerto 443 o 1936 en Node-Media-Server), RTMPT (tunelizado en HTTP) y RTMPE (cifrado propietario de Adobe).

En la actualidad su uso principal es la *ingesta* de transmisiones en vivo (YouTube Live, Twitch, Facebook Live aceptan RTMP/RTMPS), mientras que la distribución hacia los espectadores se hace con HLS, DASH, HTTP-FLV o WebRTC. La extensión _Enhanced RTMP_ (Veovera Software Organization, 2023) agrega soporte para códecs modernos (HEVC, VP9, AV1), y es precisamente lo que implementa la versión 4 de Node-Media-Server.

== Arquitectura y roles

En una sesión RTMP intervienen tres roles, que en esta tarea quedan asignados como muestra la @tab-roles.

#figure(
  table(
    columns: (auto, auto, 1fr),
    align: (center + horizon, center + horizon, left + horizon),
    [*Rol*], [*Software*], [*Función*],
    [Publicador], [VLC (`--sout`)], [Codifica o remultiplexa un video y lo empuja al servidor con el comando `publish`.],
    [Servidor], [Node-Media-Server 4.4.6], [Recibe el flujo, lo mantiene en memoria (caché de GOP) y lo reenvía a todos los suscriptores.],
    [Reproductor], [VLC], [Se suscribe a un flujo con el comando `play`, decodifica y muestra audio y video.],
  ),
  caption: [Roles de la comunicación RTMP en la tarea],
) <tab-roles>

Los flujos se identifican con una URL de la forma `rtmp://servidor:1935/aplicación/clave`. En esta tarea se usó `rtmp://nms:1935/live/test`: `live` es la _aplicación_ (enviada en el comando `connect`) y `test` es el nombre del flujo (enviado en `publish` o `play`).

== Funcionamiento del protocolo

=== Handshake

Después del _three-way handshake_ de TCP, cliente y servidor intercambian tres bloques cada uno (Adobe Systems, 2012):
- *C0 / S0* (1 byte): versión del protocolo, siempre `0x03`.
- *C1 / S1* (1536 bytes): 4 bytes de marca de tiempo, 4 bytes en cero y 1528 bytes aleatorios.
- *C2 / S2* (1536 bytes): eco del bloque recibido (C2 repite S1 y S2 repite C1), con lo cual cada extremo verifica que el otro recibió sus datos.

En la práctica, el cliente envía C0+C1 juntos, el servidor responde S0+S1+S2 en un solo envío y el cliente cierra con C2. Por lo tanto, la carga útil TCP esperada de cada bloque es:

$ "C0+C1" = 1 + 1536 = 1537 "B", quad "S0+S1+S2" = 1 + 1536 + 1536 = 3073 "B", quad "C2" = 1536 "B" $

Existe además un _handshake_ "complejo" (no documentado por Adobe) en que C1/S1 llevan un resumen HMAC-SHA256; Node-Media-Server acepta ambos.

=== Chunks y cabeceras

Cada _mensaje_ RTMP (un fotograma de video, un comando, etc.) se fragmenta en _chunks_ de tamaño máximo negociado (128 bytes por defecto, modificable con el mensaje _Set Chunk Size_). Cada chunk comienza con:
- *Basic header* (1–3 bytes): 2 bits de formato (`fmt`) y el _Chunk Stream ID_ (csid). El csid 2 está reservado para mensajes de control de protocolo.
- *Message header* de largo variable según `fmt`, como muestra la @tab-fmt. La idea es no repetir información: si un mensaje tiene el mismo largo y tipo que el anterior del mismo csid, basta con enviar el delta de tiempo.
- *Extended timestamp* (4 bytes), sólo cuando la marca de tiempo supera `0xFFFFFF`.

#figure(
  table(
    columns: (auto, auto, 1fr),
    align: (center + horizon, center + horizon, left + horizon),
    [*fmt*], [*Largo*], [*Campos incluidos*],
    [0], [11 bytes], [timestamp absoluto (3), largo del mensaje (3), _type id_ (1), _message stream id_ (4, _little-endian_)],
    [1], [7 bytes], [delta de timestamp (3), largo (3), _type id_ (1); reutiliza el stream id],
    [2], [3 bytes], [sólo delta de timestamp; reutiliza largo, tipo y stream id],
    [3], [0 bytes], [nada; continuación de un mensaje o repetición exacta del anterior],
  ),
  caption: [Tipos de cabecera de mensaje RTMP (Adobe Systems, 2012)],
) <tab-fmt>

=== Tipos de mensaje

El campo _type id_ indica qué transporta el mensaje. Los relevantes para esta tarea se resumen en la @tab-tipos.

#figure(
  table(
    columns: (auto, auto, 1fr),
    align: (center + horizon, center + horizon, left + horizon),
    [*Type id*], [*Nombre*], [*Uso*],
    [1], [Set Chunk Size], [Fija el tamaño máximo de chunk que usará el emisor.],
    [3], [Acknowledgement], [Acuse de recibo, se envía cada _window size_ bytes recibidos.],
    [4], [User Control], [Eventos: _Stream Begin_, _Set Buffer Length_, _Ping_, etc.],
    [5], [Window Ack. Size], [Cada cuántos bytes debe llegar un _Acknowledgement_.],
    [6], [Set Peer Bandwidth], [Limita el ancho de banda de salida del otro extremo (_hard_, _soft_, _dynamic_).],
    [8], [Audio Data], [Un fotograma de audio en formato de etiqueta FLV.],
    [9], [Video Data], [Un fotograma de video en formato de etiqueta FLV.],
    [18 (0x12)], [Data AMF0], [Metadatos, por ejemplo `@setDataFrame` / `onMetaData`.],
    [20 (0x14)], [Command AMF0], [Llamadas remotas: `connect`, `createStream`, `publish`, `play`, `_result`, `onStatus`.],
  ),
  caption: [Tipos de mensaje RTMP observables],
) <tab-tipos>

Los comandos se serializan en AMF0 (_Action Message Format_), un formato binario en que cada valor va precedido de un byte de tipo: `0x00` número (double de 8 bytes), `0x01` booleano, `0x02` cadena, `0x03` objeto, `0x05` nulo, `0x08` arreglo ECMA y `0x09` fin de objeto (Adobe Systems, 2007). Cada comando lleva su nombre, un _transaction id_ y un objeto de argumentos; el servidor responde con `_result`/`_error` (mismo transaction id) o con eventos `onStatus`.

En los mensajes de audio y video, el primer byte es la cabecera de la etiqueta FLV (Adobe Systems, 2010). En video, los 4 bits altos son el tipo de cuadro (1 = _keyframe_, 2 = _inter-frame_) y los 4 bajos el códec (7 = AVC/H.264), seguido de un `AVCPacketType` (0 = _sequence header_ con la configuración del decodificador, 1 = unidades NAL). En audio, los 4 bits altos indican el formato (10 = AAC) y el resto la frecuencia, resolución y canales.

== Tráfico esperado

A partir de la especificación, para una publicación seguida de una reproducción se espera la secuencia de la @fig-secuencia:
+ TCP _three-way handshake_ al puerto 1935 y handshake RTMP (C0+C1, S0+S1+S2, C2).
+ `connect` del cliente con la aplicación `live`, respondido por el servidor con _Window Acknowledgement Size_, _Set Peer Bandwidth_, _Set Chunk Size_ y `_result` (`NetConnection.Connect.Success`).
+ En el publicador: `createStream` → `_result` con el id del flujo → `publish` → `onStatus` (`NetStream.Publish.Start`) y luego metadatos (`onMetaData`), los _sequence headers_ de H.264 y AAC, y un flujo continuo de mensajes de audio y video.
+ En el reproductor: `createStream` → `play` → evento _Stream Begin_ → `onStatus` (`NetStream.Play.Start`) y el flujo de audio/video reenviado por el servidor.
+ Al terminar: `deleteStream` y cierre TCP con FIN.

En régimen permanente el tráfico debería ser casi unidireccional (publicador → servidor → reproductor), con una tasa cercana a la suma de las tasas de audio y video del archivo y con una cadencia regular. Para el video de prueba (25 fps, audio AAC a 44,1 kHz con 1024 muestras por cuadro), los intervalos esperados entre mensajes son:

$ T_"video" = frac(1, 25 "fps") = 40 "ms", quad T_"audio" = frac(1024, 44100 "Hz") = 23.2 "ms" $

#figure(
  image("secuencia.png", width: 82%),
  caption: [Diagrama de secuencia esperado para publicación y reproducción RTMP (elaboración propia)],
) <fig-secuencia>

// ================================================================
// CAPÍTULO 2: ANÁLISIS DE TRÁFICO
// ================================================================

= Análisis de tráfico <cap-trafico>

== Instalación

=== Entorno

// TODO: ajustar al equipo donde se ejecutó (SO, versión de Docker)
Se trabajó con Docker Engine y `docker compose` en un equipo Linux. Se construyeron dos imágenes propias y se usó una imagen auxiliar para capturar tráfico:
- *Servidor* (`server/Dockerfile`): imagen `node:22-alpine` sobre la que se instala `node-media-server@4.4.6` con `npm`. Se exponen los puertos 1935 (RTMP) y 8000 (HTTP-FLV, panel web y API).
- *Cliente* (`vlc/Dockerfile`): imagen `debian:bookworm-slim` con los paquetes `vlc-bin`, `vlc-plugin-base`, `vlc-plugin-video-output` y `vlc-plugin-qt`. Se crea el usuario `vlcuser`, porque VLC se niega a ejecutarse como _root_. La misma imagen se usa como publicador y como reproductor.
- *Sniffer*: imagen `nicolaka/netshoot`, que incluye `tcpdump`. Se lanza con `network_mode: service:nms`, es decir, comparte la interfaz de red del servidor y ve todo el tráfico que entra o sale de él.

Los tres servicios se conectan a la red _bridge_ `rtmpnet` (172.28.0.0/24) con direcciones fijas: servidor 172.28.0.10, publicador 172.28.0.20 y reproductor 172.28.0.30. Los archivos completos se encuentran en el Anexo. La construcción de las imágenes y el arranque del servidor se realizan con:

```bash
docker compose build
docker compose up -d nms sniffer
```

#figure(kind: image,
  pendiente[salida de `docker compose build` / `docker compose ps` con los contenedores `nms` y `sniffer` en estado _running_],
  caption: [Contenedores del servidor y del sniffer en ejecución],
) <fig-ps>

== Configuración

=== Node-Media-Server

Se usó el archivo `config.json` por defecto del paquete (@fig-config, Anexo), cuyos parámetros relevantes son `rtmp.port = 1935`, `http.port = 8000`, autenticación de publicación y reproducción desactivada (`auth.publish = false`, `auth.play = false`) y grabación automática desactivada. Al iniciar, el servidor registra en su log `Rtmp Server listening on port 0.0.0.0:1935`. Node-Media-Server no requiere declarar las aplicaciones de antemano: acepta cualquier ruta `/aplicación/clave`.

=== VLC como publicador

VLC no tiene un modo "emitir a RTMP" en su interfaz, pero su cadena de salida (`--sout`) permite usar el módulo de acceso `avio`, que delega en la biblioteca `libavformat` de FFmpeg, junto con el multiplexor FLV. Como el archivo de prueba ya está en H.264 + AAC (los códecs que admite FLV), no es necesario recodificar, sólo remultiplexar:

```bash
cvlc -I dummy /media/muestra.mp4 \
  --sout '#std{access=avio,mux=ffmpeg{mux=flv},dst=rtmp://nms:1935/live/test}' vlc://quit
```

El video de prueba (`media/muestra.mp4`) es un patrón de barras generado con FFmpeg: 640×360 a 25 fps, H.264 a 600 kbit/s con un _keyframe_ cada 50 cuadros (2 s), y un tono de 440 Hz en AAC a 96 kbit/s, 44,1 kHz; dura 30 s.

=== VLC como reproductor

El reproductor sólo necesita la URL del flujo. Para las capturas reproducibles se usó el modo sin interfaz y para la demostración el modo gráfico (servicios `player` y `player-gui` del `docker-compose.yml`):

```bash
cvlc -I dummy --vout dummy --aout dummy --run-time 12 rtmp://nms:1935/live/test vlc://quit
```

== Uso de los programas

La secuencia de uso fue: (1) levantar servidor y sniffer; (2) lanzar el publicador; (3) unos 5 s después, lanzar el reproductor durante 12 s; (4) esperar el fin del video y detener todo con `docker compose down`. El log del servidor registró ambas sesiones, como se ve en la @fig-log.

#figure(kind: image,
```
[INFO] Rtmp Server listening on port 0.0.0.0:1935
[INFO] RTMP session mw2ob5wg3nclimla 127.0.0.1:36974 start push /live/test
[INFO] RTMP session mw2ob9r47zbtx4e5 127.0.0.1:36990 start play /live/test
[INFO] RTMP session mw2ob9r47zbtx4e5 close
[INFO] RTMP session mw2ob5wg3nclimla close
```,
  caption: [Extracto del log de Node-Media-Server durante la prueba],
) <fig-log>

#figure(kind: image,
  pendiente[ventana de VLC (`player-gui`) reproduciendo `rtmp://nms:1935/live/test` con el patrón de barras de colores],
  caption: [VLC reproduciendo el flujo publicado en Node-Media-Server],
) <fig-vlc>

#figure(kind: image,
  pendiente[panel web de Node-Media-Server (`http://localhost:8000/admin`) mostrando el flujo `/live/test` activo],
  caption: [Panel de administración de Node-Media-Server con el flujo activo],
) <fig-admin>

=== Ajuste necesario en Wireshark

Al abrir la captura por primera vez, Wireshark sólo decodificó correctamente el handshake y los primeros comandos; el resto aparecía como `Unknown (0x0)` y `Malformed Packet`, e incluso como mensajes _Set Chunk Size_ con valores absurdos (1 845 943 447). La causa es que Node-Media-Server y el publicador negocian un _chunk size_ de 65 535 bytes, mientras que el disector RTMP de Wireshark descarta mensajes mayores a su preferencia `rtmpt.max_packet_size` (32 768 por defecto) y pierde la sincronización de los límites de chunk. Al subir esa preferencia a 2 000 000 (_Edit → Preferences → Protocols → RTMPT_) la captura se decodifica completa. Este detalle es en sí mismo una demostración de lo frágil que es el _framing_ de RTMP: si quien lee el flujo se equivoca en el tamaño de chunk, interpreta bytes de video como cabeceras.

== Tráfico observado

// TODO: si se reemplaza por la captura de Docker, actualizar puertos, IPs, tiempos y conteos
La captura analizada contiene dos conversaciones TCP hacia el puerto 1935 del servidor, resumidas en la @tab-conv.

#figure(
  table(
    columns: 5,
    align: center + horizon,
    [*Conexión*], [*Inicio*], [*Duración*], [*Hacia servidor*], [*Desde servidor*],
    [Publicador (puerto 36974)], [0,000 s], [29,10 s], [2 195 kB (485 tramas)], [35 kB (483 tramas)],
    [Reproductor (puerto 36990)], [4,993 s], [13,78 s], [17 kB (218 tramas)], [1 062 kB (214 tramas)],
  ),
  caption: [Conversaciones TCP de la captura (estadística _Conversations_ de Wireshark)],
) <tab-conv>

La asimetría es la esperada: el publicador sólo sube datos y el reproductor sólo los baja; en sentido contrario viajan únicamente los comandos y los ACK de TCP.

=== Establecimiento de la sesión de publicación

La @fig-ctrl lista todos los mensajes RTMP que no son audio ni video, obtenidos con el script `analizar_rtmp.sh` (@fig-script, Anexo).

#figure(kind: image,
```
 #   tiempo [s]  origen→destino  bytes  mensaje(s) RTMP
 4   0.0031      36974→1935      1603   Handshake C0+C1
 6   0.0045      1935→36974      3139   Handshake S0+S1+S2
 8   0.0046      36974→1935      1602   Handshake C2
10   0.0484      36974→1935       218   connect()
12   0.0502      1935→36974        82   Window Acknowledgement Size 5000000
14   0.0925      1935→36974       301   Set Peer Bandwidth 5000000,Dynamic | Set Chunk Size 65535 | _result()
18   0.1365      36974→1935       181   Set Chunk Size 65535 | releaseStream() | FCPublish() | createStream()
20   0.1376      1935→36974       107   _result()
23   0.1805      36974→1935       100   publish()
25   0.1814      1935→36974       195   onStatus()
28   0.6002      36974→1935     42562   @setDataFrame() | Video Data | Audio Data | Video Data | ...
197  4.9935      36990→1935      1603   Handshake C0+C1
199  4.9946      1935→36990      3139   Handshake S0+S1+S2
201  4.9947      36990→1935      1602   Handshake C2
203  5.0364      36990→1935       275   connect()
205  5.0370      1935→36990        82   Window Acknowledgement Size 5000000
207  5.0805      1935→36990       301   Set Peer Bandwidth 5000000,Dynamic | Set Chunk Size 65535 | _result()
219  5.1244      36990→1935       103   Window Acknowledgement Size 5000000 | createStream()
221  5.1250      1935→36990       107   _result()
224  5.1684      36990→1935       164   getStreamLength() | play() | Set Buffer Length 1,3000ms
226  5.1690      1935→36990        84   Stream Begin 1
228  5.2125      1935→36990     30927   onStatus() | onStatus() | |RtmpSampleAccess() | @setDataFrame() | Audio/Video ...
1397 29.1002     36974→1935       147   FCUnpublish() | deleteStream()
```,
  caption: [Mensajes RTMP de control observados (tshark, captura propia)],
) <fig-ctrl>

#figure(kind: image,
  pendiente(alto: 6.5cm)[Wireshark con filtro `rtmpt` mostrando el handshake y el comando `connect()` desplegado (campos AMF0 `app`, `flashVer`, `tcUrl`)],
  caption: [Detalle del comando `connect()` del publicador en Wireshark],
) <fig-ws-connect>

El handshake ocupa exactamente lo previsto. A cada bloque RTMP se le suman 66 bytes de cabeceras (14 de Ethernet, 20 de IP y 32 de TCP con la opción _timestamps_):

$ 1537 + 66 = 1603 "B", quad 3073 + 66 = 3139 "B", quad 1536 + 66 = 1602 "B" $

y se completa en $4.572 - 3.096 = 1.476 "ms"$ (tramas 4 a 8).

En el `connect()` (@fig-ws-connect) el publicador envía `app = "live"`, `tcUrl = "rtmp://…:1935/live"` y `flashVer = "FMLE/3.0 (compatible; Lavf60.16.100)"`. Esta última cadena revela que, aunque el programa sea VLC, quien realmente habla RTMP es `libavformat` (Lavf) de FFmpeg, que se presenta como _Flash Media Live Encoder_. Lo mismo ocurre con el reproductor, que envía `flashVer = "LNX 9,0,124,2"` (el valor por defecto de FFmpeg en modo reproducción) y además declara sus capacidades (`audioCodecs = 4071`, `videoCodecs = 252`). El servidor responde identificándose como `fmsVer = "FMS/3,0,1,123"` con `capabilities = 31`, imitando a Flash Media Server por compatibilidad, y con el código `NetConnection.Connect.Success`.

Inmediatamente el servidor impone sus parámetros: ventana de _acknowledgement_ de 5 000 000 bytes, _peer bandwidth_ dinámico de 5 000 000 bytes y un _chunk size_ de 65 535 bytes, el máximo práctico, muy por encima de los 128 bytes por defecto. El publicador responde fijando también 65 535 bytes y envía los comandos `releaseStream` y `FCPublish`, que no forman parte de la especificación de Adobe sino que son una convención heredada de FMLE; luego `createStream`, que recibe el id de flujo 1, y `publish("test", "live")`. El servidor confirma con `onStatus` (`NetStream.Publish.Start`, "/live/test is now published.").

Se observan pausas regulares de unos 42–44 ms entre cada comando y su siguiente mensaje (tramas 12→14: $92.5 - 50.2 = 42.3$ ms; 14→18: $136.5 - 92.5 = 44.0$ ms; 20→23: $180.5 - 137.6 = 42.9$ ms). Coinciden con el temporizador de _delayed ACK_ de TCP en Linux combinado con el algoritmo de Nagle, ya que el log de VLC muestra que `libavformat` abre el socket con `tcp_nodelay=0`. El efecto es que establecer la sesión toma unos 180 ms aunque la red local tenga un RTT de microsegundos.

=== Envío de medios

El primer mensaje de medios (trama 28) es un envío de 42 562 bytes que agrupa `@setDataFrame(onMetaData)`, los _sequence headers_ de H.264 (cabecera `0x17`, _keyframe_ AVC) y de AAC (cabecera `0xAF`, AAC 44 kHz estéreo) y los primeros cuadros que VLC tenía en su búfer. Los metadatos describen fielmente el archivo: `width = 640`, `height = 360`, `framerate = 25`, `videocodecid = 7` (AVC) y `audiocodecid = 10` (AAC).

A partir de ahí el tráfico es periódico. La @tab-conteo resume los mensajes por dirección. Los valores esperados para los 30 s del archivo son:

$ N_"video" = 25 "fps" times 30 "s" = 750, quad N_"audio" = frac(44100, 1024) times 30 "s" = 43.07 times 30 = 1292, quad N_"key" = frac(30 "s", 2 "s") = 15 $

El publicador envió 751 cuadros de video, de los cuales 17 son _keyframes_ (los 15 periódicos más los insertados por cambio de escena del codificador), y unos 1250 cuadros de audio (el resto queda en el búfer del codificador AAC al cortar el archivo). El reproductor, conectado sólo 12 s, recibió 346 cuadros de video y 594 de audio.

#figure(
  table(
    columns: 3,
    align: center + horizon,
    [*Concepto*], [*Publicador → NMS*], [*NMS → Reproductor*],
    [Mensajes de video (0x09)], [751], [346],
    [_Keyframes_ / _inter-frames_], [17 / 734], [8 / 338],
    [Mensajes de audio (0x08)], [≈ 1250], [594],
    [Cabeceras de chunk fmt 0 (11 bytes)], [10], [960 (todas)],
    [Cabeceras de chunk fmt 1 (7 bytes)], [1971], [0],
    [Cabeceras fmt 2 / fmt 3], [17 / 16], [0 / 0],
    [Tasa media de carga útil TCP], [≈ 601 kbit/s], [≈ 609 kbit/s],
    [Mensajes _Acknowledgement_ (0x03)], [0], [0],
  ),
  caption: [Mensajes y cabeceras por sentido de transmisión (captura propia)],
) <tab-conteo>

Un hallazgo interesante de la @tab-conteo es que cada implementación usa la compresión de cabeceras de forma distinta. El publicador (`libavformat`) aprovecha el formato 1, de 7 bytes, para casi todos los mensajes, porque cada csid transporta siempre el mismo tipo de mensaje y basta con el delta de tiempo y el largo. Node-Media-Server, en cambio, envía *siempre* cabeceras completas (fmt 0, 11 bytes) hacia el reproductor. Ambos comportamientos son válidos según la especificación; el sobrecosto del servidor es:

$ (11 - 7) "B" times 940 "mensajes" = 3760 "B" approx 3.8 "kB" $

en los 12 s de reproducción, irrelevante frente a 1 MB de video, pero muestra que el servidor prioriza la simplicidad sobre la eficiencia. Además, gracias al _chunk size_ de 65 535 bytes casi no aparecen chunks de continuación (fmt 3): un cuadro de video completo cabe en un solo chunk.

Tampoco se observó ningún mensaje _Acknowledgement_: la ventana es de 5 000 000 bytes y en toda la sesión el publicador envió unos 2,2 MB, por lo que el umbral nunca se alcanzó. El control de flujo efectivo lo hace TCP.

La @fig-throughput muestra la tasa por segundo de cada sentido. La tasa media se calculó como el total de bytes de carga útil en la ventana estable dividido por su duración; para el publicador (segundos 2 a 28):

$ overline(R)_"pub" = frac(B times 8, Delta t) = frac(1952681 "B" times 8, 26 "s") = frac(15621448 "bit", 26 "s") = 600825 "bit/s" approx 601 "kbit/s" $

valor algo menor que los nominales del archivo (video 600 + audio 96 kbit/s) porque el codificador ahorra bits en una imagen casi estática. La tasa alterna regularmente entre ≈ 570 y ≈ 650 kbit/s, lo que coincide con el GOP de 2 s: en el segundo que contiene un _keyframe_ se envía más. La bajada hacia el reproductor sigue a la subida con la misma forma, lo que confirma que el servidor reenvía sin recodificar.

#figure(
  image("throughput.png", width: 100%),
  caption: [Carga útil TCP por segundo en cada sentido (elaboración propia a partir de la captura)],
) <fig-throughput>

=== Sesión de reproducción

La sesión del reproductor (tramas 197–228) sigue el patrón esperado con algunos detalles propios de VLC/`libavformat`: antes de `play` envía `getStreamLength` (pensado para videos bajo demanda; el servidor no responde porque es un flujo en vivo), llama a `play("test", -2000)`, donde el valor negativo pide "en vivo si existe", y envía el evento de control _Set Buffer Length_ de 3000 ms para indicar cuánto búfer mantendrá.

El servidor contesta con _Stream Begin_ (evento de control de usuario 0), dos `onStatus` (`NetStream.Play.Reset` y `NetStream.Play.Start`), `|RtmpSampleAccess` (dos booleanos en falso, herencia de Flash) y los metadatos. En el mismo envío de 30 927 bytes (trama 228) incluye, sin esperar, todos los cuadros acumulados desde el último _keyframe_: es la *caché de GOP* de Node-Media-Server. Gracias a ella el reproductor recibe un _keyframe_ de inmediato y puede mostrar imagen sin esperar hasta 2 s al siguiente. Entre el inicio de la conexión del reproductor y el primer dato de video transcurren:

$ 5.2125 "s" - 4.9934 "s" = 0.219 "s" = 219 "ms" $

=== Cierre

Los dos clientes terminan de forma distinta. El publicador, al acabar el archivo, envía `FCUnpublish("test")` y `deleteStream(1)` y luego cierra TCP ordenadamente con FIN (tramas 1397–1399). El reproductor, al cumplirse `--run-time`, cierra abruptamente con un segmento *RST* (trama 1067, t = 18,77 s) sin enviar `deleteStream`. El servidor tolera ambos casos y registra `RTMP session … close` en los dos.

== Suposiciones sobre la modificación del tráfico

A continuación se plantean hipótesis sobre qué ocurriría si un intermediario pudiera modificar campos del tráfico al vuelo. Se verificarán en el capítulo 3 (Tarea 3). Como RTMP viaja sobre TCP, se asume que el atacante recalcula los checksums y respeta los números de secuencia; si no, TCP simplemente descartaría los segmentos y el efecto sería sólo retransmisiones y latencia.

+ *Byte de versión C0 distinto de 3.* La especificación indica que el servidor puede rechazar versiones que no reconoce. Se espera que Node-Media-Server cierre la conexión durante el handshake y que VLC informe un error de conexión.
+ *Bytes aleatorios de C1/S1 o el eco de C2/S2.* En el handshake simple ningún extremo verifica realmente el eco, por lo que probablemente no haya efecto. Si se usara el handshake complejo con HMAC, la verificación fallaría y la conexión se cerraría.
+ *Valor de _Set Chunk Size_.* Es el campo más delicado. Si se cambia en un sentido (por ejemplo, 65 535 → 128) el receptor interpretará los límites de chunk en lugares distintos de los que usa el emisor y leerá bytes de video como cabeceras. Se espera desincronización total del flujo y cierre de la sesión, el mismo fenómeno que sufrió Wireshark al usar un tamaño máximo incorrecto.
+ *Campo `fmt` o _Chunk Stream ID_.* Cambiar `fmt` altera el largo de la cabecera que el receptor espera leer, con el mismo efecto de desincronización. Cambiar el csid haría que el receptor asocie el chunk al estado de otro flujo lógico (por ejemplo, aplicar el delta de audio a un cuadro de video), lo que produciría marcas de tiempo erróneas.
+ *Largo del mensaje.* Si se aumenta, el receptor esperará bytes que nunca llegan y consumirá el inicio del mensaje siguiente; si se disminuye, los bytes sobrantes se interpretarán como una cabecera nueva. En ambos casos se espera corrupción del flujo.
+ *_Type id_ de 0x09 (video) a 0x08 (audio).* El servidor reenviaría cuadros de video como si fueran audio. En VLC se espera que el decodificador AAC reciba datos inválidos (errores en el log y ruido o silencio) y que el video presente saltos por cuadros faltantes.
+ *Marcas de tiempo (timestamp o delta).* No rompen el _framing_, por lo que la sesión sigue viva, pero VLC sincroniza audio y video según estas marcas: se esperan desfases labio-sonido, cuadros descartados por llegar "tarde" o pausas cuando el tiempo salta hacia adelante.
+ *Cabecera de video `0x17` → `0x27` (_keyframe_ marcado como _inter-frame_).* Node-Media-Server decide qué guardar en la caché de GOP según este bit. Si los _keyframes_ dejan de estar marcados, un reproductor que se conecte tarde no recibiría un cuadro de referencia: se esperan artefactos o pantalla gris hasta que llegue un cuadro decodificable. Alterar el `AVCPacketType` del _sequence header_ (0 → 1) impediría inicializar el decodificador H.264 y no habría video.
+ *Comandos AMF0.* Cambiar el nombre del flujo en `publish` o en `play` (por ejemplo, `test` → `tesX`) desviaría la publicación a otra clave; el reproductor quedaría esperando un flujo inexistente sin recibir datos. Cambiar el `code` de `onStatus` a `NetStream.Publish.BadName` haría probablemente que el publicador aborte. Romper la estructura AMF (por ejemplo, el byte de tipo `0x02` de una cadena) haría fallar el análisis del comando y el servidor no respondería.
+ *_Window Ack. Size_ o _Set Peer Bandwidth_.* Reducir la ventana a pocos kilobytes obligaría a enviar _Acknowledgements_ con mucha frecuencia, lo que aumentaría el tráfico de control. Con un límite _hard_ bajo, un emisor que respete la especificación debería reducir su tasa, con el consiguiente congelamiento del video en el reproductor.

== Dificultades y Visión Crítica

Durante el desarrollo de la tarea, las principales dificultades fueron:

+ *Publicar con VLC por RTMP*: la interfaz de VLC no ofrece esa opción, por lo que fue necesario construir la cadena `--sout` con el módulo `avio` y el multiplexor FLV de FFmpeg. Un primer intento recodificando el video falló por el formato de color de la fuente; la solución fue generar el video ya en H.264/AAC y sólo remultiplexarlo.
+ *Ejecutar VLC en contenedores*: VLC se niega a correr como _root_, por lo que se creó un usuario sin privilegios en la imagen. Para ver el video en pantalla además hay que compartir el servidor gráfico del host (X11 o WSLg).
+ *Decodificación en Wireshark*: con la configuración por defecto la mayor parte de la captura aparecía como paquetes malformados, hasta ajustar `rtmpt.max_packet_size`.

// ================================================================
// CONCLUSIONES
// ================================================================

= Conclusiones

// TODO: revisar y personalizar (fortalezas, debilidades y experiencia propia del grupo)
El trabajo permitió observar en una red real cómo RTMP cumple su objetivo de multiplexar audio, video y comandos sobre una única conexión TCP. El tráfico capturado coincidió en lo esencial con lo que describe la especificación de Adobe: un handshake de tamaño fijo (1537 + 3073 + 1536 bytes), una fase de negociación con mensajes de control y comandos AMF0 que dura menos de 200 ms, y luego un flujo periódico de mensajes de audio y video cuya cadencia refleja directamente las propiedades del archivo (25 cuadros de video y unos 43 de audio por segundo, un _keyframe_ cada 2 s).

Las diferencias más interesantes no estaban en la especificación, sino en las implementaciones. Se descubrió que VLC delega toda la lógica RTMP en `libavformat` de FFmpeg, que el servidor y el publicador eligen formatos de cabecera distintos para los mismos datos, que existen comandos "de facto" (`releaseStream`, `FCPublish`, `getStreamLength`) ausentes en la norma, y que Node-Media-Server usa una caché de GOP para que un reproductor nuevo vea imagen en unos 200 ms. También se comprobó que, con la ventana de 5 MB que impone el servidor, el mecanismo de _acknowledgement_ propio de RTMP prácticamente no se usa y el control de flujo recae en TCP.

El problema con el disector de Wireshark fue la lección más útil: un único parámetro de _framing_ mal interpretado (el tamaño máximo de chunk) basta para que todo el flujo se lea como basura. Esto anticipa que, de los campos que se modificarán en la Tarea 3, los que afectan la delimitación de mensajes (_chunk size_, `fmt`, largo) tendrán efectos mucho más graves que los que sólo alteran el contenido (marcas de tiempo, datos de audio o video).

Como fortaleza destacamos haber automatizado el despliegue con `docker compose` y el análisis con un script de `tshark`, lo que hace la experiencia reproducible. Como debilidad, la principal dificultad fue hacer que VLC publicara por RTMP dentro de un contenedor. Recomendamos a quien repita la experiencia ajustar desde el inicio la preferencia RTMPT de Wireshark y generar un video de prueba propio con parámetros conocidos, para poder contrastar fácilmente lo capturado con lo esperado.

= Referencias

+ Adobe Systems Incorporated (2007). _Action Message Format — AMF 0_. Adobe Systems, San José, EE. UU.
+ Adobe Systems Incorporated (2010). _Video File Format Specification, Version 10_ (FLV y F4V). Adobe Systems, San José, EE. UU.
+ Adobe Systems Incorporated (2012). _Adobe's Real Time Messaging Protocol_, versión 1.0. Adobe Systems, San José, EE. UU.
+ Chen, M. (illuspas) (2026). _Node-Media-Server v4_ [repositorio de software]. https://github.com/illuspas/Node-Media-Server
+ FFmpeg Project (2026). _FFmpeg Protocols Documentation — rtmp_. https://ffmpeg.org/ffmpeg-protocols.html\#rtmp
+ Kurose, J.; Ross, K. (2021). _Computer Networking: A Top-Down Approach_, 8ª edición. Pearson.
+ Veovera Software Organization (2023). _Enhanced RTMP_ [especificación]. https://github.com/veovera/enhanced-rtmp
+ VideoLAN (2026). _VLC media player_ [repositorio de software]. https://github.com/videolan/vlc
+ Wireshark Foundation (2026). _Wireshark User's Guide_. https://www.wireshark.org/docs/wsug_html_chunked/

#pagebreak()

= Anexo

#figure(kind: image,
```yaml
services:
  nms:
    build: ./server
    container_name: nms
    ports:
      - "1935:1935"   # RTMP
      - "8000:8000"   # HTTP-FLV / WebAdmin (http://localhost:8000/admin)
    networks:
      rtmpnet:
        ipv4_address: 172.28.0.10

  sniffer:                       # tcpdump en la interfaz del servidor
    image: nicolaka/netshoot
    network_mode: "service:nms"
    cap_add: [NET_ADMIN, NET_RAW]
    volumes:
      - ./captures:/captures
    command: ["tcpdump", "-i", "eth0", "-s", "0", "-U", "-Z", "root", "-w",
              "/captures/rtmp_docker.pcap", "tcp port 1935"]
    depends_on: [nms]

  publisher:                     # VLC publica el MP4 por RTMP
    build: ./vlc
    volumes:
      - ./media:/media:ro
    command: ["-I", "dummy", "/media/muestra.mp4", "--sout",
              "#std{access=avio,mux=ffmpeg{mux=flv},dst=rtmp://nms:1935/live/test}",
              "vlc://quit"]
    depends_on: [nms]
    networks:
      rtmpnet:
        ipv4_address: 172.28.0.20

  player:                        # VLC reproduce sin ventana
    build: ./vlc
    profiles: ["headless"]
    command: ["-I", "dummy", "--vout", "dummy", "--aout", "dummy", "-vv",
              "--run-time", "12", "rtmp://nms:1935/live/test", "vlc://quit"]
    depends_on: [nms]
    networks:
      rtmpnet:
        ipv4_address: 172.28.0.30

  player-gui:                    # VLC reproduce con ventana (X11 / WSLg)
    build: ./vlc
    profiles: ["gui"]
    entrypoint: ["vlc"]
    command: ["rtmp://nms:1935/live/test"]
    environment:
      - DISPLAY=${DISPLAY:-:0}
    volumes:
      - /tmp/.X11-unix:/tmp/.X11-unix
    depends_on: [nms]
    networks:
      rtmpnet:
        ipv4_address: 172.28.0.30

networks:
  rtmpnet:
    driver: bridge
    ipam:
      config:
        - subnet: 172.28.0.0/24
```,
  caption: [Archivo `docker-compose.yml`],
) <fig-compose>

#figure(kind: image,
```dockerfile
# Servidor RTMP: Node-Media-Server v4
FROM node:22-alpine
RUN npm install -g node-media-server@4.4.6
WORKDIR /opt/nms
RUN cp "$(npm root -g)/node-media-server/bin/key.pem" "$(npm root -g)/node-media-server/bin/cert.pem" .
COPY config.json .
EXPOSE 1935 1936 8000 8443
CMD ["node-media-server", "-c", "/opt/nms/config.json"]
```,
  caption: [Archivo `server/Dockerfile`],
) <fig-dockerfile-nms>

#figure(kind: image,
```dockerfile
# Cliente RTMP: VLC (publicador y reproductor)
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        vlc-bin vlc-plugin-base vlc-plugin-video-output vlc-plugin-qt \
        ca-certificates iproute2 iputils-ping \
    && rm -rf /var/lib/apt/lists/*
RUN useradd -m -u 1000 vlcuser      # VLC se niega a ejecutarse como root
USER vlcuser
WORKDIR /home/vlcuser
ENTRYPOINT ["cvlc"]
```,
  caption: [Archivo `vlc/Dockerfile`],
) <fig-dockerfile-vlc>

#figure(kind: image,
```json
{
    "bind": "0.0.0.0",
    "auth": { "play": false, "publish": false, "secret": "" },
    "rtmp":  { "port": 1935 },
    "rtmps": { "port": 1936, "key": "./key.pem", "cert": "./cert.pem" },
    "http":  { "port": 8000 },
    "https": { "port": 8443, "key": "./key.pem", "cert": "./cert.pem" },
    "webadmin": { "enable": true },
    "record": { "auto": false, "path": "./record" }
}
```,
  caption: [Parámetros relevantes de `server/config.json`],
) <fig-config>

#figure(kind: image,
```bash
#!/bin/bash
# Uso: ./analizar_rtmp.sh captura.pcap
P="$1"; O="-o rtmpt.max_packet_size:2000000"
echo "== Conversaciones TCP"; tshark -r "$P" -q -z conv,tcp
echo "== Mensajes RTMP de control (sin audio/video)"
tshark $O -r "$P" -Y rtmpt -T fields -e frame.number -e frame.time_relative \
  -e tcp.srcport -e tcp.dstport -e frame.len -e _ws.col.Info \
  | grep -vE "	((Audio|Video) Data\|?)+$" | cut -c1-200
echo "== Conteo por tipo de mensaje"
tshark $O -r "$P" -Y rtmpt -T fields -e _ws.col.Info | tr '|' '\n' \
  | sed 's/ [0-9(].*//' | sort | uniq -c | sort -rn
echo "== Cierre de conexiones (FIN/RST)"
tshark -r "$P" -Y "tcp.flags.fin==1 || tcp.flags.reset==1" -T fields \
  -e frame.number -e frame.time_relative -e tcp.srcport -e tcp.dstport -e tcp.flags.str
```,
  caption: [Script `analizar_rtmp.sh` (versión resumida)],
) <fig-script>
