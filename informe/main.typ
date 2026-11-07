#import "template.typ": udp-template, title-page, RoyalBlue

#set text(lang: "es", region: "CL")
#set page(numbering: "1 ")
#set heading(numbering: "1.1.1")

#title-page(
  informe-nombre: "Protocolo RTMP: Node-Media-Server y VLC",
  informe-num: "Tarea 2",
  integrantes: "Cristian San Martín",
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

Se trabajó en una máquina virtual con Ubuntu 26.04.1 LTS, Docker Engine 29.9.3 con Docker Compose v5.7.0 y Wireshark/tshark 4.6.4. Se construyeron dos imágenes propias y se usó una imagen auxiliar para capturar tráfico:
- *Servidor* (`server/Dockerfile`): imagen `node:22-alpine` sobre la que se instala `node-media-server@4.4.6` con `npm`. Se exponen los puertos 1935 (RTMP) y 8000 (HTTP-FLV, panel web y API).
- *Cliente* (`vlc/Dockerfile`): imagen `debian:bookworm-slim` con los paquetes `vlc-bin`, `vlc-plugin-base`, `vlc-plugin-video-output` y `vlc-plugin-qt`. Se crea el usuario `vlcuser`, porque VLC se niega a ejecutarse como _root_. La misma imagen se usa como publicador y como reproductor.
- *Sniffer*: imagen `nicolaka/netshoot`, que incluye `tcpdump`. Se lanza con `network_mode: service:nms`, es decir, comparte la interfaz de red del servidor y ve todo el tráfico que entra o sale de él.

Los tres servicios se conectan a la red _bridge_ `rtmpnet` (172.28.0.0/24) con direcciones fijas: servidor 172.28.0.10, publicador 172.28.0.20 y reproductor 172.28.0.30. Los archivos completos se encuentran en el Anexo. La construcción de las imágenes y el arranque del servidor se realizan con:

```bash
docker compose build
docker compose up -d nms sniffer
docker compose ps
docker compose logs nms
```

La @fig-ps muestra el resultado: ambos contenedores quedan en estado `Up`, el puerto 1935 del servidor queda publicado en el host y el log de Node-Media-Server confirma la versión 4.4.6 y la línea `Rtmp Server listening on port 0.0.0.0:1935`.

#figure(
  image("captura_compose.png", width: 100%),
  caption: [Arranque de los contenedores `nms` y `sniffer` y log inicial de Node-Media-Server],
) <fig-ps>

== Configuración

=== Node-Media-Server

Se usó el archivo `config.json` por defecto del paquete (@fig-config, Anexo), cuyos parámetros relevantes son `rtmp.port = 1935`, `http.port = 8000`, autenticación de publicación y reproducción desactivada (`auth.publish = false`, `auth.play = false`) y grabación automática desactivada. Sólo se fijó la contraseña del panel web (`admin`), que el servidor convierte en un _hash_ scrypt al iniciar (primeras líneas del log de la @fig-ps). Node-Media-Server no requiere declarar las aplicaciones de antemano: acepta cualquier ruta `/aplicación/clave`.

=== VLC como publicador

VLC no tiene un modo "emitir a RTMP" en su interfaz, pero su cadena de salida (`--sout`) permite usar el módulo de acceso `avio`, que delega en la biblioteca `libavformat` de FFmpeg, junto con el multiplexor FLV. Como el archivo de prueba ya está en H.264 + AAC (los códecs que admite FLV), no es necesario recodificar, sólo remultiplexar:

```bash
cvlc -I dummy /media/muestra.mp4 \
  --sout '#std{access=avio,mux=ffmpeg{mux=flv},dst=rtmp://nms:1935/live/test}' vlc://quit
```

El video de prueba (`media/muestra.mp4`) es un patrón de barras generado con FFmpeg: 640×360 a 25 fps, H.264 con un _keyframe_ cada 50 cuadros (2 s) y un tono de 440 Hz en AAC a 44,1 kHz; dura 180 s. Según `ffprobe`, las tasas reales del archivo son 500,2 kbit/s de video y 96,3 kbit/s de audio:

