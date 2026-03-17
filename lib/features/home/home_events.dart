import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class CityEvent {
  final String id;
  final String title;
  final String venue;
  final DateTime startsAt;
  final DateTime? endsAt;
  final String category;
  final String? url;

  const CityEvent({
    required this.id,
    required this.title,
    required this.venue,
    required this.startsAt,
    required this.endsAt,
    required this.category,
    required this.url,
  });
}

class CityEventsService {
  static final Map<String, _CacheEntry> _cache = <String, _CacheEntry>{};
  static final Map<String, Future<List<CityEvent>>> _inFlight =
      <String, Future<List<CityEvent>>>{};
  static const Duration _ttl = Duration(minutes: 10);
  static const int _pageSize = 100;
  static const int _maxPages = 12;

  Future<List<CityEvent>> fetchEvents({
    required String cityId,
    required DateTime day,
    bool forceRefresh = false,
  }) async {
    debugPrint('[events] fetch start cityId=$cityId day=$day');
    final cityCode = _cityCode(cityId);
    final key = '$cityCode:${_dayKey(day)}';
    final now = DateTime.now();

    final cached = _cache[key];
    if (!forceRefresh &&
        cached != null &&
        now.difference(cached.fetchedAt) < _ttl) {
      debugPrint(
        '[events] cache hit key=$key age=${now.difference(cached.fetchedAt).inMinutes}m',
      );
      return cached.items;
    }

    if (!forceRefresh) {
      final existing = _inFlight[key];
      if (existing != null) {
        debugPrint('[events] join in-flight key=$key');
        return existing;
      }
    }

    final future = _fetchAndCacheWithRetry(
      cityCode: cityCode,
      day: day,
      key: key,
      now: now,
    );
    _inFlight[key] = future;
    try {
      return await future;
    } catch (e) {
      if (cached != null) {
        debugPrint('[events] use stale cache key=$key due to error: $e');
        return cached.items;
      }
      rethrow;
    } finally {
      _inFlight.remove(key);
    }
  }

  Future<List<CityEvent>> _fetchAndCacheWithRetry({
    required String cityCode,
    required DateTime day,
    required String key,
    required DateTime now,
  }) async {
    try {
      return await _fetchAndCache(
        cityCode: cityCode,
        day: day,
        key: key,
        now: now,
      );
    } catch (e) {
      debugPrint('[events] first attempt failed, retrying once: $e');
      await Future<void>.delayed(const Duration(milliseconds: 700));
      return _fetchAndCache(
        cityCode: cityCode,
        day: day,
        key: key,
        now: DateTime.now(),
      );
    }
  }

  Future<List<CityEvent>> _fetchAndCache({
    required String cityCode,
    required DateTime day,
    required String key,
    required DateTime now,
  }) async {
    final dayStart = DateTime(day.year, day.month, day.day);
    final dayEnd = dayStart.add(const Duration(days: 1));
    final dayStartTs = dayStart.millisecondsSinceEpoch ~/ 1000;
    final dayEndTs = dayEnd.millisecondsSinceEpoch ~/ 1000;
    final dayStartIso = _isoDay(dayStart);
    final dayEndIso = _isoDay(dayEnd);
    final baseQuery = <String, String>{
      'lang': 'ru',
      'location': cityCode,
      'actual_since': dayStartTs.toString(),
      'actual_until': dayEndTs.toString(),
      'date_from': dayStartIso,
      'date_to': dayEndIso,
      'page_size': '$_pageSize',
      'order_by': 'dates',
      'text_format': 'text',
      'fields': 'id,title,dates,place,categories,site_url',
      'expand': 'place',
    };

    final allRows = await _fetchAllRows(
      path: '/public-api/v1.4/events/',
      baseQuery: baseQuery,
    );
    debugPrint(
      '[events] rowsTotal=${allRows.length} cityCode=$cityCode dayKey=${_dayKey(day)}',
    );

    final items = <CityEvent>[];
    final seen = <String>{};
    _appendEventsFromRows(
      out: items,
      seen: seen,
      rows: allRows,
      dayStartTs: dayStartTs,
      dayEndTs: dayEndTs,
      allowOverlapFallback: false,
    );

    if (items.isEmpty) {
      debugPrint('[events] events list empty, fallback to events-of-the-day');
      final dayIso = _isoDay(dayStart);
      final fallbackRows = await _fetchAllRows(
        path: '/public-api/v1.4/events-of-the-day/',
        baseQuery: <String, String>{
          'lang': 'ru',
          'location': cityCode,
          'date': dayIso,
          'page_size': '$_pageSize',
        },
      );
      _appendEventsFromRows(
        out: items,
        seen: seen,
        rows: fallbackRows,
        dayStartTs: dayStartTs,
        dayEndTs: dayEndTs,
        allowOverlapFallback: true,
      );
    }

    items.sort((a, b) => a.startsAt.compareTo(b.startsAt));
    final out = List<CityEvent>.unmodifiable(items);
    _cache[key] = _CacheEntry(items: out, fetchedAt: now);
    debugPrint('[events] parsed items=${out.length} cached key=$key');
    return out;
  }

