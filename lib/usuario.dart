class Usuario {
  final String nombre;
  final String contrasenaCifrada;
  final DateTime creado;

  const Usuario({
    required this.nombre,
    required this.contrasenaCifrada,
    required this.creado,
  });

  static String normalizar(String nombre) => nombre.trim().toLowerCase();

  String get llave => normalizar(nombre);

  Map<String, dynamic> aJson() => {
        'nombre': nombre,
        'contrasena': contrasenaCifrada,
        'creado': creado.toIso8601String(),
      };

  factory Usuario.deJson(Map<String, dynamic> json) => Usuario(
        nombre: json['nombre'] as String,
        contrasenaCifrada: json['contrasena'] as String,
        creado: DateTime.parse(json['creado'] as String),
      );
}

Map<String, dynamic> usuarioPublico(Usuario usuario) => {
      'usuario': usuario.nombre,
      'creado': usuario.creado.toIso8601String(),
    };