$ R_"archivo" = 500.184 + 96.278 = 596.462 "kbit/s" $

=== VLC como reproductor

El reproductor sólo necesita la URL del flujo. Para la demostración se usó el modo gráfico (servicio `player-gui`), que comparte con el contenedor el servidor gráfico X11 y el servidor de audio PulseAudio de la máquina virtual:

```bash
xhost +local:
docker compose --profile gui up player-gui
```

== Uso de los programas

La secuencia de uso fue:
+ levantar servidor y sniffer (@fig-ps);
+ lanzar el publicador (`docker compose up publisher`), que transmite los 180 s del archivo;
+ a los 36 s, abrir el reproductor con ventana;
+ cerrar VLC cuando terminó la publicación (t = 232 s) y abrirlo una segunda vez (t = 242 s) para repetir la prueba;
+ detener todo con `docker compose down`.

Las capturas de pantalla de VLC y del panel web se tomaron en una repetición del mismo procedimiento, levantando sólo el servidor (sin el sniffer) para no sobrescribir la captura de tráfico analizada en la sección siguiente.

La @fig-vlc muestra el reproductor en el contenedor `vlc-player-gui`: la ventana de VLC, cuyo título indica la URL `rtmp://nms:1935/live/test` y el identificador del contenedor (`on d66b8b51dd5b`), muestra el patrón de barras con el contador de segundos del video de prueba, y detrás se ve la terminal con el log del contenedor. En esta ocasión el audio también se reprodujo, gracias al socket de PulseAudio compartido con la máquina virtual.

#figure(
  image("captura_vlc.png", width: 100%),
  caption: [VLC (contenedor `vlc-player-gui`) reproduciendo el flujo publicado en Node-Media-Server],
) <fig-vlc>

El panel web de Node-Media-Server (@fig-admin) confirma desde el lado del servidor lo mismo que luego muestra la captura: un flujo en vivo con dos sesiones (_1 publishing · 1 playing_) y un tráfico de red de 0,6 Mbit/s de entrada y 0,6 Mbit/s de salida, coherente con los ≈ 607 kbit/s que sube el publicador y los ≈ 613 kbit/s que el servidor reenvía al reproductor (@tab-conteo). El proceso del servidor usa apenas 0,6 % de CPU y 82,6 MB de memoria, lo que muestra que reenviar un flujo sin recodificarlo es una tarea muy liviana.

#figure(
  image("captura_admin.png", width: 100%),
  caption: [Panel de administración de Node-Media-Server (`http://localhost:8000/admin`) con el flujo activo],
) <fig-admin>

=== Decodificación en Wireshark

Wireshark identifica el tráfico del puerto 1935 como RTMP sin configuración adicional. El filtro de visualización correcto es `rtmpt` (con "t"): el filtro `rtmp` corresponde a otro protocolo, el _Routing Table Maintenance Protocol_ de AppleTalk, y no muestra ningún paquete.

Cabe destacar que en una prueba previa con Wireshark 4.2 la mayoría de los mensajes aparecía como `Malformed Packet`, porque esa versión descarta los mensajes RTMP mayores a 32 768 bytes (preferencia `rtmpt.max_packet_size`) y Node-Media-Server negocia un _chunk size_ de 65 535 bytes: al perder un mensaje, el disector pierde también la sincronización de los límites de chunk y empieza a leer bytes de video como cabeceras. En la versión 4.6.4 usada en este informe esa preferencia ya no existe (tshark la reporta como _obsolete preference_) y la captura se decodifica completa. Este episodio muestra lo frágil que es el _framing_ de RTMP: quien lea el flujo con un tamaño de chunk equivocado lo interpreta como basura.

== Tráfico observado

La captura (`captures/rtmp_docker.pcap`) dura 242,36 s y contiene 48 204 tramas, repartidas en tres conversaciones TCP hacia el puerto 1935 del servidor (@tab-conv).

