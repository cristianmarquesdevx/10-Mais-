/// Autenticação compartilhada do 10 é +.
///
/// Fonte única do login por código de uso único (Supabase Auth / GoTrue) usado
/// pelo passageiro, pelo parceiro e pelo console da operação. Os três apps
/// falam com o mesmo servidor de acesso e guardam a sessão do mesmo jeito —
/// antes cada app tinha sua CÓPIA do mesmo arquivo, e a divergência entre as
/// cópias era só uma questão de tempo.
library;

export 'src/auth_service.dart';
