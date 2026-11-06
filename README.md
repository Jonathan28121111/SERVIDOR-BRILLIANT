# Servidor del Juego Brilliant

Servidor en Dart ([shelf](https://pub.dev/packages/shelf)) para registrar
usuarios del juego, iniciar sesión y jugar partidas en línea de dos jugadores.
La app vive en el repositorio `pruebas_numeros`.

## Arrancarlo

```bash
cd servidor
dart pub get
dart run bin/servidor.dart                 # puerto 8080, datos en datos/usuarios.json
dart run bin/servidor.dart --puerto 9000 --datos /ruta/usuarios.json
```

Se apaga con `Ctrl+C`.

## Pruebas

```bash
dart test
dart analyze
```

## Rutas

Todas las respuestas son JSON. Los errores tienen la forma
`{"error": "<clave>", "mensaje": "<texto>"}`.

| Método | Ruta        | Cuerpo                         | Token | Respuesta |
|--------|-------------|--------------------------------|-------|-----------|
| GET    | `/salud`    | —                              | No    | `200 {"estado": "bien"}` |
| POST   | `/registro` | `{"usuario", "contrasena"}`    | No    | `201 {"token", "usuario", "creado"}` |
| POST   | `/sesion`   | `{"usuario", "contrasena"}`    | No    | `200 {"token", "usuario", "creado"}` |
| GET    | `/yo`       | —                              | Sí    | `200 {"usuario", "creado"}` |
| DELETE | `/sesion`   | —                              | Sí    | `204` |
| DELETE | `/cuenta`   | `{"contrasena"}`               | Sí    | `204` |

El token se manda en la cabecera `Authorization: Bearer <token>`.

### Errores

| Código | Clave                 | Cuándo |
|--------|-----------------------|--------|
| 400    | `cuerpo_invalido`     | El cuerpo no es JSON |
| 400    | `faltan_campos`       | Falta `usuario` o `contrasena` |
| 400    | `nombre_invalido`     | Usuario de 3 a 20 caracteres: letras, números, `.`, `-`, `_` |
| 400    | `contrasena_corta`    | Menos de 8 caracteres |
| 400    | `falta_contrasena`    | Borrar la cuenta sin confirmar la contraseña |
| 401    | `credenciales_malas`  | Usuario o contraseña incorrectos (no dice cuál) |
| 401    | `sin_sesion`          | Token ausente, inventado, cerrado o caducado |
| 403    | `contrasena_mala`     | Contraseña incorrecta al borrar la cuenta |
| 409    | `nombre_ocupado`      | El usuario ya existe (sin distinguir mayúsculas) |
| 429    | `demasiados_intentos` | 5 fallos de inicio de sesión en 15 minutos |

## Seguridad

- Contraseñas cifradas con PBKDF2 y sal por usuario; nunca se guardan ni se
  devuelven en claro.
- Los tokens son aleatorios (32 bytes), caducan a los 7 días y se pueden cerrar.
  Viven en memoria: al reiniciar el servidor hay que volver a iniciar sesión.
- Borrar la cuenta pide la contraseña y cierra todas sus sesiones.
- El archivo de usuarios se escribe primero en un temporal y luego se renombra,
  para no corromperlo si el proceso se corta a mitad.
- CORS abierto (`*`) para que la versión web del juego pueda llamar al servidor.

## Partidas en línea

`GET /juego` abre un **WebSocket**. Todos los mensajes son JSON con un campo
`tipo`. El primero tiene que ser el saludo con el token de `/sesion` (va en el
mensaje y no en la URL para que no quede en los logs):

```json
{"tipo": "hola", "token": "<token>"}
```

Sin saludo válido en 10 s, o con un token vencido, el servidor responde
`{"tipo": "error", "error": "sin_sesion"}` y cuelga.

### Del cliente al servidor

| Tipo         | Campos                                                    | Cuándo |
|--------------|-----------------------------------------------------------|--------|
| `crear_sala` | `nivel` (1–4)                                             | En el lobby |
| `unirse`     | `codigo`                                                  | En el lobby |
| `empezar`    | —                                                         | Solo el anfitrión, con los dos en la sala |
| `anclas`     | `valores`: `[[fila, columna, numero], ...]`               | Fase `anclas` |
| `jugada`     | `ronda`, `fila`, `columna`, `numero`, `puntos`, `terminado` | Fase `juego` |
| `pasar`      | `ronda`                                                   | Fase `juego`, sin jugada posible |
| `rendirse`   | —                                                         | Fases `anclas` o `juego` |
| `salir_sala` | —                                                         | En espera o con la partida terminada |

### Del servidor al cliente

- `bienvenida`: el saludo fue aceptado.
- `estado`: la foto completa de la sala, **personal para cada jugador**. Se
  manda con cada cambio: `codigo`, `nivel`, `anfitrion`, `fase`
  (`espera`/`anclas`/`juego`/`terminada`), `ronda`, `dados`, `segundosRonda`,
  `jugadores` (con `conectado`, `listo`, `puntos`, `jugoRonda`, `terminado`,
  `segundosGracia`), `mias` (las casillas propias, para reconstruir el
  tablero) y `resultado` (`ganador`, `motivo`).
- `sin_sala`, `sala_cerrada`: ya no estás en ninguna sala.
- `reemplazada`: se abrió el juego en otra ventana; esta conexión se cierra.
- `error`: `{"error": "<clave>", "mensaje": "<texto>"}`.

### Reglas que aplica el servidor

- **Código de sala**: 6 caracteres sin los que se confunden al dictarlos
  (0/O, 1/I/L). No distingue mayúsculas. Hay un freno de 10 códigos
  equivocados por minuto contra la fuerza bruta.
- **Rondas**: los dos reciben los mismos dados. La siguiente tirada sale
  cuando ambos jugaron o pasaron. Cada ronda dura como máximo 90 s; quien no
  juega, pasa. Quien ya terminó su tablero no frena las rondas.
- **Desconexión**: el jugador tiene 60 s para volver. Mientras tanto el reloj
  de la ronda se para y el rival ve la cuenta regresiva. Al volver recibe el
  `estado` completo. Si no vuelve, el rival gana por `abandono`; si los dos se
  caen y nadie vuelve, la partida termina en `abandonoAmbos`. Se mandan pings
  cada 10 s para detectar conexiones muertas.
- **Final**: gana quien tenga más puntos cuando los dos terminan (`puntos`), o
  hay `empate`, o gana el rival de quien se rinde (`rendicion`). La sala
  terminada se borra a los 10 minutos.
- El servidor valida que el número salió en los dados, que la casilla no
  estuviera ocupada y que no se juegue dos veces la misma ronda. Las reglas de
  cada zona del tablero y el cálculo de puntos los aplica el cliente.