#figure(
  table(
    columns: 6,
    align: center + horizon,
    [*Conexión*], [*Inicio*], [*Duración*], [*Tramas*], [*Hacia servidor*], [*Desde servidor*],
    [Publicador \ 172.28.0.20:56514], [0,000 s], [179,16 s], [29 141], [14 MB \ (15 982 tramas)], [872 kB \ (13 159 tramas)],
    [Reproductor \ 172.28.0.30:40932], [36,172 s], [196,19 s], [19 033], [616 kB \ (9 258 tramas)], [11 MB \ (9 775 tramas)],
    [Reproductor (reintento) \ 172.28.0.30:47328], [242,158 s], [0,21 s], [30], [4 433 B \ (15 tramas)], [4 665 B \ (15 tramas)],
  ),
  caption: [Conversaciones TCP de la captura (`tshark -z conv,tcp`)],
) <tab-conv>

Las tramas de las tres conexiones suman el total de la captura:

$ 29141 + 19033 + 30 = 48204 "tramas" $

La asimetría es la esperada: el publicador sube 14 MB y recibe sólo 872 kB, que son casi exclusivamente ACK de TCP; el reproductor recibe 11 MB y envía 616 kB. De hecho, la trama más frecuente de la captura mide 66 bytes (22 297 tramas): son ACK de TCP sin carga útil.

=== Establecimiento de la sesión de publicación

La @fig-ws-lista muestra en Wireshark el inicio de la sesión de publicación y la @fig-ctrl lista todos los mensajes RTMP que no son audio ni video, obtenidos con el script `analizar_rtmp.sh` (@fig-script, Anexo).

#figure(
  image("captura_wireshark_lista.png", width: 100%),
  caption: [Inicio de la sesión de publicación en Wireshark (filtro `rtmpt`)],
) <fig-ws-lista>

#figure(kind: image,
```
   #    t [s]    sentido   bytes  mensaje(s) RTMP
    4    0.0014  P → S      1603  Handshake C0+C1
    6    0.0274  S → P      3139  Handshake S0+S1+S2
    8    0.0275  P → S      1602  Handshake C2
   12    0.0661  P → S       200  connect('live')
   14    0.0674  S → P        82  Window Acknowledgement Size 5000000
   16    0.1070  S → P       301  Set Peer Bandwidth 5000000,Dynamic
                                  | Set Chunk Size 65535
                                  | _result('NetConnection.Connect.Success')
   20    0.1480  P → S       181  Set Chunk Size 65535 | releaseStream('test')
                                  | FCPublish('test') | createStream()
   22    0.1488  S → P       107  _result()
   25    0.1890  P → S       100  publish('test')
   27    0.1897  S → P       195  onStatus('NetStream.Publish.Start')
   30    0.6472  P → S      4410  @setDataFrame() | Video Data | Audio Data
 5826   36.1722  R → S      1603  Handshake C0+C1
 5828   36.1732  S → R      3139  Handshake S0+S1+S2
 5830   36.1740  R → S      1602  Handshake C2
 5834   36.2150  R → S       257  connect('live')
 5836   36.2154  S → R        82  Window Acknowledgement Size 5000000
 5838   36.2581  S → R       301  Set Peer Bandwidth | Set Chunk Size | _result()
 5842   36.3001  R → S       103  Window Acknowledgement Size 5000000 | createStream()
 5844   36.3005  S → R       107  _result()
 5847   36.3434  R → S       164  getStreamLength() | play('test')
                                  | Set Buffer Length 3000ms
 5849   36.3447  S → R        84  Stream Begin 1
 5850   36.3454  S → R      7306  onStatus('Play.Reset') | onStatus('Play.Start')
                                  | |RtmpSampleAccess() | @setDataFrame() | Audio/Video
15348   68.6479  R → S        70  Acknowledgement 2501012
25073  101.2893  R → S        70  Acknowledgement 5003584
34892  134.2434  R → S        70  Acknowledgement 7504924
44513  166.8883  R → S        70  Acknowledgement 10008138
48161  179.1556  P → S        97  FCUnpublish()
48165  179.1556  P → S       100  deleteStream()
48178  242.1584  R2 → S     1603  Handshake C0+C1 (tercera conexión, puerto 47328)
  ...
48203  242.3642  S → R2      350  onStatus('Play.Reset') | onStatus('Play.Start')
```,
  caption: [Mensajes RTMP de control observados (tshark). P = publicador 172.28.0.20:56514, S = servidor 172.28.0.10:1935, R = reproductor 172.28.0.30:40932, R2 = reproductor 172.28.0.30:47328],
) <fig-ctrl>

