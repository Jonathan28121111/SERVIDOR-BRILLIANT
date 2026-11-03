# Servidor de cuentas

Servidor en Dart ([shelf](https://pub.dev/packages/shelf)) para registrar
usuarios del juego e iniciar sesión.

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
