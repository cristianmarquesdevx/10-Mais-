/// Onde o app do parceiro guarda o arquivo do documento (F9).
///
/// O bucket é PRIVADO de propósito: o GET do objeto exige o JWT do dono e a
/// política de RLS. Nenhuma URL anônima entrega documento de parceiro.
///
/// ESTES VALORES SÃO CONTRATO: `scripts/contract.py` tem os mesmos
/// (`KYC_STORAGE_BUCKET`, `KYC_STORAGE_PATH_PREFIX`) e
/// `scripts/test_contract.py` confere que os dois continuam iguais — um
/// bucket divergente faria o app escrever num lugar que o servidor recusa.
library;

/// Bucket privado do KYC.
const String kycStorageBucket = 'kyc-docs';

/// Prefixo da pasta do parceiro dentro do bucket.
///
/// O path é `<prefixo>/<uid>/pending/<doc>_<ms>.jpg`: a segunda pastinha é
/// o uid do DONO, e é dela que a RLS tira a conclusão de quem pode ler e
/// escrever. O `pending` é a pasta de quem ainda não tem caso aberto — o
/// case id só existe depois que o caso é criado, e o arquivo sobe ANTES
/// (para a operação nunca ver um caso sem documento).
const String kycStoragePathPrefix = 'kyc';

/// O path do objeto no bucket.
String kycStoragePath({
  required String userId,
  required String docType,
  required int millis,
}) =>
    '$kycStoragePathPrefix/$userId/pending/${docType}_$millis.jpg';