El handshake ocupa exactamente lo previsto. A cada bloque RTMP se le suman 66 bytes de cabeceras (14 de Ethernet, 20 de IP y 32 de TCP con la opción _timestamps_):

$ 1537 + 66 = 1603 "B", quad 3073 + 66 = 3139 "B", quad 1536 + 66 = 1602 "B" $

El tiempo de respuesta del servidor (C0+C1 → S0+S1+S2) fue muy distinto en las dos conexiones:

$ "publicador:" quad 0.027388 - 0.001416 = 0.025972 "s" approx 26.0 "ms" $

$ "reproductor:" quad 36.173180 - 36.172224 = 0.000956 "s" approx 0.96 "ms" $

Como ambas conexiones recorren la misma red virtual, la diferencia no se debe a la red: la primera conexión que atiende Node-Media-Server después de arrancar es más lenta, probablemente por la inicialización diferida de la sesión RTMP en Node.js (carga y compilación del código la primera vez que se ejecuta). Las siguientes se atienden en menos de 1 ms.

#figure(
  image("captura_connect.png", width: 100%),
  caption: [Detalle del comando `connect('live')` del publicador en Wireshark (trama 12)],
) <fig-ws-connect>

En el `connect()` (@fig-ws-connect) se ve la cabecera de chunk completa (`Format: 0`, 11 bytes), el _chunk stream_ 3, el tipo `0x14` (comando AMF0) y un cuerpo de 133 bytes. El objeto AMF0 trae `app = 'live'`, `type = 'nonprivate'`, `tcUrl = 'rtmp://nms:1935/live'` (con el nombre DNS del contenedor del servidor) y `flashVer = 'FMLE/3.0 (compatible; Lavf59.27.100)'`. Esta última cadena revela que, aunque el programa sea VLC, quien realmente habla RTMP es `libavformat` (Lavf) de FFmpeg 5.1, la versión incluida en Debian 12, que se presenta como _Flash Media Live Encoder_. Lo mismo ocurre con el reproductor, que envía `flashVer = 'LNX 9,0,124,2'`, el valor por defecto de FFmpeg en modo reproducción.

El servidor responde con `_result('NetConnection.Connect.Success')` y, en las tramas 14 y 16, impone sus parámetros: ventana de _acknowledgement_ de 5 000 000 bytes, _peer bandwidth_ dinámico de 5 000 000 bytes y un _chunk size_ de 65 535 bytes, muy por encima de los 128 bytes por defecto. El publicador fija también 65 535 bytes y envía `releaseStream` y `FCPublish`, que no forman parte de la especificación de Adobe sino que son una convención heredada de FMLE; luego `createStream`, que recibe el id de flujo 1, y `publish('test')`.

#figure(
  image("captura_onstatus.png", width: 100%),
  caption: [Detalle de la respuesta `onStatus('NetStream.Publish.Start')` del servidor (trama 27)],
) <fig-ws-onstatus>

La respuesta `onStatus` (@fig-ws-onstatus) ya viaja en el _message stream_ 1 creado por `createStream`, y su cuerpo de 117 bytes contiene, en orden, cada uno de los tipos AMF0 descritos en la @tab-tipos: una cadena (`0x02`, `'onStatus'`), un número (`0x00`, _transaction id_ 0), un nulo (`0x05`) y un objeto (`0x03`) con `level = 'status'`, `code = 'NetStream.Publish.Start'` y `description = '/live/test is now published.'`.

