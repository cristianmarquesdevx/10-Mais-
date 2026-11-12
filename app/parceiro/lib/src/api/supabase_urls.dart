/// Onde o projeto (e o Storage) estão.
///
/// O app não inventa host: a raiz do projeto é DERIVADA da base do GoTrue
/// (`<raiz>/auth/v1`), que já vem do build. O Storage é `<raiz>/storage/v1`.
library;

/// A raiz do projeto Supabase a partir da base do GoTrue.
///
/// `http://10.0.2.2:54321/auth/v1` → `http://10.0.2.2:54321`.
///
/// Base fora do formato (um domínio customizado, por exemplo) é devolvida
/// como está: é melhor tentar o Storage no host errado do que não tentar.
String supabaseProjectRoot(String authBase) {
  var b = authBase.trim();
  if (b.endsWith('/')) b = b.substring(0, b.length - 1);
  const suffix = '/auth/v1';
  if (b.endsWith(suffix)) return b.substring(0, b.length - suffix.length);
  return b;
}
