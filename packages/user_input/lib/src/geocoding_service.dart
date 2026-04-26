import 'dart:convert';
import 'package:http/http.dart' as http;

class GeocodingService {
  /// Free Nominatim search – returns list of {lat, lon, displayName}.
  Future<List<Map<String, dynamic>>> search(String query) async {
    final uri = Uri.https(
      'nominatim.openstreetmap.org',
      '/search',
      {
        'q': query,
        'format': 'json',
        'limit': '5',
      },
    );
    final response = await http.get(uri, headers: {
      'User-Agent': 'bus_boss_v2/1.0 (your_email@example.com)', // replace with real
    });
    if (response.statusCode != 200) return [];
    final List data = json.decode(response.body);
    return data
        .map((e) => {
              'lat': double.parse(e['lat']),
              'lon': double.parse(e['lon']),
              'displayName': e['display_name'],
            })
        .toList();
  }
}