Entre varios comandos se repiten pausas de unos 40 ms (tramas 14→16: $107.044 - 67.446 = 39.598$ ms; 16→20: $148.007 - 107.044 = 40.963$ ms; 22→25: $189.034 - 148.751 = 40.283$ ms). Coinciden con el temporizador de _delayed ACK_ de TCP en Linux combinado con el algoritmo de Nagle, ya que `libavformat` abre el socket sin `TCP_NODELAY`. El efecto es que la publicación queda confirmada recién a los 189,7 ms, aunque los mensajes en sí tardan menos de 1 ms en cruzar la red.

=== Envío de medios

El primer envío de medios (trama 30, t = 0,647 s) agrupa `@setDataFrame(onMetaData)`, los _sequence headers_ de H.264 (cabecera `0x17`, _keyframe_ AVC) y de AAC (cabecera `0xAF`) y los primeros cuadros. A partir de ahí el tráfico es periódico.

Una diferencia visible respecto de una prueba en _loopback_ es el tamaño de las tramas: la mayoría de las tramas con datos mide 1514 bytes, porque la red _bridge_ de Docker usa MTU 1500 (1500 de IP + 14 de Ethernet). Sin embargo, también aparecen tramas de 2962, 4410 y hasta 27 578 bytes: son varios segmentos TCP que la interfaz virtual agrupa antes de entregarlos a `tcpdump` (_segmentation/receive offload_), por lo que la captura no refleja exactamente los paquetes que cruzarían una red física.

La @tab-conteo resume los mensajes por sentido. Los valores esperados para los 180 s del archivo son:

$ N_"video" = 25 "fps" times 180 "s" = 4500, quad N_"key" = frac(180 "s", 2 "s") = 90 $

$ N_"audio" = frac(44100, 1024) times 180 "s" = 43.066 times 180 = 7752 $

El publicador envió 4502 cuadros de video, de los cuales 92 son _keyframes_ (los 90 periódicos más los insertados por cambio de escena del codificador), y 7748 cuadros de audio: ambos prácticamente iguales a lo esperado.

El reproductor recibió datos desde t = 36,345 s hasta el fin de la publicación (t = 179,156 s), es decir, durante $179.156 - 36.345 = 142.811$ s. En ese lapso se esperarían $142.811 times 25 = 3570$ cuadros de video y $142.811 times 43.066 = 6150$ de audio, pero recibió 3602 y 6201. La diferencia,

$ 3602 - 3570 = 32 "cuadros" = 32/25 = 1.28 "s de video" $

$ 6201 - 6150 = 51 "cuadros" = 51/43.066 = 1.18 "s de audio" $

corresponde a la caché de GOP que el servidor entrega al conectarse el reproductor (ver Sesión de reproducción).

#figure(
  table(
    columns: 3,
    align: center + horizon,
    [*Concepto*], [*Publicador → NMS*], [*NMS → Reproductor*],
    [Mensajes de video (0x09)], [4502], [3602],
    [_Keyframes_ / _inter-frames_], [92 / 4410], [74 / 3528],
    [Mensajes de audio (0x08)], [7748], [6201],
    [Cabeceras de chunk fmt 0 (11 bytes)], [10], [todas],
    [Cabeceras de chunk fmt 1 (7 bytes)], [11 966], [0],
    [Cabeceras fmt 2 / fmt 3], [81 / 97], [0 / 0],
    [Tasa media de carga útil TCP (s 38–177)], [607,3 kbit/s], [613,0 kbit/s],
    [Mensajes _Acknowledgement_ (0x03)], [0 (el servidor no envía)], [4 (envía el reproductor)],
  ),
  caption: [Mensajes y cabeceras por sentido de transmisión (captura propia)],
) <tab-conteo>

