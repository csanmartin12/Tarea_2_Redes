#!/usr/bin/env python3
"""Genera la narración del video (un MP3 por bloque) con edge-tts.

Uso (en la VM, con internet):
    pip install --break-system-packages edge-tts
    python3 scripts/generar_voz.py              # voz masculina chilena
    python3 scripts/generar_voz.py --voz es-CL-CatalinaNeural   # voz femenina chilena
Los audios quedan en voz/bloque_01.mp3 ... voz/bloque_11.mp3
"""
import argparse, asyncio, os
import edge_tts

BLOQUES = [
    "Cuando ves un stream en Twitch, ¿alguna vez te preguntaste cómo llega el video desde el computador del streamer hasta el servidor? Casi siempre, ese primer tramo viaja por un protocolo llamado RTMP. Así que lo armé en mi computador, lo hice funcionar y lo espié paquete por paquete. Te muestro qué encontré.",
    "RTMP viene de la época de Flash. Lo inventó Macromedia, después lo heredó Adobe, y aunque Flash ya no existe, el protocolo siguió vivo: hoy es lo que usan programas como OBS para subir una transmisión en vivo. Va sobre TCP, en el puerto 1935, y su gracia es que mezcla audio, video y comandos en una sola conexión, sin que un cuadro de video pesado haga esperar al audio.",
    "La idea es simple. Primero, cliente y servidor se saludan: es el handshake. Después el cliente da órdenes: connect para entrar, publish si va a transmitir, play si va a ver. Y de ahí en adelante, todo son datos: cada cuadro de audio y video viaja como un mensaje, picado en pedacitos llamados chunks. En mi montaje hay tres personajes: un VLC que transmite, el servidor Node Media Server, y otro VLC que mira.",
    "Para no instalar nada a mano, armé todo con Docker. Este archivo levanta cuatro contenedores en una red propia: el servidor, el VLC que publica, el VLC que reproduce, y un cuarto que es el espía: el sniffer. Comparte la tarjeta de red del servidor y graba todo con tcpdump. Un detalle curioso: VLC se niega a correr como administrador, así que tuve que crearle un usuario normal dentro del contenedor.",
    "Un solo comando y quedan arriba el servidor y el sniffer. En el log aparece lo importante: el servidor está escuchando en el puerto 1935. Desde ahora, todo lo que pase por ahí queda grabado.",
    "Ahora le doy play al publicador. Transmite un video de prueba de tres minutos: barras de colores y un pitido. Unos segundos después abro el reproductor, y ahí está: el video sale de un contenedor, pasa por el servidor y llega al otro. El panel web lo confirma: una sesión transmitiendo, una mirando, y más o menos 0,6 megabits por segundo en cada sentido. Y el servidor usa menos del uno por ciento del procesador. Reenviar video sin tocarlo casi no cuesta nada.",
    "Ahora lo bueno: abrir la captura en Wireshark. Y la primera trampa: si buscas rtmp, no sale nada, porque ese nombre ya lo usaba un protocolo antiguo de Apple. El filtro correcto es rtmpt, con una t al final. Y ahí aparece el saludo, con los tamaños exactos que dice la especificación: 1537 bytes, después 3073, y al final 1536. Súmale 66 bytes de cabeceras de red y calza perfecto con la captura.",
    "Este es el connect del publicador, y trae una sorpresa. En el campo flashVer dice Lavf, que es la librería de FFmpeg. O sea, el programa dice VLC, pero el que realmente habla RTMP por dentro es FFmpeg. Justo después, el servidor pone sus reglas: confirmaciones cada cinco millones de bytes y pedazos de hasta 65535 bytes, en vez de los 128 de fábrica. Así, un cuadro completo cabe en un solo pedazo.",
    "El servidor responde que la publicación partió, y desde ahí es puro audio y video: 25 cuadros de video y unos 43 de audio por segundo. En tres minutos conté 4502 cuadros de video, casi exactamente los 4500 que esperaba. En el gráfico, la subida y la bajada van prácticamente pegadas, en unos 600 kilobits por segundo. ¿Y ese pico? Es el servidor mandándole al reproductor nuevo los últimos cuadros que tenía guardados, unos 100 kilobytes de golpe. Por eso la imagen aparece en menos de 200 milisegundos.",
    "Y hubo cosas que no esperaba. El reproductor avisa cada 2,5 megabytes que va recibiendo todo, pero el servidor nunca le avisa nada al publicador: al final, el que controla el flujo es TCP. Cuando la transmisión termina, nadie le dice nada al reproductor; se queda esperando. Y si pides un stream que no existe, el servidor igual te dice que todo partió bien.",
    "En la próxima tarea voy a meter las manos en este tráfico mientras viaja: cambiar el tamaño de los pedazos, esconder los cuadros clave o cambiar el nombre del stream, y ver qué se rompe. Todo el código y la captura quedan en GitHub. Gracias por ver.",
]

# Cómo debe leer la voz algunas palabras (se aplica antes de generar el audio).
# Si alguna suena mal, cambia aquí su pronunciación y regenera ese bloque con --bloque N.
PRONUNCIACION = {
    "rtmpt": "erre te eme pe te",
    "rtmp": "erre te eme pe",
    "RTMP": "erre te eme pe",
    "TCP": "te ce pe",
    "VLC": "uve ele ce",
    "OBS": "o be ese",
    "FFmpeg": "efe efe em peg",
    "Lavf": "ele a uve efe",
    "flashVer": "flash ver",
    "tcpdump": "te ce pe dump",
}


def pronunciar(texto):
    import re
    for k in sorted(PRONUNCIACION, key=len, reverse=True):
        texto = re.sub(r"\b" + re.escape(k) + r"\b", PRONUNCIACION[k], texto)
    return texto


async def main(voz, vel, solo):
    os.makedirs("voz", exist_ok=True)
    for i, texto in enumerate(BLOQUES, 1):
        if solo and i != solo:
            continue
        out = f"voz/bloque_{i:02d}.mp3"
        await edge_tts.Communicate(pronunciar(texto), voz, rate=vel).save(out)
        print("listo", out)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--voz", default="es-CL-LorenzoNeural")
    ap.add_argument("--velocidad", default="+0%", help="por ejemplo +10%% o -5%%")
    ap.add_argument("--bloque", type=int, default=0, help="regenerar solo un bloque (1-11)")
    a = ap.parse_args()
    asyncio.run(main(a.voz, a.velocidad, a.bloque))
