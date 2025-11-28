import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

void main() {
  runApp(const CariTambalApp());
}

class CariTambalApp extends StatelessWidget {
  const CariTambalApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cari Tambal',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const WorkshopLocatorPage(),
    );
  }
}

class WorkshopLocatorPage extends StatefulWidget {
  const WorkshopLocatorPage({super.key});

  @override
  State<WorkshopLocatorPage> createState() => _WorkshopLocatorPageState();
}

class _WorkshopLocatorPageState extends State<WorkshopLocatorPage> {
  static const _googlePlacesApiKey = String.fromEnvironment('GOOGLE_MAPS_API_KEY');
  static const _defaultRadiusMeters = 5000;

  GoogleMapController? _mapController;
  Position? _currentPosition;
  List<WorkshopPlace> _places = const [];
  bool _isLoading = true;
  _ErrorState? _errorState;

  @override
  void initState() {
    super.initState();
    _initLocationAndSearch();
  }

  @override
  void dispose() {
    _mapController?.dispose();
    super.dispose();
  }

  Future<void> _initLocationAndSearch() async {
    _safeSetState(() {
      _isLoading = true;
      _errorState = null;
    });

    try {
      final position = await _determinePosition();
      if (!mounted) return;

      _safeSetState(() => _currentPosition = position);

      final places = await PlacesRepository(apiKey: _googlePlacesApiKey)
          .fetchNearbyWorkshops(position, radiusMeters: _defaultRadiusMeters);

      if (!mounted) return;

      _safeSetState(() {
        _places = places;
        _errorState = places.isEmpty
            ? _ErrorState(
                message: 'Tidak ada bengkel/tambal ban dalam radius.',
                actions: [
                  _ErrorAction(
                    label: 'Coba lagi',
                    icon: Icons.refresh,
                    onPressed: _initLocationAndSearch,
                  ),
                ],
              )
            : null;
      });

      if (places.isNotEmpty) {
        _fitCameraToResults(focus: places.first.location);
      }
    } on LocationPermissionDeniedException catch (e) {
      _setError(
        e.message,
        actions: [
          _ErrorAction(
            label: 'Buka Pengaturan Aplikasi',
            icon: Icons.app_settings_alt,
            onPressed: () async {
              await Geolocator.openAppSettings();
            },
          ),
        ],
      );
    } on LocationServiceDisabledException catch (e) {
      _setError(
        e.message,
        actions: [
          _ErrorAction(
            label: 'Buka Pengaturan Lokasi',
            icon: Icons.location_on,
            onPressed: () async {
              await Geolocator.openLocationSettings();
            },
          ),
        ],
      );
    } on PlacesApiKeyMissingException catch (e) {
      _setError(e.message);
    } on PlacesException catch (e) {
      _setError(e.message);
    } catch (e) {
      _setError('Terjadi kesalahan: $e');
    } finally {
      _safeSetState(() => _isLoading = false);
    }
  }