Un hallazgo interesante de la @tab-conteo es que cada implementación usa la compresión de cabeceras de forma distinta. El publicador (`libavformat`) usa el formato 1, de 7 bytes, para casi todos los mensajes, porque cada _chunk stream_ transporta siempre el mismo tipo de mensaje y basta con el delta de tiempo y el largo. Node-Media-Server, en cambio, envía *siempre* cabeceras completas (fmt 0, 11 bytes) hacia el reproductor. Ambos comportamientos son válidos según la especificación; con unos 9 800 mensajes de audio y video reenviados, el sobrecosto del servidor es:

$ (11 - 7) "B" times (6201 + 3602) = 4 times 9803 = 39212 "B" approx 39 "kB" $

apenas un 0,36 % de los 11 MB enviados al reproductor.

=== Tasa de transmisión

La @fig-throughput muestra la carga útil TCP por segundo en cada sentido. La tasa media se calculó en la misma ventana estable para ambos sentidos (segundos 38 a 177, 140 s):

$ overline(R)_"pub" = frac(10627311 "B" times 8, 140 "s") = frac(85018488 "bit", 140 "s") = 607275 "bit/s" approx 607.3 "kbit/s" $

$ overline(R)_"rep" = frac(10727883 "B" times 8, 140 "s") = frac(85823064 "bit", 140 "s") = 613022 "bit/s" approx 613.0 "kbit/s" $

La tasa del publicador supera en $607.3 - 596.5 = 10.8$ kbit/s a la tasa de medios del archivo. Esa diferencia es el costo del encapsulado: cada cuadro lleva una cabecera de chunk fmt 1 (1 + 7 = 8 bytes) y la cabecera de etiqueta FLV (5 bytes en video, 2 en audio):

$ 25 times (8 + 5) + 43.066 times (8 + 2) = 325 + 430.7 = 755.7 "B/s" = 6.0 "kbit/s" $

lo que explica más de la mitad de la diferencia; el resto proviene de que la tasa media del archivo se calcula sobre los 180 s y no sobre la ventana medida. La bajada hacia el reproductor es 5,7 kbit/s mayor que la subida; de eso, unos 2,2 kbit/s se explican por las cabeceras completas del servidor ($(25 + 43.066) times 4 "B" times 8 = 2178$ bit/s).

#figure(
  image("throughput.png", width: 100%),
  caption: [Carga útil TCP por segundo en cada sentido (elaboración propia a partir de la captura)],
) <fig-throughput>

En el gráfico se distinguen:
- una alternancia regular entre ≈ 570 y ≈ 660 kbit/s, con período de 2 s: el segundo que contiene un _keyframe_ transporta más bytes;
- un pico de 1353 kbit/s al iniciar la reproducción (t = 36 s), que es la caché de GOP;
- una caída a ≈ 130 kbit/s en t = 59 s seguida de un pico de ≈ 1060 kbit/s en t = 60 s, presente tanto en la subida como en la bajada: el publicador se detuvo cerca de un segundo y luego envió lo acumulado. Como el reproductor replica exactamente el mismo patrón, la pausa se originó en el publicador o en la máquina virtual, no en el servidor;
- que la curva del reproductor es una copia de la del publicador, lo que confirma que el servidor reenvía sin recodificar.

=== Sesión de reproducción

La sesión del reproductor (tramas 5826–5850) sigue el patrón esperado con algunos detalles propios de VLC/`libavformat`: antes de `play` envía `getStreamLength` (pensado para videos bajo demanda; el servidor no responde porque es un flujo en vivo), llama a `play('test')` y envía el evento de control _Set Buffer Length_ de 3000 ms para indicar cuánto búfer mantendrá.

El servidor contesta con _Stream Begin_ (evento de control de usuario 0), dos `onStatus` (`NetStream.Play.Reset` y `NetStream.Play.Start`), `|RtmpSampleAccess` (dos booleanos en falso, herencia de Flash) y los metadatos. Inmediatamente después, en las 18 tramas de los 55 ms siguientes, entrega 103 385 bytes con todos los cuadros acumulados desde el último _keyframe_ (la primera trama de video, la 5850, es un _keyframe_): es la *caché de GOP* de Node-Media-Server, que permite al reproductor mostrar imagen de inmediato en lugar de esperar hasta 2 s al siguiente _keyframe_. Entre el SYN del reproductor y el primer dato de video transcurren:

