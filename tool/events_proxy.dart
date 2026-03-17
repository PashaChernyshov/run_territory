import 'dart:async';
import 'dart:convert';
import 'dart:io';

class _CacheEntry {
  final int statusCode;
  final String body;
  final DateTime fetchedAt;

  const _CacheEntry({
    required this.statusCode,
    required this.body,
    required this.fetchedAt,
  });
}

final Map<String, _CacheEntry> _cache = <String, _CacheEntry>{};
const _ttl = Duration(minutes: 10);

Future<void> main(List<String> args) async {
  final host = InternetAddress.anyIPv4;
  final port = 8787;
  final server = await HttpServer.bind(host, port);
  stdout.writeln('[events-proxy] listening on http://${host.address}:$port');
  stdout.writeln('[events-proxy] for local PC:    http://127.0.0.1:$port/events');
  stdout.writeln('[events-proxy] for LAN devices: http://<your-pc-ip>:$port/events');

  await for (final req in server) {
    unawaited(_handle(req));
  }
}

Future<void> _handle(HttpRequest req) async {
  _setCors(req.response);

  if (req.method == 'OPTIONS') {
    req.response.statusCode = HttpStatus.noContent;
    await req.response.close();
    return;
  }

  if (req.uri.path == '/events') {
    await _handleEvents(req);
    return;
  }

  if (req.uri.path == '/events_of_day') {
    await _handleEventsOfDay(req);
    return;
  }

  if (req.uri.path != '/events') {
    _json(req.response, HttpStatus.notFound, <String, dynamic>{
      'error': 'not_found',
      'path': req.uri.path,
    });
    return;
  }
}

Future<void> _handleEvents(HttpRequest req) async {
  final location = (req.uri.queryParameters['location'] ?? 'msk').trim();
  final actualSince = req.uri.queryParameters['actual_since'] ?? '';
  final actualUntil = req.uri.queryParameters['actual_until'] ?? '';
  final dateFrom = (req.uri.queryParameters['date_from'] ?? '').trim();
  final dateTo = (req.uri.queryParameters['date_to'] ?? '').trim();
  final pageSize = _safePageSize(req.uri.queryParameters['page_size']);
  final page = _safePage(req.uri.queryParameters['page']);

  final since = int.tryParse(actualSince);
  final until = int.tryParse(actualUntil);
  if (since == null || until == null || since <= 0 || until <= 0 || since >= until) {
    _json(req.response, HttpStatus.badRequest, <String, dynamic>{
      'error': 'bad_request',
      'message': 'actual_since/actual_until are required unix timestamps',
    });
    return;
  }

  _evictExpiredCache();
  final cacheKey = '$location:$since:$until:$pageSize:$page';
  final now = DateTime.now();
  final cached = _cache[cacheKey];
  if (cached != null && now.difference(cached.fetchedAt) < _ttl) {
    req.response.headers.set('x-events-cache', 'HIT');
    _writeRaw(req.response, cached.statusCode, cached.body);
    return;
  }

  final target = Uri.parse('https://kudago.com/public-api/v1.4/events/').replace(
    queryParameters: <String, String>{
      'lang': 'ru',
      'location': location,
      'actual_since': since.toString(),
      'actual_until': until.toString(),
      if (dateFrom.isNotEmpty) 'date_from': dateFrom,
      if (dateTo.isNotEmpty) 'date_to': dateTo,
      'page_size': pageSize.toString(),
      'page': page.toString(),
      'order_by': 'dates',
      'text_format': 'text',
      'fields': 'id,title,dates,place,categories,site_url',
      'expand': 'place',
    },
  );

  stdout.writeln(
    '[events-proxy] fetch location=$location day=$since..$until page=$page',
  );

  try {
    final upstream = await _fetchUpstream(target);
    stdout.writeln(
      '[events-proxy] upstream status=${upstream.statusCode} bytes=${upstream.body.length} page=$page',
    );
    if (upstream.statusCode >= 200 && upstream.statusCode < 300 && upstream.body.isNotEmpty) {
      _cache[cacheKey] = _CacheEntry(
        statusCode: upstream.statusCode,
        body: upstream.body,
        fetchedAt: now,
      );
      req.response.headers.set('x-events-cache', 'MISS');
    }
    _writeRaw(req.response, upstream.statusCode, upstream.body);
  } catch (e) {
    _json(req.response, HttpStatus.badGateway, <String, dynamic>{
      'error': 'upstream_unavailable',
      'message': e.toString(),
    });
  }
}