  Future<List<Map<String, dynamic>>> _fetchAllRows({
    required String path,
    required Map<String, String> baseQuery,
  }) async {
    final allRows = <Map<String, dynamic>>[];
    for (int page = 1; page <= _maxPages; page++) {
      final uri = Uri.parse('https://kudago.com$path').replace(
        queryParameters: <String, String>{
          ...baseQuery,
          'page': '$page',
        },
      );

      final res = await _getWithFallback(uri).timeout(
        const Duration(seconds: 16),
        onTimeout: () {
          throw Exception('Events timeout after 16s');
        },
      );

      final decoded = jsonDecode(res.body);
      if (decoded is! Map<String, dynamic>) {
        throw Exception('Events API malformed response');
      }
      final rows = decoded['results'];
      if (rows is! List) {
        throw Exception('Events API malformed results');
      }

      for (final raw in rows) {
        if (raw is Map) {
          allRows.add(Map<String, dynamic>.from(raw));
        }
      }

      final hasNext = decoded['next'] != null;
      if (!hasNext || rows.length < _pageSize) {
        break;
      }
    }
    return allRows;
  }

  void _appendEventsFromRows({
    required List<CityEvent> out,
    required Set<String> seen,
    required List<Map<String, dynamic>> rows,
    required int dayStartTs,
    required int dayEndTs,
    required bool allowOverlapFallback,
  }) {
    for (final map in rows) {
      final id = map['id']?.toString();
      final title = map['title']?.toString();
      if (id == null || id.isEmpty || title == null || title.trim().isEmpty) {
        continue;
      }

      final dateSlot = _pickSlotForDay(
        rawDates: map['dates'],
        dayStartTs: dayStartTs,
        dayEndTs: dayEndTs,
        allowOverlapFallback: allowOverlapFallback,
      );
      if (dateSlot == null) continue;

      final startsAt = DateTime.fromMillisecondsSinceEpoch(
        dateSlot.startTs * 1000,
      );
      final endsAt = dateSlot.endTs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(dateSlot.endTs! * 1000);

      String venue = 'Локация уточняется';
      final place = map['place'];
      if (place is Map && place['title'] != null) {
        final t = place['title'].toString().trim();
        if (t.isNotEmpty) venue = t;
      }

      String category = 'Событие';
      final categories = map['categories'];
      if (categories is List && categories.isNotEmpty) {
        category = _categoryRu(categories.first.toString());
      }

      final url = map['site_url']?.toString();
      final dedupeKey = '$id|${startsAt.millisecondsSinceEpoch}|${title.trim().toLowerCase()}';
      if (!seen.add(dedupeKey)) continue;

      out.add(
        CityEvent(
          id: id,
          title: title.trim(),
          venue: venue,
          startsAt: startsAt,
          endsAt: endsAt,
          category: category,
          url: (url == null || url.isEmpty) ? null : url,
        ),
      );
    }
  }

  Future<http.Response> _getWithFallback(Uri target) async {
    final groups = _fallbackGroups(target);
    for (int i = 0; i < groups.length; i++) {
      final group = groups[i];
      final winner = await _raceForFirstValid(group);
      if (winner != null) {
        debugPrint(
          '[events] group ${i + 1}/${groups.length} success: ${winner.request?.url ?? 'unknown'}',
        );
        return winner;
      }
      debugPrint(
        '[events] group ${i + 1}/${groups.length} produced no valid response',
      );
    }
    throw Exception('Events API unavailable from all sources');
  }

