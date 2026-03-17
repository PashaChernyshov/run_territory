import 'package:latlong2/latlong.dart';

class City {
  final String id;
  final String name;
  final String region;
  final LatLng center;
  final double defaultZoom;
  final int seed;

  const City({
    required this.id,
    required this.name,
    required this.region,
    required this.center,
    required this.defaultZoom,
    required this.seed,
  });
}

class CityDefaults {
  static List<City> russiaMajor() => const [
    City(
      id: 'moscow',
      name: 'Москва',
      region: 'Москва',
      center: LatLng(55.751244, 37.618423),
      defaultZoom: 13.6,
      seed: 101,
    ),
    City(
      id: 'spb',
      name: 'Санкт-Петербург',
      region: 'Ленинградская область',
      center: LatLng(59.93863, 30.31413),
      defaultZoom: 13.7,
      seed: 102,
    ),
    City(
      id: 'kazan',
      name: 'Казань',
      region: 'Татарстан',
      center: LatLng(55.796127, 49.106405),
      defaultZoom: 13.8,
      seed: 103,
    ),
    City(
      id: 'novosibirsk',
      name: 'Новосибирск',
      region: 'Новосибирская область',
      center: LatLng(55.008353, 82.935733),
      defaultZoom: 13.6,
      seed: 104,
    ),
    City(
      id: 'ekb',
      name: 'Екатеринбург',
      region: 'Свердловская область',
      center: LatLng(56.838926, 60.605703),
      defaultZoom: 13.6,
      seed: 105,
    ),
    City(
      id: 'nizhny',
      name: 'Нижний Новгород',
      region: 'Нижегородская область',
      center: LatLng(56.296504, 43.936059),
      defaultZoom: 13.6,
      seed: 106,
    ),
    City(
      id: 'samara',
      name: 'Самара',
      region: 'Самарская область',
      center: LatLng(53.195873, 50.100193),
      defaultZoom: 13.6,
      seed: 107,
    ),
    City(
      id: 'ufa',
      name: 'Уфа',
      region: 'Башкортостан',
      center: LatLng(54.738762, 55.972055),
      defaultZoom: 13.6,
      seed: 108,
    ),
    City(
      id: 'perm',
      name: 'Пермь',
      region: 'Пермский край',
      center: LatLng(58.010455, 56.229443),
      defaultZoom: 13.6,
      seed: 109,
    ),
    City(
      id: 'rostov',
      name: 'Ростов-на-Дону',
      region: 'Ростовская область',
      center: LatLng(47.235713, 39.701505),
      defaultZoom: 13.6,
      seed: 110,
    ),
    City(
      id: 'krasnodar',
      name: 'Краснодар',
      region: 'Краснодарский край',
      center: LatLng(45.03547, 38.975313),
      defaultZoom: 13.6,
      seed: 111,
    ),
    City(
      id: 'sochi',
      name: 'Сочи',
      region: 'Краснодарский край',
      center: LatLng(43.585525, 39.723062),
      defaultZoom: 13.8,
      seed: 112,
    ),
    City(
      id: 'voronezh',
      name: 'Воронеж',
      region: 'Воронежская область',
      center: LatLng(51.660781, 39.200296),
      defaultZoom: 13.6,
      seed: 113,
    ),
    City(
      id: 'volgograd',
      name: 'Волгоград',
      region: 'Волгоградская область',
      center: LatLng(48.708048, 44.513303),
      defaultZoom: 13.6,
      seed: 114,
    ),
    City(
      id: 'krasnoyarsk',
      name: 'Красноярск',
      region: 'Красноярский край',
      center: LatLng(56.015283, 92.893248),
      defaultZoom: 13.6,
      seed: 115,
    ),
    City(
      id: 'omsk',
      name: 'Омск',
      region: 'Омская область',
      center: LatLng(54.98848, 73.324236),
      defaultZoom: 13.6,
      seed: 116,
    ),
  ];
}

class MapStyle {
  final String id;
  final String title;
  final String urlTemplate;
  final String mapLibreStyleUrl;
  final List<String> subdomains;

  const MapStyle({
    required this.id,
    required this.title,
    required this.urlTemplate,
    required this.mapLibreStyleUrl,
    required this.subdomains,
  });

  static const standard = MapStyle(
    id: 'standard',
    title: 'Стандартная',
    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    mapLibreStyleUrl: 'https://tiles.openfreemap.org/styles/liberty?language=ru',
    subdomains: [],
  );

  static const light = MapStyle(
    id: 'light',
    title: 'Светлая',
    urlTemplate:
        'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png',
    mapLibreStyleUrl: 'https://tiles.openfreemap.org/styles/liberty?language=ru',
    subdomains: ['a', 'b', 'c', 'd'],
  );

  static const dark = MapStyle(
    id: 'dark',
    title: 'Темная',
    urlTemplate:
        'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png',
    mapLibreStyleUrl: 'https://tiles.openfreemap.org/styles/liberty?language=ru',
    subdomains: ['a', 'b', 'c', 'd'],
  );

  static const ultraDark = MapStyle(
    id: 'ultra_dark',
    title: 'Ультра темная',
    urlTemplate:
        'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png',
    mapLibreStyleUrl: 'https://tiles.openfreemap.org/styles/liberty?language=ru',
    subdomains: ['a', 'b', 'c', 'd'],
  );

  // Backward compatibility for already persisted values.
  static const osmDark = standard;
  static const cartoDark = dark;
  static const cartoLight = light;

  static MapStyle byId(String id) {
    switch (id) {
      case 'standard':
        return light;
      case 'light':
        return light;
      case 'dark':
        return dark;
      case 'ultra_dark':
        return dark;
      case 'ofm_liberty':
        return light;
      case 'ofm_bright':
        return light;
      case 'ofm_positron':
        return light;
      case 'carto_dark':
        return dark;
      case 'carto_light':
        return light;
      case 'osm':
      default:
        return light;
    }
  }

  MapStyle next() {
    if (id == 'dark' || id == 'ultra_dark' || id == 'carto_dark') return light;
    return dark;
  }
}