$ 36.345371 "s" - 36.172162 "s" = 0.173209 "s" approx 173 "ms" $

=== Acknowledgement de RTMP

A diferencia de lo esperado en el marco teórico, el mecanismo de _acknowledgement_ propio de RTMP sí aparece, pero sólo en un sentido. El reproductor envía un mensaje _Acknowledgement_ (tipo `0x03`) cada vez que acumula unos 2,5 MB recibidos:

$ 5003584 - 2501012 = 2502572 "B" \
  7504924 - 5003584 = 2501340 "B" \
  10008138 - 7504924 = 2503214 "B" $

es decir, a la mitad de la ventana de 5 000 000 bytes anunciada por el servidor: `libavformat` adelanta el acuse para que el servidor nunca llegue a esperarlo. En cambio, el servidor *nunca* envía _Acknowledgement_ al publicador, pese a que éste le envió más de 13,5 MB (casi tres ventanas completas). El publicador tampoco espera esos acuses, por lo que la transmisión no se ve afectada: en la práctica, el control de flujo efectivo lo hace TCP.

=== Cierre de las conexiones

El publicador, al acabar el archivo, envía `FCUnpublish('test')` y `deleteStream(1)` (t = 179,156 s) y cierra TCP ordenadamente: FIN del publicador (trama 48167) y FIN del servidor 1,2 ms después (trama 48170).

El reproductor, en cambio, no recibe ningún aviso de fin de flujo: después de t = 179,156 s simplemente deja de recibir datos y queda esperando. La conexión se cierra recién cuando se cierra la ventana de VLC, con un FIN del reproductor en t = 232,363 s (trama 48172), sin enviar `deleteStream`.

Diez segundos después (t = 242,158 s) se volvió a abrir VLC para repetir la prueba, lo que generó una tercera conexión (puerto 47328). Como la publicación ya había terminado, esta conexión permite observar qué hace el servidor ante un `play` sobre un flujo inexistente: completó el handshake y respondió `NetStream.Play.Start` aunque el flujo `/live/test` ya no existía: Node-Media-Server no informa `NetStream.Play.StreamNotFound`, sino que deja al reproductor suscrito a la espera de que alguien vuelva a publicar. La captura termina en ese punto, al detenerse los contenedores.

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
+ *Decodificación en Wireshark*: el filtro intuitivo `rtmp` no muestra nada, porque corresponde a otro protocolo; el correcto es `rtmpt`. Además, en Wireshark 4.2 la mayor parte de la captura aparecía como paquetes malformados por el límite de 32 768 bytes del disector, problema que ya no existe en la versión 4.6.
+ *Permisos de las herramientas*: el archivo de captura lo escribe `tcpdump` como _root_ dentro del contenedor, por lo que hubo que cambiar su dueño (`chown`) en el host; y el perfil AppArmor de `tshark` en Ubuntu le impedía abrir el archivo directamente, lo que se resolvió entregándole la captura por una tubería (`cat captura | tshark -r -`).
+ *Audio en el contenedor*: VLC reproducía la imagen pero no el sonido, porque el contenedor no tenía acceso al servidor de audio; se resolvió compartiendo el socket de PulseAudio del host.

// ================================================================
// CONCLUSIONES
// ================================================================

= Conclusiones

// TODO: revisar y personalizar (fortalezas, debilidades y experiencia propia)
El trabajo permitió observar en una red real cómo RTMP cumple su objetivo de multiplexar audio, video y comandos sobre una única conexión TCP. El tráfico capturado coincidió en lo esencial con lo que describe la especificación de Adobe: un handshake de tamaño fijo (1537 + 3073 + 1536 bytes), una fase de negociación con mensajes de control y comandos AMF0 que dura menos de 200 ms, y luego un flujo periódico de mensajes de audio y video cuya cadencia refleja directamente las propiedades del archivo (25 cuadros de video y unos 43 de audio por segundo, un _keyframe_ cada 2 s).