  List<List<Uri>> _fallbackGroups(Uri target) {
    final local = _localProxyUris(target);
    final localNetwork = local.where((u) => u.hasAuthority).toList(growable: false);
    final allOrigins = Uri.parse(
      'https://api.allorigins.win/raw?url=${Uri.encodeComponent(target.toString())}',
    );
    final isomorphic = Uri.parse(
      'https://cors.isomorphic-git.org/${target.toString()}',
    );

    if (kIsWeb) {
      if (localNetwork.isNotEmpty) {
        // Web in local dev: rely on local proxy first to avoid CORS chains.
        return <List<Uri>>[localNetwork];
      }
      return <List<Uri>>[
        <Uri>[allOrigins, isomorphic],
        <Uri>[target],
      ];
    }

    return <List<Uri>>[
      <Uri>[target],
      <Uri>[allOrigins, isomorphic],
      local.where((u) => u.hasAuthority).toList(growable: false),
    ];
  }

  Future<http.Response?> _raceForFirstValid(List<Uri> candidates) async {
    if (candidates.isEmpty) return null;

    final completer = Completer<http.Response?>();
    var left = candidates.length;
    var maxTimeout = const Duration(seconds: 8);

    for (final uri in candidates) {
      final t = _timeoutForUri(uri);
      if (t > maxTimeout) {
        maxTimeout = t;
      }
      _fetchCandidate(uri).then((res) {
        if (res != null && !completer.isCompleted) {
          completer.complete(res);
          return;
        }
        left -= 1;
        if (left == 0 && !completer.isCompleted) {
          completer.complete(null);
        }
      });
    }

    return completer.future.timeout(
      maxTimeout + const Duration(seconds: 2),
      onTimeout: () => null,
    );
  }

  Future<http.Response?> _fetchCandidate(Uri uri) async {
    debugPrint('[events] try $uri');
    try {
      final res = await http
          .get(
            uri,
            headers: const {'accept': 'application/json'},
          )
          .timeout(_timeoutForUri(uri));

      if (res.statusCode < 200 || res.statusCode >= 300 || res.body.isEmpty) {
        debugPrint('[events] bad status=${res.statusCode} from $uri');
        return null;
      }

      final parsed = _tryParseJsonMap(res.body);
      if (parsed == null || parsed['results'] is! List) {
        debugPrint('[events] non-events payload from $uri');
        return null;
      }
      return res;
    } catch (e) {
      debugPrint('[events] failed $uri: $e');
      return null;
    }
  }

  Duration _timeoutForUri(Uri uri) {
    final host = uri.host.toLowerCase();
    final isLocalHost = host == 'localhost' || host == '127.0.0.1';
    final isLocalProxy = isLocalHost && uri.port == 8787;
    if (isLocalProxy) {
      return const Duration(seconds: 14);
    }
    if (isLocalHost) {
      return const Duration(seconds: 3);
    }
    if (host == 'kudago.com') {
      return const Duration(seconds: 7);
    }
    if (host.contains('allorigins') || host.contains('isomorphic-git')) {
      return const Duration(seconds: 8);
    }
    if (!uri.hasAuthority) {
      return const Duration(seconds: 6);
    }
    return const Duration(seconds: 7);
  }

  List<Uri> _localProxyUris(Uri target) {
    // Local proxy currently supports /events and /events-of-the-day endpoints.
    final targetPath = target.path.toLowerCase();
    late final String localPath;
    if (targetPath.contains('/events-of-the-day')) {
      localPath = '/events_of_day';
    } else if (targetPath.contains('/events')) {
      localPath = '/events';
    } else {
      return const <Uri>[];
    }
    final qp = target.queryParameters;
    if (qp.isEmpty) return const <Uri>[];

    final localQp = Map<String, String>.from(qp);
    final baseHostProxy = _baseHostProxyUri(localQp);

    final out = <Uri>[
      if (baseHostProxy != null)
        baseHostProxy.replace(path: localPath),
      if (!kIsWeb)
        Uri.parse('http://127.0.0.1:8787$localPath')
            .replace(queryParameters: localQp),
      if (!kIsWeb)
        Uri.parse('http://localhost:8787$localPath')
            .replace(queryParameters: localQp),
    ];
    final seen = <String>{};
    return out.where((u) => seen.add(u.toString())).toList(growable: false);
  }

  Uri? _baseHostProxyUri(Map<String, String> qp) {
    if (!kIsWeb) return null;
    final host = Uri.base.host.trim();
    if (host.isEmpty) return null;

    return Uri(
      scheme: 'http',
      host: host,
      port: 8787,
      path: '/events',
      queryParameters: qp,
    );
  }

