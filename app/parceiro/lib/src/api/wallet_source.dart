import 'client.dart';

/// Fonte do saldo da carteira do motorista.
///
/// Hoje é uma leitura ao endpoint de carteira do backend existente — o valor
/// é sempre do servidor, nunca calculado no app. Quando o backend Supabase
/// entrar, esta mesma interface recebe a implementação por Realtime (canal
/// na linha da carteira, com RLS por motorista) e a tela não muda.
abstract interface class WalletBalanceSource {
  /// Último saldo conhecido, em reais. Lança em falha de rede/servidor.
  Future<double> fetchBalance();
}

/// Leitura do saldo no endpoint de carteira do backend atual.
class ApiWalletBalanceSource implements WalletBalanceSource {
  const ApiWalletBalanceSource(this.api);

  final ApiClient api;

  @override
  Future<double> fetchBalance() async => (await api.wallet()).balance;
}
