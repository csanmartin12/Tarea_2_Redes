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
    "¿Alguna vez te preguntaste cómo llega un stream en vivo desde el computador de un streamer hasta los servidores de Twitch o YouTube? En la mayoría de los casos, el primer tramo de ese viaje usa un protocolo llamado erre te eme pe. En este video te muestro cómo lo instalé, lo hice funcionar y lo espié paquete por paquete.",
    "Erre te eme pe significa Real Time Messaging Protocol. Lo creó Macromedia, después Adobe, para el antiguo reproductor Flash. Flash murió, pero el protocolo sobrevivió: hoy es el estándar para la ingesta, es decir, para subir una transmisión en vivo al servidor. Funciona sobre te ce pe, en el puerto mil novecientos treinta y cinco, y su gracia es mezclar audio, video y comandos en una sola conexión, sin que un cuadro de video grande atrase al audio.",
    "Una sesión tiene tres partes. Primero, un saludo o handshake: el cliente y el servidor intercambian bloques de tamaño fijo. Después vienen los comandos: connect para entrar a una aplicación, publish para transmitir y play para ver. Y finalmente los datos: cada fotograma de audio y video viaja como un mensaje, cortado en pedazos llamados chunks. En mi caso tengo tres actores: un uve ele ce que publica un video, el servidor Node Media Server y otro uve ele ce que lo reproduce.",
    "Para que todo sea reproducible, lo monté con Docker. Este archivo levanta cuatro contenedores en una red propia. El servidor, con Node Media Server versión cuatro punto cuatro punto seis. Un uve ele ce publicador. Un uve ele ce reproductor. Y un cuarto contenedor, el sniffer, que comparte la tarjeta de red del servidor y graba todo el tráfico con te ce pe dump. Detalle curioso: uve ele ce se niega a ejecutarse como administrador, así que tuve que crearle un usuario normal dentro del contenedor.",
    "Con un solo comando se levantan el servidor y el sniffer. El log confirma que el servidor está escuchando en el puerto mil novecientos treinta y cinco. Desde este momento, todo lo que pase por ese puerto queda grabado.",
    "Ahora el publicador envía un video de prueba de tres minutos: barras de colores y un tono de cuatrocientos cuarenta hertz. Unos segundos después abro el reproductor, y ahí está: el video viaja del primer contenedor al servidor y del servidor al segundo contenedor. El panel web del servidor lo confirma: un stream en vivo, una sesión publicando, una viendo, y unos cero coma seis megabits por segundo en cada sentido. Y fíjate en el uso de procesador: cero coma seis por ciento. Reenviar video sin recodificarlo es muy liviano.",
    "Ahora abro la captura en Wireshark. Primera trampa: si filtras por erre te eme pe, no aparece nada, porque ese nombre pertenece a un protocolo antiguo de Apple. El filtro correcto es erre te eme pe te. Y ahí está el handshake, con los tamaños exactos que dice la especificación: mil quinientos treinta y siete bytes del cliente, tres mil setenta y tres del servidor y mil quinientos treinta y seis de cierre. Más sesenta y seis bytes de cabeceras de red, da justo lo que muestra la captura.",
    "Este es el comando connect. Mira el campo flash ver: dice Lavf, que es la librería de efe efe em peg. O sea, aunque el programa sea uve ele ce, quien realmente habla erre te eme pe por dentro es efe efe em peg. Después el servidor impone sus reglas: ventana de cinco millones de bytes y chunks de hasta sesenta y cinco mil quinientos treinta y cinco bytes, en vez de los ciento veintiocho que trae el protocolo por defecto. Con eso, un fotograma completo cabe en un solo pedazo.",
    "El servidor responde publish start, y desde ahí todo es audio y video: veinticinco cuadros de video y unos cuarenta y tres de audio por segundo. En tres minutos conté cuatro mil quinientos dos cuadros de video, prácticamente los cuatro mil quinientos esperados. En este gráfico la subida y la bajada son casi idénticas, unos seiscientos kilobits por segundo. Ese pico al abrir el reproductor es la caché del servidor: le manda de golpe unos cien kilobytes con los últimos cuadros, para que el video aparezca en menos de doscientos milisegundos.",
    "Y hubo sorpresas. El reproductor confirma lo recibido cada dos coma cinco megabytes, pero el servidor nunca le confirma nada al publicador: en la práctica, quien controla el flujo es te ce pe. Cuando termina la transmisión, el reproductor no recibe ningún aviso; simplemente se queda esperando. Y si pides un stream que no existe, el servidor igual responde play start.",
    "En la próxima tarea voy a modificar este tráfico en pleno viaje: cambiar el tamaño de chunk, desmarcar los cuadros clave o el nombre del stream, y ver qué se rompe. Todo el código y la captura están en el repositorio de GitHub. Gracias por ver.",
]


async def main(voz, vel, solo):
    os.makedirs("voz", exist_ok=True)
    for i, texto in enumerate(BLOQUES, 1):
        if solo and i != solo:
            continue
        out = f"voz/bloque_{i:02d}.mp3"
        await edge_tts.Communicate(texto, voz, rate=vel).save(out)
        print("listo", out)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--voz", default="es-CL-LorenzoNeural")
    ap.add_argument("--velocidad", default="+0%", help="por ejemplo +10%% o -5%%")
    ap.add_argument("--bloque", type=int, default=0, help="regenerar solo un bloque (1-11)")
    a = ap.parse_args()
    asyncio.run(main(a.voz, a.velocidad, a.bloque))