  Map<String, dynamic>? _tryParseJsonMap(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      return null;
    } catch (_) {
      return null;
    }
  }

  _DateBounds? _pickSlotForDay({
    required Object? rawDates,
    required int dayStartTs,
    required int dayEndTs,
    required bool allowOverlapFallback,
  }) {
    if (rawDates is! List || rawDates.isEmpty) return null;

    _DateBounds? best;
    _DateBounds? midnightBest;
    _DateBounds? overlapBest;
    for (final raw in rawDates) {
      if (raw is! Map) continue;
      final row = Map<String, dynamic>.from(raw);
      final start = _toInt(row['start']);
      if (start == null) continue;

      final end = _toInt(row['end']) ?? start;
      final startsWithinDay = start >= dayStartTs && start < dayEndTs;
      if (startsWithinDay) {
        final candidate = _DateBounds(startTs: start, endTs: end);
        final dt = DateTime.fromMillisecondsSinceEpoch(start * 1000);
        final isMidnight = dt.hour == 0 && dt.minute == 0;
        if (isMidnight) {
          if (midnightBest == null || candidate.startTs < midnightBest.startTs) {
            midnightBest = candidate;
          }
        } else {
          if (best == null || candidate.startTs < best.startTs) {
            best = candidate;
          }
        }
      } else if (allowOverlapFallback) {
        final overlapsDay = end > dayStartTs && start < dayEndTs;
        if (!overlapsDay) continue;
        final approximateStart = dayStartTs + 12 * 60 * 60;
        final candidate = _DateBounds(
          startTs: approximateStart,
          endTs: end,
        );
        if (overlapBest == null || candidate.startTs < overlapBest.startTs) {
          overlapBest = candidate;
        }
      }
    }

    return best ?? midnightBest ?? overlapBest;
  }

  static int? _toInt(Object? raw) {
    int? v;
    if (raw is int) {
      v = raw;
    } else if (raw is num) {
      v = raw.toInt();
    } else if (raw != null) {
      v = int.tryParse(raw.toString());
    }
    if (v == null) return null;
    // Accept both seconds and milliseconds unix epoch.
    if (v > 1000000000000) {
      return v ~/ 1000;
    }
    return v;
  }

  static String _isoDay(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }

  static String _dayKey(DateTime d) => '${d.year}-${d.month}-${d.day}';

  static String _cityCode(String cityId) {
    switch (cityId) {
      case 'moscow':
        return 'msk';
      case 'spb':
        return 'spb';
      case 'kazan':
        return 'kzn';
      case 'ekb':
        return 'ekb';
      case 'novosibirsk':
        return 'nsk';
      case 'nizhny':
        return 'nnv';
      case 'samara':
        return 'smr';
      case 'ufa':
        return 'ufa';
      case 'perm':
        return 'ekb';
      case 'rostov':
        return 'krd';
      case 'krasnodar':
        return 'krd';
      case 'sochi':
        return 'sochi';
      case 'voronezh':
        return 'msk';
      case 'volgograd':
        return 'msk';
      case 'krasnoyarsk':
        return 'krasnoyarsk';
      case 'omsk':
        return 'nsk';
      default:
        return 'msk';
    }
  }

  static String _categoryRu(String c) {
    switch (c.toLowerCase()) {
      case 'concert':
        return 'Концерт';
      case 'party':
        return 'Вечеринка';
      case 'festival':
        return 'Фестиваль';
      case 'exhibition':
        return 'Выставка';
      case 'education':
        return 'Образование';
      case 'lecture':
        return 'Лекция';
      case 'workshop':
      case 'master-class':
      case 'masterclass':
        return 'Мастер-класс';
      case 'theater':
      case 'theatre':
        return 'Театр';
      case 'tour':
        return 'Экскурсия';
      case 'movie':
      case 'cinema':
        return 'Кино';
      case 'kids':
        return 'Для детей';
      case 'quest':
        return 'Квест';
      case 'sport':
        return 'Спорт';
      case 'market':
        return 'Маркет';
      default:
        return 'Событие';
    }
  }
}

class _CacheEntry {
  final List<CityEvent> items;
  final DateTime fetchedAt;

  const _CacheEntry({
    required this.items,
    required this.fetchedAt,
  });
}

class _DateBounds {
  final int startTs;
  final int? endTs;

  const _DateBounds({
    required this.startTs,
    required this.endTs,
  });
}
