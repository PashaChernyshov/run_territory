# run_territory

Interactive event map built with `Flutter`.

`run_territory` is a map-first application for exploring city events in a visual way. The project combines a Flutter UI, map rendering, city-based presets, local preference persistence, and a lightweight proxy for loading live event data in the browser without CORS issues.

## What the Project Does

- displays an interactive city map
- works with city-specific map defaults and styles
- loads event data for the selected location
- keeps user preferences locally with `shared_preferences`
- includes a local proxy for fetching and caching event data on web

## Tech Stack

- Flutter
- Dart
- flutter_map
- maplibre_gl
- HTTP
- shared_preferences

## Architecture

```text
lib/
  core/
    di/                        dependency wiring
    storage/                   local preferences
  domain/
    models/                    city and map models
  features/home/
    application/               controller and use cases
    data/                      repository layer
    presentation/              map screen and UI
tool/
  events_proxy.dart            local proxy for event loading and caching
```

## Local Run

Install dependencies:

```bash
flutter pub get
```

Run on a local web server:

```bash
flutter run -d web-server --web-hostname 0.0.0.0 --web-port 8080
```

Open in the browser:

```text
http://localhost:8080
```

## Live Events on Web

For browser-based event loading, start the local proxy:

```bash
dart run tool/events_proxy.dart
```

The proxy starts at:

```text
http://0.0.0.0:8787/events
```

It is used to:

- bypass CORS restrictions
- cache upstream responses for a short period
- make local network testing easier

## Testing on Another Device in the Same Wi-Fi Network

1. Find your computer's local IP address, for example `192.168.1.42`.
2. Open the app on the phone with `http://192.168.1.42:8080`.
3. Keep the proxy running on the same computer so the app can request event data through `http://192.168.1.42:8787/events`.

## Project Positioning

This repository is best described as:

- a Flutter event-map prototype
- a location-aware city discovery interface
- a foundation for a culture, nightlife, or city guide product