  Future<Position> _determinePosition() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw LocationServiceDisabledException();
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied) {
      throw LocationPermissionDeniedException();
    }

    if (permission == LocationPermission.deniedForever) {
      throw LocationPermissionDeniedException(
        message:
            'Izin lokasi ditolak permanen. Buka pengaturan untuk mengaktifkan akses lokasi.',
      );
    }

    return Geolocator.getCurrentPosition();
  }

  void _fitCameraToResults({LatLng? focus}) {
    if (_mapController == null) return;

    final points = <LatLng>[
      if (_currentPosition != null)
        LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
      ..._places.map((place) => place.location),
      if (focus != null) focus,
    ];

    if (points.isEmpty) return;

    // When we only have one point, center on it with a reasonable zoom.
    if (points.length == 1) {
      _mapController!.animateCamera(
        CameraUpdate.newLatLngZoom(points.first, 15),
      );
      return;
    }

    var south = points.first.latitude;
    var north = points.first.latitude;
    var west = points.first.longitude;
    var east = points.first.longitude;

    for (final point in points.skip(1)) {
      south = south < point.latitude ? south : point.latitude;
      north = north > point.latitude ? north : point.latitude;
      west = west < point.longitude ? west : point.longitude;
      east = east > point.longitude ? east : point.longitude;
    }

    if (south == north) {
      south -= 0.001;
      north += 0.001;
    }

    if (west == east) {
      west -= 0.001;
      east += 0.001;
    }

    final bounds = LatLngBounds(
      southwest: LatLng(south, west),
      northeast: LatLng(north, east),
    );

    _mapController!.animateCamera(
      CameraUpdate.newLatLngBounds(bounds, 60),
    );
  }

  Future<void> _onDirectionTap(WorkshopPlace place) async {
    final destination = '${place.location.latitude},${place.location.longitude}';
    final googleMapsUrl = Uri.parse(
      'https://www.google.com/maps/dir/?api=1&destination=$destination&travelmode=driving',
    );

    if (Platform.isIOS) {
      final googleMapsSchemeUrl = Uri.parse('comgooglemaps://?daddr=$destination');
      if (await canLaunchUrl(googleMapsSchemeUrl)) {
        await launchUrl(googleMapsSchemeUrl, mode: LaunchMode.externalApplication);
        return;
      }

      final appleMapsUrl = Uri.parse('http://maps.apple.com/?daddr=$destination&dirflg=d');
      if (await canLaunchUrl(appleMapsUrl)) {
        await launchUrl(appleMapsUrl, mode: LaunchMode.externalApplication);
        return;
      }
    }

    if (await canLaunchUrl(googleMapsUrl)) {
      await launchUrl(googleMapsUrl, mode: LaunchMode.externalApplication);
      return;
    }

    _showMessage('Tidak dapat membuka aplikasi navigasi.');
  }

  Set<Marker> _buildMarkers() {
    final markers = <Marker>{};

    if (_currentPosition != null) {
      markers.add(
        Marker(
          markerId: const MarkerId('current_location'),
          position: LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
          infoWindow: const InfoWindow(title: 'Lokasi Anda'),
        ),
      );
    }

    for (final place in _places) {
      markers.add(
        Marker(
          markerId: MarkerId(place.placeId ?? place.name),
          position: place.location,
          infoWindow: InfoWindow(
            title: place.name,
            snippet: place.address,
          ),
        ),
      );
    }

    return markers;
  }

  Widget _buildStatus() {
    if (_isLoading) {
      return const Expanded(
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final errorState = _errorState;
    if (errorState != null) {
      return Expanded(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  errorState.message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: errorState.actions
                      .map(
                        (action) => ElevatedButton.icon(
                          onPressed: _isLoading
                              ? null
                              : () async {
                                  await action.onPressed();
                                },
                          icon: Icon(action.icon),
                          label: Text(action.label),
                        ),
                      )
                      .toList(),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Expanded(
      child: Column(
        children: [
          SizedBox(
            height: 280,
            child: GoogleMap(
              initialCameraPosition: CameraPosition(
                target: _currentPosition != null
                    ? LatLng(_currentPosition!.latitude, _currentPosition!.longitude)
                    : const LatLng(-6.175392, 106.827153),
                zoom: 13,
              ),
              markers: _buildMarkers(),
              myLocationEnabled: true,
              myLocationButtonEnabled: true,
              onMapCreated: (controller) {
                _mapController = controller;
                _fitCameraToResults();
              },
            ),
          ),
          const SizedBox(height: 12),
          _buildPlacesList(),
        ],
      ),
    );
  }

  Widget _buildPlacesList() {
    if (_places.isEmpty) {
      return const Expanded(
        child: Center(
          child: Text('Tidak ada hasil untuk ditampilkan.'),
        ),
      );
    }

    return Expanded(
      child: ListView.builder(
        itemCount: _places.length,
        itemBuilder: (context, index) {
          final place = _places[index];
          return Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: ListTile(
              onTap: () => _fitCameraToResults(focus: place.location),
              title: Text(place.name),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(place.address),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('${place.distanceInMeters.toStringAsFixed(0)} m'),
                      if (place.rating != null)
                        Row(
                          children: [
                            const Icon(Icons.star, color: Colors.amber, size: 18),
                            Text(place.rating!.toStringAsFixed(1)),
                          ],
                        ),
                    ],
                  ),
                ],
              ),
              trailing: ElevatedButton(
                onPressed: () => _onDirectionTap(place),
                child: const Text('Get Direction'),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cari Tambal & Bengkel Terdekat'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _isLoading ? null : _initLocationAndSearch,
            tooltip: 'Muat ulang lokasi dan pencarian',
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Menampilkan lokasi Anda dan 5 bengkel/tambal ban terdekat dalam radius ${_defaultRadiusMeters / 1000} km.',
                style: const TextStyle(fontSize: 14),
              ),
            ),
          ),
          _buildStatus(),
        ],
      ),
    );
  }

  void _showMessage(String message) {
    final context = this.context;
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void _setError(String message, {List<_ErrorAction> actions = const []}) {
    final hasRetry = actions.any((action) => action.label == 'Coba lagi');
    final mergedActions = [
      ...actions,
      if (!hasRetry)
        _ErrorAction(
          label: 'Coba lagi',
          icon: Icons.refresh,
          onPressed: _initLocationAndSearch,
        ),
    ];

    _safeSetState(
      () => _errorState = _ErrorState(message: message, actions: mergedActions),
    );
  }

  void _safeSetState(VoidCallback fn) {
    if (!mounted) return;
    setState(fn);
  }
}

