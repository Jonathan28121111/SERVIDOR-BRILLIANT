import 'dart:io';

import 'package:servidor_brilliant/almacen_usuarios.dart';
import 'package:servidor_brilliant/api.dart';
import 'package:shelf/shelf_io.dart' as io;

Future<void> main(List<String> argumentos) async {
  final puerto = int.tryParse(_opcion(argumentos, '--puerto') ?? '') ?? 8080;
  final datos = _opcion(argumentos, '--datos') ?? 'datos/usuarios.json';

  final api = Api(almacen: AlmacenUsuarios(datos));
  final servidor =
      await io.serve(api.manejador, InternetAddress.anyIPv4, puerto);

  stdout.writeln('Servidor de cuentas en http://localhost:${servidor.port}');
  stdout.writeln('Usuarios guardados en $datos');
}

String? _opcion(List<String> argumentos, String nombre) {
  final i = argumentos.indexOf(nombre);
  if (i == -1 || i + 1 >= argumentos.length) {
    return null;
  }
  return argumentos[i + 1];
}