Future<void> _handleEventsOfDay(HttpRequest req) async {
  final location = (req.uri.queryParameters['location'] ?? 'msk').trim();
  final date = (req.uri.queryParameters['date'] ?? '').trim();
  final pageSize = _safePageSize(req.uri.queryParameters['page_size']);
  final page = _safePage(req.uri.queryParameters['page']);

  if (date.isEmpty) {
    _json(req.response, HttpStatus.badRequest, <String, dynamic>{
      'error': 'bad_request',
      'message': 'date is required in YYYY-MM-DD',
    });
    return;
  }

  _evictExpiredCache();
  final cacheKey = 'events_of_day:$location:$date:$pageSize:$page';
  final now = DateTime.now();
  final cached = _cache[cacheKey];
  if (cached != null && now.difference(cached.fetchedAt) < _ttl) {
    req.response.headers.set('x-events-cache', 'HIT');
    _writeRaw(req.response, cached.statusCode, cached.body);
    return;
  }

  final target = Uri.parse('https://kudago.com/public-api/v1.4/events-of-the-day/').replace(
    queryParameters: <String, String>{
      'lang': 'ru',
      'location': location,
      'date': date,
      'page_size': pageSize.toString(),
      'page': page.toString(),
      'expand': 'event',
      'text_format': 'text',
    },
  );

  stdout.writeln(
    '[events-proxy] fetch events_of_day location=$location date=$date page=$page',
  );

  try {
    final upstream = await _fetchUpstream(target);
    stdout.writeln(
      '[events-proxy] upstream events_of_day status=${upstream.statusCode} bytes=${upstream.body.length} page=$page',
    );

    if (upstream.statusCode < 200 || upstream.statusCode >= 300 || upstream.body.isEmpty) {
      _writeRaw(req.response, upstream.statusCode, upstream.body);
      return;
    }

    final decoded = jsonDecode(upstream.body);
    if (decoded is! Map<String, dynamic>) {
      _json(req.response, HttpStatus.badGateway, <String, dynamic>{
        'error': 'upstream_malformed',
        'message': 'events_of_day malformed response',
      });
      return;
    }

    final results = decoded['results'];
    if (results is! List) {
      _json(req.response, HttpStatus.badGateway, <String, dynamic>{
        'error': 'upstream_malformed',
        'message': 'events_of_day malformed results',
      });
      return;
    }

    final flat = <Map<String, dynamic>>[];
    for (final raw in results) {
      if (raw is! Map) continue;
      final row = Map<String, dynamic>.from(raw);
      final eventRaw = row['event'] ?? row['object'];
      if (eventRaw is! Map) continue;
      final objectMap = Map<String, dynamic>.from(eventRaw);
      final overrideTitle = row['title']?.toString().trim();
      if (overrideTitle != null && overrideTitle.isNotEmpty) {
        objectMap['title'] = overrideTitle;
      }
      final normalized = await _normalizeEventPayload(objectMap);
      if (normalized != null) {
        flat.add(normalized);
      }
    }
    stdout.writeln(
      '[events-proxy] events_of_day rows=${results.length} flattened=${flat.length} page=$page',
    );

    final out = jsonEncode(<String, dynamic>{
      'count': flat.length,
      'next': decoded['next'],
      'previous': decoded['previous'],
      'results': flat,
    });

    _cache[cacheKey] = _CacheEntry(
      statusCode: HttpStatus.ok,
      body: out,
      fetchedAt: now,
    );
    req.response.headers.set('x-events-cache', 'MISS');
    _writeRaw(req.response, HttpStatus.ok, out);
  } catch (e) {
    _json(req.response, HttpStatus.badGateway, <String, dynamic>{
      'error': 'upstream_unavailable',
      'message': e.toString(),
    });
  }
}

Future<Map<String, dynamic>?> _normalizeEventPayload(
  Map<String, dynamic> raw,
) async {
  final hasRichFields = raw['title'] != null && raw['dates'] is List;
  if (hasRichFields) return raw;

  final id = raw['id']?.toString();
  if (id == null || id.isEmpty) return null;
  final detailed = await _fetchEventById(id);
  if (detailed == null) return null;
  return detailed;
}

Future<Map<String, dynamic>?> _fetchEventById(String id) async {
  final uri = Uri.parse('https://kudago.com/public-api/v1.4/events/$id/').replace(
    queryParameters: <String, String>{
      'lang': 'ru',
      'text_format': 'text',
      'fields': 'id,title,dates,place,categories,site_url',
      'expand': 'place',
    },
  );
  try {
    final upstream = await _fetchUpstream(uri);
    if (upstream.statusCode < 200 || upstream.statusCode >= 300) {
      stdout.writeln('[events-proxy] event/$id status=${upstream.statusCode}');
      return null;
    }
    final decoded = jsonDecode(upstream.body);
    if (decoded is! Map<String, dynamic>) {
      stdout.writeln('[events-proxy] event/$id malformed payload');
      return null;
    }
    stdout.writeln('[events-proxy] event/$id detailed payload received');
    return decoded;
  } catch (e) {
    stdout.writeln('[events-proxy] event/$id fetch failed: $e');
    return null;
  }
}

Future<_UpstreamResponse> _fetchUpstream(Uri uri) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await client.getUrl(uri).timeout(const Duration(seconds: 12));
    req.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final res = await req.close().timeout(const Duration(seconds: 15));
    final bytes = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    final body = utf8.decode(bytes);
    return _UpstreamResponse(statusCode: res.statusCode, body: body);
  } finally {
    client.close(force: true);
  }
}

void _setCors(HttpResponse res) {
  res.headers.set('access-control-allow-origin', '*');
  res.headers.set('access-control-allow-methods', 'GET, OPTIONS');
  res.headers.set('access-control-allow-headers', 'Content-Type, Accept');
}

void _json(HttpResponse res, int statusCode, Map<String, dynamic> body) {
  _writeRaw(res, statusCode, jsonEncode(body));
}

void _writeRaw(HttpResponse res, int statusCode, String body) {
  res.statusCode = statusCode;
  res.headers.contentType = ContentType.json;
  res.write(body);
  unawaited(res.close());
}

int _safePageSize(String? raw) {
  final v = int.tryParse(raw ?? '') ?? 100;
  if (v < 1) return 1;
  if (v > 200) return 200;
  return v;
}

int _safePage(String? raw) {
  final v = int.tryParse(raw ?? '') ?? 1;
  if (v < 1) return 1;
  if (v > 1000) return 1000;
  return v;
}

void _evictExpiredCache() {
  final now = DateTime.now();
  final expired = <String>[];
  for (final e in _cache.entries) {
    if (now.difference(e.value.fetchedAt) >= _ttl) {
      expired.add(e.key);
    }
  }
  for (final key in expired) {
    _cache.remove(key);
  }
}

class _UpstreamResponse {
  final int statusCode;
  final String body;

  const _UpstreamResponse({
    required this.statusCode,
    required this.body,
  });
}