Las diferencias más interesantes no estaban en la especificación, sino en las implementaciones. Se descubrió que VLC delega toda la lógica RTMP en `libavformat` de FFmpeg, que el servidor y el publicador eligen formatos de cabecera distintos para los mismos datos, que existen comandos "de facto" (`releaseStream`, `FCPublish`, `getStreamLength`) ausentes en la norma, y que Node-Media-Server usa una caché de GOP para que un reproductor nuevo vea imagen en unos 200 ms. También se comprobó que el mecanismo de _acknowledgement_ propio de RTMP se usa sólo a medias: el reproductor acusa recibo cada 2,5 MB, pero el servidor nunca lo hace hacia el publicador, de modo que el control de flujo efectivo recae en TCP. Finalmente, el reproductor no recibe aviso alguno cuando termina la publicación, y el servidor acepta un `play` sobre un flujo inexistente sin reportar error.

El problema con el disector de Wireshark fue la lección más útil: un único parámetro de _framing_ mal interpretado (el tamaño máximo de chunk) basta para que todo el flujo se lea como basura. Esto anticipa que, de los campos que se modificarán en la Tarea 3, los que afectan la delimitación de mensajes (_chunk size_, `fmt`, largo) tendrán efectos mucho más graves que los que sólo alteran el contenido (marcas de tiempo, datos de audio o video).

Como fortaleza destaco haber automatizado el despliegue con `docker compose` y el análisis con un script de `tshark`, lo que hace la experiencia reproducible. Como debilidad, la principal dificultad fue hacer que VLC publicara por RTMP dentro de un contenedor. Recomiendo a quien repita la experiencia usar el filtro `rtmpt`, revisar la versión de Wireshark (las anteriores a la 4.6 requieren subir `rtmpt.max_packet_size`) y generar un video de prueba propio con parámetros conocidos, para poder contrastar fácilmente lo capturado con lo esperado.

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

  player-gui:                    # VLC con ventana (X11) y sonido (PulseAudio del host)
    build: ./vlc
    profiles: ["gui"]
    entrypoint: ["vlc"]
    command: ["--aout", "pulse", "rtmp://nms:1935/live/test"]
    environment:
      - DISPLAY=${DISPLAY:-:0}
      - PULSE_SERVER=unix:/run/user/1000/pulse/native
    volumes:
      - /tmp/.X11-unix:/tmp/.X11-unix
      - ${XDG_RUNTIME_DIR:-/run/user/1000}/pulse/native:/run/user/1000/pulse/native
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
P="$1"; O=""
# Wireshark <= 4.2: subir el límite del disector (NMS usa chunk size 65535)
tshark -G defaultprefs | grep -q rtmpt.max_packet_size && O="-o rtmpt.max_packet_size:2000000"
# La captura se entrega por tubería: AppArmor impide a tshark abrir archivos directamente
ts() { cat "$P" | tshark $O -r - "$@" 2>/dev/null; }
echo "== Conversaciones TCP"; ts -q -z conv,tcp
echo "== Mensajes RTMP de control (sin audio/video)"
ts -Y rtmpt -T fields -e frame.number -e frame.time_relative -e ip.src -e tcp.srcport \
   -e ip.dst -e tcp.dstport -e frame.len -e _ws.col.Info \
  | grep -vE "	((Audio|Video) Data\|?)+$" | cut -c1-200
echo "== Conteo por tipo de mensaje"
ts -Y rtmpt -T fields -e _ws.col.Info | tr '|' '\n' | sed 's/ [0-9(].*//' | sort | uniq -c | sort -rn
echo "== Cierre de conexiones (FIN/RST)"
ts -Y "tcp.flags.fin==1 || tcp.flags.reset==1" -T fields -e frame.number \
   -e frame.time_relative -e ip.src -e tcp.srcport -e ip.dst -e tcp.dstport -e tcp.flags.str
```,
  caption: [Script `analizar_rtmp.sh` (versión resumida)],
) <fig-script>
