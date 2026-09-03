# Video de Hannah: montaje de capacidades

Tipo trailer: musica, rotulos cortos en pantalla, sin locucion. Todo lo que se ve son capturas
reales del escritorio con Hannah encima; no hay maquetas ni pantallas falsas. Se tiene que
entender en mudo, porque en la portada del site el video arranca sin sonido y en bucle.

Dos cortes del mismo material:

- **Hero, 30 s**: 7 golpes de 3 a 5 s, uno por capacidad. Va en la portada.
- **Extendido, 60 a 75 s**: los mismos golpes con mas aire y tres mas (bienvenida, panel, otro avatar). Para YouTube y el README.

## Estilo

- **Rotulos** en la esquina inferior izquierda, dos lineas como mucho: una palabra grande y una
  frase corta debajo. Tipografia Fraunces para la palabra grande e Inter para la frase (las del
  site), blanco sobre el video, con la palabra grande en el lila del site (#b48cff). Nada de
  cajas ni fondos detras del texto: el escritorio ya es oscuro.
- **Ritmo**: cada golpe entra con la accion ya empezando, no con la ventana quieta. Corte seco
  entre golpes, sin transiciones. El rotulo aparece al primer frame del golpe y se va con el.
- **Musica**: electronica suave, sin voz, con pulso claro para cortar al ritmo. Que baje un poco
  en el golpe de la carpeta (es el mas largo y el mas importante).
- **Encuadre**: pantalla completa 1920x1080 con la ventana de Hannah en su esquina real (400x620)
  y el resto del escritorio visible. Cuando hay que ver detalle (la cara, la pildora de permiso),
  zoom de edicion al 200% sobre la ventana, suave, no un corte.
- Sin voz en off. La voz de Hannah solo en dos golpes (saludo y chiste), muy baja bajo la musica,
  para que en la version con sonido se note que la voz y la boca van juntas.

## Hero, 30 segundos

| # | Dur. | Rotulo | Que se ve |
|---|---|---|---|
| 1 | 0 a 4 s | (sin rotulo, solo el logo "Hannah" pequeño arriba a la izquierda que se queda todo el video) | El escritorio real con ventanas abiertas y ella en la esquina, idle: respira, parpadea, te sigue con la mirada. Que quede claro que es un overlay encima de todo. |
| 2 | 4 a 8 s | **Talks back** / in real time, with a face and a body | Zoom a la ventana: le dices "Hi Hannah" (no se oye) y ella responde saludando con la mano; boca, gesto y expresion a la vez. |
| 3 | 8 a 16 s | **Hands** / gives her a job, she asks before anything risky | Plano ancho: el gestor de archivos abierto con Downloads hecho un desastre. Aparece la pildora "permission to create four folders", clic en si, el panel de terminal enseña los `mkdir` y `mv`, y en el gestor van apareciendo las carpetas y moviendose los archivos. El golpe largo. |
| 4 | 16 a 20 s | **Sees** / describes what your camera sees | Indicador de camara encendido en el HUD y el texto de lo que ve apareciendo en el chat ("a mug next to a notebook..."). |
| 5 | 20 a 23 s | **Lives on your desktop** / stays on top, moves between screens | Salto al otro monitor (o de esquina a esquina si hay uno) y sigue encima de la ventana que este debajo. |
| 6 | 23 a 27 s | **Yours** / your GPU or any API, open source | Corte rapido al panel ⚙: las tres tarjetas, clic entre "En mi PC" y "En la nube". Dos segundos bastan. |
| 7 | 27 a 30 s | **Any avatar** / drop in a VRM | Cambia a otro VRM desde la tarjeta Look y el nuevo ya esta hablando y gesticulando. Congela el ultimo frame; la portada lo repite. |

Sin tarjeta final: el comando de instalacion esta justo debajo del video en la pagina.

Si un golpe no sale bien en tu maquina, quitalo y alarga el 3: el video aguanta con seis.

## Extendido, 60 a 75 segundos

Mismos golpes, con 1 o 2 s mas cada uno, y estos tres intercalados:

- Antes del 2: **First run** / she asks where to think. La pantalla de bienvenida: se ve "En mi PC" recomendado con tu GPU detectada y el clic. 5 s.
- Despues del 3: **Interrupt her** / she stops the instant you talk. Ella esta contando algo largo y se calla en seco a mitad de palabra cuando hablas. Zoom a la cara. 4 s.
- Despues del 4: **Body language** / generated per sentence, not canned clips. Dos frases seguidas con gestos distintos, plano medio de la ventana. 5 s.

Cierre: el site con la seccion Install, tu sistema detectado en las pestañas y el comando; clic en Copy. 4 s. Rotulo: **One command** / Linux, macOS, Windows.

## Capturar el material

Aunque no se oiga, ella tiene que hacer las cosas de verdad delante de la camara, asi que se
graba como una sesion normal y luego se corta. Lista para dejarlo todo listo antes de darle a
grabar:

1. Escritorio ordenado con dos o tres ventanas reales detras (editor, navegador), modo no molestar.
2. `hannah` en marcha y caliente: habla con ella un minuto antes para que todos los modelos esten cargados.
3. Manos activas (`AGENT_ENABLED=true`, key en el panel, `TOOLS_ENABLED=true`); `hannah doctor` con todo en verde.
4. Downloads con 10 o 12 archivos reales mezclados (PDF, JPG, ZIP, MP3, DOCX) y el gestor de archivos abierto en esa carpeta, pequeño, al lado de la ventana.
5. Camara enfocando un objeto reconocible en la mesa.
6. Un segundo VRM a mano para el golpe 7, y `"brain"` borrado de `hannah-backend/data/settings.json` justo antes del golpe de bienvenida (solo en el extendido).
7. OBS a 1920x1080, 30 fps, pantalla completa. Graba la voz de Hannah en su propia pista por si la usas en los golpes 2 y 7.

Frases que dices (no se oyen, pero disparan cada golpe): "Hi Hannah" / "Organize my downloads by
type" y "Yes" / "What's on my desk?" / "Go to the other screen" / "Tell me a joke". Si al pedir
lo de Downloads ella se inventa el resultado en vez de delegar, di "Use your hands: organize my
downloads by type". Si la aprobacion es de riesgo alto, pulsa el boton de la pildora: en video
queda igual de bien.

## Entrega

- Hero: `hannah-site/assets/demo.webm` y `assets/demo.mp4`, 1600x1000 (recorte del 1080p centrado en la ventana y el gestor de archivos). Poster: un frame del golpe 3 con las carpetas a medio aparecer, a `assets/app.jpg`.
- Extendido: `demo-tour.mp4`, 1920x1080, donde lo subas; se enlaza desde el README.
- README de GitHub (no reproduce video): un GIF de 8 a 10 s con solo el golpe 3 (la carpeta
  ordenandose) o el 2 (el saludo), 800 px de ancho, 15 fps, y debajo el enlace al video completo.
  En el site no va ningun GIF: el `<video>` mudo en bucle hace lo mismo con color completo y
  pesa diez veces menos.

Cuando lo tengas, me avisas y lo dejo puesto en el site con el poster nuevo.