class _ErrorState {
  const _ErrorState({required this.message, this.actions = const []});

  final String message;
  final List<_ErrorAction> actions;
}

class _ErrorAction {
  const _ErrorAction({
    required this.label,
    required this.onPressed,
    this.icon = Icons.settings,
  });

  final String label;
  final IconData icon;
  final Future<void> Function() onPressed;
}

class WorkshopPlace {
  WorkshopPlace({
    required this.name,
    required this.address,
    required this.location,
    required this.distanceInMeters,
    this.rating,
    this.placeId,
  });

  final String name;
  final String address;
  final LatLng location;
  final double distanceInMeters;
  final double? rating;
  final String? placeId;
}

class PlacesRepository {
  PlacesRepository({required this.apiKey});

  final String apiKey;

  Future<List<WorkshopPlace>> fetchNearbyWorkshops(
    Position position, {
    int radiusMeters = 2000,
  }) async {
    if (apiKey.isEmpty) {
      throw PlacesApiKeyMissingException();
    }

    final uri = Uri.parse(
      'https://maps.googleapis.com/maps/api/place/nearbysearch/json'
      '?location=${position.latitude},${position.longitude}'
      '&radius=$radiusMeters'
      '&keyword=bicycle%20repair%20auto%20repair%20tire%20service'
      '&opennow=true'
      '&key=$apiKey',
    );

    final response = await http.get(uri);
    if (response.statusCode != 200) {
      throw PlacesException('Gagal memuat data lokasi (${response.statusCode}).');
    }

    final jsonBody = jsonDecode(response.body) as Map<String, dynamic>;
    if (jsonBody['status'] != 'OK' && jsonBody['status'] != 'ZERO_RESULTS') {
      throw PlacesException('Gagal memuat data: ${jsonBody['status']}');
    }

    final results = (jsonBody['results'] as List? ?? [])
        .map((e) => e as Map<String, dynamic>)
        .toList();

    final places = results.map((place) {
      final geometry = place['geometry'] as Map<String, dynamic>?;
      final location = geometry?['location'] as Map<String, dynamic>?;
      final lat = (location?['lat'] as num?)?.toDouble();
      final lng = (location?['lng'] as num?)?.toDouble();

      final distance = lat != null && lng != null
          ? Geolocator.distanceBetween(
              position.latitude,
              position.longitude,
              lat,
              lng,
            )
          : double.infinity;

      return WorkshopPlace(
        name: place['name'] as String? ?? 'Tanpa nama',
        address: place['vicinity'] as String? ?? 'Alamat tidak tersedia',
        location: LatLng(lat ?? 0, lng ?? 0),
        distanceInMeters: distance,
        rating: (place['rating'] as num?)?.toDouble(),
        placeId: place['place_id'] as String?,
      );
    }).where((place) => place.distanceInMeters.isFinite).toList();

    places.sort((a, b) => a.distanceInMeters.compareTo(b.distanceInMeters));
    return places.take(5).toList();
  }
}

class PlacesException implements Exception {
  PlacesException(this.message);
  final String message;

  @override
  String toString() => message;
}

class PlacesApiKeyMissingException extends PlacesException {
  PlacesApiKeyMissingException()
      : super(
            'Google Maps API key belum diset. Tambahkan --dart-define=GOOGLE_MAPS_API_KEY=YOUR_KEY saat build/run.');
}

class LocationPermissionDeniedException implements Exception {
  LocationPermissionDeniedException({
    this.message =
        'Izin lokasi ditolak. Kami memerlukan akses lokasi untuk menemukan bengkel terdekat.',
  });

  final String message;

  @override
  String toString() => message;
}

class LocationServiceDisabledException implements Exception {
  LocationServiceDisabledException({
    this.message = 'Layanan GPS tidak aktif. Aktifkan lokasi untuk melanjutkan.',
  });

  final String message;

  @override
  String toString() => message;
}
