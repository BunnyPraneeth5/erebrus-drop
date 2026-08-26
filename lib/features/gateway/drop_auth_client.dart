import 'gateway_config.dart';
import 'gateway_http.dart';
import 'gateway_models.dart';

/// Login methods the gateway has configured (`GET /api/v2/auth/methods`).
class DropAuthMethods {
  const DropAuthMethods({
    this.wallet = true,
    this.email = true,
    this.google = false,
    this.apple = false,
  });

  final bool wallet;
  final bool email;
  final bool google;
  final bool apple;

  static const unknown = DropAuthMethods();
}

/// Wallet/social auth against the Erebrus gateway (v2).
class DropAuthClient {
  DropAuthClient({String? gatewayUrl, this.onUnauthorized})
    : _base = GatewayHttp.normalizeBase(gatewayUrl ?? resolveGatewayUrl());

  final Uri _base;
  Future<void> Function(String token)? onUnauthorized;

  String get baseUrl {
    final port = _base.hasPort ? ':${_base.port}' : '';
    return '${_base.scheme}://${_base.host}$port';
  }

  /// `GET /api/v2/auth` — fetch a challenge for [walletAddress].
  Future<DropAuthChallenge> fetchAuthChallenge({
    required String walletAddress,
    String chain = 'sol',
  }) async {
    final uri = GatewayHttp.apiUri(
      _base,
      path: '/api/v2/auth',
      query: {'wallet_address': walletAddress, 'chain': chain},
    );
    final map = await GatewayHttp.getJson(uri);
    return DropAuthChallenge(
      challengeId: (map['flow_id'] ?? '').toString(),
      message: (map['message'] ?? '').toString(),
    );
  }

  /// `POST /api/v2/auth` — complete wallet-signature login.
  Future<DropAuthSession> authenticate({
    required String challengeId,
    required String signature,
    required String publicKey,
    String? referralCode,
  }) async {
    final body = <String, dynamic>{
      'flow_id': challengeId,
      'signature': signature,
      'public_key': publicKey,
    };
    final ref = referralCode?.trim();
    if (ref != null && ref.isNotEmpty) {
      body['ref'] = ref;
    }
    final map = await GatewayHttp.postJson(
      GatewayHttp.apiUri(_base, path: '/api/v2/auth'),
      body,
    );
    return DropAuthSession(
      token: (map['token'] ?? '').toString(),
      userId: (map['user_id'] ?? '').toString(),
      role: (map['role'] ?? 'user').toString(),
      walletAddress: publicKey,
    );
  }

  /// `GET /api/v2/orgs` — list organizations the caller belongs to.
  Future<List<DropOrg>> fetchOrgs(String bearerToken) async {
    final list = await GatewayHttp.getJsonList(
      GatewayHttp.apiUri(_base, path: '/api/v2/orgs'),
      bearerToken: bearerToken,
      onUnauthorized: onUnauthorized,
    );
    return list
        .whereType<Map<dynamic, dynamic>>()
        .map((e) => DropOrg.fromJson(Map<String, dynamic>.from(e)))
        .where((o) => o.id.isNotEmpty)
        .toList();
  }

  /// `POST /api/v2/orgs` — create a new organization.
  Future<DropOrg> createOrg({
    required String bearerToken,
    required String name,
    required String slug,
  }) async {
    final map = await GatewayHttp.postJson(
      GatewayHttp.apiUri(_base, path: '/api/v2/orgs'),
      {'name': name.trim(), 'slug': slug.trim().toLowerCase()},
      bearerToken: bearerToken,
      onUnauthorized: onUnauthorized,
    );
    return DropOrg.fromJson(map);
  }

  /// `POST /api/v2/referrals/redeem` — binds an invite code to the signed-in
  /// user (one referrer per account, ever). On success returns the caller's
  /// referral summary — `{code, referred_count, referral_bound, referred_by,
  /// recent}` — or `{bound: true}` when the summary can't be reloaded. There is
  /// no `message`/`xp` field: XP is awarded server-side to both parties only
  /// once the referee qualifies (active org membership), and lifetime XP is read
  /// separately from `GET /api/v2/rank/me` (`xp_earned`).
  ///
  /// Throws [GatewayException] on failure: 404 `invite code not found`, 409 when
  /// a code is already applied, or 400 for a self-redeem / missing code.
  Future<Map<String, dynamic>> redeemReferral({
    required String bearerToken,
    required String code,
  }) async {
    return GatewayHttp.postJson(
      GatewayHttp.apiUri(_base, path: '/api/v2/referrals/redeem'),
      {'code': code.trim()},
      bearerToken: bearerToken,
      onUnauthorized: onUnauthorized,
    );
  }

  /// `GET /api/v2/auth/methods` — which login methods the gateway supports.
  Future<DropAuthMethods> fetchAuthMethods() async {
    final map = await GatewayHttp.getJson(
      GatewayHttp.apiUri(_base, path: '/api/v2/auth/methods'),
    );
    return DropAuthMethods(
      wallet: map['wallet'] != false,
      email: map['email'] == true,
      google: map['google'] == true,
      apple: map['apple'] == true,
    );
  }

  /// `POST /api/v2/auth/email/login/start` — send a login code to the email.
  Future<void> emailLoginStart(
    String email, {
    String app = 'Erebrus Drop',
  }) async {
    await GatewayHttp.postJson(
      GatewayHttp.apiUri(_base, path: '/api/v2/auth/email/login/start'),
      {'email': email.trim().toLowerCase(), 'app': app},
    );
  }

  /// `POST /api/v2/auth/email/login/verify` — verify the code, get a session.
  Future<DropAuthSession> emailLoginVerify({
    required String email,
    required String code,
  }) async {
    final normalizedCode = code.replaceAll(RegExp(r'\D'), '');
    final map = await GatewayHttp.postJson(
      GatewayHttp.apiUri(_base, path: '/api/v2/auth/email/login/verify'),
      {'email': email.trim().toLowerCase(), 'code': normalizedCode},
    );
    return _identitySession(map);
  }

  /// `POST /api/v2/auth/google` — exchange a Google id_token for a session.
  Future<DropAuthSession> googleLogin(String idToken) async {
    final map = await GatewayHttp.postJson(
      GatewayHttp.apiUri(_base, path: '/api/v2/auth/google'),
      {'id_token': idToken},
    );
    return _identitySession(map);
  }

  /// `POST /api/v2/auth/apple` — validate Apple authorization and get a session.
  Future<DropAuthSession> appleLogin({
    required String idToken,
    required String authorizationCode,
    required String nonce,
    required String state,
  }) async {
    final map = await GatewayHttp.postJson(
      GatewayHttp.apiUri(_base, path: '/api/v2/auth/apple'),
      {
        'id_token': idToken,
        'authorization_code': authorizationCode,
        'nonce': nonce,
        'state': state,
      },
    );
    return _identitySession(map);
  }

  DropAuthSession _identitySession(Map<String, dynamic> map) => DropAuthSession(
    token: (map['token'] ?? '').toString(),
    userId: (map['user_id'] ?? '').toString(),
    role: (map['role'] ?? 'user').toString(),
    walletAddress:
        (map['wallet_address'] ?? map['wallet'] ?? map['public_key'] ?? '')
            .toString(),
  );
}

class DropAuthChallenge {
  const DropAuthChallenge({required this.challengeId, required this.message});
  final String challengeId;
  final String message;
}

class DropAuthSession {
  const DropAuthSession({
    required this.token,
    required this.userId,
    required this.role,
    required this.walletAddress,
  });
  final String token;
  final String userId;
  final String role;
  final String walletAddress;
}
